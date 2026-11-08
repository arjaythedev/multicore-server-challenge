module main

import crypto.bcrypt
import crypto.hmac
import crypto.sha256
import db.pg
import encoding.base64
import json2
import net.http
import net.urllib
import os
import time
import veb

pub struct Context {
	veb.Context
}

pub struct App {
mut:
	conns       chan &DbConn
	secret      string
	secret_bytes []u8
}

// libpq connections are leased exclusively through the channel. Prepared
// statements are session-scoped, so each slot owns the names registered on its
// physical connection.
struct DbConn {
mut:
	conn     &pg.Conn
	prepared map[string]string
}

struct PreparedSpec {
	query  string
	params int
}

struct Auth {
	id      string
	token   string
	present bool
}

// Return scalar columns and serialize them in V. PostgreSQL still computes
// the same per-request flags and counts, but avoids building nested JSON for
// every article before the response is assembled.
const article_select = "SELECT a.slug,a.title,a.description,a.body,COALESCE((SELECT json_agg(t.name ORDER BY t.name) FROM article_tags at JOIN tags t ON t.id=at.tag_id WHERE at.article_id=a.id),'[]'::json)::text,to_char(a.created_at AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"'),to_char(a.updated_at AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"'),EXISTS(SELECT 1 FROM favorites f WHERE f.article_id=a.id AND f.user_id=$1),(SELECT count(*) FROM favorites f WHERE f.article_id=a.id),u.username,u.bio,u.image,EXISTS(SELECT 1 FROM follows fo WHERE fo.follower_id=$1 AND fo.followee_id=u.id) FROM articles a JOIN users u ON u.id=a.author_id"
const list_select = "a.slug,a.title,a.description,to_char(a.created_at AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"'),to_char(a.updated_at AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"'),COALESCE((SELECT json_agg(t.name ORDER BY t.name) FROM article_tags at JOIN tags t ON t.id=at.tag_id WHERE at.article_id=a.id),'[]'::json)::text,EXISTS(SELECT 1 FROM favorites f WHERE f.article_id=a.id AND f.user_id=$1),(SELECT count(*) FROM favorites f WHERE f.article_id=a.id),u.username,u.bio,u.image,EXISTS(SELECT 1 FROM follows fo WHERE fo.follower_id=$1 AND fo.followee_id=a.author_id)"
const tags_query = "SELECT COALESCE(json_agg(name ORDER BY name),'[]'::json)::text FROM tags"
const profile_query = "SELECT json_build_object('profile',json_build_object('username',u.username,'bio',u.bio,'image',u.image,'following',EXISTS(SELECT 1 FROM follows f WHERE f.follower_id=$1 AND f.followee_id=u.id))) FROM users u WHERE u.username=$2"
const comments_query = "SELECT COALESCE((SELECT json_agg(json_build_object('id',c.id,'createdAt',to_char(c.created_at AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"'),'updatedAt',to_char(c.updated_at AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"'),'body',c.body,'author',json_build_object('username',u.username,'bio',u.bio,'image',u.image,'following',EXISTS(SELECT 1 FROM follows f WHERE f.follower_id=$1 AND f.followee_id=u.id))) ORDER BY c.created_at DESC,c.id DESC) FROM (SELECT * FROM comments WHERE article_id=a.id ORDER BY created_at DESC,id DESC LIMIT 100) c JOIN users u ON u.id=c.author_id),'[]'::json) FROM articles a WHERE a.slug=$2"
const follow_query = "WITH t AS (SELECT id FROM users WHERE username=$2), w AS (INSERT INTO follows(follower_id,followee_id) SELECT $1,id FROM t ON CONFLICT DO NOTHING RETURNING followee_id) SELECT json_build_object('profile',json_build_object('username',u.username,'bio',u.bio,'image',u.image,'following',(EXISTS(SELECT 1 FROM follows f WHERE f.follower_id=$1 AND f.followee_id=u.id) OR EXISTS(SELECT 1 FROM w)))) FROM users u WHERE u.username=$2"
const unfollow_query = "WITH t AS (SELECT id FROM users WHERE username=$2), w AS (DELETE FROM follows WHERE follower_id=$1 AND followee_id=(SELECT id FROM t)) SELECT json_build_object('profile',json_build_object('username',u.username,'bio',u.bio,'image',u.image,'following',false)) FROM users u WHERE u.username=$2"
const comment_create_query = "WITH t AS (SELECT id FROM articles WHERE slug=$1), c AS (INSERT INTO comments(article_id,author_id,body) SELECT id,$2,$3 FROM t RETURNING id,body,created_at,updated_at,author_id) SELECT json_build_object('id',c.id,'body',c.body,'createdAt',to_char(c.created_at AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"'),'updatedAt',to_char(c.updated_at AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"'),'author',json_build_object('username',u.username,'bio',u.bio,'image',u.image,'following',false)) FROM c JOIN users u ON u.id=c.author_id"
const article_delete_query = "WITH t AS (SELECT id,author_id FROM articles WHERE slug=$1), w AS (DELETE FROM articles WHERE id=(SELECT id FROM t WHERE author_id=$2)) SELECT author_id::text FROM t"
const comment_delete_query = "WITH t AS (SELECT c.id,c.author_id FROM comments c JOIN articles a ON a.id=c.article_id WHERE c.id=$1 AND a.slug=$2), w AS (DELETE FROM comments WHERE id=(SELECT id FROM t WHERE author_id=$3)) SELECT author_id::text FROM t"
const favorite_query = "WITH t AS (SELECT id FROM articles WHERE slug=$2), w AS (INSERT INTO favorites(user_id,article_id) SELECT $1,id FROM t ON CONFLICT DO NOTHING) SELECT id::text FROM t"
const unfavorite_query = "WITH t AS (SELECT id FROM articles WHERE slug=$2), w AS (DELETE FROM favorites WHERE user_id=$1 AND article_id=(SELECT id FROM t)) SELECT id::text FROM t"
const jwt_header_b64 = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9'
const hex_digits = '0123456789abcdef'

fn article_query() string {
	return '${article_select} WHERE a.slug=$2'
}

fn prepared_specs() []PreparedSpec {
	mut specs := []PreparedSpec{}
	specs << PreparedSpec{query: tags_query, params: 0}
	specs << PreparedSpec{query: article_query(), params: 2}
	specs << PreparedSpec{query: profile_query, params: 2}
	specs << PreparedSpec{query: comments_query, params: 2}
	specs << PreparedSpec{query: follow_query, params: 2}
	specs << PreparedSpec{query: unfollow_query, params: 2}
	specs << PreparedSpec{query: comment_create_query, params: 3}
	specs << PreparedSpec{query: article_delete_query, params: 2}
	specs << PreparedSpec{query: comment_delete_query, params: 3}
	specs << PreparedSpec{query: favorite_query, params: 2}
	specs << PreparedSpec{query: unfavorite_query, params: 2}
	specs << PreparedSpec{query: 'SELECT id::text,json_build_object(\'username\',username,\'email\',email,\'bio\',bio,\'image\',image)::text FROM users WHERE email=$1', params: 1}
	specs << PreparedSpec{query: 'SELECT json_build_object(\'email\',email,\'username\',username,\'bio\',bio,\'image\',image) FROM users WHERE id=$1', params: 1}
	for filter in ['', 'tag', 'author', 'favorited'] {
		specs << PreparedSpec{query: article_list_statement(false, filter), params: if filter == '' { 3 } else { 4 }}
	}
	specs << PreparedSpec{query: article_list_statement(true, 'feed'), params: 3}
	return specs
}

fn env(name string, fallback string) string {
	env_value := os.getenv(name)
	return if env_value == '' { fallback } else { env_value }
}

fn (mut slot DbConn) exec(statement string, params []string) ![]pg.Row {
	if name := slot.prepared[statement] {
		return slot.conn.exec_prepared(name, params)
	}
	return slot.conn.exec_param_many(statement, params)
}

fn (app &App) query(statement string, params []string) ![]pg.Row {
	mut slot := <-app.conns or { return error('database connection queue closed') }
	result := slot.exec(statement, params) or {
		app.conns <- slot
		return err
	}
	app.conns <- slot
	return result
}

fn (app &App) one(statement string, params []string) !pg.Row {
	rows := app.query(statement, params)!
	if rows.len == 0 { return error('not found') }
	return rows[0]
}

fn value(obj map[string]json2.Any, key string) json2.Any {
	return obj[key] or { json2.null }
}

fn string_value(obj map[string]json2.Any, key string) string {
	x := value(obj, key)
	return if x is string { x.str() } else { '' }
}

fn optional_string(obj map[string]json2.Any, key string) (bool, string, bool) {
	if key !in obj { return false, '', true }
	x := obj[key] or { return false, '', true }
	match x {
		json2.Null { return false, '', true }
		string { return true, x.str(), true }
		else { return false, '', false }
	}
}

fn (app &App) body(ctx &Context, wrapper string) !map[string]json2.Any {
	root := json2.decode[map[string]json2.Any](ctx.req.data, json2.DecoderOptions{}) or { return error('invalid JSON') }
	node := root[wrapper] or { return error('missing object') }
	if node !is map[string]json2.Any { return error('invalid object') }
	return node as map[string]json2.Any
}

fn (app &App) article_json(viewer string, slug string) !string {
	row := app.one(article_query(), [viewer, slug])!
	return article_from_row(row)
}

fn (app &App) auth(ctx &Context) !Auth {
	authorization := ctx.req.header.get(.authorization) or { '' }
	if authorization == '' { return Auth{} }
	if !authorization.starts_with('Token ') { return error('invalid token') }
	token := authorization[6..]
	first_dot := token.index('.') or { return error('invalid token') }
	second_dot := token.index_after('.', first_dot + 1) or { return error('invalid token') }
	if token.index_after('.', second_dot + 1) != none || second_dot == token.len - 1 { return error('invalid token') }
	header_part := token[..first_dot]
	claims_part := token[first_dot + 1..second_dot]
	signature_part := token[second_dot + 1..]
	if header_part != jwt_header_b64 {
		header := json2.decode[map[string]json2.Any](base64.url_decode_str(header_part), json2.DecoderOptions{}) or { return error('invalid token') }
		alg := header['alg'] or { return error('invalid token') }
		if alg !is string || alg.str() != 'HS256' { return error('invalid token') }
	}
	expected := hmac.new(app.secret_bytes, token[..second_dot].bytes(), sha256.sum, sha256.block_size)
	actual := base64.url_decode(signature_part)
	if !hmac.equal(expected, actual) { return error('invalid token') }
	claims_text := base64.url_decode_str(claims_part)
	if fast := fast_claims(claims_text) {
		if fast.exp <= time.now().unix() { return error('invalid token') }
		return Auth{fast.sub, token, true}
	}
	claims := json2.decode[map[string]json2.Any](claims_text, json2.DecoderOptions{}) or { return error('invalid token') }
	exp := claims['exp'] or { return error('invalid token') }
	if exp.i64() <= time.now().unix() { return error('invalid token') }
	sub := claims['sub'] or { return error('invalid token') }
	if sub !is string || !is_positive_decimal(sub.str()) { return error('invalid token') }
	return Auth{sub.str(), token, true}
}

struct FastClaims {
	sub string
	exp i64
}

// Tokens emitted by this server and by the load generator use this compact
// claim order. Keep the general JSON path above for other valid HS256 tokens.
fn fast_claims(payload string) ?FastClaims {
	prefix := '{"sub":"'
	if !payload.starts_with(prefix) { return none }
	sub_end := payload.index('","iat":') or { return none }
	sub := payload[prefix.len..sub_end]
	if !is_positive_decimal(sub) { return none }
	exp_marker := ',"exp":'
	exp_marker_start := payload.index_after(exp_marker, sub_end) or { return none }
	exp_start := exp_marker_start + exp_marker.len
	if exp_start <= sub_end || !payload.ends_with('}') { return none }
	exp_text := payload[exp_start..payload.len - 1]
	exp, ok := parse_decimal(exp_text)
	if !ok { return none }
	return FastClaims{sub: sub, exp: exp}
}

fn (app &App) issue_token(id string) string {
	encoded_claims := base64.url_encode('{"sub":"${id}","iat":${time.now().unix()},"exp":${time.now().unix() + 2592000}}'.bytes())
	message := '${jwt_header_b64}.${encoded_claims}'
	signature := hmac.new(app.secret_bytes, message.bytes(), sha256.sum, sha256.block_size)
	return '${message}.${base64.url_encode(signature)}'
}

fn add_token(user_json string, token string) string {
	return '${user_json[..user_json.len - 1]},"token":"${token}"}'
}

fn json_string(value string) string {
	mut out := '"'
	for i in 0 .. value.len {
		b := value[i]
		match b {
			`"` { out += '\\"' }
			`\\` { out += '\\\\' }
			8 { out += '\\b' }
			9 { out += '\\t' }
			10 { out += '\\n' }
			12 { out += '\\f' }
			13 { out += '\\r' }
			else {
				if b < 32 {
					out += '\\u00${hex_byte(b)}'
				} else {
					out += value[i..i + 1]
				}
			}
		}
	}
	return out + '"'
}

fn hex_byte(value u8) string {
	return '${hex_digits[int(value >> 4)].ascii_str()}${hex_digits[int(value & 15)].ascii_str()}'
}

fn json_nullable(row pg.Row, index int) string {
	if value := row.val_opt(index) {
		return json_string(value)
	}
	return 'null'
}

fn json_bool(value string) string {
	return if value == 't' || value == 'true' { 'true' } else { 'false' }
}

// ARTICLE_SELECT row layout: slug, title, description, body, tags JSON,
// created, updated, favorited, favorites count, username, bio, image,
// following.
fn article_from_row(row pg.Row) string {
	return '{"slug":${json_string(row.val(0))},"title":${json_string(row.val(1))},"description":${json_string(row.val(2))},"body":${json_string(row.val(3))},"tagList":${row.val(4)},"createdAt":${json_string(row.val(5))},"updatedAt":${json_string(row.val(6))},"favorited":${json_bool(row.val(7))},"favoritesCount":${row.val(8)},"author":{"username":${json_string(row.val(9))},"bio":${json_nullable(row, 10)},"image":${json_nullable(row, 11)},"following":${json_bool(row.val(12))}}}'
}

// LIST_SELECT row layout starts after the count: slug, title, description,
// created, updated, tags JSON, favorited, favorites count, username, bio,
// image, following.
fn article_list_from_row(row pg.Row) string {
	if row.val(1) == '' {
		return ''
	}
	return '{"slug":${json_string(row.val(1))},"title":${json_string(row.val(2))},"description":${json_string(row.val(3))},"tagList":${row.val(6)},"createdAt":${json_string(row.val(4))},"updatedAt":${json_string(row.val(5))},"favorited":${json_bool(row.val(7))},"favoritesCount":${row.val(8)},"author":{"username":${json_string(row.val(9))},"bio":${json_nullable(row, 10)},"image":${json_nullable(row, 11)},"following":${json_bool(row.val(12))}}}'
}

fn (mut ctx Context) reply(status int, value string) veb.Result {
	ctx.res.set_status(http.status_from_int(status))
	ctx.res.header.set(.content_type, 'application/json')
	return ctx.text(value)
}

fn (mut ctx Context) fail(status int, message string) veb.Result {
	return ctx.reply(status, '{"errors":{"body":["${message}"]}}')
}

fn route(app &App, mut ctx Context, path string) veb.Result {
	method := ctx.req.method.str()
	clean_path := path.trim_left('/')
	if clean_path == 'api/tags' && method == 'GET' {
		row := app.one(tags_query, []) or { return ctx.fail(500, 'database error') }
		return ctx.reply(200, '{"tags":${row.val(0)}}')
	}
	segments := clean_path.split('/')
	if segments.len >= 2 && segments[0] == 'api' {
		return api(app, mut ctx, method, segments)
	}
	return ctx.fail(404, 'not found')
}

fn register(app &App, mut ctx Context) veb.Result {
	body := app.body(ctx, 'user') or { return ctx.fail(422, 'invalid user') }
	username := string_value(body, 'username')
	email := string_value(body, 'email')
	password := string_value(body, 'password')
	if username == '' || email == '' || password == '' { return ctx.fail(422, 'username, email and password are required') }
	hash := bcrypt.generate_from_password(password.bytes(), 10) or { return ctx.fail(422, 'invalid password') }
	row := app.one("INSERT INTO users(username,email,password_hash) VALUES($1,$2,$3) RETURNING id::text,json_build_object('username',username,'email',email,'bio',bio,'image',image)::text", [username, email, hash]) or {
		return ctx.fail(if err.msg().contains('duplicate key') { 422 } else { 500 }, 'could not register user')
	}
	id := row.val(0)
	return ctx.reply(201, '{"user":${add_token(row.val(1), app.issue_token(id))}}')
}

fn login(app &App, mut ctx Context) veb.Result {
	body := app.body(ctx, 'user') or { return ctx.fail(422, 'invalid user') }
	email := string_value(body, 'email')
	password := string_value(body, 'password')
	if email == '' || password == '' { return ctx.fail(422, 'email and password are required') }
	row := app.one("SELECT id::text,password_hash,json_build_object('username',username,'email',email,'bio',bio,'image',image)::text FROM users WHERE email=$1", [email]) or { return ctx.fail(401, 'invalid email or password') }
	hash := row.val(1)
	bcrypt.compare_hash_and_password(password.bytes(), hash.bytes()) or { return ctx.fail(401, 'invalid email or password') }
	return ctx.reply(200, '{"user":${add_token(row.val(2), app.issue_token(row.val(0)))}}')
}

fn current_user(app &App, mut ctx Context, auth Auth) veb.Result {
	if !auth.present { return ctx.fail(401, 'authentication required') }
	row := app.one("SELECT json_build_object('email',email,'username',username,'bio',bio,'image',image) FROM users WHERE id=$1", [auth.id]) or { return ctx.fail(401, 'user not found') }
	return ctx.reply(200, '{"user":${add_token(row.val(0), auth.token)}}')
}

fn update_user(app &App, mut ctx Context, auth Auth) veb.Result {
	if !auth.present { return ctx.fail(401, 'authentication required') }
	body := app.body(ctx, 'user') or { return ctx.fail(422, 'invalid user') }
	email_set, email, email_valid := optional_string(body, 'email')
	username_set, username, username_valid := optional_string(body, 'username')
	password_set, password, password_valid := optional_string(body, 'password')
	bio_set, bio, bio_valid := optional_string(body, 'bio')
	image_set, image, image_valid := optional_string(body, 'image')
	if !email_valid || !username_valid || !password_valid || !bio_valid || !image_valid { return ctx.fail(422, 'invalid user fields') }
	if (email_set && email == '') || (username_set && username == '') { return ctx.fail(422, 'email and username must not be empty') }
	mut password_hash := ''
	if password_set { password_hash = bcrypt.generate_from_password(password.bytes(), 10) or { return ctx.fail(422, 'invalid password') } }
	row := app.one("UPDATE users SET email=CASE WHEN $2='1' THEN $3 ELSE email END,username=CASE WHEN $4='1' THEN $5 ELSE username END,password_hash=CASE WHEN $6='1' THEN $7 ELSE password_hash END,bio=CASE WHEN $8='1' THEN $9 ELSE bio END,image=CASE WHEN $10='1' THEN $11 ELSE image END WHERE id=$1 RETURNING json_build_object('email',email,'username',username,'bio',bio,'image',image)", [auth.id,if email_set { '1' } else { '0' },email,if username_set { '1' } else { '0' },username,if password_set { '1' } else { '0' },password_hash,if bio_set { '1' } else { '0' },bio,if image_set { '1' } else { '0' },image]) or { return ctx.fail(if err.msg().contains('duplicate key') { 422 } else { if err.msg().contains('not found') { 401 } else { 500 } }, 'could not update user') }
	return ctx.reply(200, '{"user":${add_token(row.val(0), auth.token)}}')
}

fn get_profile(app &App, mut ctx Context, username string, auth Auth) veb.Result {
	row := app.one(profile_query, [if auth.present { auth.id } else { '0' }, username]) or { return ctx.fail(404, 'profile not found') }
	return ctx.reply(200, row.val(0))
}

fn follow(app &App, mut ctx Context, username string, auth Auth, follow bool) veb.Result {
	if !auth.present { return ctx.fail(401, 'authentication required') }
	statement := if follow { follow_query } else { unfollow_query }
	row := app.one(statement, [auth.id, username]) or { return ctx.fail(404, 'profile not found') }
	return ctx.reply(200, row.val(0))
}

fn get_article(app &App, mut ctx Context, slug string, auth Auth) veb.Result {
	row := app.one(article_query(), [if auth.present { auth.id } else { '0' }, slug]) or { return ctx.fail(404, 'article not found') }
	return ctx.reply(200, '{"article":${article_from_row(row)}}')
}

fn list_articles(app &App, mut ctx Context, auth Auth) veb.Result {
	return article_list(app, mut ctx, auth, false)
}

fn feed(app &App, mut ctx Context, auth Auth) veb.Result {
	if !auth.present { return ctx.fail(401, 'authentication required') }
	return article_list(app, mut ctx, auth, true)
}

// Keep the hot list statements stable so every connection can prepare them
// once at startup. `filter` is empty, tag, author, favorited, or feed.
fn article_list_statement(feed bool, filter string) string {
	mut page_where := ' ORDER BY a.id DESC LIMIT $2 OFFSET $3'
	mut count_source := 'SELECT 1 FROM articles ORDER BY id'
	if feed {
		page_where = ' WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id=fo.followee_id ORDER BY a2.id DESC LIMIT ($2::bigint+$3::bigint)) x WHERE fo.follower_id=$1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC'
		count_source = 'SELECT 1 FROM articles a WHERE a.author_id IN (SELECT followee_id FROM follows WHERE follower_id=$1)'
	} else if filter == 'tag' {
		page_where = ' WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id=(SELECT id FROM tags WHERE name=$4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC'
		count_source = 'SELECT 1 FROM article_tags at WHERE at.tag_id=(SELECT id FROM tags WHERE name=$4)'
	} else if filter == 'author' {
		page_where = ' WHERE a.author_id=(SELECT id FROM users WHERE username=$4) ORDER BY a.id DESC LIMIT $2 OFFSET $3'
		count_source = 'SELECT 1 FROM articles a WHERE a.author_id=(SELECT id FROM users WHERE username=$4)'
	} else if filter == 'favorited' {
		page_where = ' WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id=(SELECT id FROM users WHERE username=$4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC'
		count_source = 'SELECT 1 FROM favorites f WHERE f.user_id=(SELECT id FROM users WHERE username=$4)'
	}
	return "WITH c AS (SELECT count(*) AS n FROM (${count_source} LIMIT 1000) s), p AS (SELECT a.id,a.slug,a.title,a.description,a.created_at,a.updated_at,a.author_id FROM articles a${page_where}) SELECT c.n,${list_select} FROM c LEFT JOIN p a ON true LEFT JOIN users u ON u.id=a.author_id ORDER BY a.id DESC"
}

fn article_list(app &App, mut ctx Context, auth Auth, feed bool) veb.Result {
	limit := ctx.query['limit'] or { '20' }
	offset := ctx.query['offset'] or { '0' }
	limit_value, limit_valid := parse_decimal(limit)
	offset_value, offset_valid := parse_decimal(offset)
	if !limit_valid || !offset_valid || limit_value < 1 || limit_value > 100 { return ctx.fail(422, 'invalid pagination') }
	viewer := if auth.present { auth.id } else { '0' }
	mut args := [viewer, limit, offset]
	mut filter := ''
	if feed {
		filter = 'feed'
	} else if ctx.query['tag'] or { '' } != '' {
		tag := ctx.query['tag'] or { '' }
		filter = 'tag'
		args << tag
	} else if ctx.query['author'] or { '' } != '' {
		author := ctx.query['author'] or { '' }
		filter = 'author'
		args << author
	} else if ctx.query['favorited'] or { '' } != '' {
		favorited := ctx.query['favorited'] or { '' }
		filter = 'favorited'
		args << favorited
	}
	mut statement := article_list_statement(feed, filter)
	if feed && offset_value > 9223372036854775707 {
		statement = "WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT followee_id FROM follows WHERE follower_id=$1) LIMIT 1000) s), p AS (SELECT a.id,a.slug,a.title,a.description,a.created_at,a.updated_at,a.author_id FROM articles a WHERE false) SELECT c.n,${list_select} FROM c LEFT JOIN p a ON true LEFT JOIN users u ON u.id=a.author_id ORDER BY a.id DESC"
	}
	rows := app.query(statement, args) or { return ctx.fail(500, 'database error') }
	mut items := []string{cap: rows.len}
	for row in rows {
		article := article_list_from_row(row)
		if article != '' { items << article }
	}
	count := if rows.len > 0 { rows[0].val(0) } else { '0' }
	return ctx.reply(200, '{"articles":[${items.join( ',')}],"articlesCount":${count}}')
}

fn create_article(app &App, mut ctx Context, auth Auth) veb.Result {
	if !auth.present { return ctx.fail(401, 'authentication required') }
	body := app.body(ctx, 'article') or { return ctx.fail(422, 'invalid article') }
	title := string_value(body, 'title')
	description := string_value(body, 'description')
	content := string_value(body, 'body')
	if title == '' || description == '' || content == '' { return ctx.fail(422, 'title, description and body are required') }
	mut tags := []string{}
	if tag_list := body['tagList'] {
		if tag_list is []json2.Any {
			for tag in tag_list { if tag is string && tag.str() != '' { tags << tag.str() } else { return ctx.fail(422, 'invalid tagList') } }
		} else if tag_list !is json2.Null {
			return ctx.fail(422, 'invalid tagList')
		}
	}
	encoded_tags := tags.map(json_string(it)).join(',')
	statement := "WITH n AS (SELECT nextval(pg_get_serial_sequence('articles','id')) AS id), a AS (INSERT INTO articles(id,slug,author_id,title,description,body) SELECT n.id,trim(both '-' from lower(regexp_replace($2,'[^A-Za-z0-9]+','-','g'))) || '-' || n.id,$1,$2,$3,$4 FROM n RETURNING id,slug,title,description,body,created_at,updated_at,author_id), t AS (INSERT INTO tags(name) SELECT DISTINCT jsonb_array_elements_text(('[' || $5 || ']')::jsonb) ON CONFLICT(name) DO UPDATE SET name=EXCLUDED.name RETURNING id,name), x AS (INSERT INTO article_tags(article_id,tag_id) SELECT a.id,t.id FROM a CROSS JOIN t) SELECT json_build_object('slug',a.slug,'title',a.title,'description',a.description,'body',a.body,'tagList',COALESCE((SELECT json_agg(t.name ORDER BY t.name) FROM t),'[]'::json),'createdAt',to_char(a.created_at AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"'),'updatedAt',to_char(a.updated_at AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"'),'favorited',false,'favoritesCount',0,'author',json_build_object('username',u.username,'bio',u.bio,'image',u.image,'following',EXISTS(SELECT 1 FROM follows f WHERE f.follower_id=$1 AND f.followee_id=u.id))) FROM a JOIN users u ON u.id=a.author_id"
	article := app.one(statement, [auth.id,title,description,content,encoded_tags]) or { return ctx.fail(500, 'database error') }
	return ctx.reply(201, '{"article":${article.val(0)}}')
}

fn update_article(app &App, mut ctx Context, slug string, auth Auth) veb.Result {
	if !auth.present { return ctx.fail(401, 'authentication required') }
	body := app.body(ctx, 'article') or { return ctx.fail(422, 'invalid article') }
	owner := app.one('SELECT id::text,author_id::text FROM articles WHERE slug=$1', [slug]) or { return ctx.fail(404, 'article not found') }
	if owner.val(1) != auth.id { return ctx.fail(403, 'not the author') }
	title_set, title, title_valid := optional_string(body, 'title')
	description_set, description, description_valid := optional_string(body, 'description')
	content_set, content, content_valid := optional_string(body, 'body')
	if !title_valid || !description_valid || !content_valid { return ctx.fail(422, 'invalid article fields') }
	if (title_set && title == '') || (description_set && description == '') || (content_set && content == '') { return ctx.fail(422, 'article fields must not be empty') }
	app.query("UPDATE articles SET title=CASE WHEN $2='1' THEN $3 ELSE title END,description=CASE WHEN $4='1' THEN $5 ELSE description END,body=CASE WHEN $6='1' THEN $7 ELSE body END,slug=CASE WHEN $2='1' THEN trim(both '-' from lower(regexp_replace($3,'[^A-Za-z0-9]+','-','g'))) || '-' || id ELSE slug END,updated_at=now() WHERE id=$1", [owner.val(0),if title_set { '1' } else { '0' },title,if description_set { '1' } else { '0' },description,if content_set { '1' } else { '0' },content]) or { return ctx.fail(500, 'database error') }
	row := app.one('SELECT slug FROM articles WHERE id=$1', [owner.val(0)]) or { return ctx.fail(500, 'database error') }
	article := app.article_json(auth.id, row.val(0)) or { return ctx.fail(500, 'database error') }
	return ctx.reply(200, '{"article":${article}}')
}

fn delete_article(app &App, mut ctx Context, slug string, auth Auth) veb.Result {
	if !auth.present { return ctx.fail(401, 'authentication required') }
	owner := app.one(article_delete_query, [slug, auth.id]) or { return ctx.fail(404, 'article not found') }
	if owner.val(0) != auth.id { return ctx.fail(403, 'not the author') }
	ctx.res.set_status(.no_content)
	return ctx.text('')
}

fn favorite(app &App, mut ctx Context, slug string, auth Auth, favorite bool) veb.Result {
	if !auth.present { return ctx.fail(401, 'authentication required') }
	statement := if favorite { favorite_query } else { unfavorite_query }
	app.one(statement, [auth.id, slug]) or { return ctx.fail(404, 'article not found') }
	updated := app.article_json(auth.id, slug) or { return ctx.fail(500, 'database error') }
	return ctx.reply(200, '{"article":${updated}}')
}

fn list_comments(app &App, mut ctx Context, slug string, auth Auth) veb.Result {
	viewer := if auth.present { auth.id } else { '0' }
	rows := app.query(comments_query, [viewer,slug]) or { return ctx.fail(500, 'database error') }
	if rows.len == 0 { return ctx.fail(404, 'article not found') }
	return ctx.reply(200, '{"comments":' + rows[0].val(0) + '}')
}

fn create_comment(app &App, mut ctx Context, slug string, auth Auth) veb.Result {
	if !auth.present { return ctx.fail(401, 'authentication required') }
	body := app.body(ctx, 'comment') or { return ctx.fail(422, 'invalid comment') }
	content := string_value(body, 'body')
	if content == '' { return ctx.fail(422, 'body is required') }
	rows := app.query(comment_create_query, [slug, auth.id, content]) or { return ctx.fail(500, 'database error') }
	if rows.len == 0 { return ctx.fail(404, 'article not found') }
	row := rows[0]
	return ctx.reply(201, '{"comment":${row.val(0)}}')
}

fn delete_comment(app &App, mut ctx Context, slug string, id string, auth Auth) veb.Result {
	if !auth.present { return ctx.fail(401, 'authentication required') }
	if !is_positive_decimal(id) { return ctx.fail(404, 'comment not found') }
	row := app.one(comment_delete_query, [id,slug,auth.id]) or { return ctx.fail(404, 'comment not found') }
	if row.val(0) != auth.id { return ctx.fail(403, 'not the author') }
	ctx.res.set_status(.no_content)
	return ctx.text('')
}

fn is_positive_decimal(value string) bool {
	number, valid := parse_decimal(value)
	return valid && number > 0
}

fn parse_decimal(value string) (i64, bool) {
	if value.len == 0 { return 0, false }
	mut number := i64(0)
	for digit in value {
		if digit < `0` || digit > `9` { return 0, false }
		n := i64(digit - `0`)
		if number > (9223372036854775807 - n) / 10 { return 0, false }
		number = number * 10 + n
	}
	return number, true
}

fn api(app &App, mut ctx Context, method string, p []string) veb.Result {
	if method == 'POST' && p.len == 2 && p[1] == 'users' { return register(app, mut ctx) }
	if method == 'POST' && p.len == 3 && p[1] == 'users' && p[2] == 'login' { return login(app, mut ctx) }
	mut auth := app.auth(ctx) or { return ctx.fail(401, 'invalid token') }
	if p.len == 2 && p[1] == 'user' {
		if method == 'GET' { return current_user(app, mut ctx, auth) }
		if method == 'PUT' { return update_user(app, mut ctx, auth) }
		return ctx.fail(404, 'not found')
	}
	if p.len == 3 && p[1] == 'profiles' {
		if method == 'GET' { return get_profile(app, mut ctx, p[2], auth) }
		return ctx.fail(404, 'not found')
	}
	if p.len == 4 && p[1] == 'profiles' && p[3] == 'follow' {
		if method == 'POST' { return follow(app, mut ctx, p[2], auth, true) }
		if method == 'DELETE' { return follow(app, mut ctx, p[2], auth, false) }
	}
	if p.len == 2 && p[1] == 'articles' && method == 'GET' { return list_articles(app, mut ctx, auth) }
	if p.len == 3 && p[1] == 'articles' && p[2] == 'feed' && method == 'GET' { return feed(app, mut ctx, auth) }
	if p.len == 2 && p[1] == 'articles' && method == 'POST' { return create_article(app, mut ctx, auth) }
	if p.len >= 3 && p[1] == 'articles' {
		if p.len == 3 {
			if method == 'GET' { return get_article(app, mut ctx, p[2], auth) }
			if method == 'PUT' { return update_article(app, mut ctx, p[2], auth) }
			if method == 'DELETE' { return delete_article(app, mut ctx, p[2], auth) }
		}
		if p.len == 4 && p[3] == 'favorite' {
			if method == 'POST' { return favorite(app, mut ctx, p[2], auth, true) }
			if method == 'DELETE' { return favorite(app, mut ctx, p[2], auth, false) }
		}
		if p.len == 4 && p[3] == 'comments' {
			if method == 'GET' { return list_comments(app, mut ctx, p[2], auth) }
			if method == 'POST' { return create_comment(app, mut ctx, p[2], auth) }
		}
		if p.len == 5 && p[3] == 'comments' && method == 'DELETE' { return delete_comment(app, mut ctx, p[2], p[4], auth) }
	}
	return ctx.fail(404, 'not found')
}

@['/:path...'; get; post; put; delete]
pub fn (app &App) dispatch(mut ctx Context, path string) veb.Result {
	return route(app, mut ctx, path)
}

fn main() {
	db_url := os.getenv('DATABASE_URL')
	secret := os.getenv('JWT_SECRET')
	if db_url == '' || secret == '' { panic('DATABASE_URL and JWT_SECRET are required') }
	url := urllib.parse(db_url) or { panic(err) }
	userinfo := url.user or { panic('DATABASE_URL must include credentials') }
	config := pg.Config{host: url.hostname(), port: if url.port() == '' { 5432 } else { url.port().int() }, user: userinfo.username, password: userinfo.password, dbname: url.path.trim_left('/')}
	db_conns := env('DB_CONNS', '64').int()
	if db_conns < 1 || db_conns > 90 { panic('DB_CONNS must be between 1 and 90') }
	mut conns := chan &DbConn{cap: db_conns}
	specs := prepared_specs()
	for _ in 0 .. db_conns {
		conn := pg.connect_direct(config) or { panic(err) }
		mut prepared := map[string]string{}
		for index, spec in specs {
			name := 'conduit_q_${index}'
			conn.prepare(name, spec.query, spec.params) or { panic(err) }
			prepared[spec.query] = name
		}
		conns <- &DbConn{conn: conn, prepared: prepared}
	}
	mut app := &App{conns: conns, secret: secret, secret_bytes: secret.bytes()}
	veb.run_at[App, Context](mut app, host: env('HOST', '127.0.0.1'), port: env('PORT', '3000').int(), timeout_in_seconds: 75) or { panic(err) }
}

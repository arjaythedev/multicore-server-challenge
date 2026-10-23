// The Conduit API: each route checks auth, then the body, then asks the database; answer() writes the response
// from the rows that come back.

import bcrypt;
import buf;
import http;
import json;
import jwt;
import pg;
import server;
import sql;
import std;

// ---------- request bodies ----------

// A string field of a body: absent, null, a string (in fbuf), or something else.
let F_ABSENT = 0;
let F_NULL = 1;
let F_STRING = 2;
let F_BAD = 3;

struct Field { state: i64 = 0, off: i64 = 0, len: i64 = 0 }

fn value(fbuf: const u8[:], f: Field) -> const u8[:] { fbuf[f.off..f.off + f.len] }

fn read_field(r: json::Reader&, f: Field&, fbuf: u8[>..]&) {
    let c = json::peek(r);
    if c == '"' {
        var sc: u8[>..] = [];
        let s = json::read_string(r, sc);
        f.state = F_STRING;
        f.off = fbuf.len;
        f.len = s.len;
        fbuf.append(s);
    } else if c == 'n' {
        json::word(r, "null");
        f.state = F_NULL;
    } else {
        json::skip(r);
        f.state = F_BAD;
    }
}

// A present, non-empty string.
fn required(fbuf: const u8[:], f: Field) -> bool { f.state == F_STRING && f.len > 0 && valid_text(value(fbuf, f)) }

// Absent or null, or a string (non-empty when nonempty).
fn optional(fbuf: const u8[:], f: Field, nonempty: bool) -> bool {
    if f.state == F_ABSENT || f.state == F_NULL { return true; }
    return f.state == F_STRING && valid_text(value(fbuf, f)) && (!nonempty || f.len > 0);
}

// Passwords are bcrypt byte strings, not PostgreSQL text. JSON U+0000 is
// valid here; usernames/email/bio/image keep the stricter text-column check.
fn required_password(fbuf: const u8[:], f: Field) -> bool {
    return f.state == F_STRING && f.len > 0 && valid_utf8(value(fbuf, f), true);
}

fn optional_password(fbuf: const u8[:], f: Field) -> bool {
    if f.state == F_ABSENT || f.state == F_NULL { return true; }
    return required_password(fbuf, f);
}

fn param_opt(m: u8[>..]&, fbuf: const u8[:], f: Field) {
    if f.state == F_STRING { param_text(m, value(fbuf, f)); } else { param_null(m); }
}

// F(reader, key) for each member of the object under `wrapper`; false unless the body is an object holding one.
fn read_body<F>(body: const u8[:], wrapper: const u8[:]) -> bool {
    var r = json::reader(body);
    var found = false;
    var bad = false;
    json::each_member(r) { name =>
        if name == wrapper {
            if json::peek(r) == '{' {
                found = true;
                json::each_member(r) { k => F(r, k); };
            } else {
                json::skip(r);
                bad = true;
            }
        } else {
            json::skip(r);
        }
    };
    return json::finish(r) && found && !bad;
}

// tagList: an array of non-empty strings, or null; false for anything else.
fn read_tags(r: json::Reader&, tbuf: u8[>..]&, tag_ends: i64[>..]&) -> bool {
    let c = json::peek(r);
    if c == 'n' { json::word(r, "null"); return true; }
    if c != '[' { json::skip(r); return false; }
    var ok = true;
    json::each_element(r) {
        if json::peek(r) == '"' {
            var sc: u8[>..] = [];
            let s = json::read_string(r, sc);
            if s.len == 0 || !valid_text(s) { ok = false; }
            tbuf.append(s);
            tag_ends.push(tbuf.len);
        } else {
            json::skip(r);
            ok = false;
        }
    };
    return ok;
}

// ---------- routing ----------

// The viewer: 0 without an Authorization header, -1 with one that isn't a valid "Token <jwt>".
fn viewer_of(r: Request&) -> i64 {
    if !r.has_auth { return 0; }
    if !starts_with(r.auth, "Token ") { return -1; }
    let id = jwt_verify(jwt_key, r.auth[6..], now_ms);
    return if id > 0 { id } else { -1 };
}

// A path segment, percent-decoded onto out; false when it doesn't decode to text.
fn segment(out: u8[>..]&, s: const u8[:]) -> bool { pct_decode(out, s, false) && valid_text(out) }

fn handle(slot: i64, r: Request&) {
    let path = r.path;
    if !starts_with(path, "/api/") { fail(slot, 404, "not found"); return; }
    let rest = path[5..];
    var cuts: i64[..5] = [];
    for c, i in rest {
        if c == '/' {
            if cuts.len == 4 { fail(slot, 404, "not found"); return; }
            cuts.push(i);
        }
    }
    let n = cuts.len + 1;
    var starts: i64[5] = [0; 5];
    var ends: i64[5] = [0; 5];
    for i in n {
        starts[i] = if i == 0 { 0 } else { cuts[i - 1] + 1 };
        ends[i] = if i < cuts.len { cuts[i] } else { rest.len };
        if ends[i] == starts[i] { fail(slot, 404, "not found"); return; }
    }
    let s0 = rest[starts[0]..ends[0]];
    let s1 = if n > 1 { rest[starts[1]..ends[1]] } else { rest[0..0] };
    let s2 = if n > 2 { rest[starts[2]..ends[2]] } else { rest[0..0] };
    let s3 = if n > 3 { rest[starts[3]..ends[3]] } else { rest[0..0] };
    let m = r.method;

    if s0 == "articles" {
        if n == 1 {
            if m == M_GET { list(slot, r); return; }
            if m == M_POST { create_article(slot, r); return; }
        } else if n == 2 {
            if m == M_GET && s1 == "feed" { feed(slot, r); return; }
            if m == M_GET { by_slug(slot, r, s1, K_ARTICLE, false); return; }
            if m == M_PUT { update_article(slot, r, s1); return; }
            if m == M_DELETE { by_slug(slot, r, s1, K_DELETE_ARTICLE, true); return; }
        } else if n == 3 && s2 == "comments" {
            if m == M_GET { by_slug(slot, r, s1, K_COMMENTS, false); return; }
            if m == M_POST { create_comment(slot, r, s1); return; }
        } else if n == 3 && s2 == "favorite" {
            if m == M_POST { by_slug(slot, r, s1, K_FAVORITE, true); return; }
            if m == M_DELETE { by_slug(slot, r, s1, K_UNFAVORITE, true); return; }
        } else if n == 4 && s2 == "comments" && m == M_DELETE {
            delete_comment(slot, r, s1, s3);
            return;
        }
    } else if s0 == "tags" && n == 1 && m == M_GET {
        begin(slot, K_TAGS, 0);
        var m: u8[>..] = [];
        bind_end(m, stmt(slot, m, ST_TAGS, 0));
        pool_add(slot, m, ST_TAGS);
        return;
    } else if s0 == "user" && n == 1 {
        if m == M_GET { current_user(slot, r); return; }
        if m == M_PUT { update_user(slot, r); return; }
    } else if s0 == "profiles" {
        if n == 2 && m == M_GET { profile(slot, r, s1, K_PROFILE, false); return; }
        if n == 3 && s2 == "follow" {
            if m == M_POST { profile(slot, r, s1, K_FOLLOW, true); return; }
            if m == M_DELETE { profile(slot, r, s1, K_UNFOLLOW, true); return; }
        }
    } else if s0 == "users" && m == M_POST {
        if n == 1 { register(slot, r); return; }
        if n == 2 && s1 == "login" { login(slot, r); return; }
    }
    fail(slot, 404, "not found");
}

// ---------- users ----------

fn register(slot: i64, r: Request&) {
    var username = Field { .. };
    var email = Field { .. };
    var password = Field { .. };
    var fbuf: u8[>..] = [];
    let ok = read_body(r.body, "user") { jr: json::Reader&, k =>
        if k == "username" { read_field(jr, username, fbuf); }
        else if k == "email" { read_field(jr, email, fbuf); }
        else if k == "password" { read_field(jr, password, fbuf); }
        else { json::skip(jr); }
    };
    if !ok { fail(slot, 422, "invalid body"); return; }
    if !required(fbuf, username) || !required(fbuf, email) || !required_password(fbuf, password) {
        fail(slot, 422, "username, email and password are required");
        return;
    }
    if password.len > PASSWORD_MAX { fail(slot, 422, "password is too long"); return; }
    begin(slot, K_REGISTER_HASH, 0);
    var msg: u8[>..] = [];
    let b = stmt(slot, msg, ST_REGISTER, 3);
    param_text(msg, value(fbuf, username));
    param_text(msg, value(fbuf, email));
    conns[slot].hash_at = msg.len + 4;
    param_text(msg, "000000000000000000000000000000000000000000000000000000000000");
    bind_end(msg, b);
    keep(slot, msg);
    conns[slot].write = true;
    hash_job(slot, false, value(fbuf, password), "");
}

fn login(slot: i64, r: Request&) {
    var email = Field { .. };
    var password = Field { .. };
    var fbuf: u8[>..] = [];
    let ok = read_body(r.body, "user") { jr: json::Reader&, k =>
        if k == "email" { read_field(jr, email, fbuf); }
        else if k == "password" { read_field(jr, password, fbuf); }
        else { json::skip(jr); }
    };
    if !ok { fail(slot, 422, "invalid body"); return; }
    if !required(fbuf, email) || !required_password(fbuf, password) { fail(slot, 422, "email and password are required"); return; }
    if password.len > PASSWORD_MAX { fail(slot, 401, "invalid email or password"); return; }
    begin(slot, K_LOGIN, 0);
    var msg: u8[>..] = [];
    let b = stmt(slot, msg, ST_LOGIN, 1);
    param_text(msg, value(fbuf, email));
    bind_end(msg, b);
    set_ctx(slot, value(fbuf, password));
    submit(slot, msg, false);
}

fn current_user(slot: i64, r: Request&) {
    let viewer = viewer_of(r);
    if viewer <= 0 { fail(slot, 401, "unauthorized"); return; }
    begin(slot, K_CURRENT, viewer);
    var msg: u8[>..] = [];
    let b = stmt(slot, msg, ST_CURRENT_USER, 1);
    param_int(msg, viewer);
    bind_end(msg, b);
    set_ctx(slot, r.auth[6..]);
    submit(slot, msg, false);
}

fn update_user(slot: i64, r: Request&) {
    let viewer = viewer_of(r);
    if viewer <= 0 { fail(slot, 401, "unauthorized"); return; }
    var email = Field { .. };
    var username = Field { .. };
    var password = Field { .. };
    var bio = Field { .. };
    var image = Field { .. };
    var fbuf: u8[>..] = [];
    let ok = read_body(r.body, "user") { jr: json::Reader&, k =>
        if k == "email" { read_field(jr, email, fbuf); }
        else if k == "username" { read_field(jr, username, fbuf); }
        else if k == "password" { read_field(jr, password, fbuf); }
        else if k == "bio" { read_field(jr, bio, fbuf); }
        else if k == "image" { read_field(jr, image, fbuf); }
        else { json::skip(jr); }
    };
    if !ok { fail(slot, 422, "invalid body"); return; }
    if !optional(fbuf, email, true) || !optional(fbuf, username, true) || !optional_password(fbuf, password) || !optional(fbuf, bio, false)
       || !optional(fbuf, image, false) {
        fail(slot, 422, "invalid user fields");
        return;
    }
    let hashing = password.state == F_STRING;
    if hashing && password.len > PASSWORD_MAX { fail(slot, 422, "password is too long"); return; }
    begin(slot, if hashing { K_UPDATE_HASH } else { K_UPDATE_USER }, viewer);
    var msg: u8[>..] = [];
    let b = stmt(slot, msg, ST_UPDATE_USER, 6);
    param_int(msg, viewer);
    param_opt(msg, fbuf, email);
    param_opt(msg, fbuf, username);
    if hashing {
        conns[slot].hash_at = msg.len + 4;
        param_text(msg, "000000000000000000000000000000000000000000000000000000000000");
    } else {
        param_null(msg);
    }
    param_opt(msg, fbuf, bio);
    param_opt(msg, fbuf, image);
    bind_end(msg, b);
    set_ctx(slot, r.auth[6..]);
    if hashing {
        keep(slot, msg);
        conns[slot].write = true;
        hash_job(slot, false, value(fbuf, password), "");
    } else {
        submit(slot, msg, true);
    }
}

// ---------- profiles ----------

fn profile(slot: i64, r: Request&, name: const u8[:], kind: i64, write: bool) {
    var pval: u8[>..] = [];
    let viewer = viewer_of(r);
    if viewer < 0 || (write && viewer == 0) { fail(slot, 401, "unauthorized"); return; }
    if !segment(pval, name) { fail(slot, 404, "profile not found"); return; }
    begin(slot, kind, viewer);
    var msg: u8[>..] = [];
    let st = if kind == K_PROFILE { ST_PROFILE } else if kind == K_FOLLOW { ST_FOLLOW } else { ST_UNFOLLOW };
    let b = stmt(slot, msg, st, 2);
    param_int(msg, viewer);
    param_text(msg, pval);
    bind_end(msg, b);
    submit(slot, msg, write);
}

// ---------- articles ----------

// limit (default 20, 1 to 100) and offset (default 0); a parameter that is present, even empty, must be valid.
fn page(q: const u8[:]) -> i64, i64, bool {
    var pval: u8[>..] = [];
    var limit = 20;
    var offset = 0;
    pval.clear();
    if query_get(q, "limit", pval) {
        let v, ok = parse_uint(pval);
        if !ok || v < 1 || v > 100 { return 0, 0, false; }
        limit = v;
    }
    pval.clear();
    if query_get(q, "offset", pval) {
        let v, ok = parse_uint(pval);
        if !ok { return 0, 0, false; }
        offset = v;
    }
    return limit, offset, true;
}

fn empty_list(slot: i64) {
    var out: u8[>..] = [];
    let at = begin_response(out, 200, conns[slot].close_after);
    out.append("{\"articles\":[],\"articlesCount\":0}");
    end_response(out, at);
    reply(slot, out);
}

fn list(slot: i64, r: Request&) {
    var pval: u8[>..] = [];
    let viewer = viewer_of(r);
    if viewer < 0 { fail(slot, 401, "unauthorized"); return; }
    let limit, offset, ok = page(r.query);
    if !ok { fail(slot, 422, "limit must be 1-100 and offset >= 0"); return; }
    // The first non-empty filter in the order tag, author, favorited applies.
    var st = ST_LIST_ALL;
    for i in 3 {
        pval.clear();
        if query_get(r.query, if i == 0 { "tag" } else if i == 1 { "author" } else { "favorited" }, pval) && pval.len > 0 {
            st = ST_LIST_TAG + i;
            break;
        }
    }
    if st != ST_LIST_ALL && !valid_text(pval) { empty_list(slot); return; }
    begin(slot, K_LIST, viewer);
    var msg: u8[>..] = [];
    let b = stmt(slot, msg, st, if st == ST_LIST_ALL { 3 } else { 4 });
    param_int(msg, viewer);
    param_int(msg, limit);
    param_int(msg, offset);
    if st != ST_LIST_ALL { param_text(msg, pval); }
    bind_end(msg, b);
    pool_add(slot, msg, st);
}

fn feed(slot: i64, r: Request&) {
    let viewer = viewer_of(r);
    if viewer <= 0 { fail(slot, 401, "unauthorized"); return; }
    let limit, offset, ok = page(r.query);
    if !ok { fail(slot, 422, "limit must be 1-100 and offset >= 0"); return; }
    begin(slot, K_LIST, viewer);
    var msg: u8[>..] = [];
    let b = stmt(slot, msg, ST_FEED, 4);
    param_int(msg, viewer);
    param_int(msg, limit);
    param_int(msg, offset);
    param_int(msg, if offset > 0x7fffffffffffffff - limit { 0x7fffffffffffffff } else { offset + limit });
    bind_end(msg, b);
    pool_add(slot, msg, ST_FEED);
}

// The single-article requests that take nothing but the slug.
fn by_slug(slot: i64, r: Request&, slug: const u8[:], kind: i64, auth: bool) {
    var pval: u8[>..] = [];
    let viewer = viewer_of(r);
    if viewer < 0 || (auth && viewer == 0) { fail(slot, 401, "unauthorized"); return; }
    if !segment(pval, slug) { fail(slot, 404, "article not found"); return; }
    begin(slot, kind, viewer);
    var msg: u8[>..] = [];
    let st = match kind {
        K_ARTICLE => ST_ARTICLE,
        K_DELETE_ARTICLE => ST_DELETE_ARTICLE,
        K_COMMENTS => ST_COMMENTS,
        K_FAVORITE => ST_FAVORITE,
        _ => ST_UNFAVORITE,
    };
    let b = stmt(slot, msg, st, 2);
    param_int(msg, viewer);
    param_text(msg, pval);
    bind_end(msg, b);
    if kind == K_COMMENTS { pool_add(slot, msg, ST_COMMENTS); }
    else if kind == K_ARTICLE && article_batch { pool_add(slot, msg, ST_ARTICLE); }
    else { submit(slot, msg, auth); }
}

// Called only after the writer's complete Sync group has reached ReadyForQuery.
// Replace the saved mutation with a read, so retries can never replay a committed write.
// The returned id remains valid even if the slug changed while the mutation waited.
fn favorite_committed(slot: i64, rows: const u8[:]) {
    let m = first_row(rows);
    if m.len == 0 { fail(slot, 404, "article not found"); return; }
    var r = row(m);
    let id = col_int(r);
    let viewer = conns[slot].viewer;
    begin(slot, K_ARTICLE, viewer);
    var msg: u8[>..] = [];
    let b = stmt(slot, msg, ST_ARTICLE_BY_ID, 2);
    param_int(msg, viewer);
    param_int(msg, id);
    bind_end(msg, b);
    submit(slot, msg, false);
}

// Called after the UPDATE writer group reaches ReadyForQuery. A separate
// statement gets a fresh snapshot; replacing the kept mutation with this read
// also means a later retry cannot replay an already committed UPDATE.
fn article_update_committed(slot: i64, rows: const u8[:]) {
    let m = first_row(rows);
    if m.len == 0 { fail(slot, 404, "article not found"); return; }
    var r = row(m);
    let owner = col_int(r);
    let id = col_int(r);
    let viewer = conns[slot].viewer;
    if owner != viewer { fail(slot, 403, "not the author"); return; }
    begin(slot, K_ARTICLE, viewer);
    var msg: u8[>..] = [];
    let b = stmt(slot, msg, ST_ARTICLE_BY_ID, 2);
    param_int(msg, viewer);
    param_int(msg, id);
    bind_end(msg, b);
    submit(slot, msg, false);
}

fn create_article(slot: i64, r: Request&) {
    let viewer = viewer_of(r);
    if viewer <= 0 { fail(slot, 401, "unauthorized"); return; }
    var title = Field { .. };
    var description = Field { .. };
    var body = Field { .. };
    var tags_ok = true;
    var tbuf: u8[>..] = [];
    var tag_ends: i64[>..] = [];
    var fbuf: u8[>..] = [];
    let ok = read_body(r.body, "article") { jr: json::Reader&, k =>
        if k == "title" { read_field(jr, title, fbuf); }
        else if k == "description" { read_field(jr, description, fbuf); }
        else if k == "body" { read_field(jr, body, fbuf); }
        else if k == "tagList" { tbuf.clear(); tag_ends.clear(); tags_ok = read_tags(jr, tbuf, tag_ends); }
        else { json::skip(jr); }
    };
    if !ok { fail(slot, 422, "invalid body"); return; }
    if !required(fbuf, title) || !required(fbuf, description) || !required(fbuf, body) {
        fail(slot, 422, "title, description and body are required");
        return;
    }
    if !tags_ok { fail(slot, 422, "tagList must be an array of non-empty strings"); return; }
    begin(slot, K_CREATE, viewer);
    var msg: u8[>..] = [];
    var b = stmt(slot, msg, ST_INSERT_ARTICLE, 4);
    param_int(msg, viewer);
    param_text(msg, value(fbuf, title));
    param_text(msg, value(fbuf, description));
    param_text(msg, value(fbuf, body));
    bind_end(msg, b);
    if tag_ends.len > 0 {
        b = stmt(slot, msg, ST_INSERT_TAGS, 1);
        param_text_array(msg, tbuf, tag_ends);
        bind_end(msg, b);
        b = stmt(slot, msg, ST_INSERT_ARTICLE_TAGS, 1);
        param_text_array(msg, tbuf, tag_ends);
        bind_end(msg, b);
    }
    b = stmt(slot, msg, ST_INSERTED_ARTICLE, 1);
    param_int(msg, viewer);
    bind_end(msg, b);
    submit(slot, msg, true);
}

fn update_article(slot: i64, r: Request&, slug: const u8[:]) {
    var pval: u8[>..] = [];
    let viewer = viewer_of(r);
    if viewer <= 0 { fail(slot, 401, "unauthorized"); return; }
    var title = Field { .. };
    var description = Field { .. };
    var body = Field { .. };
    var fbuf: u8[>..] = [];
    let ok = read_body(r.body, "article") { jr: json::Reader&, k =>
        if k == "title" { read_field(jr, title, fbuf); }
        else if k == "description" { read_field(jr, description, fbuf); }
        else if k == "body" { read_field(jr, body, fbuf); }
        else { json::skip(jr); }
    };
    if !ok { fail(slot, 422, "invalid body"); return; }
    if !optional(fbuf, title, true) || !optional(fbuf, description, true) || !optional(fbuf, body, true) {
        fail(slot, 422, "title, description and body must be non-empty strings");
        return;
    }
    if !segment(pval, slug) { fail(slot, 404, "article not found"); return; }
    begin(slot, K_UPDATE_ARTICLE, viewer);
    var msg: u8[>..] = [];
    let b = stmt(slot, msg, ST_UPDATE_ARTICLE, 5);
    param_int(msg, viewer);
    param_text(msg, pval);
    param_opt(msg, fbuf, title);
    param_opt(msg, fbuf, description);
    param_opt(msg, fbuf, body);
    bind_end(msg, b);
    submit(slot, msg, true);
}

fn create_comment(slot: i64, r: Request&, slug: const u8[:]) {
    var pval: u8[>..] = [];
    let viewer = viewer_of(r);
    if viewer <= 0 { fail(slot, 401, "unauthorized"); return; }
    var body = Field { .. };
    var fbuf: u8[>..] = [];
    let ok = read_body(r.body, "comment") { jr: json::Reader&, k =>
        if k == "body" { read_field(jr, body, fbuf); } else { json::skip(jr); }
    };
    if !ok || !required(fbuf, body) { fail(slot, 422, "body is required"); return; }
    if !segment(pval, slug) { fail(slot, 404, "article not found"); return; }
    begin(slot, K_CREATE_COMMENT, viewer);
    var msg: u8[>..] = [];
    let b = stmt(slot, msg, ST_CREATE_COMMENT, 3);
    param_int(msg, viewer);
    param_text(msg, value(fbuf, body));
    param_text(msg, pval);
    bind_end(msg, b);
    submit(slot, msg, true);
}

fn delete_comment(slot: i64, r: Request&, slug: const u8[:], id_text: const u8[:]) {
    var pval: u8[>..] = [];
    let viewer = viewer_of(r);
    if viewer <= 0 { fail(slot, 401, "unauthorized"); return; }
    let id, ok = parse_uint(id_text);
    if !ok || !segment(pval, slug) { fail(slot, 404, "comment not found"); return; }
    begin(slot, K_DELETE_COMMENT, viewer);
    var msg: u8[>..] = [];
    let b = stmt(slot, msg, ST_DELETE_COMMENT, 3);
    param_int(msg, viewer);
    param_int(msg, id);
    param_text(msg, pval);
    bind_end(msg, b);
    submit(slot, msg, true);
}

// ---------- answers ----------

fn col_null(r: Row&) -> bool { read32(r.data, r.pos) < 0 }

fn text_col(out: u8[>..]&, r: Row&) { let v, ok = col(r); put_nullable(out, v, ok); }

fn person(out: u8[>..]&, r: Row&) {
    key(out, "username"); text_col(out, r); out.push(',');
    key(out, "bio"); text_col(out, r); out.push(',');
    key(out, "image"); text_col(out, r);
}

// An article from the columns sql::columns selects.
fn write_article(out: u8[>..]&, r: Row&, body: bool) {
    out.push('{');
    key(out, "slug"); text_col(out, r); out.push(',');
    key(out, "title"); text_col(out, r); out.push(',');
    key(out, "description"); text_col(out, r); out.push(',');
    if body { key(out, "body"); text_col(out, r); out.push(','); }
    key(out, "createdAt"); put_time(out, col_int(r)); out.push(',');
    key(out, "updatedAt"); put_time(out, col_int(r)); out.push(',');
    key(out, "tagList");
    let tags, has = col(r);
    if has { out.append(tags); } else { out.append("[]"); }
    out.push(',');
    key(out, "favoritesCount"); format(out, col_int(r)); out.push(',');
    key(out, "favorited"); put_bool(out, col_bool(r)); out.push(',');
    key(out, "author"); out.push('{');
    person(out, r); out.push(',');
    key(out, "following"); put_bool(out, col_bool(r));
    out.append("}}");
}

// A comment from the columns id, created_at, updated_at, body, username, bio, image[, following].
fn write_comment(out: u8[>..]&, r: Row&, has_following: bool) {
    out.push('{');
    key(out, "id"); format(out, col_int(r)); out.push(',');
    key(out, "createdAt"); put_time(out, col_int(r)); out.push(',');
    key(out, "updatedAt"); put_time(out, col_int(r)); out.push(',');
    key(out, "body"); text_col(out, r); out.push(',');
    key(out, "author"); out.push('{');
    person(out, r); out.push(',');
    key(out, "following"); put_bool(out, has_following && col_bool(r));
    out.append("}}");
}

// {"user": ...} from the columns username, email, bio, image, with the token.
fn write_user(out: u8[>..]&, r: Row&, token: const u8[:]) {
    let username, u_ok = col(r);
    let email, e_ok = col(r);
    let bio, b_ok = col(r);
    let image, i_ok = col(r);
    out.append("{\"user\":{");
    key(out, "email"); put_nullable(out, email, e_ok); out.push(',');
    key(out, "token"); json_append_string(token, out); out.push(',');
    key(out, "username"); put_nullable(out, username, u_ok); out.push(',');
    key(out, "bio"); put_nullable(out, bio, b_ok); out.push(',');
    key(out, "image"); put_nullable(out, image, i_ok);
    out.append("}}");
}

fn first_row(rows: const u8[:]) -> const u8[:] {
    each_row(rows) { m => return m; };
    return rows[0..0];
}

// The rows of a request's last statement came back.
fn answer(slot: i64, rows: const u8[:]) {
    let c .= conns[slot];
    let close = c.close_after;
    let m = first_row(rows);
    var out: u8[>..] = [];
    match c.kind {
        K_FAVORITE, K_UNFAVORITE => { favorite_committed(slot, rows); return; },
        K_UPDATE_ARTICLE => { article_update_committed(slot, rows); return; },
        K_REGISTER, K_CURRENT, K_UPDATE_USER => {
            if m.len == 0 { fail(slot, 401, "unauthorized"); return; }
            var r = row(m);
            var tok: u8[>..] = [];
            if c.kind == K_REGISTER {
                if !jwt_issue(tok, jwt_key, col_int(r), now_ms / 1000) { fail(slot, 500, "could not sign token"); return; }
            } else { tok.append(ctx(slot)); }
            let at = begin_response(out, if c.kind == K_REGISTER { 201 } else { 200 }, close);
            write_user(out, r, tok);
            end_response(out, at);
        },
        K_LOGIN => {
            if m.len == 0 { fail(slot, 401, "invalid email or password"); return; }
            var r = row(m);
            var tok: u8[>..] = [];
            if !jwt_issue(tok, jwt_key, col_int(r), now_ms / 1000) { fail(slot, 500, "could not sign token"); return; }
            let at = begin_response(out, 200, close);
            write_user(out, r, tok);
            end_response(out, at);
            let hash, ok = col(r);
            hash_job(slot, true, ctx(slot), if ok { hash } else { "" });
            keep(slot, out);                          // sent once the password matches
            c.kind = K_LOGIN_CHECK;
            return;
        },
        K_PROFILE, K_FOLLOW, K_UNFOLLOW => {
            if m.len == 0 { fail(slot, 404, "profile not found"); return; }
            var r = row(m);
            let at = begin_response(out, 200, close);
            out.append("{\"profile\":{");
            person(out, r);
            out.push(',');
            key(out, "following");
            put_bool(out, if c.kind == K_PROFILE { col_bool(r) } else { c.kind == K_FOLLOW });
            out.append("}}");
            end_response(out, at);
        },
        K_LIST => {
            let at = begin_response(out, 200, close);
            out.append("{\"articles\":[");
            var count = 0;
            var first = true;
            each_row(rows) { d =>
                var r = row(d);
                if !col_null(r) {
                    if !first { out.push(','); }
                    first = false;
                    write_article(out, r, false);
                    col_skip(r);
                } else {
                    for i in 13 { col_skip(r); }
                }
                count = col_int(r);
            };
            out.append("],\"articlesCount\":");
            format(out, count);
            out.push('}');
            end_response(out, at);
        },
        K_ARTICLE, K_CREATE => {
            if m.len == 0 { fail(slot, 404, "article not found"); return; }
            var r = row(m);
            let at = begin_response(out, if c.kind == K_CREATE { 201 } else { 200 }, close);
            out.append("{\"article\":");
            write_article(out, r, true);
            out.push('}');
            end_response(out, at);
        },
        K_DELETE_ARTICLE, K_DELETE_COMMENT => {
            if m.len == 0 { fail(slot, 404, if c.kind == K_DELETE_ARTICLE { "article not found" } else { "comment not found" }); return; }
            var r = row(m);
            if col_int(r) != c.viewer { fail(slot, 403, "not the author"); return; }
            no_content(out, close);
        },
        K_COMMENTS => {
            if m.len == 0 { fail(slot, 404, "article not found"); return; }
            let at = begin_response(out, 200, close);
            out.append("{\"comments\":[");
            var first = true;
            each_row(rows) { d =>
                var r = row(d);
                if !col_null(r) {
                    if !first { out.push(','); }
                    first = false;
                    write_comment(out, r, true);
                }
            };
            out.append("]}");
            end_response(out, at);
        },
        K_CREATE_COMMENT => {
            if m.len == 0 { fail(slot, 404, "article not found"); return; }
            var r = row(m);
            let at = begin_response(out, 201, close);
            out.append("{\"comment\":");
            write_comment(out, r, false);
            out.push('}');
            end_response(out, at);
        },
        K_TAGS => {
            let at = begin_response(out, 200, close);
            out.append("{\"tags\":");
            var has = false;
            if m.len > 0 {
                var r = row(m);
                let v, ok = col(r);
                if ok { out.append(v); has = true; }
            }
            if !has { out.append("[]"); }
            out.push('}');
            end_response(out, at);
        },
        _ => { fail(slot, 500, "internal error"); return; },
    }
    reply(slot, out);
}

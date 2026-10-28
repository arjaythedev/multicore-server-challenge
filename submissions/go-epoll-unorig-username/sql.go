package main

// sql.go: the statements and how their (binary) rows become JSON.
//
// Every read statement takes the same five arrays, one element per waiting request:
// r.i ordinal, r.v viewer (or user id), r.lim, r.off, r.s (slug / username / tag / email).
// The per-request part is SPEC.md's reference SQL, with the page of ids cut before any per-article
// work so OFFSET rows cost one index step, a list's viewer-independent article data computed once per
// distinct article, tag names fetched by primary key, and the viewer flags skipped for anonymous viewers.

const R = `unnest($1::int4[], $2::int8[], $3::int8[], $4::int8[], $5::text[]) r(i, v, lim, off, s)`

const slugify = `trim(both '-' from lower(regexp_replace($2::text, '[^A-Za-z0-9]+', '-', 'g')))`

func def(name, sql string) string {
	stmts[name] = sql
	return name
}

// artCols is the Article column list for article row a with author row u and viewer v. Empty
// cnt/favd/fol keep the reference favoritesCount, favorited and following expressions.
func artCols(a, v string, body bool, cnt, favd, fol string) string {
	if cnt == "" {
		cnt = `(SELECT count(*) FROM favorites f WHERE f.article_id = ` + a + `.id)`
	}
	if favd == "" {
		favd = `(` + v + ` <> 0 AND EXISTS (SELECT 1 FROM favorites f WHERE f.user_id = ` + v + ` AND f.article_id = ` + a + `.id))`
	}
	if fol == "" {
		fol = `(` + v + ` <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ` + v + ` AND fo.followee_id = ` + a + `.author_id))`
	}
	s := a + `.slug, ` + a + `.title, ` + a + `.description, `
	if body {
		s += a + `.body, `
	}
	return s + a + `.created_at, ` + a + `.updated_at,
  ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) n FROM article_tags at WHERE at.article_id = ` + a + `.id ORDER BY n),
  ` + cnt + `, ` + favd + `, u.username, u.bio, u.image, ` + fol
}

// enriched is a CTE e with the viewer-independent list Article columns (tags, favorite count, author) of
// every article on a page of p, computed once per statement however many of its requests show that article.
const enriched = `e AS MATERIALIZED (SELECT a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at,
  ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) n FROM article_tags at WHERE at.article_id = a.id ORDER BY n) tags,
  (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) fc, u.username, u.bio, u.image
  FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = ANY(ARRAY(SELECT DISTINCT id FROM p)))`

// list builds the page and capped-count statements of an article list from its page-of-ids query
// and its count source.
func list(name, page, count, fol string) []string {
	if fol == "" {
		fol = `(p.v <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = p.v AND fo.followee_id = e.author_id))`
	}
	return []string{
		def(name, `WITH p AS MATERIALIZED (SELECT r.i, r.v, x.id FROM `+R+` CROSS JOIN LATERAL (`+page+`) x), `+enriched+`
  SELECT p.i, e.slug, e.title, e.description, e.created_at, e.updated_at, e.tags, e.fc,
    (p.v <> 0 AND EXISTS (SELECT 1 FROM favorites f WHERE f.user_id = p.v AND f.article_id = e.id)),
    e.username, e.bio, e.image, `+fol+`
  FROM p JOIN e ON e.id = p.id ORDER BY p.i, p.id DESC`),
		def(name+"_n", `SELECT r.i, (SELECT count(*) FROM (`+count+` LIMIT 1000) s) FROM `+R),
	}
}

const (
	kTags = iota
	kArticle
	kComments
	kProfile
	kUser
	kLogin
	kAll
	kTag
	kAuthor
	kFav
	kFeed
	nKinds
)

var kinds [nKinds]kind

func init() {
	listRow := func(j *job, st int, c [][]byte) {
		if st == 1 {
			j.n = i64(c[0])
			return
		}
		if j.rows > 0 {
			j.out = append(j.out, ',')
		}
		j.out = appendArticle(j.out, c, false)
	}
	const lp = `{"articles":[`
	byUsername := `(SELECT u.id FROM users u WHERE u.username = r.s)`
	byTag := `(SELECT t.id FROM tags t WHERE t.name = r.s)`
	kinds = [nKinds]kind{
		kTags: {[]string{def("tags", `SELECT r.i, (SELECT array_agg(t.name ORDER BY t.name) FROM tags t) FROM `+R)},
			`{"tags":`, func(j *job, _ int, c [][]byte) {
				j.out = append(appendTextArray(j.out, c[0]), '}')
			}},
		kArticle: {[]string{def("article", `SELECT r.i, `+artCols("a", "r.v", true, "", "", "")+`
  FROM `+R+` JOIN articles a ON a.slug = r.s JOIN users u ON u.id = a.author_id`)},
			`{"article":`, func(j *job, _ int, c [][]byte) {
				j.out = append(appendArticle(j.out, c, true), '}')
			}},
		kComments: {[]string{def("comments", `SELECT r.i, c.* FROM `+R+` JOIN articles a ON a.slug = r.s
  LEFT JOIN LATERAL (
    SELECT c.id, c.created_at, c.updated_at, c.body, u.username, u.bio, u.image,
           (r.v <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = c.author_id))
      FROM comments c JOIN users u ON u.id = c.author_id
     WHERE c.article_id = a.id
     ORDER BY c.created_at DESC, c.id DESC
     LIMIT 100) c ON true`)},
			`{"comments":[`, func(j *job, _ int, c [][]byte) {
				j.n = 1 // the article exists
				if c[0] == nil {
					return
				}
				if j.rows > 0 {
					j.out = append(j.out, ',')
				}
				j.out = appendComment(j.out, c, c[7][0] == 1)
			}},
		kProfile: {[]string{def("profile", `SELECT r.i, u.username, u.bio, u.image,
  (r.v <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = u.id))
  FROM `+R+` JOIN users u ON u.username = r.s`)},
			`{"profile":`, func(j *job, _ int, c [][]byte) {
				j.out = append(appendProfile(j.out, c[:3], c[3][0] == 1), '}')
			}},
		kUser: {[]string{def("user", `SELECT r.i, u.username, u.email, u.bio, u.image FROM `+R+` JOIN users u ON u.id = r.v`)},
			`{"user":`, func(j *job, _ int, c [][]byte) { j.out = appendUser(j.out, c) }},
		kLogin: {[]string{def("login", `SELECT r.i, u.username, u.email, u.bio, u.image, u.id, u.password_hash
  FROM `+R+` JOIN users u ON u.email = r.s`)},
			`{"user":`, func(j *job, _ int, c [][]byte) {
				j.out = appendUser(j.out, c)
				j.n, j.hash = i64(c[4]), string(c[5])
			}},
		kAll: {list("list_all",
			`SELECT a.id FROM articles a ORDER BY a.id DESC LIMIT r.lim OFFSET r.off`,
			`SELECT 1 FROM articles a`, ""), lp, listRow},
		kTag: {list("list_tag",
			`SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = `+byTag+` ORDER BY at.article_id DESC LIMIT r.lim OFFSET r.off`,
			`SELECT 1 FROM article_tags at WHERE at.tag_id = `+byTag, ""), lp, listRow},
		kAuthor: {list("list_author",
			`SELECT a.id FROM articles a WHERE a.author_id = `+byUsername+` ORDER BY a.id DESC LIMIT r.lim OFFSET r.off`,
			`SELECT 1 FROM articles a WHERE a.author_id = `+byUsername, ""), lp, listRow},
		kFav: {list("list_fav",
			`SELECT f.article_id AS id FROM favorites f WHERE f.user_id = `+byUsername+` ORDER BY f.article_id DESC LIMIT r.lim OFFSET r.off`,
			`SELECT 1 FROM favorites f WHERE f.user_id = `+byUsername, ""), lp, listRow},
		// Every feed article's author is followed by the viewer in the statement's snapshot.
		kFeed: {list("list_feed",
			`SELECT x.id FROM follows fo CROSS JOIN LATERAL (
       SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT r.lim + r.off) x
     WHERE fo.follower_id = r.v ORDER BY x.id DESC LIMIT r.lim OFFSET r.off`,
			`SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v)`,
			"true"), lp, listRow},
	}
}

// ---------- writes: one statement each (the article insert is four) ----------

var (
	wRegister = def("w_register", `INSERT INTO users (username, email, password_hash) VALUES ($1::text, $2::text, $3::text)
  ON CONFLICT DO NOTHING RETURNING username, email, bio, image, id`)
	wUser = def("w_user", `UPDATE users SET email = COALESCE($2::text, email), username = COALESCE($3::text, username),
  password_hash = COALESCE($4::text, password_hash), bio = COALESCE($5::text, bio), image = COALESCE($6::text, image)
  WHERE id = $1::int8 RETURNING username, email, bio, image`)
	wFollow = def("w_follow", `WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2::text),
  w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1::int8, id FROM t ON CONFLICT DO NOTHING)
  SELECT username, bio, image FROM t`)
	wUnfollow = def("w_unfollow", `WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2::text),
  w AS (DELETE FROM follows WHERE follower_id = $1::int8 AND followee_id IN (SELECT id FROM t))
  SELECT username, bio, image FROM t`)

	// The new article's id is the session's currval of the sequence in the statements that follow.
	wArticle = def("w_article", `INSERT INTO articles (id, slug, author_id, title, description, body)
  SELECT n.id, `+slugify+` || '-' || n.id, $1::int8, $2::text, $3::text, $4::text
    FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n`)
	wTags        = def("w_tags", `INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ORDER BY 1 ON CONFLICT (name) DO NOTHING`)
	wArticleTags = def("w_article_tags", `INSERT INTO article_tags (article_id, tag_id)
  SELECT currval(pg_get_serial_sequence('articles', 'id')), t.id FROM tags t WHERE t.name = ANY($1::text[])`)
	wArticleNew = def("w_article_new", `SELECT `+artCols("a", "$1::int8", true, "", "", "")+`
  FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = (SELECT currval(pg_get_serial_sequence('articles', 'id')))`)

	// Row: the article's author_id, then the updated Article (NULL unless the viewer is the author).
	wArticleUpdate = def("w_article_update", `WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1::text),
  w AS (UPDATE articles a SET title = COALESCE($2::text, a.title), description = COALESCE($3::text, a.description),
          body = COALESCE($4::text, a.body), updated_at = now(),
          slug = CASE WHEN $2::text IS NULL THEN a.slug ELSE `+slugify+` || '-' || a.id END
        FROM t WHERE a.id = t.id AND t.author_id = $5::int8
        RETURNING a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, a.author_id)
  SELECT t.author_id, `+artCols("w", "$5::int8", true, "", "", "")+`
    FROM t LEFT JOIN w ON true LEFT JOIN users u ON u.id = w.author_id`)
	wArticleDelete = def("w_article_delete", `WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1::text),
  w AS (DELETE FROM articles WHERE id IN (SELECT id FROM t WHERE author_id = $2::int8))
  SELECT author_id FROM t`)

	// The statement's own insert/delete is not in its snapshot, so the count is adjusted by it.
	wFavorite = def("w_favorite", `WITH a AS (SELECT * FROM articles WHERE slug = $2::text),
  w AS (INSERT INTO favorites (user_id, article_id) SELECT $1::int8, id FROM a ON CONFLICT DO NOTHING RETURNING 1)
  SELECT `+artCols("a", "$1::int8", true,
		`(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) + (SELECT count(*) FROM w)`, "true", "")+`
    FROM a JOIN users u ON u.id = a.author_id`)
	wUnfavorite = def("w_unfavorite", `WITH a AS (SELECT * FROM articles WHERE slug = $2::text),
  w AS (DELETE FROM favorites WHERE user_id = $1::int8 AND article_id IN (SELECT id FROM a) RETURNING 1)
  SELECT `+artCols("a", "$1::int8", true,
		`(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) - (SELECT count(*) FROM w)`, "false", "")+`
    FROM a JOIN users u ON u.id = a.author_id`)

	wComment = def("w_comment", `WITH c AS (INSERT INTO comments (article_id, author_id, body)
      SELECT id, $2::int8, $3::text FROM articles WHERE slug = $1::text
      RETURNING id, created_at, updated_at, body, author_id)
  SELECT c.id, c.created_at, c.updated_at, c.body, u.username, u.bio, u.image FROM c JOIN users u ON u.id = c.author_id`)
	wCommentDelete = def("w_comment_delete", `WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
      WHERE c.id = $1::int8 AND a.slug = $2::text),
  w AS (DELETE FROM comments WHERE id IN (SELECT id FROM t WHERE author_id = $3::int8))
  SELECT author_id FROM t`)
)

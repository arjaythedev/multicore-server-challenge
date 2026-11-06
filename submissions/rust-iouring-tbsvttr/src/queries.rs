use crate::wire::{OID_INT4_ARR, OID_INT8, OID_INT8_ARR, OID_TEXT, OID_TEXT_ARR};

pub struct PreparedDef {
    pub name: &'static str,
    pub sql: String,
    pub oids: &'static [u32],
}

fn def(name: &'static str, sql: impl Into<String>, oids: &'static [u32]) -> PreparedDef {
    PreparedDef {
        name,
        sql: sql.into(),
        oids,
    }
}

// Single-pass count capped at 1000 rows.
fn capped_count(subquery: &str) -> String {
    format!("(SELECT count(*) FROM ({subquery} LIMIT 1000) s)")
}

fn feed_def() -> PreparedDef {
    def(
        "feed",
        format!(
            "WITH u AS MATERIALIZED ( \
               SELECT r.k, r.v, r.depth, \
                 ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v) AS fids \
               FROM unnest($1::int8[], $2::int8[]) WITH ORDINALITY r(v, depth, k) \
             ), \
             hub_floors AS MATERIALIZED ( \
               SELECT h.fid, \
                 (SELECT a.id FROM articles a WHERE a.author_id = h.fid ORDER BY a.id DESC LIMIT 1 OFFSET h.depth - 1) AS floor_id, \
                 EXISTS (SELECT 1 FROM articles a WHERE a.author_id = h.fid ORDER BY a.id ASC LIMIT 1 OFFSET 999) AS big \
               FROM ( \
                 SELECT f.fid, max(u.depth) AS depth \
                 FROM u, unnest(u.fids) AS f(fid) \
                 GROUP BY f.fid HAVING count(*) >= 2 \
                 ORDER BY count(*) DESC, f.fid LIMIT 48 \
               ) h \
             ), \
             cap_authors AS MATERIALIZED ( \
               SELECT ARRAY(SELECT hf.fid FROM hub_floors hf WHERE hf.big) AS fids \
             ), \
             uf AS MATERIALIZED ( \
               SELECT u.k, u.fids, u.depth, \
                 COALESCE((SELECT max(hf.floor_id) FROM hub_floors hf WHERE hf.fid = ANY(u.fids)), 0::int8) AS floor_id \
               FROM u \
             ), \
             ff AS MATERIALIZED ( \
               SELECT f.fid, max(uf.depth) AS depth, min(uf.floor_id) AS floor_id \
               FROM uf, unnest(uf.fids) AS f(fid) \
               GROUP BY f.fid ORDER BY f.fid \
             ) \
             SELECT 0::int8, uf.k, \
               CASE WHEN cardinality(uf.fids) = 0 THEN 0::int8 \
                    WHEN uf.fids && (SELECT fids FROM cap_authors) THEN 1000::int8 \
                    ELSE {} \
               END, \
               uf.floor_id, \
               uf.fids \
             FROM uf \
             UNION ALL \
             SELECT 1::int8, ff.fid, 0::int8, 0::int8, \
               ARRAY(SELECT a.id FROM articles a WHERE a.author_id = ff.fid AND a.id >= ff.floor_id ORDER BY a.id DESC LIMIT ff.depth) \
             FROM ff",
            capped_count("SELECT 1 FROM articles a WHERE a.author_id = ANY(uf.fids)")
        ),
        &[OID_INT8_ARR, OID_INT8_ARR],
    )
}

pub fn read_catalog() -> Vec<PreparedDef> {
    vec![
        // Sequential scan over the 2-page tags heap; sorted in memory by ReadWorker.
        def("tags", "SELECT id, name FROM tags", &[]),
        def(
            "uid",
            "SELECT u.id, u.username, u.email, u.bio, u.image \
             FROM users u WHERE u.id = ANY($1::int8[])",
            &[OID_INT8_ARR],
        ),
        def(
            "uemail",
            "SELECT u.id, u.username, u.email, u.bio, u.image, u.password_hash \
             FROM users u WHERE u.email = ANY($1::text[])",
            &[OID_TEXT_ARR],
        ),
        def(
            "prof",
            "SELECT r.k, u.username, u.bio, u.image, \
               CASE WHEN r.v > 0 THEN EXISTS (SELECT 1 FROM follows f WHERE f.follower_id = r.v AND f.followee_id = u.id) ELSE false END \
             FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY r(v, uname, k) \
             CROSS JOIN LATERAL (SELECT id, username, bio, image FROM users WHERE username = r.uname) u",
            &[OID_INT8_ARR, OID_TEXT_ARR],
        ),
        def(
            "aslug",
            "SELECT 0::int8, a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.body \
             FROM articles a WHERE a.slug = ANY($1::text[])",
            &[OID_TEXT_ARR],
        ),
        def(
            "aid",
            "SELECT 0::int8, a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.body \
             FROM articles a WHERE a.id = ANY($1::int8[])",
            &[OID_INT8_ARR],
        ),
        def(
            "cmts",
            "WITH t AS MATERIALIZED ( \
               SELECT r.k, c.id, c.body, c.created_at, c.updated_at, c.author_id \
               FROM unnest($1::text[]) WITH ORDINALITY r(slug, k) JOIN articles a ON a.slug = r.slug \
               LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c \
                 WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true \
             ), \
             au AS MATERIALIZED ( \
               SELECT COALESCE(array_agg(DISTINCT t.author_id) FILTER (WHERE t.author_id IS NOT NULL), '{}'::int8[]) AS aids FROM t \
             ) \
             SELECT 0::int8, t.k, t.id, t.author_id, t.created_at, t.updated_at, t.body, NULL::text, NULL::text FROM t \
             UNION ALL \
             SELECT 1::int8, u.id, 0::int8, 0::int8, NULL::timestamptz, NULL::timestamptz, u.username, u.bio, u.image \
             FROM au CROSS JOIN LATERAL unnest(au.aids) aid JOIN users u ON u.id = aid \
             UNION ALL \
             SELECT 2::int8, rv.v, fo.followee_id, 0::int8, NULL::timestamptz, NULL::timestamptz, NULL::text, NULL::text, NULL::text \
             FROM ( \
               SELECT rv.v, array_agg(t.author_id) AS kaids \
               FROM unnest($2::int8[], $3::int8[]) rv(v, k) \
               JOIN t ON t.k = rv.k AND t.author_id IS NOT NULL \
               GROUP BY rv.v \
             ) rv \
             CROSS JOIN LATERAL unnest(ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = rv.v AND fo.followee_id = ANY(rv.kaids))) fo(followee_id)",
            &[OID_TEXT_ARR, OID_INT8_ARR, OID_INT8_ARR],
        ),
        def(
            "global",
            "SELECT 0::int8, (SELECT count(*) FROM (SELECT 1 FROM articles ORDER BY id ASC LIMIT 1000) s), 0::int8, \
             NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz \
             UNION ALL \
             SELECT r.k, a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at \
             FROM unnest($1::int8[], $2::int8[]) WITH ORDINALITY r(lim, off, k) \
             CROSS JOIN LATERAL (SELECT a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at \
               FROM articles a ORDER BY a.id DESC LIMIT r.lim OFFSET r.off) a",
            &[OID_INT8_ARR, OID_INT8_ARR],
        ),
        def(
            "global_win",
            "SELECT 0::int8, (SELECT count(*) FROM (SELECT 1 FROM articles ORDER BY id ASC LIMIT 1000) s), 0::int8, \
             NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz \
             UNION ALL \
             SELECT 1::int8, a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at \
             FROM (SELECT a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at \
               FROM articles a ORDER BY a.id DESC LIMIT $1) a",
            &[OID_INT8],
        ),
        def(
            "tag",
            "WITH u AS MATERIALIZED ( \
               SELECT r.k, t.id, \
                 CASE WHEN t.id IS NULL THEN 0::int8 \
                      WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = t.id LIMIT 1 OFFSET 999) THEN 1000::int8 \
                      ELSE (SELECT count(*) FROM article_tags at WHERE at.tag_id = t.id) \
                 END AS cnt \
               FROM unnest($1::text[]) WITH ORDINALITY r(tag, k) LEFT JOIN tags t ON t.name = r.tag \
             ) \
             SELECT -u.k, u.cnt, 0::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz FROM u \
             UNION ALL \
             SELECT p.k, a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at \
             FROM unnest($2::int8[], $3::int8[], $4::int8[]) WITH ORDINALITY p(uk, lim, off, k) \
             JOIN u ON u.k = p.uk AND u.id IS NOT NULL AND u.cnt > p.off \
             CROSS JOIN LATERAL (SELECT at.article_id FROM article_tags at WHERE at.tag_id = u.id \
               ORDER BY at.article_id DESC LIMIT p.lim OFFSET p.off) x \
             JOIN articles a ON a.id = x.article_id",
            &[OID_TEXT_ARR, OID_INT8_ARR, OID_INT8_ARR, OID_INT8_ARR],
        ),
        def(
            "author",
            format!(
                "WITH u AS MATERIALIZED ( \
                   SELECT r.k, usr.id, CASE WHEN usr.id IS NULL THEN 0::int8 ELSE {} END AS cnt \
                   FROM unnest($1::text[]) WITH ORDINALITY r(username, k) LEFT JOIN users usr ON usr.username = r.username \
                 ) \
                 SELECT -u.k, u.cnt, 0::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz FROM u \
                 UNION ALL \
                 SELECT p.k, a.id, u.id, a.slug, a.title, a.description, a.created_at, a.updated_at \
                 FROM unnest($2::int8[], $3::int8[], $4::int8[]) WITH ORDINALITY p(uk, lim, off, k) \
                 JOIN u ON u.k = p.uk AND u.id IS NOT NULL AND u.cnt > p.off \
                 CROSS JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at \
                   FROM articles a WHERE a.author_id = u.id ORDER BY a.id DESC LIMIT p.lim OFFSET p.off) a",
                capped_count("SELECT 1 FROM articles a WHERE a.author_id = usr.id")
            ),
            &[OID_TEXT_ARR, OID_INT8_ARR, OID_INT8_ARR, OID_INT8_ARR],
        ),
        def(
            "favlist",
            format!(
                "WITH u AS MATERIALIZED ( \
                   SELECT r.k, usr.id, CASE WHEN usr.id IS NULL THEN 0::int8 ELSE {} END AS cnt \
                   FROM unnest($1::text[]) WITH ORDINALITY r(username, k) LEFT JOIN users usr ON usr.username = r.username \
                 ) \
                 SELECT -u.k, u.cnt, 0::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz FROM u \
                 UNION ALL \
                 SELECT p.k, a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at \
                 FROM unnest($2::int8[], $3::int8[], $4::int8[]) WITH ORDINALITY p(uk, lim, off, k) \
                 JOIN u ON u.k = p.uk AND u.id IS NOT NULL AND u.cnt > p.off \
                 CROSS JOIN LATERAL (SELECT f.article_id FROM favorites f WHERE f.user_id = u.id \
                   ORDER BY f.article_id DESC LIMIT p.lim OFFSET p.off) x \
                 JOIN articles a ON a.id = x.article_id",
                capped_count("SELECT 1 FROM favorites f WHERE f.user_id = usr.id")
            ),
            &[OID_TEXT_ARR, OID_INT8_ARR, OID_INT8_ARR, OID_INT8_ARR],
        ),
        feed_def(),
        def(
            "artmeta",
            "SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at \
             FROM articles a WHERE a.id = ANY($1::int8[])",
            &[OID_INT8_ARR],
        ),
        def(
            "artx",
            "SELECT r.id, \
               ARRAY(SELECT at.tag_id FROM article_tags at WHERE at.article_id = r.id), \
               (SELECT count(*) FROM favorites f WHERE f.article_id = r.id) \
             FROM unnest($1::int8[]) AS r(id)",
            &[OID_INT8_ARR],
        ),
        def(
            "artau",
            "SELECT u.id, u.username, u.bio, u.image \
             FROM users u WHERE u.id = ANY($1::int8[])",
            &[OID_INT8_ARR],
        ),
        def(
            "flags",
            "SELECT 0::int8, p.v, f.article_id \
             FROM unnest($1::int8[], $3::int4[], $4::int4[]) p(v, s, e) \
             CROSS JOIN LATERAL ( \
               SELECT f.article_id FROM favorites f WHERE f.user_id = p.v AND f.article_id = ANY(($2::int8[])[p.s : p.e]) \
             ) f \
             UNION ALL \
             SELECT 1::int8, q.v, fo.followee_id \
             FROM unnest($5::int8[], $7::int4[], $8::int4[]) q(v, s, e) \
             CROSS JOIN LATERAL ( \
               SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = q.v AND fo.followee_id = ANY(($6::int8[])[q.s : q.e]) \
             ) fo",
            &[
                OID_INT8_ARR,
                OID_INT8_ARR,
                OID_INT4_ARR,
                OID_INT4_ARR,
                OID_INT8_ARR,
                OID_INT8_ARR,
                OID_INT4_ARR,
                OID_INT4_ARR,
            ],
        ),
    ]
}

pub fn write_catalog() -> Vec<PreparedDef> {
    vec![
        def(
            "register",
            "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING \
             RETURNING id, username, email, bio, image",
            &[OID_TEXT, OID_TEXT, OID_TEXT],
        ),
        def(
            "upduser",
            "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), \
             password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) \
             WHERE id = $1 RETURNING id, username, email, bio, image",
            &[OID_INT8, OID_TEXT, OID_TEXT, OID_TEXT, OID_TEXT, OID_TEXT],
        ),
        def(
            "follow",
            "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), \
             w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING) \
             SELECT username, bio, image FROM t",
            &[OID_INT8, OID_TEXT],
        ),
        def(
            "unfollow",
            "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), \
             w AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM t)) \
             SELECT username, bio, image FROM t",
            &[OID_INT8, OID_TEXT],
        ),
        def(
            "fav",
            "WITH t AS (SELECT id FROM articles WHERE slug = $2), \
             w AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING) \
             SELECT id FROM t",
            &[OID_INT8, OID_TEXT],
        ),
        def(
            "unfav",
            "WITH t AS (SELECT id FROM articles WHERE slug = $2), \
             w AS (DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM t)) \
             SELECT id FROM t",
            &[OID_INT8, OID_TEXT],
        ),
        def(
            "fav_batch",
            "WITH r AS (SELECT x.k, x.uid, a.id AS aid FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY x(uid, slug, k) \
               CROSS JOIN LATERAL (SELECT id FROM articles WHERE slug = x.slug) a), \
             w AS (INSERT INTO favorites (user_id, article_id) SELECT DISTINCT uid, aid FROM r ORDER BY 2, 1 ON CONFLICT DO NOTHING) \
             SELECT k, aid FROM r",
            &[OID_INT8_ARR, OID_TEXT_ARR],
        ),
        def(
            "unfav_batch",
            "WITH r AS (SELECT x.k, x.uid, a.id AS aid FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY x(uid, slug, k) \
               CROSS JOIN LATERAL (SELECT id FROM articles WHERE slug = x.slug) a), \
             w AS (DELETE FROM favorites f USING r WHERE f.user_id = r.uid AND f.article_id = r.aid) \
             SELECT k, aid FROM r",
            &[OID_INT8_ARR, OID_TEXT_ARR],
        ),
        def(
            "follow_batch",
            "WITH r AS (SELECT x.k, x.fid, u.id AS tid, u.username, u.bio, u.image \
               FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY x(fid, uname, k) \
               CROSS JOIN LATERAL (SELECT id, username, bio, image FROM users WHERE username = x.uname) u), \
             w AS (INSERT INTO follows (follower_id, followee_id) SELECT DISTINCT fid, tid FROM r ORDER BY 1, 2 ON CONFLICT DO NOTHING) \
             SELECT k, username, bio, image FROM r",
            &[OID_INT8_ARR, OID_TEXT_ARR],
        ),
        def(
            "unfollow_batch",
            "WITH r AS (SELECT x.k, x.fid, u.id AS tid, u.username, u.bio, u.image \
               FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY x(fid, uname, k) \
               CROSS JOIN LATERAL (SELECT id, username, bio, image FROM users WHERE username = x.uname) u), \
             w AS (DELETE FROM follows fo USING r WHERE fo.follower_id = r.fid AND fo.followee_id = r.tid) \
             SELECT k, username, bio, image FROM r",
            &[OID_INT8_ARR, OID_TEXT_ARR],
        ),
        def(
            "newart",
            "WITH ins AS (INSERT INTO articles (id, slug, author_id, title, description, body) \
               SELECT n.id, $5::text || '-' || n.id, $1, $2, $3, $4 \
               FROM (SELECT nextval('articles_id_seq'::regclass) AS id) n \
               RETURNING id, slug, title, description, body, created_at, updated_at, author_id), \
             existing AS MATERIALIZED (SELECT id, name FROM tags WHERE name = ANY($6::text[])), \
             new_tags AS (INSERT INTO tags (name) \
               SELECT name FROM (SELECT DISTINCT unnest($6::text[]) AS name) names \
               WHERE NOT EXISTS (SELECT 1 FROM existing e WHERE e.name = names.name) \
               ORDER BY name ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id, name), \
             all_tags AS (SELECT id, name FROM existing UNION ALL SELECT id, name FROM new_tags), \
             ins_at AS (INSERT INTO article_tags (article_id, tag_id) SELECT ins.id, all_tags.id FROM ins, all_tags) \
             SELECT ins.slug, ins.title, ins.description, ins.body, \
               ARRAY(SELECT name FROM all_tags ORDER BY name), \
               ins.created_at, ins.updated_at, \
               EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = ins.id AND f.user_id = $1), \
               (SELECT count(*) FROM favorites f WHERE f.article_id = ins.id), \
               u.username, u.bio, u.image, \
               EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = ins.author_id) \
             FROM ins JOIN users u ON u.id = ins.author_id",
            &[OID_INT8, OID_TEXT, OID_TEXT, OID_TEXT, OID_TEXT, OID_TEXT_ARR],
        ),
        def(
            "updart",
            "WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1), \
             w AS (UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), \
               body = COALESCE($4, body), \
               slug = CASE WHEN $2::text IS NULL THEN slug ELSE $6::text || '-' || id END, updated_at = now() \
               WHERE id = (SELECT id FROM t WHERE author_id = $5) RETURNING 1) \
             SELECT t.id, t.author_id FROM t",
            &[OID_TEXT, OID_TEXT, OID_TEXT, OID_TEXT, OID_INT8, OID_TEXT],
        ),
        def(
            "delart",
            "WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1), \
             w AS (DELETE FROM articles WHERE id = (SELECT id FROM t WHERE author_id = $2)) \
             SELECT author_id FROM t",
            &[OID_TEXT, OID_INT8],
        ),
        def(
            "newcmt",
            "WITH t AS (SELECT id FROM articles WHERE slug = $1), \
             c AS (INSERT INTO comments (article_id, author_id, body) SELECT id, $2, $3 FROM t \
               RETURNING id, body, created_at, updated_at, author_id) \
             SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image \
             FROM c JOIN users u ON u.id = c.author_id",
            &[OID_TEXT, OID_INT8, OID_TEXT],
        ),
        def(
            "newcmt_batch",
            "WITH r AS MATERIALIZED (SELECT s.k, s.uid, s.body, s.aid, nextval('comments_id_seq'::regclass) AS cid \
               FROM (SELECT x.k, x.uid, x.body, a.id AS aid \
                 FROM unnest($1::int8[], $2::text[], $3::text[]) WITH ORDINALITY x(uid, slug, body, k) \
                 CROSS JOIN LATERAL (SELECT id FROM articles WHERE slug = x.slug) a ORDER BY x.k) s), \
             ins AS (INSERT INTO comments (id, article_id, author_id, body) \
               SELECT cid, aid, uid, body FROM r ORDER BY aid, cid \
               RETURNING id, body, created_at, updated_at, author_id) \
             SELECT r.k, ins.id, ins.body, ins.created_at, ins.updated_at, u.username, u.bio, u.image \
             FROM r JOIN ins ON ins.id = r.cid JOIN users u ON u.id = ins.author_id",
            &[OID_INT8_ARR, OID_TEXT_ARR, OID_TEXT_ARR],
        ),
        def(
            "delcmt",
            "WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id \
               WHERE c.id = $1 AND a.slug = $2), \
             w AS (DELETE FROM comments WHERE id = (SELECT id FROM t WHERE author_id = $3)) \
             SELECT author_id FROM t",
            &[OID_INT8, OID_TEXT, OID_INT8],
        ),
    ]
}

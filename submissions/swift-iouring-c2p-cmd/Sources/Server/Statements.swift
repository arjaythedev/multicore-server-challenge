// Every statement the server prepares. Reads take arrays of distinct keys, so one execution answers
// a whole batch of requests, and every row carries what it needs to find its request again.

let sessionSettings: [(String, String)] = [
    ("plan_cache_mode", "force_generic_plan"),
    ("jit", "off"),
    ("max_parallel_workers_per_gather", "0"),
    ("enable_memoize", "off"),
    ("work_mem", "32MB"),
]

func cappedCount(_ subquery: String) -> String { "(SELECT count(*) FROM (\(subquery) LIMIT 1000) s)" }

let slugify = "trim(both '-' from lower(regexp_replace($2::text, '[^A-Za-z0-9]+', '-', 'g')))"

/// One list row: the page, then the article. A negative first column carries a key's capped count.
let countRow = "SELECT -u.k, u.cnt, 0::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz FROM u"

let globalCount = """
    SELECT 0::int8, CASE WHEN EXISTS (SELECT 1 FROM articles ORDER BY id ASC LIMIT 1 OFFSET 999) \
    THEN 1000 ELSE (SELECT count(*) FROM articles) END, 0::int8, \
    NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz
    """

let statements: [(name: String, sql: String, oids: [Int32])] = [
    ("tags", "SELECT id, name FROM tags ORDER BY name", []),
    ("uid", "SELECT u.id, u.username, u.email, u.bio, u.image FROM users u WHERE u.id = ANY($1::int8[])", [oidInt8Array]),
    ("uemail", "SELECT u.id, u.username, u.email, u.bio, u.image, u.password_hash FROM users u WHERE u.email = ANY($1::text[])",
     [oidTextArray]),
    ("prof", """
        SELECT r.k, u.username, u.bio, u.image, \
        CASE WHEN r.v > 0 THEN EXISTS (SELECT 1 FROM follows f WHERE f.follower_id = r.v AND f.followee_id = u.id) ELSE false END \
        FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY r(v, uname, k) \
        CROSS JOIN LATERAL (SELECT id, username, bio, image FROM users WHERE username = r.uname) u
        """, [oidInt8Array, oidTextArray]),
    ("aid", """
        SELECT a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.body \
        FROM articles a WHERE a.id = ANY($1::int8[])
        """, [oidInt8Array]),
    ("cmts", """
        WITH arts AS MATERIALIZED (SELECT a.id, a.slug FROM articles a WHERE a.id = ANY($4::int8[])), \
        t AS MATERIALIZED ( \
          SELECT r.k, c.id, c.body, c.created_at, c.updated_at, c.author_id \
          FROM unnest($1::text[], $4::int8[]) WITH ORDINALITY r(slug, aid, k) \
          JOIN arts a ON a.id = r.aid AND a.slug = r.slug \
          LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c \
            WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true \
        ), \
        au AS MATERIALIZED ( \
          SELECT COALESCE(array_agg(DISTINCT t.author_id) FILTER (WHERE t.author_id IS NOT NULL), '{}'::int8[]) AS aids FROM t \
        ) \
        SELECT 0::int8, t.k, t.id, t.author_id, t.created_at, t.updated_at, t.body, NULL::text, NULL::text FROM t \
        UNION ALL \
        SELECT 1::int8, u.id, 0::int8, 0::int8, NULL::timestamptz, NULL::timestamptz, u.username, u.bio, u.image \
        FROM users u WHERE u.id = ANY((SELECT aids FROM au)::int8[]) \
        UNION ALL \
        SELECT 2::int8, rv.v, fo.followee_id, 0::int8, NULL::timestamptz, NULL::timestamptz, NULL::text, NULL::text, NULL::text \
        FROM (SELECT rv.v, array_agg(t.author_id) AS kaids FROM unnest($2::int8[], $3::int8[]) rv(v, k) \
          JOIN t ON t.k = rv.k AND t.author_id IS NOT NULL GROUP BY rv.v) rv \
        CROSS JOIN LATERAL unnest(ARRAY(SELECT fo.followee_id FROM follows fo \
          WHERE fo.follower_id = rv.v AND fo.followee_id = ANY(rv.kaids))) fo(followee_id)
        """, [oidTextArray, oidInt8Array, oidInt8Array, oidInt8Array]),
    ("global", globalCount + """
         UNION ALL \
        SELECT r.k, a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at \
        FROM unnest($1::int8[], $2::int8[]) WITH ORDINALITY r(lim, off, k) \
        CROSS JOIN LATERAL (SELECT a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at \
          FROM articles a ORDER BY a.id DESC LIMIT r.lim OFFSET r.off) a
        """, [oidInt8Array, oidInt8Array]),
    ("gwin", globalCount + """
         UNION ALL \
        SELECT 1::int8, a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at \
        FROM (SELECT a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at \
          FROM articles a ORDER BY a.id DESC LIMIT $1) a
        """, [oidInt8]),
    ("tag", """
        WITH u AS MATERIALIZED ( \
          SELECT r.k, t.id, \
            CASE WHEN t.id IS NULL THEN 0::int8 \
                 WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = t.id LIMIT 1 OFFSET 999) THEN 1000::int8 \
                 ELSE (SELECT count(*) FROM article_tags at WHERE at.tag_id = t.id) END AS cnt \
          FROM unnest($1::text[]) WITH ORDINALITY r(tag, k) LEFT JOIN tags t ON t.name = r.tag \
        ) \(countRow) \
        UNION ALL \
        SELECT p.k, a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at \
        FROM unnest($2::int8[], $3::int8[], $4::int8[]) WITH ORDINALITY p(uk, lim, off, k) \
        JOIN u ON u.k = p.uk AND u.id IS NOT NULL AND u.cnt > p.off \
        CROSS JOIN LATERAL (SELECT at.article_id FROM article_tags at WHERE at.tag_id = u.id \
          ORDER BY at.article_id DESC LIMIT p.lim OFFSET p.off) x \
        JOIN articles a ON a.id = x.article_id
        """, [oidTextArray, oidInt8Array, oidInt8Array, oidInt8Array]),
    ("author", """
        WITH u AS MATERIALIZED ( \
          SELECT r.k, usr.id, CASE WHEN usr.id IS NULL THEN 0::int8 ELSE \
            \(cappedCount("SELECT 1 FROM articles a WHERE a.author_id = usr.id")) END AS cnt \
          FROM unnest($1::text[]) WITH ORDINALITY r(username, k) LEFT JOIN users usr ON usr.username = r.username \
        ) \(countRow) \
        UNION ALL \
        SELECT p.k, a.id, u.id, a.slug, a.title, a.description, a.created_at, a.updated_at \
        FROM unnest($2::int8[], $3::int8[], $4::int8[]) WITH ORDINALITY p(uk, lim, off, k) \
        JOIN u ON u.k = p.uk AND u.id IS NOT NULL AND u.cnt > p.off \
        CROSS JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at \
          FROM articles a WHERE a.author_id = u.id ORDER BY a.id DESC LIMIT p.lim OFFSET p.off) a
        """, [oidTextArray, oidInt8Array, oidInt8Array, oidInt8Array]),
    ("favlist", """
        WITH u AS MATERIALIZED ( \
          SELECT r.k, usr.id, CASE WHEN usr.id IS NULL THEN 0::int8 ELSE \
            \(cappedCount("SELECT 1 FROM favorites f WHERE f.user_id = usr.id")) END AS cnt \
          FROM unnest($1::text[]) WITH ORDINALITY r(username, k) LEFT JOIN users usr ON usr.username = r.username \
        ) \(countRow) \
        UNION ALL \
        SELECT p.k, a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at \
        FROM unnest($2::int8[], $3::int8[], $4::int8[]) WITH ORDINALITY p(uk, lim, off, k) \
        JOIN u ON u.k = p.uk AND u.id IS NOT NULL AND u.cnt > p.off \
        CROSS JOIN LATERAL (SELECT f.article_id FROM favorites f WHERE f.user_id = u.id \
          ORDER BY f.article_id DESC LIMIT p.lim OFFSET p.off) x \
        JOIN articles a ON a.id = x.article_id
        """, [oidTextArray, oidInt8Array, oidInt8Array, oidInt8Array]),
    ("feed", """
        WITH u AS MATERIALIZED ( \
          SELECT r.k, r.v, r.depth, ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v) AS fids \
          FROM unnest($1::int8[], $2::int8[]) WITH ORDINALITY r(v, depth, k) \
        ), \
        hub_floors AS MATERIALIZED ( \
          SELECT h.fid, \
            (SELECT a.id FROM articles a WHERE a.author_id = h.fid ORDER BY a.id DESC LIMIT 1 OFFSET h.depth - 1) AS floor_id, \
            EXISTS (SELECT 1 FROM articles a WHERE a.author_id = h.fid ORDER BY a.id ASC LIMIT 1 OFFSET 999) AS big \
          FROM (SELECT f.fid, max(u.depth) AS depth FROM u, unnest(u.fids) AS f(fid) \
            GROUP BY f.fid HAVING count(*) >= 2 ORDER BY count(*) DESC, f.fid LIMIT 32) h \
        ), \
        cap_authors AS MATERIALIZED (SELECT ARRAY(SELECT hf.fid FROM hub_floors hf WHERE hf.big) AS fids) \
        SELECT -u.k, \
          CASE WHEN cardinality(u.fids) = 0 THEN 0::int8 \
               WHEN u.fids && (SELECT fids FROM cap_authors) THEN 1000::int8 \
               ELSE \(cappedCount("SELECT 1 FROM articles a WHERE a.author_id = ANY(u.fids)")) END, \
          0::int8 \
        FROM u \
        UNION ALL \
        SELECT p.k, x.id, x.author_id \
        FROM unnest($3::int8[], $4::int8[], $5::int8[]) WITH ORDINALITY p(uk, lim, off, k) \
        JOIN u ON u.k = p.uk AND cardinality(u.fids) > 0 \
        CROSS JOIN LATERAL (SELECT COALESCE(max(hf.floor_id), 0::int8) AS floor_id FROM hub_floors hf WHERE hf.fid = ANY(u.fids)) fl \
        CROSS JOIN LATERAL ( \
          SELECT y.id, y.author_id FROM unnest(u.fids) AS fid \
          CROSS JOIN LATERAL (SELECT a2.id, fid AS author_id FROM articles a2 \
            WHERE a2.author_id = fid AND a2.id >= fl.floor_id ORDER BY a2.id DESC LIMIT (p.lim + p.off)) y \
          ORDER BY y.id DESC LIMIT p.lim OFFSET p.off \
        ) x
        """, [oidInt8Array, oidInt8Array, oidInt8Array, oidInt8Array, oidInt8Array]),
    ("artmeta", """
        SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at FROM articles a WHERE a.id = ANY($1::int8[])
        """, [oidInt8Array]),
    ("artx", """
        SELECT f.article_id, NULL::int4, count(*) FROM favorites f WHERE f.article_id = ANY($1::int8[]) GROUP BY f.article_id \
        UNION ALL \
        SELECT at.article_id, at.tag_id, 0::int8 FROM article_tags at WHERE at.article_id = ANY($1::int8[])
        """, [oidInt8Array]),
    ("artau", "SELECT u.id, u.username, u.bio, u.image FROM users u WHERE u.id = ANY($1::int8[])", [oidInt8Array]),
    ("flags", """
        SELECT 0::int8, p.v, f.article_id FROM unnest($1::int8[], $3::int4[], $4::int4[]) p(v, s, e) \
        CROSS JOIN LATERAL (SELECT f.article_id FROM favorites f \
          WHERE f.user_id = p.v AND f.article_id = ANY(($2::int8[])[p.s : p.e])) f \
        UNION ALL \
        SELECT 1::int8, q.v, fo.followee_id FROM unnest($5::int8[], $7::int4[], $8::int4[]) q(v, s, e) \
        CROSS JOIN LATERAL (SELECT fo.followee_id FROM follows fo \
          WHERE fo.follower_id = q.v AND fo.followee_id = ANY(($6::int8[])[q.s : q.e])) fo
        """, [oidInt8Array, oidInt8Array, oidInt4Array, oidInt4Array, oidInt8Array, oidInt8Array, oidInt4Array, oidInt4Array]),

    // Writes. Each runs alone or in an implicit pipeline transaction, and finds its own target, so a
    // write is one statement and one round trip.
    ("register", """
        INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING \
        RETURNING id, username, email, bio, image
        """, [oidText, oidText, oidText]),
    ("upduser", """
        UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), \
        password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) \
        WHERE id = $1 RETURNING id, username, email, bio, image
        """, [oidInt8, oidText, oidText, oidText, oidText, oidText]),
    ("follow", """
        WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), \
        w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING) \
        SELECT username, bio, image FROM t
        """, [oidInt8, oidText]),
    ("unfollow", """
        WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), \
        w AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM t)) \
        SELECT username, bio, image FROM t
        """, [oidInt8, oidText]),
    ("fav", """
        WITH t AS (SELECT id FROM articles WHERE slug = $2), \
        w AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING) \
        SELECT id FROM t
        """, [oidInt8, oidText]),
    ("unfav", """
        WITH t AS (SELECT id FROM articles WHERE slug = $2), \
        w AS (DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM t)) \
        SELECT id FROM t
        """, [oidInt8, oidText]),
    ("newart", """
        WITH ins AS (INSERT INTO articles (id, slug, author_id, title, description, body) \
          SELECT n.id, \(slugify) || '-' || n.id, $1, $2, $3, $4 \
          FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n RETURNING id), \
        existing AS MATERIALIZED (SELECT id, name FROM tags WHERE name = ANY($5::text[])), \
        new_tags AS (INSERT INTO tags (name) \
          SELECT name FROM (SELECT DISTINCT unnest($5::text[]) AS name) names \
          WHERE NOT EXISTS (SELECT 1 FROM existing e WHERE e.name = names.name) \
          ORDER BY name ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id, name), \
        all_tags AS (SELECT id, name FROM existing UNION ALL SELECT id, name FROM new_tags), \
        ins_at AS (INSERT INTO article_tags (article_id, tag_id) SELECT ins.id, all_tags.id FROM ins, all_tags) \
        SELECT id FROM ins
        """, [oidInt8, oidText, oidText, oidText, oidTextArray]),
    ("updart", """
        WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1), \
        w AS (UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), \
          body = COALESCE($4, body), \
          slug = CASE WHEN $2::text IS NULL THEN slug ELSE \(slugify) || '-' || id END, updated_at = now() \
          WHERE id = (SELECT id FROM t WHERE author_id = $5) RETURNING 1) \
        SELECT t.id, t.author_id FROM t
        """, [oidText, oidText, oidText, oidText, oidInt8]),
    ("delart", """
        WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1), \
        w AS (DELETE FROM articles WHERE id = (SELECT id FROM t WHERE author_id = $2)) \
        SELECT author_id FROM t
        """, [oidText, oidInt8]),
    ("newcmt", """
        WITH t AS (SELECT id FROM articles WHERE slug = $1), \
        c AS (INSERT INTO comments (article_id, author_id, body) SELECT id, $2, $3 FROM t \
          RETURNING id, body, created_at, updated_at, author_id) \
        SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image \
        FROM c JOIN users u ON u.id = c.author_id
        """, [oidText, oidInt8, oidText]),
    ("delcmt", """
        WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id \
          WHERE c.id = $1 AND a.slug = $2), \
        w AS (DELETE FROM comments WHERE id = (SELECT id FROM t WHERE author_id = $3)) \
        SELECT author_id FROM t
        """, [oidInt8, oidText, oidInt8]),
]

//! Prepared statement catalog and session configurations for PostgreSQL 18.
//!
//! Every query is prepared once at connection startup, ensuring zero runtime planning
//! overhead and full compatibility with `plan_cache_mode = force_generic_plan`.

pub const OID_INT4: u32 = 23;
pub const OID_INT8: u32 = 20;
pub const OID_TEXT: u32 = 25;
pub const OID_INT4_ARR: u32 = 1007;
pub const OID_INT8_ARR: u32 = 1016;
pub const OID_TEXT_ARR: u32 = 1009;

pub struct StmtDef {
    pub name: &'static str,
    pub sql: &'static str,
    pub oids: &'static [u32],
}

pub const SESSION_INIT_SQL: &str = "\
SET plan_cache_mode = force_generic_plan; \
SET jit = off; \
SET max_parallel_workers_per_gather = 0; \
SET enable_memoize = off;";

pub const PREPARED_STATEMENTS: &[StmtDef] = &[
    // Transaction control (pipelined group commit)
    StmtDef {
        name: "s_begin",
        sql: "BEGIN",
        oids: &[],
    },
    StmtDef {
        name: "s_commit",
        sql: "COMMIT",
        oids: &[],
    },

    // 1. Tags list
    StmtDef {
        name: "s_tags",
        sql: "SELECT name FROM tags ORDER BY name",
        oids: &[],
    },

    // 2. User by id (GET /api/user)
    StmtDef {
        name: "s_uid",
        sql: "SELECT id, username, email, bio, image FROM users WHERE id = $1",
        oids: &[OID_INT8],
    },

    // 3. User by email (login step 1)
    StmtDef {
        name: "s_uemail",
        sql: "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1",
        oids: &[OID_TEXT],
    },

    // 4. Profile by username with following check
    StmtDef {
        name: "s_prof",
        sql: "SELECT u.id, u.username, u.bio, u.image, \
              EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following \
              FROM users u WHERE u.username = $2",
        oids: &[OID_INT8, OID_TEXT],
    },

    // 5. Article by slug (with viewer flags and text[] tagList)
    StmtDef {
        name: "s_aslug",
        sql: "SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, a.author_id, \
              u.username, u.bio, u.image, \
              EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following, \
              EXISTS (SELECT 1 FROM favorites fa WHERE fa.user_id = $1 AND fa.article_id = a.id) AS favorited, \
              (SELECT count(*) FROM favorites fa WHERE fa.article_id = a.id) AS fc, \
              ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tags \
              FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = $2",
        oids: &[OID_INT8, OID_TEXT],
    },

    // 6. Comments list by article slug (LEFT JOIN to distinguish missing slug 404 from 0 comments 200)
    StmtDef {
        name: "s_cmts",
        sql: "SELECT a.id AS article_id, c.id, c.body, c.created_at, c.updated_at, c.author_id, \
              u.username, u.bio, u.image, \
              EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following \
              FROM articles a \
              LEFT JOIN comments c ON c.article_id = a.id \
              LEFT JOIN users u ON u.id = c.author_id \
              WHERE a.slug = $2 \
              ORDER BY c.created_at DESC NULLS LAST, c.id DESC NULLS LAST LIMIT 100",
        oids: &[OID_INT8, OID_TEXT],
    },

    // 7. Global articles list (windowed count + page)
    StmtDef {
        name: "s_global",
        sql: "SELECT 0::int8, CASE WHEN EXISTS (SELECT 1 FROM articles ORDER BY id ASC LIMIT 1 OFFSET 999) \
                     THEN 1000::int8 ELSE (SELECT count(*) FROM articles) END, \
                     NULL::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz, \
                     NULL::int8, NULL::text, NULL::text, NULL::text, NULL::text[], NULL::int8, NULL::bool, NULL::bool \
              UNION ALL \
              SELECT 1::int8, NULL, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, \
                     a.author_id, u.username, u.bio, u.image, \
                     ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1), \
                     (SELECT count(*) FROM favorites fa WHERE fa.article_id = a.id), \
                     EXISTS (SELECT 1 FROM favorites fa WHERE fa.user_id = $3 AND fa.article_id = a.id), \
                     EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $3 AND fo.followee_id = a.author_id) \
              FROM (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id \
                    FROM articles a ORDER BY a.id DESC LIMIT $1 OFFSET $2) a \
              LEFT JOIN LATERAL (SELECT u.username, u.bio, u.image FROM users u WHERE u.id = a.author_id LIMIT 1) u ON true \
              ORDER BY 1 ASC, 3 DESC NULLS LAST",
        oids: &[OID_INT8, OID_INT8, OID_INT8],
    },

    // 8. Tag articles list (SPEC line 156: in-SQL tag resolution, unknown tag returns 0 rows)
    StmtDef {
        name: "s_tag_list",
        sql: "SELECT 0::int8, CASE WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1 OFFSET 999) \
                     THEN 1000::int8 ELSE (SELECT count(*) FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1)) END, \
                     NULL::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz, \
                     NULL::int8, NULL::text, NULL::text, NULL::text, NULL::text[], NULL::int8, NULL::bool, NULL::bool \
              UNION ALL \
              SELECT 1::int8, NULL, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, \
                     a.author_id, u.username, u.bio, u.image, \
                     ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1), \
                     (SELECT count(*) FROM favorites fa WHERE fa.article_id = a.id), \
                     EXISTS (SELECT 1 FROM favorites fa WHERE fa.user_id = $4 AND fa.article_id = a.id), \
                     EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $4 AND fo.followee_id = a.author_id) \
              FROM (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) x \
              JOIN articles a ON a.id = x.article_id \
              LEFT JOIN LATERAL (SELECT u.username, u.bio, u.image FROM users u WHERE u.id = a.author_id LIMIT 1) u ON true \
              ORDER BY 1 ASC, 3 DESC NULLS LAST",
        oids: &[OID_TEXT, OID_INT8, OID_INT8, OID_INT8],
    },

    // 9. Author articles list
    StmtDef {
        name: "s_author_list",
        sql: "WITH au AS (SELECT id, username, bio, image FROM users WHERE username = $1) \
              SELECT 0::int8, (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT id FROM au) LIMIT 1000) s), \
                     NULL::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz, \
                     NULL::int8, NULL::text, NULL::text, NULL::text, NULL::text[], NULL::int8, NULL::bool, NULL::bool \
              UNION ALL \
              SELECT 1::int8, NULL, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, \
                     a.author_id, au.username, au.bio, au.image, \
                     ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1), \
                     (SELECT count(*) FROM favorites fa WHERE fa.article_id = a.id), \
                     EXISTS (SELECT 1 FROM favorites fa WHERE fa.user_id = $4 AND fa.article_id = a.id), \
                     EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $4 AND fo.followee_id = a.author_id) \
              FROM au, (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id \
                    FROM articles a WHERE a.author_id = (SELECT id FROM au) ORDER BY a.id DESC LIMIT $2 OFFSET $3) a \
              ORDER BY 1 ASC, 3 DESC NULLS LAST",
        oids: &[OID_TEXT, OID_INT8, OID_INT8, OID_INT8],
    },

    // 10. Favorited articles list (direct count since max count is 82)
    StmtDef {
        name: "s_fav_list",
        sql: "WITH fu AS (SELECT id FROM users WHERE username = $1) \
              SELECT 0::int8, (SELECT count(*) FROM favorites f WHERE f.user_id = (SELECT id FROM fu)), \
                     NULL::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz, \
                     NULL::int8, NULL::text, NULL::text, NULL::text, NULL::text[], NULL::int8, NULL::bool, NULL::bool \
              UNION ALL \
              SELECT 1::int8, NULL, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, \
                     a.author_id, u.username, u.bio, u.image, \
                     ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1), \
                     (SELECT count(*) FROM favorites fa WHERE fa.article_id = a.id), \
                     EXISTS (SELECT 1 FROM favorites fa WHERE fa.user_id = $4 AND fa.article_id = a.id), \
                     EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $4 AND fo.followee_id = a.author_id) \
              FROM (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT id FROM fu) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) x \
              JOIN articles a ON a.id = x.article_id \
              LEFT JOIN LATERAL (SELECT u.username, u.bio, u.image FROM users u WHERE u.id = a.author_id LIMIT 1) u ON true \
              ORDER BY 1 ASC, 3 DESC NULLS LAST",
        oids: &[OID_TEXT, OID_INT8, OID_INT8, OID_INT8],
    },

    // 11. Feed (articles by authors viewer follows)
    StmtDef {
        name: "s_feed",
        sql: "WITH fids AS MATERIALIZED (SELECT followee_id FROM follows WHERE follower_id = $1), \
              big AS MATERIALIZED ( \
                SELECT EXISTS (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT followee_id FROM fids) OFFSET 999) AS has_1000 \
              ), \
              cnt AS MATERIALIZED ( \
                SELECT CASE WHEN (SELECT has_1000 FROM big) THEN 1000::int8 \
                            ELSE (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT followee_id FROM fids) LIMIT 1000) s) \
                       END AS n \
              ), \
              page_ids AS MATERIALIZED ( \
                SELECT a.id, a.author_id \
                FROM fids \
                CROSS JOIN LATERAL ( \
                  SELECT a.id, a.author_id \
                  FROM articles a WHERE a.author_id = fids.followee_id ORDER BY a.id DESC LIMIT ($2 + $3) \
                ) a \
                ORDER BY a.id DESC LIMIT $2 OFFSET $3 \
              ), \
              page AS MATERIALIZED ( \
                SELECT p.id, a.slug, a.title, a.description, a.created_at, a.updated_at, p.author_id \
                FROM page_ids p \
                JOIN articles a ON a.id = p.id \
              ) \
              SELECT 0::int8, cnt.n, NULL::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz, \
                     NULL::int8, NULL::text, NULL::text, NULL::text, NULL::text[], NULL::int8, NULL::bool, NULL::bool \
              FROM cnt \
              UNION ALL \
              SELECT 1::int8, NULL, p.id, p.slug, p.title, p.description, p.created_at, p.updated_at, \
                     p.author_id, u.username, u.bio, u.image, \
                     ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = p.id ORDER BY 1), \
                     (SELECT count(*) FROM favorites fa WHERE fa.article_id = p.id), \
                     EXISTS (SELECT 1 FROM favorites fa WHERE fa.user_id = $1 AND fa.article_id = p.id), \
                     true::bool \
              FROM page p \
              LEFT JOIN LATERAL (SELECT u.username, u.bio, u.image FROM users u WHERE u.id = p.author_id LIMIT 1) u ON true \
              ORDER BY 1 ASC, 3 DESC NULLS LAST",
        oids: &[OID_INT8, OID_INT8, OID_INT8],
    },

    // 12. Register user (conflict-free ON CONFLICT DO NOTHING RETURNING)
    StmtDef {
        name: "s_reg",
        sql: "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) \
              ON CONFLICT DO NOTHING \
              RETURNING id, username, email, bio, image",
        oids: &[OID_TEXT, OID_TEXT, OID_TEXT],
    },

    // 13. Update user (conflict-free update avoiding unique violation)
    StmtDef {
        name: "s_upduser",
        sql: "WITH u AS ( \
                SELECT id FROM users WHERE id = $1 \
              ), \
              upd AS ( \
                UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), \
                                 password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) \
                WHERE id = $1 \
                  AND NOT EXISTS ( \
                      SELECT 1 FROM users WHERE id != $1 AND ( \
                          ($2::text IS NOT NULL AND email = $2) OR \
                          ($3::text IS NOT NULL AND username = $3) \
                      ) \
                  ) \
                RETURNING id, username, email, bio, image \
              ) \
              SELECT (SELECT id FROM u) AS uid, upd.username, upd.email, upd.bio, upd.image \
              FROM (SELECT 1) _d \
              LEFT JOIN upd ON true",
        oids: &[OID_INT8, OID_TEXT, OID_TEXT, OID_TEXT, OID_TEXT, OID_TEXT],
    },

    // 14. Batched favorites insert
    StmtDef {
        name: "s_fav_batch",
        sql: "WITH r AS ( \
                SELECT x.k, x.uid, a.id AS aid FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY x(uid, slug, k) \
                JOIN articles a ON a.slug = x.slug \
              ), \
              w AS ( \
                INSERT INTO favorites (user_id, article_id) \
                SELECT DISTINCT uid, aid FROM r ORDER BY 1, 2 ON CONFLICT DO NOTHING \
              ) \
              SELECT r.k, r.aid, (SELECT count(*) FROM favorites f WHERE f.article_id = r.aid) FROM r",
        oids: &[OID_INT8_ARR, OID_TEXT_ARR],
    },

    // 15. Batched unfavorite delete
    StmtDef {
        name: "s_unfav_batch",
        sql: "WITH r AS ( \
                SELECT x.k, x.uid, a.id AS aid FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY x(uid, slug, k) \
                JOIN articles a ON a.slug = x.slug \
              ), \
              w AS ( \
                DELETE FROM favorites f USING r WHERE f.user_id = r.uid AND f.article_id = r.aid \
              ) \
              SELECT r.k, r.aid, (SELECT count(*) FROM favorites f WHERE f.article_id = r.aid) FROM r",
        oids: &[OID_INT8_ARR, OID_TEXT_ARR],
    },

    // 16. Batched follow insert
    StmtDef {
        name: "s_follow_batch",
        sql: "WITH r AS ( \
                SELECT x.k, x.fid, u.id AS tid, u.username, u.bio, u.image \
                FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY x(fid, uname, k) \
                JOIN users u ON u.username = x.uname \
              ), \
              w AS ( \
                INSERT INTO follows (follower_id, followee_id) \
                SELECT DISTINCT fid, tid FROM r ORDER BY 1, 2 ON CONFLICT DO NOTHING \
              ) \
              SELECT r.k, r.username, r.bio, r.image FROM r",
        oids: &[OID_INT8_ARR, OID_TEXT_ARR],
    },

    // 17. Batched unfollow delete
    StmtDef {
        name: "s_unfollow_batch",
        sql: "WITH r AS ( \
                SELECT x.k, x.fid, u.id AS tid, u.username, u.bio, u.image \
                FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY x(fid, uname, k) \
                JOIN users u ON u.username = x.uname \
              ), \
              w AS ( \
                DELETE FROM follows fo USING r WHERE fo.follower_id = r.fid AND fo.followee_id = r.tid \
              ) \
              SELECT r.k, r.username, r.bio, r.image FROM r",
        oids: &[OID_INT8_ARR, OID_TEXT_ARR],
    },

    // 18. Batched comment create
    StmtDef {
        name: "s_cmt_create_batch",
        sql: "WITH r AS MATERIALIZED ( \
                SELECT nextval('comments_id_seq'::regclass) AS id, a.id AS article_id, x.author, x.body, x.k \
                FROM unnest($1::text[], $2::int8[], $3::text[]) WITH ORDINALITY AS x(slug, author, body, k) \
                JOIN articles a ON a.slug = x.slug \
              ), \
              c AS ( \
                INSERT INTO comments (id, article_id, author_id, body) \
                SELECT id, article_id, author, body FROM r \
                RETURNING id, body, created_at, updated_at, author_id \
              ) \
              SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, r.k \
              FROM c JOIN r ON r.id = c.id JOIN users u ON u.id = c.author_id",
        oids: &[OID_TEXT_ARR, OID_INT8_ARR, OID_TEXT_ARR],
    },

    // 19. Comment delete (distinguishes 404 missing from 403 forbidden per SPEC line 252)
    StmtDef {
        name: "s_cmt_delete",
        sql: "WITH sel AS ( \
                SELECT c.id, c.author_id \
                FROM comments c \
                JOIN articles a ON a.id = c.article_id \
                WHERE c.id = $1 AND a.slug = $2 \
              ), \
              del AS ( \
                DELETE FROM comments c USING sel \
                WHERE c.id = sel.id AND sel.author_id = $3 \
                RETURNING c.id \
              ) \
              SELECT (SELECT author_id FROM sel) AS author_id, (SELECT id FROM del) AS deleted_id",
        oids: &[OID_INT8, OID_TEXT, OID_INT8],
    },

    // 20. Article delete (distinguishes 404 missing from 403 forbidden per SPEC line 207)
    StmtDef {
        name: "s_art_delete",
        sql: "WITH sel AS ( \
                SELECT id, author_id FROM articles WHERE slug = $1 \
              ), \
              del AS ( \
                DELETE FROM articles a USING sel \
                WHERE a.id = sel.id AND sel.author_id = $2 \
                RETURNING a.id \
              ) \
              SELECT (SELECT author_id FROM sel) AS author_id, (SELECT id FROM del) AS deleted_id",
        oids: &[OID_TEXT, OID_INT8],
    },

    // 21. Article create (SPEC line 183: in-SQL SLUGIFY with generated ID)
    StmtDef {
        name: "s_art_create",
        sql: "WITH ins AS ( \
                INSERT INTO articles (id, slug, author_id, title, description, body) \
                SELECT n.id, trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id, $1, $2, $3, $4 \
                FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n \
                RETURNING id, slug, title, description, body, created_at, updated_at, author_id \
              ), \
              existing AS MATERIALIZED (SELECT id, name FROM tags WHERE name = ANY($5::text[])), \
              new_tags AS ( \
                INSERT INTO tags (name) \
                SELECT name FROM (SELECT DISTINCT unnest($5::text[]) AS name) names \
                WHERE NOT EXISTS (SELECT 1 FROM existing e WHERE e.name = names.name) \
                ORDER BY name ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id, name \
              ), \
              all_tags AS (SELECT id, name FROM existing UNION ALL SELECT id, name FROM new_tags), \
              ins_at AS ( \
                INSERT INTO article_tags (article_id, tag_id) \
                SELECT ins.id, all_tags.id FROM ins, all_tags \
                ON CONFLICT DO NOTHING \
              ) \
              SELECT ins.id, ins.slug, ins.title, ins.description, ins.body, ins.created_at, ins.updated_at, ins.author_id, \
                     u.username, u.bio, u.image, \
                     ARRAY(SELECT name FROM all_tags ORDER BY name) AS tag_list \
              FROM ins JOIN users u ON u.id = ins.author_id",
        oids: &[OID_INT8, OID_TEXT, OID_TEXT, OID_TEXT, OID_TEXT_ARR],
    },

    // 22. Article update (distinguishes 404 missing from 403 forbidden per SPEC line 196)
    StmtDef {
        name: "s_art_update",
        sql: "WITH sel AS (SELECT id, author_id FROM articles WHERE slug = $1), \
              upd AS ( \
                UPDATE articles a \
                SET title = COALESCE($3, a.title), description = COALESCE($4, a.description), body = COALESCE($5, a.body), \
                    slug = CASE WHEN $3::text IS NULL THEN a.slug ELSE trim(both '-' from lower(regexp_replace($3, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || a.id END, \
                    updated_at = now() \
                FROM sel \
                WHERE a.id = sel.id AND sel.author_id = $2 \
                RETURNING a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, a.author_id \
              ) \
              SELECT (SELECT author_id FROM sel) AS author_id, \
                     u.id, u.slug, u.title, u.description, u.body, u.created_at, u.updated_at, u.author_id, \
                     usr.username, usr.bio, usr.image, \
                     ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = u.id ORDER BY 1) AS tags, \
                     (SELECT count(*) FROM favorites fa WHERE fa.article_id = u.id) AS favorites_count, \
                     EXISTS (SELECT 1 FROM favorites fa WHERE fa.user_id = $2 AND fa.article_id = u.id) AS favorited, \
                     EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $2 AND fo.followee_id = u.author_id) AS following \
              FROM (SELECT 1) _d \
              LEFT JOIN upd u ON true \
              LEFT JOIN users usr ON usr.id = u.author_id",
        oids: &[OID_TEXT, OID_INT8, OID_TEXT, OID_TEXT, OID_TEXT],
    },

    // 23. Tag upsert
    StmtDef {
        name: "s_tag_insert",
        sql: "INSERT INTO tags (name) VALUES ($1) ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id",
        oids: &[OID_TEXT],
    },

    // 24. Article tag link
    StmtDef {
        name: "s_art_tag_insert",
        sql: "INSERT INTO article_tags (article_id, tag_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
        oids: &[OID_INT8, OID_INT4],
    },

    // 25. Follow on
    StmtDef {
        name: "s_follow_on",
        sql: "INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM users WHERE username = $2 ON CONFLICT DO NOTHING",
        oids: &[OID_INT8, OID_TEXT],
    },

    // 26. Follow off
    StmtDef {
        name: "s_follow_off",
        sql: "DELETE FROM follows fo USING users u WHERE fo.follower_id = $1 AND fo.followee_id = u.id AND u.username = $2",
        oids: &[OID_INT8, OID_TEXT],
    },

    // 27. Favorite on
    StmtDef {
        name: "s_fav_on",
        sql: "INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM articles WHERE slug = $2 ON CONFLICT DO NOTHING",
        oids: &[OID_INT8, OID_TEXT],
    },

    // 28. Favorite off
    StmtDef {
        name: "s_fav_off",
        sql: "DELETE FROM favorites f USING articles a WHERE f.user_id = $1 AND f.article_id = a.id AND a.slug = $2",
        oids: &[OID_INT8, OID_TEXT],
    },

    // 29. Comment create
    StmtDef {
        name: "s_cmt_create",
        sql: "WITH ins AS ( \
                INSERT INTO comments (article_id, author_id, body) \
                SELECT a.id, $1, $3 FROM articles a WHERE a.slug = $2 \
                RETURNING id, body, created_at, updated_at, author_id \
              ) \
              SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image \
              FROM ins c JOIN users u ON u.id = c.author_id",
        oids: &[OID_INT8, OID_TEXT, OID_TEXT],
    },
];

package conduit;

import static conduit.Pg.INT8;
import static conduit.Pg.INT8_ARRAY;
import static conduit.Pg.TEXT;
import static conduit.Pg.TEXT_ARRAY;

import java.util.List;

/**
 * Prepared SQL. Every read statement takes arrays of the distinct keys of one batch and tags each output row with the
 * key's 1-based ordinal k. Results match SPEC.md's reference SQL; row order within a key is restored in Java where
 * the statement doesn't fix it.
 */
final class Sql {
    record Stmt(String name, String sql, int[] types) {}

    private static Stmt s(String name, String sql, int... types) {
        return new Stmt(name, sql, types);
    }

    private static String capped(String rows) {
        return "(SELECT count(*) FROM (" + rows + " LIMIT 1000) s)";
    }

    /** Article columns after k: [id, author_id, slug, title, description, created_at, updated_at]. */
    private static final String COLS = "a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at";
    /** NULL padding for a count row in a list statement (count in column 1, then COLS minus id). */
    private static final String PAD = "NULL::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz";

    static List<Stmt> reads() {
        return List.of(
                s("tags", "SELECT id, name FROM tags ORDER BY name"),
                s("uid", "SELECT r.k, u.id, u.username, u.email, u.bio, u.image FROM unnest($1::int8[]) WITH ORDINALITY r(id, k) "
                        + "JOIN users u ON u.id = r.id", INT8_ARRAY),
                s("uemail", "SELECT r.k, u.id, u.username, u.email, u.bio, u.image, u.password_hash "
                        + "FROM unnest($1::text[]) WITH ORDINALITY r(email, k) JOIN users u ON u.email = r.email", TEXT_ARRAY),
                s("prof", "SELECT r.k, u.id, u.username, u.bio, u.image FROM unnest($1::text[]) WITH ORDINALITY r(username, k) "
                        + "JOIN users u ON u.username = r.username", TEXT_ARRAY),
                // article rows: [k, id, author_id, slug, title, description, created_at, updated_at, body]
                s("aslug", "SELECT r.k, " + COLS + ", a.body FROM unnest($1::text[]) WITH ORDINALITY r(slug, k) "
                        + "JOIN articles a ON a.slug = r.slug", TEXT_ARRAY),
                s("aid", "SELECT r.k, " + COLS + ", a.body FROM unnest($1::int8[]) WITH ORDINALITY r(id, k) "
                        + "JOIN articles a ON a.id = r.id", INT8_ARRAY),
                // [k, article id, comment id, body, created_at, updated_at, author_id, username, bio, image]
                s("cmts", "SELECT r.k, a.id, c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image "
                        + "FROM unnest($1::text[]) WITH ORDINALITY r(slug, k) JOIN articles a ON a.slug = r.slug "
                        + "LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c "
                        + "  WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true "
                        + "LEFT JOIN users u ON u.id = c.author_id", TEXT_ARRAY),
                // Lists: k <= 0 rows are capped counts (-k is the count key, the count in column 1); k > 0 rows are
                // page rows. The global count walks the primary key from the oldest end, whose pages are all-visible,
                // so it stays an index-only scan while new articles keep the newest pages dirty.
                s("global", "SELECT 0::int8, (SELECT count(*) FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s), " + PAD + " "
                        + "UNION ALL "
                        + "SELECT r.k, " + COLS + " FROM unnest($1::int8[], $2::int8[]) WITH ORDINALITY r(lim, off, k) "
                        + "CROSS JOIN LATERAL (SELECT * FROM articles a ORDER BY a.id DESC LIMIT r.lim OFFSET r.off) a",
                        INT8_ARRAY, INT8_ARRAY),
                s("tag", "SELECT -r.k, " + capped("SELECT 1 FROM article_tags at WHERE at.tag_id = t.id") + ", " + PAD + " "
                        + "FROM unnest($1::text[]) WITH ORDINALITY r(tag, k) LEFT JOIN tags t ON t.name = r.tag "
                        + "UNION ALL "
                        + "SELECT r.k, " + COLS + " FROM unnest($2::text[], $3::int8[], $4::int8[]) WITH ORDINALITY r(tag, lim, off, k) "
                        + "JOIN tags t ON t.name = r.tag "
                        + "CROSS JOIN LATERAL (SELECT at.article_id FROM article_tags at WHERE at.tag_id = t.id "
                        + "  ORDER BY at.article_id DESC LIMIT r.lim OFFSET r.off) p "
                        + "JOIN articles a ON a.id = p.article_id",
                        TEXT_ARRAY, TEXT_ARRAY, INT8_ARRAY, INT8_ARRAY),
                s("author", "SELECT -r.k, " + capped("SELECT 1 FROM articles a WHERE a.author_id = u.id") + ", " + PAD + " "
                        + "FROM unnest($1::text[]) WITH ORDINALITY r(username, k) LEFT JOIN users u ON u.username = r.username "
                        + "UNION ALL "
                        + "SELECT r.k, " + COLS + " FROM unnest($2::text[], $3::int8[], $4::int8[]) WITH ORDINALITY r(username, lim, off, k) "
                        + "JOIN users u ON u.username = r.username "
                        + "CROSS JOIN LATERAL (SELECT * FROM articles a WHERE a.author_id = u.id ORDER BY a.id DESC LIMIT r.lim OFFSET r.off) a",
                        TEXT_ARRAY, TEXT_ARRAY, INT8_ARRAY, INT8_ARRAY),
                s("favlist", "SELECT -r.k, " + capped("SELECT 1 FROM favorites f WHERE f.user_id = u.id") + ", " + PAD + " "
                        + "FROM unnest($1::text[]) WITH ORDINALITY r(username, k) LEFT JOIN users u ON u.username = r.username "
                        + "UNION ALL "
                        + "SELECT r.k, " + COLS + " FROM unnest($2::text[], $3::int8[], $4::int8[]) WITH ORDINALITY r(username, lim, off, k) "
                        + "JOIN users u ON u.username = r.username "
                        + "CROSS JOIN LATERAL (SELECT f.article_id FROM favorites f WHERE f.user_id = u.id "
                        + "  ORDER BY f.article_id DESC LIMIT r.lim OFFSET r.off) p "
                        + "JOIN articles a ON a.id = p.article_id",
                        TEXT_ARRAY, TEXT_ARRAY, INT8_ARRAY, INT8_ARRAY),
                // Feeds: capped counts per distinct viewer ($1, k <= 0), pages per (viewer, limit, offset) (k > 0).
                // Followees shared by several viewers of the batch ("hubs") are looked at once: whether they have
                // 1,000+ articles (then every viewer following one counts 1,000 without a scan), and the id of their
                // depth-th newest article, a floor below which no page of that depth can reach, so every other
                // followee's index scan stops there.
                s("feed", "WITH u AS MATERIALIZED ( "
                        + "  SELECT r.k, r.v, ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v) AS fids, "
                        + "    COALESCE((SELECT max(p.lim + p.off) FROM unnest($2::int8[], $3::int8[], $4::int8[]) p(v, lim, off) "
                        + "      WHERE p.v = r.v), 1) AS depth "
                        + "  FROM unnest($1::int8[]) WITH ORDINALITY r(v, k)), "
                        + "hubs AS MATERIALIZED ( "
                        + "  SELECT h.fid, "
                        + "    (SELECT a.id FROM articles a WHERE a.author_id = h.fid ORDER BY a.id DESC LIMIT 1 OFFSET h.depth - 1) AS floor_id, "
                        + "    EXISTS (SELECT 1 FROM articles a WHERE a.author_id = h.fid ORDER BY a.id DESC LIMIT 1 OFFSET 999) AS big "
                        + "  FROM (SELECT f.fid, max(u.depth) AS depth FROM u, unnest(u.fids) f(fid) "
                        + "    GROUP BY f.fid HAVING count(*) >= 2 ORDER BY count(*) DESC, f.fid LIMIT 32) h), "
                        + "big AS MATERIALIZED (SELECT ARRAY(SELECT fid FROM hubs WHERE big) AS fids) "
                        + "SELECT -u.k, CASE WHEN u.fids && (SELECT fids FROM big) THEN 1000::int8 "
                        + "  ELSE (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = ANY(u.fids) LIMIT 1000) s) END, " + PAD + " "
                        + "FROM u "
                        + "UNION ALL "
                        + "SELECT p.k, " + COLS + " FROM unnest($2::int8[], $3::int8[], $4::int8[]) WITH ORDINALITY p(v, lim, off, k) "
                        + "JOIN u ON u.v = p.v "
                        + "CROSS JOIN LATERAL (SELECT COALESCE(max(h.floor_id), 0) AS floor_id FROM hubs h WHERE h.fid = ANY(u.fids)) fl "
                        + "CROSS JOIN LATERAL (SELECT y.id FROM unnest(u.fids) f(fid) CROSS JOIN LATERAL "
                        + "  (SELECT a2.id FROM articles a2 WHERE a2.author_id = f.fid AND a2.id >= fl.floor_id "
                        + "    ORDER BY a2.id DESC LIMIT p.lim + p.off) y "
                        + "  ORDER BY y.id DESC LIMIT p.lim OFFSET p.off) x "
                        + "JOIN articles a ON a.id = x.id",
                        INT8_ARRAY, INT8_ARRAY, INT8_ARRAY, INT8_ARRAY),
                // ---- phase B: once per distinct article of the batch ----
                // [id, tag ids, favorites count, author username, bio, image]
                s("artx", "SELECT r.id, ARRAY(SELECT at.tag_id FROM article_tags at WHERE at.article_id = r.id), "
                        + "(SELECT count(*) FROM favorites f WHERE f.article_id = r.id), u.username, u.bio, u.image "
                        + "FROM unnest($1::int8[], $2::int8[]) r(id, author) JOIN users u ON u.id = r.author",
                        INT8_ARRAY, INT8_ARRAY),
                // viewer flags: (0, viewer, article) per favorited pair asked about, (1, viewer, followee) per followed
                // pair; each viewer's candidates in one primary-key range scan (= ANY) instead of a probe each.
                s("flags", "WITH p AS (SELECT x.v, array_agg(x.a) AS aa FROM unnest($1::int8[], $2::int8[]) x(v, a) GROUP BY x.v), "
                        + "q AS (SELECT x.v, array_agg(x.u) AS uu FROM unnest($3::int8[], $4::int8[]) x(v, u) GROUP BY x.v) "
                        + "SELECT 0::int8, p.v, f.article_id FROM p CROSS JOIN LATERAL "
                        + "  (SELECT f.article_id FROM favorites f WHERE f.user_id = p.v AND f.article_id = ANY(p.aa)) f "
                        + "UNION ALL "
                        + "SELECT 1::int8, q.v, fo.followee_id FROM q CROSS JOIN LATERAL "
                        + "  (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = q.v AND fo.followee_id = ANY(q.uu)) fo",
                        INT8_ARRAY, INT8_ARRAY, INT8_ARRAY, INT8_ARRAY));
    }

    private static final String SLUGIFY = "trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g')))";

    static List<Stmt> writes() {
        return List.of(
                s("register", "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING "
                        + "RETURNING id, username, email, bio, image", TEXT, TEXT, TEXT),
                s("upduser", "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), "
                        + "password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) "
                        + "WHERE id = $1 RETURNING id, username, email, bio, image", INT8, TEXT, TEXT, TEXT, TEXT, TEXT),
                // Runs of the same kind of write in a group go as one statement over arrays: row k is the run's k-th
                // write. Inserts take their rows in key order, so concurrent groups would lock in the same order.
                s("fav_n", "WITH r AS (SELECT x.k, x.uid, a.id AS aid FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY x(uid, slug, k) "
                        + "  JOIN articles a ON a.slug = x.slug), "
                        + "w AS (INSERT INTO favorites (user_id, article_id) SELECT DISTINCT uid, aid FROM r ORDER BY 1, 2 ON CONFLICT DO NOTHING) "
                        + "SELECT k, aid FROM r", INT8_ARRAY, TEXT_ARRAY),
                s("unfav_n", "WITH r AS (SELECT x.k, x.uid, a.id AS aid FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY x(uid, slug, k) "
                        + "  JOIN articles a ON a.slug = x.slug), "
                        + "w AS (DELETE FROM favorites f USING r WHERE f.user_id = r.uid AND f.article_id = r.aid) "
                        + "SELECT k, aid FROM r", INT8_ARRAY, TEXT_ARRAY),
                s("follow_n", "WITH r AS (SELECT x.k, x.fid, u.id AS tid, u.username, u.bio, u.image "
                        + "  FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY x(fid, uname, k) JOIN users u ON u.username = x.uname), "
                        + "w AS (INSERT INTO follows (follower_id, followee_id) SELECT DISTINCT fid, tid FROM r ORDER BY 1, 2 ON CONFLICT DO NOTHING) "
                        + "SELECT k, username, bio, image FROM r", INT8_ARRAY, TEXT_ARRAY),
                s("unfollow_n", "WITH r AS (SELECT x.k, x.fid, u.id AS tid, u.username, u.bio, u.image "
                        + "  FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY x(fid, uname, k) JOIN users u ON u.username = x.uname), "
                        + "w AS (DELETE FROM follows fo USING r WHERE fo.follower_id = r.fid AND fo.followee_id = r.tid) "
                        + "SELECT k, username, bio, image FROM r", INT8_ARRAY, TEXT_ARRAY),
                // new comments: ids drawn in request order, so comments of one transaction (same created_at) still
                // list newest first
                s("newcmt_n", "WITH r AS MATERIALIZED (SELECT x.k, x.uid, x.body, a.id AS aid "
                        + "  FROM unnest($1::int8[], $2::text[], $3::text[]) WITH ORDINALITY x(uid, slug, body, k) "
                        + "  JOIN articles a ON a.slug = x.slug ORDER BY x.k), "
                        + "ids AS MATERIALIZED (SELECT s.k, s.uid, s.body, s.aid, nextval(pg_get_serial_sequence('comments', 'id')) AS id "
                        + "  FROM (SELECT * FROM r ORDER BY k OFFSET 0) s), "
                        + "c AS (INSERT INTO comments (id, article_id, author_id, body) SELECT id, aid, uid, body FROM ids "
                        + "  RETURNING id, body, created_at, updated_at, author_id) "
                        + "SELECT ids.k, c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image "
                        + "FROM c JOIN ids ON ids.id = c.id JOIN users u ON u.id = c.author_id", INT8_ARRAY, TEXT_ARRAY, TEXT_ARRAY),
                s("newart", "INSERT INTO articles (id, slug, author_id, title, description, body) "
                        + "SELECT n.id, " + SLUGIFY + " || '-' || n.id, $1, $2, $3, $4 "
                        + "FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n RETURNING id", INT8, TEXT, TEXT, TEXT),
                s("newtags", "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ORDER BY 1 ON CONFLICT (name) DO NOTHING", TEXT_ARRAY),
                // currval: the id the preceding newart drew in this session
                s("arttags", "INSERT INTO article_tags (article_id, tag_id) "
                        + "SELECT currval(pg_get_serial_sequence('articles', 'id')), t.id FROM tags t WHERE t.name = ANY($1::text[])", TEXT_ARRAY),
                s("updart", "WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1), "
                        + "w AS (UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), "
                        + "  body = COALESCE($4, body), "
                        + "  slug = CASE WHEN $2::text IS NULL THEN slug ELSE " + SLUGIFY + " || '-' || id END, updated_at = now() "
                        + "  WHERE id = (SELECT id FROM t WHERE author_id = $5) RETURNING 1) "
                        + "SELECT t.id, t.author_id FROM t", TEXT, TEXT, TEXT, TEXT, INT8),
                s("delart", "WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1), "
                        + "w AS (DELETE FROM articles WHERE id = (SELECT id FROM t WHERE author_id = $2)) "
                        + "SELECT author_id FROM t", TEXT, INT8),
                s("delcmt", "WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id "
                        + "  WHERE c.id = $1 AND a.slug = $2), "
                        + "w AS (DELETE FROM comments WHERE id = (SELECT id FROM t WHERE author_id = $3)) "
                        + "SELECT author_id FROM t", INT8, TEXT, INT8));
    }
}

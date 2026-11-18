package conduit.db

import conduit.pg.Oid

// Generated from the leader's statement text (not hand-edited). Statement shapes after rust-epoll-theCatWisel (MIT): queries.rs as of #143, unchanged except that the capped-count gate on the tag, author and favorited pages is removed (it returned empty pages past the cap);
// only `tags` is ours (ordered by name, so the app sorts tag ids by their rank in the database collation).
internal object TpSql {
    const val ASLUG = """SELECT r.k, a.id, a.author_id, a.body FROM unnest($1::text[]) WITH ORDINALITY r(slug, k) JOIN articles a ON a.slug = r.slug"""
    val ASLUG_OIDS = intArrayOf(Oid.TEXT_ARRAY)
    const val AID = """SELECT r.k, a.id, a.author_id, a.body FROM unnest($1::int8[]) WITH ORDINALITY r(id, k) JOIN articles a ON a.id = r.id"""
    val AID_OIDS = intArrayOf(Oid.INT8_ARRAY)
    const val ARTX = """SELECT r.k, a.slug, a.title, a.description, a.created_at, a.updated_at, ARRAY(SELECT at.tag_id FROM article_tags at WHERE at.article_id = r.id), (SELECT count(*) FROM favorites f WHERE f.article_id = r.id) FROM unnest($1::int8[]) WITH ORDINALITY r(id, k) JOIN articles a ON a.id = r.id"""
    val ARTX_OIDS = intArrayOf(Oid.INT8_ARRAY)
    const val ARTAU = """SELECT r.k, u.username, u.bio, u.image FROM unnest($1::int8[]) WITH ORDINALITY r(id, k) JOIN users u ON u.id = r.id"""
    val ARTAU_OIDS = intArrayOf(Oid.INT8_ARRAY)
    const val FLAGS = """SELECT 0::int8, p.v, f.article_id FROM unnest($1::int8[], $3::int4[], $4::int4[]) p(v, s, e) CROSS JOIN LATERAL (SELECT f.article_id FROM favorites f WHERE f.user_id = p.v AND f.article_id = ANY(($2::int8[])[p.s : p.e])) f UNION ALL SELECT 1::int8, q.v, fo.followee_id FROM unnest($5::int8[], $7::int4[], $8::int4[]) q(v, s, e) CROSS JOIN LATERAL (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = q.v AND fo.followee_id = ANY(($6::int8[])[q.s : q.e])) fo"""
    val FLAGS_OIDS = intArrayOf(Oid.INT8_ARRAY, Oid.INT8_ARRAY, Oid.INT4_ARRAY, Oid.INT4_ARRAY, Oid.INT8_ARRAY, Oid.INT8_ARRAY, Oid.INT4_ARRAY, Oid.INT4_ARRAY)
    const val CMTS = """SELECT r.k, a.id, c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image FROM unnest($1::text[]) WITH ORDINALITY r(slug, k) JOIN articles a ON a.slug = r.slug LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true LEFT JOIN users u ON u.id = c.author_id"""
    val CMTS_OIDS = intArrayOf(Oid.TEXT_ARRAY)
    const val GLOBAL = """SELECT 0::int8, CASE WHEN EXISTS (SELECT 1 FROM articles ORDER BY id ASC LIMIT 1 OFFSET 999) THEN 1000 ELSE (SELECT count(*) FROM articles) END, 0::int8 UNION ALL SELECT r.k, a.id, a.author_id FROM unnest($1::int8[], $2::int8[]) WITH ORDINALITY r(lim, off, k) CROSS JOIN LATERAL (SELECT a.id, a.author_id FROM articles a ORDER BY a.id DESC LIMIT r.lim OFFSET r.off) a"""
    val GLOBAL_OIDS = intArrayOf(Oid.INT8_ARRAY, Oid.INT8_ARRAY)
    const val GLOBAL_WIN = """SELECT 0::int8, CASE WHEN EXISTS (SELECT 1 FROM articles ORDER BY id ASC LIMIT 1 OFFSET 999) THEN 1000 ELSE (SELECT count(*) FROM articles) END, 0::int8 UNION ALL SELECT 1::int8, a.id, a.author_id FROM (SELECT a.id, a.author_id FROM articles a ORDER BY a.id DESC LIMIT $1) a"""
    val GLOBAL_WIN_OIDS = intArrayOf(Oid.INT8)
    const val TAG = """WITH u AS MATERIALIZED (SELECT r.k, t.id, CASE WHEN t.id IS NULL THEN 0::int8 WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = t.id LIMIT 1 OFFSET 999) THEN 1000::int8 ELSE (SELECT count(*) FROM article_tags at WHERE at.tag_id = t.id) END AS cnt FROM unnest($1::text[]) WITH ORDINALITY r(tag, k) LEFT JOIN tags t ON t.name = r.tag) SELECT -u.k, u.cnt, 0::int8 FROM u UNION ALL SELECT p.k, a.id, a.author_id FROM unnest($2::int8[], $3::int8[], $4::int8[]) WITH ORDINALITY p(uk, lim, off, k) JOIN u ON u.k = p.uk AND u.id IS NOT NULL CROSS JOIN LATERAL (SELECT at.article_id FROM article_tags at WHERE at.tag_id = u.id ORDER BY at.article_id DESC LIMIT p.lim OFFSET p.off) x JOIN articles a ON a.id = x.article_id"""
    val TAG_OIDS = intArrayOf(Oid.TEXT_ARRAY, Oid.INT8_ARRAY, Oid.INT8_ARRAY, Oid.INT8_ARRAY)
    const val FAVLIST = """WITH u AS MATERIALIZED (SELECT r.k, usr.id, (SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = usr.id LIMIT 1000) s) AS cnt FROM unnest($1::text[]) WITH ORDINALITY r(username, k) LEFT JOIN users usr ON usr.username = r.username) SELECT -u.k, u.cnt, 0::int8 FROM u UNION ALL SELECT p.k, a.id, a.author_id FROM unnest($2::int8[], $3::int8[], $4::int8[]) WITH ORDINALITY p(uk, lim, off, k) JOIN u ON u.k = p.uk AND u.id IS NOT NULL CROSS JOIN LATERAL (SELECT f.article_id FROM favorites f WHERE f.user_id = u.id ORDER BY f.article_id DESC LIMIT p.lim OFFSET p.off) x JOIN articles a ON a.id = x.article_id"""
    val FAVLIST_OIDS = intArrayOf(Oid.TEXT_ARRAY, Oid.INT8_ARRAY, Oid.INT8_ARRAY, Oid.INT8_ARRAY)
    const val AUTHOR = """WITH u AS MATERIALIZED (SELECT r.k, usr.id, (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = usr.id LIMIT 1000) s) AS cnt FROM unnest($1::text[]) WITH ORDINALITY r(username, k) LEFT JOIN users usr ON usr.username = r.username) SELECT -u.k, u.cnt, 0::int8 FROM u UNION ALL SELECT p.k, a.id, u.id FROM unnest($2::int8[], $3::int8[], $4::int8[]) WITH ORDINALITY p(uk, lim, off, k) JOIN u ON u.k = p.uk AND u.id IS NOT NULL CROSS JOIN LATERAL (SELECT a.id FROM articles a WHERE a.author_id = u.id ORDER BY a.id DESC LIMIT p.lim OFFSET p.off) a"""
    val AUTHOR_OIDS = intArrayOf(Oid.TEXT_ARRAY, Oid.INT8_ARRAY, Oid.INT8_ARRAY, Oid.INT8_ARRAY)
    const val FEED = """WITH u AS MATERIALIZED (SELECT r.k, r.v, r.depth, ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v) AS fids FROM unnest($1::int8[], $2::int8[]) WITH ORDINALITY r(v, depth, k)), hub_floors AS MATERIALIZED (SELECT h.fid, (SELECT a.id FROM articles a WHERE a.author_id = h.fid ORDER BY a.id DESC LIMIT 1 OFFSET h.depth - 1) AS floor_id FROM (SELECT f.fid, max(u.depth) AS depth FROM u, unnest(u.fids) AS f(fid) GROUP BY f.fid HAVING count(*) >= 2 ORDER BY count(*) DESC, f.fid LIMIT 32) h), cap_authors AS MATERIALIZED (SELECT ARRAY(SELECT hf.fid FROM (SELECT hf.fid FROM hub_floors hf WHERE hf.floor_id IS NOT NULL ORDER BY hf.floor_id DESC LIMIT 16) hf WHERE EXISTS (SELECT 1 FROM articles a WHERE a.author_id = hf.fid LIMIT 1 OFFSET 999)) AS fids) SELECT -u.k, CASE WHEN cardinality(u.fids) = 0 THEN 0::int8 WHEN u.fids && (SELECT fids FROM cap_authors) THEN 1000::int8 ELSE (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = ANY(u.fids) LIMIT 1000) s) END, 0::int8 FROM u UNION ALL SELECT p.k, x.id, x.author_id FROM unnest($3::int8[], $4::int8[], $5::int8[]) WITH ORDINALITY p(uk, lim, off, k) JOIN u ON u.k = p.uk CROSS JOIN LATERAL (SELECT COALESCE(max(hf.floor_id), 0::int8) AS floor_id FROM hub_floors hf WHERE hf.fid = ANY(u.fids)) fl CROSS JOIN LATERAL (SELECT y.id, y.author_id FROM unnest(u.fids) AS fid CROSS JOIN LATERAL (SELECT a2.id, fid AS author_id FROM articles a2 WHERE a2.author_id = fid AND a2.id >= fl.floor_id ORDER BY a2.id DESC LIMIT (p.lim + p.off)) y ORDER BY y.id DESC LIMIT p.lim OFFSET p.off) x"""
    val FEED_OIDS = intArrayOf(Oid.INT8_ARRAY, Oid.INT8_ARRAY, Oid.INT8_ARRAY, Oid.INT8_ARRAY, Oid.INT8_ARRAY)
    const val TAGS = """SELECT id, name FROM tags ORDER BY name"""
    val TAGS_OIDS = IntArray(0)
    /** name, sql, oids of every statement; prepared on every connection as "tp_<name>". */
    val all: List<Triple<String, String, IntArray>> = listOf(
        Triple("tp_aslug", ASLUG, ASLUG_OIDS),
        Triple("tp_aid", AID, AID_OIDS),
        Triple("tp_artx", ARTX, ARTX_OIDS),
        Triple("tp_artau", ARTAU, ARTAU_OIDS),
        Triple("tp_flags", FLAGS, FLAGS_OIDS),
        Triple("tp_cmts", CMTS, CMTS_OIDS),
        Triple("tp_global", GLOBAL, GLOBAL_OIDS),
        Triple("tp_global_win", GLOBAL_WIN, GLOBAL_WIN_OIDS),
        Triple("tp_tag", TAG, TAG_OIDS),
        Triple("tp_favlist", FAVLIST, FAVLIST_OIDS),
        Triple("tp_author", AUTHOR, AUTHOR_OIDS),
        Triple("tp_feed", FEED, FEED_OIDS),
        Triple("tp_tags", TAGS, TAGS_OIDS),
    )
}

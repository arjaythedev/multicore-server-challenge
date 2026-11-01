package conduit.app

import conduit.db.ReadKind
import conduit.db.Sharing
import conduit.db.WriteStmt
import conduit.pg.Oid

// The SQL catalog. Reads are batched (one execution serves every queued request of a kind, see ReadKind); the
// shapes are C# #2's (csharp-sockets-jh-d, research/sql-catalog.md), measured cheapest or tied on the full seed:
// - the page is cut in a subquery before anything is decorated (OFFSET rows cost one index step, no subqueries);
// - favorited/following are `(SELECT true ...) IS NOT NULL` PK probes: inside a batch, EXISTS became a hashed
//   subplan rebuilt per request from all of the viewer's rows;
// - tag names by tags_pkey per link (a join hashes all 200 tags per article in the generic plan);
// - lists return one row per request even for an empty page (the capped count); `OFFSET 0` keeps the count a
//   per-request subquery (pulled up, it runs once per article row);
// - a subquery that references no request column is tied to the request row with `r.i >= 0`, or it becomes an
//   InitPlan evaluated once per statement and shared by every request. That is the per-request reading of rule 5;
//   the ReadShare shapes (default) share on purpose, see [ReadShare].
// Writes are single statements (CTEs) with the author checks in SQL, so no write needs a separate SELECT.

private const val U =
    "unnest(\$1::int4[], \$2::int8[], \$3::int4[], \$4::int8[], \$5::text[]) AS r(i, v, l, o, k)"

/**
 * Who sorts tag lists. Set once at startup, before [Sql] is first touched: when the database collation is byte order
 * (C / POSIX / C.UTF-8) the app sorts each article's tag names itself (JsonWriter.textArray(sortBytes)), which saves
 * Postgres a Sort node per article; otherwise SQL sorts them (`ORDER BY 1` follows the collation, as the reference).
 */
internal object TagOrder {
    var appSorts = false

    /** pg_database probe for [isByteOrder]: provider, datcollate, datlocale. */
    const val PROBE =
        "SELECT datlocprovider::text, datcollate, coalesce(datlocale, '') FROM pg_database WHERE datname = current_database()"

    /** True when `ORDER BY` on text is plain byte order: libc C/POSIX/C.*, or the builtin C / C.UTF-8 locales. */
    fun isByteOrder(provider: String, collate: String, locale: String): Boolean = when (provider) {
        "c" -> collate == "C" || collate == "POSIX" || collate.startsWith("C.")
        "b" -> locale == "C" || locale == "C.UTF-8"
        else -> false
    }
}

private val TAG_NAMES: String
    get() = "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at " +
        "WHERE at.article_id = a.id" + (if (TagOrder.appSorts) ")" else " ORDER BY 1)")
private const val FAV_COUNT = "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id)"
private const val FAVORITED = "(SELECT true FROM favorites f WHERE f.user_id = r.v AND f.article_id = a.id) IS NOT NULL"
private const val FOLLOWING =
    "(SELECT true FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = a.author_id) IS NOT NULL"

/** Article columns after the key columns: see [Cols]. */
private val TAIL: String
    get() = "a.created_at, a.updated_at, $TAG_NAMES, $FAV_COUNT, $FAVORITED, u.username, u.bio, u.image"
private val LIST_COLS: String get() = "a.slug, a.title, a.description, $TAIL"
private val FULL_COLS: String get() = "a.slug, a.title, a.description, a.body, $TAIL"

/** A page of article ids (column `id`, newest first) -> list columns. */
private fun listOf(ids: String, following: String) =
    "SELECT $LIST_COLS, $following FROM ($ids) p JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id " +
        "ORDER BY p.id DESC"

private fun list(count: String, page: String) =
    "SELECT r.i, c.n, x.* FROM $U CROSS JOIN LATERAL (SELECT $count AS n OFFSET 0) c LEFT JOIN LATERAL ($page) x ON true"

/**
 * Whether one execution shares work between the requests of its batch. Set once at startup, before [Sql] is first
 * touched (like [TagOrder]). Off: every request computes its own rows (the shapes above). On (READ_SHARE=1): a kind's
 * statement computes each distinct key's count and page, and each distinct article's columns, once per execution, and
 * joins them back to every request row in the same layout ([Cols]); favorited/following stay per request row. Only
 * requests already waiting when the statement starts share it, and nothing outlives it: the #1 entry's reading of
 * rule 5, the same as [Sql.TAGS]'s broadcast. [maxBatch]: most requests per execution while sharing.
 * [viewerFlags] (READ_VIEWER_FLAGS=1): shared lists look up favorited/following once per viewer, `user_id = v AND
 * article_id = ANY (the viewer's page)`, instead of two primary-key probes per row (the #1 entry's technique).
 */
internal object ReadShare {
    var on = false
    var maxBatch = 256
    var viewerFlags = false

    /**
     * READ_FEED_MAX_BATCH (default 192, 0 = the usual cap): most feeds per execution. Viewers' pages differ, but the batch
     * shares the hub floors and counts and decorates each distinct article once ([feedShared]), so a bigger batch is cheaper per
     * feed (EXPLAIN: 334 us per feed at 64, 233 at 200) while one execution holds a read connection for longer. At 180k lab
     * users cap 64 collapsed and 192 held (see README).
     */
    var feedMaxBatch = 0

    /**
     * READ_FEED_HEAVY (lab, default off): a feed's count is capped at 1000, and most viewers follow an author with 1000+
     * articles, which makes the capped count walk ~890 index entries per request (~37% of a feed's Postgres time). When on,
     * each execution looks (once) at the up to 8 followees shared by >= 2 viewers of the batch and checks whether each has
     * 1000+ articles; a viewer who follows one of them gets 1000 without the scan. Same result as the plain capped count
     * (any followee with 1000+ articles means at least 1000 in total), so rows and JSON are identical.
     */
    var feedHeavy = false

    /**
     * READ_FEED_FLOOR (lab, default off; needs [feedHeavy]): per execution, each of the 16 followees shared by >= 2 viewers
     * ("hubs") gets a floor id: the id of its depth-th newest article (depth = the deepest page any viewer of the batch asks
     * of it). A viewer who follows a hub cannot have an article older than that floor in its first depth feed rows (the hub
     * alone supplies depth newer ones), so the other followees' per-author probes stop at the floor instead of fetching
     * depth rows each. Exact, as the Rust leader's "floor cutoffs" (#3 on the leaderboard).
     */
    var feedFloor = false

    /**
     * READ_FEED_SHARE (default on; 0 = the per-request decoration; needs [feedHeavy] and [feedFloor]): the feeds of a batch
     * overlap (about 630 page rows for 290-340 distinct articles at 64 feeds), so the statement cuts every viewer's page
     * first and then decorates each distinct page article once: tag names, favorites count and author by one `= ANY`
     * probe per table instead of subqueries per page row, and the viewer's favorited flags by one favorites_pkey
     * probe per viewer. Same rows in the same order as the per-request decoration (the equality harness in
     * .tmp/exp/sqlr compares every column).
     */
    var feedShared = false

    /**
     * READ_FEED_ROWS (default on; needs [feedShared]; 0 = the v4 statement that joins every page row to its article's
     * columns): the feed statement returns each viewer's page as narrow rows (count, article id) and each distinct article of
     * the batch ONCE, plus flag rows for the viewer's favorites ([conduit.db.Sharing.ARTICLES]); the pool collects the article
     * rows in an id table and the handler looks each page id up. No fan-out join, no final sort over wide rows, a fraction of
     * the bytes on the wire (about 630 wide rows for 290-340 distinct articles per 64 feeds before).
     */
    var feedRows = false

    /** READ_GLOBAL_WIN (default on; needs [sharedRows]; 0 = one index scan per distinct page): the global list's pages come from one window scan, see [Sql.LIST_ALL]. */
    var globalWin = false

    /**
     * READ_SHARED_ROWS (default on; needs [on]; 0 = the shared shapes that fan every row out to every request): comments
     * and the global, tag and author lists return each distinct thread or page ONCE and the pool hands every request of a
     * group views of the same rows ([conduit.db.Sharing.GROUPS]); what is per request (favorited, following) comes back as
     * a few flag rows. At 865 comments requests per execution over a few dozen threads, Postgres serialized and the pool
     * parsed every thread once per request before (the leaders send each distinct row once; .tmp/reports/multicore-sql-research-20261030.md).
     */
    var sharedRows = false
}

/** The batch's requests, materialized once and referenced by several CTEs. */
private const val R = "r AS MATERIALIZED (SELECT * FROM $U)"

/**
 * `art`: one row per distinct article: id, author_id, slug, title, description, [body], created_at, updated_at, tags,
 * fc (favorites count), username, bio, image. [from] yields the distinct keys and [where] picks the article by them.
 * `OFFSET 0` keeps the LATERAL a per-key index probe: pulled up into a plain join, the generic plan (which takes a
 * LIMIT parameter for 10% of the table) hashed all of articles and users per execution (278 ms per 60 requests).
 */
private fun art(from: String, where: String, withBody: Boolean) =
    "art AS MATERIALIZED (SELECT x.* FROM $from CROSS JOIN LATERAL (SELECT a.id, a.author_id, a.slug, a.title, " +
        "a.description, ${if (withBody) "a.body, " else ""}a.created_at, a.updated_at, $TAG_NAMES AS tags, " +
        "$FAV_COUNT AS fc, u.username, u.bio, u.image FROM articles a JOIN users u ON u.id = a.author_id " +
        "WHERE $where OFFSET 0) x)"

private const val ART_FAVORITED =
    "(SELECT true FROM favorites f WHERE f.user_id = r.v AND f.article_id = art.id) IS NOT NULL"
private const val ART_FOLLOWING =
    "(SELECT true FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = art.author_id) IS NOT NULL"

/** Article columns of [Cols] from `art` for request row `r`. */
private fun artCols(withBody: Boolean, following: String) =
    "art.slug, art.title, art.description, ${if (withBody) "art.body, " else ""}art.created_at, art.updated_at, " +
        "art.tags, art.fc, $ART_FAVORITED, art.username, art.bio, art.image, $following"

/**
 * A shared list. [ctes] define `cn` (one capped count n per distinct count key) and `pp` (the page's article ids, one
 * set per distinct page key); [countJoin] and [pageOn] join them back to the request row. An empty page is one row
 * with a NULL slug, as in [list].
 */
private fun sharedList(ctes: String, countJoin: String, pageOn: String, following: String) =
    if (ReadShare.viewerFlags && following == ART_FOLLOWING) {
        viewerFlagsList(ctes, countJoin, pageOn)
    } else {
        "WITH $R, $ctes, ${art("(SELECT DISTINCT pp.id FROM pp) d", "a.id = d.id", withBody = false)} " +
            "SELECT r.i, cn.n, ${artCols(withBody = false, following)} FROM r $countJoin LEFT JOIN pp ON $pageOn " +
            "LEFT JOIN art ON art.id = pp.id ORDER BY r.i, pp.id DESC"
    }

/**
 * [sharedList] with favorited/following per viewer ([ReadShare.viewerFlags]): `fl` holds each signed-in viewer's page
 * articles and their authors, `fav`/`fol` the ones they favorite/follow (one favorites_pkey and one follows_pkey scan
 * per viewer, `= ANY`), joined back to the rows. A viewer's (viewer, article) and (viewer, author) pairs are unique
 * (primary keys), so no row is duplicated; anonymous viewers (0) and empty pages get false.
 */
private fun viewerFlagsList(ctes: String, countJoin: String, pageOn: String) =
    "WITH $R, $ctes, ${art("(SELECT DISTINCT pp.id FROM pp) d", "a.id = d.id", withBody = false)}, " +
        "fl AS MATERIALIZED (SELECT r.v, array_agg(DISTINCT art.id) AS aids, array_agg(DISTINCT art.author_id) AS uids " +
        "FROM r JOIN pp ON $pageOn JOIN art ON art.id = pp.id WHERE r.v > 0 GROUP BY r.v), " +
        "fav AS MATERIALIZED (SELECT fl.v, x.article_id FROM fl CROSS JOIN LATERAL (SELECT f.article_id FROM favorites f " +
        "WHERE f.user_id = fl.v AND f.article_id = ANY (fl.aids) OFFSET 0) x), " +
        "fol AS MATERIALIZED (SELECT fl.v, x.followee_id FROM fl CROSS JOIN LATERAL (SELECT fo.followee_id FROM follows fo " +
        "WHERE fo.follower_id = fl.v AND fo.followee_id = ANY (fl.uids) OFFSET 0) x) " +
        "SELECT r.i, cn.n, art.slug, art.title, art.description, art.created_at, art.updated_at, art.tags, art.fc, " +
        "fav.article_id IS NOT NULL, art.username, art.bio, art.image, fol.followee_id IS NOT NULL " +
        "FROM r $countJoin LEFT JOIN pp ON $pageOn LEFT JOIN art ON art.id = pp.id " +
        "LEFT JOIN fav ON fav.v = r.v AND fav.article_id = art.id " +
        "LEFT JOIN fol ON fol.v = r.v AND fol.followee_id = art.author_id ORDER BY r.i, pp.id DESC"

/** Shared rows ([ReadShare.sharedRows]) are in effect: a kind's statement and its [conduit.db.ReadKind.sharing] follow it. */
private val rowsShared: Boolean get() = ReadShare.on && ReadShare.sharedRows

/** Columns of a shared list's rows after the count: the [Cols] layout with placeholder flags (the viewer's come as flag rows), then the article and author ids. */
private const val SHARED_ART_COLS =
    "art.slug, art.title, art.description, art.created_at, art.updated_at, art.tags, art.fc, false, art.username, " +
        "art.bio, art.image, false, art.id, art.author_id"

/** A flag row's columns after the request marker and the flag: NULLs up to the width of a list row (16 columns). */
private val LIST_FLAG_PAD = ", NULL".repeat(14)

/**
 * `ids`, `ar`, `tg`, `fc`, `art`: the distinct articles of the page ids in [from] (a CTE with a column `id`), each decorated
 * once with one `= ANY` probe per table instead of subqueries per page row: `ar` the articles with their authors, `tg` the
 * tag names (sorted by name unless the app sorts), `fc` the favorites counts; `art` joins them (no tags: an empty array,
 * no favorites: 0). `art` has the columns of [art]'s without `body`, plus `author_id`.
 */
private fun distinctArticles(from: String): String {
    val ids = "ANY ((SELECT ids.a FROM ids)::int8[])"
    val tagNames = "array_agg(t.name" + (if (TagOrder.appSorts) ")" else " ORDER BY t.name)")
    return "ids AS MATERIALIZED (SELECT array_agg(DISTINCT $from.id) AS a FROM $from), " +
        "ar AS MATERIALIZED (SELECT a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at, " +
        "u.username, u.bio, u.image FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = $ids), " +
        "tg AS MATERIALIZED (SELECT at.article_id AS id, $tagNames AS tags FROM article_tags at " +
        "JOIN tags t ON t.id = at.tag_id WHERE at.article_id = $ids GROUP BY at.article_id), " +
        "fc AS MATERIALIZED (SELECT f.article_id AS id, count(*) AS n FROM favorites f " +
        "WHERE f.article_id = $ids GROUP BY f.article_id), " +
        "art AS MATERIALIZED (SELECT ar.id, ar.author_id, ar.slug, ar.title, ar.description, ar.created_at, ar.updated_at, " +
        "COALESCE(tg.tags, '{}') AS tags, COALESCE(fc.n, 0) AS fc, ar.username, ar.bio, ar.image FROM ar " +
        "LEFT JOIN tg ON tg.id = ar.id LEFT JOIN fc ON fc.id = ar.id)"
}

/**
 * A shared-rows list ([conduit.db.Sharing.GROUPS]). [ctes] define `cn` (the capped count), `pk` (one row per group of requests
 * with the same key, limit and offset: its key columns and `rep` = the first request's index) and `pp` (`rep`, the page's
 * article ids); [countJoin] joins `cn` to `pk` and [groupOn] matches a request row `r` to its group. Rows: `pk.rep`, the count
 * and the page's articles in the layout of [Cols] (an empty page is one row with a NULL slug), once per group. Flag rows
 * `(-1 - request, flag, NULL...)` for each signed-in request: the article id for a page article the viewer favorited, minus
 * the author id for an author the viewer follows (one favorites_pkey and one follows_pkey probe per request, `= ANY`).
 */
private fun sharedRowsList(ctes: String, countJoin: String, groupOn: String) =
    "WITH $R, $ctes, ${distinctArticles("pp")}, " +
        "pa AS MATERIALIZED (SELECT pp.rep, array_agg(pp.id) AS aids, array_agg(DISTINCT art.author_id) AS uids " +
        "FROM pp JOIN art ON art.id = pp.id GROUP BY pp.rep) " +
        "(SELECT pk.rep, cn.n, $SHARED_ART_COLS FROM pk $countJoin LEFT JOIN pp ON pp.rep = pk.rep " +
        "LEFT JOIN art ON art.id = pp.id ORDER BY pk.rep, pp.id DESC) " +
        "UNION ALL (SELECT -1 - r.i, x.article_id$LIST_FLAG_PAD FROM r JOIN pk ON $groupOn JOIN pa ON pa.rep = pk.rep " +
        "CROSS JOIN LATERAL (SELECT f.article_id FROM favorites f WHERE f.user_id = r.v AND f.article_id = ANY (pa.aids) " +
        "OFFSET 0) x WHERE r.v > 0) " +
        "UNION ALL (SELECT -1 - r.i, -x.followee_id$LIST_FLAG_PAD FROM r JOIN pk ON $groupOn JOIN pa ON pa.rep = pk.rep " +
        "CROSS JOIN LATERAL (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v " +
        "AND fo.followee_id = ANY (pa.uids) OFFSET 0) x WHERE r.v > 0)"

/** [pageKeys] for [sharedRowsList]: `pk` carries each group's `rep`. */
private fun pageKeysRep(lookup: String) =
    "kk AS MATERIALIZED (SELECT DISTINCT r.k FROM r), fk AS MATERIALIZED (SELECT kk.k, ($lookup) AS id FROM kk), " +
        "pk AS MATERIALIZED (SELECT r.k, r.l, r.o, min(r.i) AS rep FROM r GROUP BY r.k, r.l, r.o)"

/** [filteredPages] for [sharedRowsList]: `pp` carries the group's `rep` instead of its key columns. */
private fun filteredPagesRep(ids: String) =
    "pp AS MATERIALIZED (SELECT pk.rep, x.id FROM pk JOIN fk ON fk.k = pk.k CROSS JOIN LATERAL ($ids) x)"

private const val GROUP_ON = "pk.k = r.k AND pk.l = r.l AND pk.o = r.o"

/** Distinct page keys (key columns + limit + offset) of a filtered list, and the id of the filter's row as `fk.id`. */
private fun pageKeys(lookup: String) =
    "kk AS MATERIALIZED (SELECT DISTINCT r.k FROM r), " +
        "fk AS MATERIALIZED (SELECT kk.k, ($lookup) AS id FROM kk), " +
        "pk AS MATERIALIZED (SELECT DISTINCT r.k, r.l, r.o FROM r)"

/** pp for a filtered list: [ids] selects `id` for `fk.id` with LIMIT pk.l OFFSET pk.o. */
private fun filteredPages(ids: String) =
    "pp AS MATERIALIZED (SELECT pk.k, pk.l, pk.o, x.id FROM pk JOIN fk ON fk.k = pk.k CROSS JOIN LATERAL ($ids) x)"

private const val KEYED_PAGE_ON = "pp.k = r.k AND pp.l = r.l AND pp.o = r.o"

/**
 * Column layouts, all read with binary formats. Reads have `r.i` at column 0, lists the capped count (int8) at 1.
 * Article: slug, title, description, [body], created_at, updated_at, tag_list text[], favorites_count int8,
 * favorited bool, username, bio, image, following bool.
 */
internal object Cols {
    // Shared rows ([ReadShare.sharedRows]): the viewer's favorited/following columns hold false and two columns follow the
    // layout, article id and author id; the viewer's flags are the request's flag rows (Result.hasFlag, JsonWriter.article).
    const val ARTICLE = 1      // ARTICLE_BY_SLUG / ARTICLE_BY_ID: full article from column 1
    const val ARTICLE_SHARED = 2 // ARTICLE_BY_SLUG with shared rows: the article id is column 1, the full article follows
    const val LIST_COUNT = 1
    const val LIST = 2         // list article (no body) from column 2; NULL slug = empty page
    const val CREATED = 0      // ARTICLE_CREATE: full article from column 0

    // Feed rows ([ReadShare.feedRows], Sharing.ARTICLES): column 1 is the capped count (count row, NULL in page rows) or the article id
    // (article and flag rows), column 2 the page's article id (page rows) or the author id (article rows), then slug, title,
    // description, created_at, updated_at, tags, favorites count, username, bio, image from column 3 (article rows only).
    const val FEED_ROW = 3
}

internal object Sql {
    /**
     * Row: names text[] (sorted by name; an index-only scan of tags_name_key). Broadcast: every tags request queued
     * when a read connection frees is answered by one execution (see [ReadKind.broadcast]).
     */
    val TAGS = ReadKind(
        "tags",
        "SELECT ARRAY(SELECT t.name FROM tags t ORDER BY t.name)",
        maxBatch = 1024,
        broadcast = true,
    )

    private val batch get() = if (ReadShare.on) ReadShare.maxBatch else 64

    /** k = slug. Row: i, full article. No row: 404. */
    val ARTICLE_BY_SLUG = ReadKind(
        "article",
        if (rowsShared) {
            // each distinct slug's article (with body) ONCE: column 1 is its id (flag rows carry their flag there), the layout
            // of [Cols.ARTICLE_SHARED] follows; the viewer's favorited / follows-the-author are flag rows (the article id /
            // minus the author id), one favorites_pkey and one follows_pkey probe per signed-in request
            "WITH $R, kk AS MATERIALIZED (SELECT r.k, r.l, r.o, min(r.i) AS rep FROM r GROUP BY r.k, r.l, r.o), " +
                "${art("kk", "a.slug = kk.k", withBody = true)} " +
                "(SELECT kk.rep, art.id, art.slug, art.title, art.description, art.body, art.created_at, art.updated_at, " +
                "art.tags, art.fc, false, art.username, art.bio, art.image, false, art.id, art.author_id " +
                "FROM kk JOIN art ON art.slug = kk.k ORDER BY kk.rep) " +
                "UNION ALL (SELECT -1 - r.i, art.id${", NULL".repeat(15)} FROM r " +
                "JOIN kk ON kk.k = r.k AND kk.l = r.l AND kk.o = r.o JOIN art ON art.slug = kk.k " +
                "CROSS JOIN LATERAL (SELECT 1 FROM favorites f WHERE f.user_id = r.v AND f.article_id = art.id OFFSET 0) x " +
                "WHERE r.v > 0) " +
                "UNION ALL (SELECT -1 - r.i, -art.author_id${", NULL".repeat(15)} FROM r " +
                "JOIN kk ON kk.k = r.k AND kk.l = r.l AND kk.o = r.o JOIN art ON art.slug = kk.k " +
                "CROSS JOIN LATERAL (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = art.author_id " +
                "OFFSET 0) x WHERE r.v > 0)"
        } else if (ReadShare.on) {
            "WITH $R, kk AS MATERIALIZED (SELECT DISTINCT r.k FROM r), ${art("kk", "a.slug = kk.k", withBody = true)} " +
                "SELECT r.i, ${artCols(withBody = true, ART_FOLLOWING)} FROM r JOIN art ON art.slug = r.k"
        } else {
            "SELECT r.i, x.* FROM $U CROSS JOIN LATERAL (SELECT $FULL_COLS, $FOLLOWING " +
                "FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = r.k) x"
        },
        maxBatch = batch,
        sharing = if (rowsShared) Sharing.GROUPS else Sharing.NONE,
    )

    /** o = article id (read-back after favorite/update: by id, so a concurrent rename can't 404). */
    val ARTICLE_BY_ID = ReadKind(
        "article_id",
        if (ReadShare.on) {
            "WITH $R, ${art("(SELECT DISTINCT r.o FROM r) d", "a.id = d.o", withBody = true)} " +
                "SELECT r.i, ${artCols(withBody = true, ART_FOLLOWING)} FROM r JOIN art ON art.id = r.o"
        } else {
            "SELECT r.i, x.* FROM $U CROSS JOIN LATERAL (SELECT $FULL_COLS, $FOLLOWING " +
                "FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = r.o) x"
        },
        maxBatch = batch,
    )

    /**
     * k = slug. Rows: i, comment id int8, created_at, updated_at, body, username, bio, image, following.
     * No row: no article (404). One row with NULL comment id: an article without comments. The viewer's followees are
     * read once per request instead of one follows probe per comment.
     */
    val COMMENTS = ReadKind(
        "comments",
        if (rowsShared) {
            // each distinct slug's thread (newest 100, with authors) ONCE (rows tagged with the group's first request), and per
            // signed-in request the thread's authors it follows as flag rows (the author id): one follows_pkey probe, `= ANY`
            "WITH $R, kk AS MATERIALIZED (SELECT r.k, r.l, r.o, min(r.i) AS rep FROM r GROUP BY r.k, r.l, r.o), " +
                "ar AS MATERIALIZED (SELECT kk.rep, a.id FROM kk CROSS JOIN LATERAL " +
                "(SELECT a.id FROM articles a WHERE a.slug = kk.k OFFSET 0) a), " +
                "cm AS MATERIALIZED (SELECT ar.rep, c.* FROM ar CROSS JOIN LATERAL (SELECT c.id, c.created_at, " +
                "c.updated_at, c.body, u.username, u.bio, u.image, c.author_id FROM comments c " +
                "JOIN users u ON u.id = c.author_id WHERE c.article_id = ar.id " +
                "ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c), " +
                "au AS MATERIALIZED (SELECT cm.rep, array_agg(DISTINCT cm.author_id) AS ids FROM cm GROUP BY cm.rep) " +
                "(SELECT ar.rep, cm.id, cm.created_at, cm.updated_at, cm.body, cm.username, cm.bio, cm.image, cm.author_id " +
                "FROM ar LEFT JOIN cm ON cm.rep = ar.rep ORDER BY ar.rep, cm.created_at DESC, cm.id DESC) " +
                "UNION ALL (SELECT -1 - r.i, x.followee_id, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM r " +
                "JOIN kk ON kk.k = r.k AND kk.l = r.l AND kk.o = r.o JOIN au ON au.rep = kk.rep " +
                "CROSS JOIN LATERAL (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v " +
                "AND fo.followee_id = ANY (au.ids) OFFSET 0) x WHERE r.v > 0)"
        } else if (ReadShare.on) {
            // each distinct slug's thread (newest 100, with authors) and each distinct viewer's followees once
            "WITH $R, kk AS MATERIALIZED (SELECT DISTINCT r.k FROM r), " +
                "ar AS MATERIALIZED (SELECT kk.k, a.id FROM kk CROSS JOIN LATERAL " +
                "(SELECT a.id FROM articles a WHERE a.slug = kk.k OFFSET 0) a), " +
                "cm AS MATERIALIZED (SELECT ar.k, c.* FROM ar CROSS JOIN LATERAL (SELECT c.id, c.created_at, " +
                "c.updated_at, c.body, c.author_id, u.username, u.bio, u.image FROM comments c " +
                "JOIN users u ON u.id = c.author_id WHERE c.article_id = ar.id " +
                "ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c), " +
                "fv AS MATERIALIZED (SELECT vv.v, ARRAY(SELECT fo.followee_id FROM follows fo " +
                "WHERE fo.follower_id = vv.v) AS ids FROM (SELECT DISTINCT r.v FROM r) vv) " +
                "SELECT r.i, cm.id, cm.created_at, cm.updated_at, cm.body, cm.username, cm.bio, cm.image, " +
                "cm.author_id = ANY (fv.ids) FROM r JOIN ar ON ar.k = r.k JOIN fv ON fv.v = r.v " +
                "LEFT JOIN cm ON cm.k = r.k ORDER BY r.i, cm.created_at DESC, cm.id DESC"
        } else {
            "SELECT r.i, x.* FROM $U CROSS JOIN LATERAL (" +
                "SELECT c.id, c.created_at, c.updated_at, c.body, u.username, u.bio, u.image, " +
                "c.author_id = ANY (f.ids) AS following FROM articles a " +
                "CROSS JOIN LATERAL (SELECT ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v) AS ids) f " +
                "LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c " +
                "WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true " +
                "LEFT JOIN users u ON u.id = c.author_id WHERE a.slug = r.k ORDER BY c.created_at DESC, c.id DESC) x"
        },
        maxBatch = batch,
        sharing = if (rowsShared) Sharing.GROUPS else Sharing.NONE,
    )

    /** k = username. Row: i, username, bio, image, following. No row: 404. */
    val PROFILE = ReadKind(
        "profile",
        if (ReadShare.on) {
            "WITH $R, kk AS MATERIALIZED (SELECT DISTINCT r.k FROM r), pu AS MATERIALIZED (SELECT u.* FROM kk " +
                "CROSS JOIN LATERAL (SELECT u.id, u.username, u.bio, u.image FROM users u WHERE u.username = kk.k " +
                "OFFSET 0) u) " +
                "SELECT r.i, pu.username, pu.bio, pu.image, " +
                "(SELECT true FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = pu.id) IS NOT NULL " +
                "FROM r JOIN pu ON pu.username = r.k"
        } else {
            "SELECT r.i, x.* FROM $U CROSS JOIN LATERAL (SELECT u.username, u.bio, u.image, " +
                "(SELECT true FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = u.id) IS NOT NULL " +
                "FROM users u WHERE u.username = r.k) x"
        },
        maxBatch = batch,
    )

    /** v = user id. Row: i, email, username, bio, image. No row: 401. */
    val USER_BY_ID = ReadKind(
        "user",
        "SELECT r.i, x.* FROM $U CROSS JOIN LATERAL (SELECT u.email, u.username, u.bio, u.image FROM users u " +
            "WHERE u.id = r.v) x",
    )

    /** k = email (login). Row: i, id, email, username, bio, image, password_hash. */
    val USER_BY_EMAIL = ReadKind(
        "user_email",
        "SELECT r.i, x.* FROM $U CROSS JOIN LATERAL (SELECT u.id, u.email, u.username, u.bio, u.image, " +
            "u.password_hash FROM users u WHERE u.email = r.k) x",
    )

    /**
     * Global list. Count: "a 1000th row exists" walks at most 1000 entries from the old, all-visible end of the PK,
     * the exact count only below that; both tied to the request row.
     */
    val LIST_ALL = ReadKind(
        "list",
        if (rowsShared) {
            // one count per execution, one page per distinct (limit, offset), each sent once
            sharedRowsList(
                "cn AS MATERIALIZED (SELECT CASE WHEN EXISTS (SELECT 1 FROM articles c ORDER BY c.id OFFSET 999) " +
                    "THEN 1000 ELSE (SELECT count(*) FROM articles c) END AS n), " +
                    "pk AS MATERIALIZED (SELECT r.k, r.l, r.o, min(r.i) AS rep FROM r GROUP BY r.k, r.l, r.o), " +
                    (if (ReadShare.globalWin) {
                        // the pages of a batch overlap (offsets 0-40): ONE scan of the newest max(limit + offset) ids, sliced per page
                        "win AS MATERIALIZED (SELECT array_agg(w.id ORDER BY w.id DESC) AS ids FROM (SELECT a.id FROM articles a " +
                            "ORDER BY a.id DESC LIMIT (SELECT max(pk.l::bigint + pk.o) FROM pk)) w), " +
                            "pp AS MATERIALIZED (SELECT pk.rep, x.id FROM pk CROSS JOIN win CROSS JOIN LATERAL " +
                            "unnest(win.ids[pk.o::int + 1 : pk.o::int + pk.l]) AS x(id))"
                    } else {
                        "pp AS MATERIALIZED (SELECT pk.rep, x.id FROM pk CROSS JOIN LATERAL " +
                            "(SELECT a.id FROM articles a ORDER BY a.id DESC LIMIT pk.l OFFSET pk.o) x)"
                    }),
                "CROSS JOIN cn",
                GROUP_ON,
            )
        } else if (ReadShare.on) {
            // one count per execution, one page per distinct (limit, offset)
            sharedList(
                "cn AS MATERIALIZED (SELECT CASE WHEN EXISTS (SELECT 1 FROM articles c ORDER BY c.id OFFSET 999) " +
                    "THEN 1000 ELSE (SELECT count(*) FROM articles c) END AS n), " +
                    "pk AS MATERIALIZED (SELECT DISTINCT r.l, r.o FROM r), " +
                    "pp AS MATERIALIZED (SELECT pk.l, pk.o, x.id FROM pk CROSS JOIN LATERAL " +
                    "(SELECT a.id FROM articles a ORDER BY a.id DESC LIMIT pk.l OFFSET pk.o) x)",
                "CROSS JOIN cn",
                "pp.l = r.l AND pp.o = r.o",
                ART_FOLLOWING,
            )
        } else {
            list(
                "CASE WHEN EXISTS (SELECT 1 FROM articles c WHERE r.i >= 0 ORDER BY c.id OFFSET 999) THEN 1000 " +
                    "ELSE (SELECT count(*) FROM articles c WHERE r.i >= 0) END",
                "SELECT $LIST_COLS, $FOLLOWING FROM (SELECT a.id, a.slug, a.title, a.description, a.created_at, " +
                    "a.updated_at, a.author_id FROM articles a ORDER BY a.id DESC LIMIT r.l OFFSET r.o) a " +
                    "JOIN users u ON u.id = a.author_id ORDER BY a.id DESC",
            )
        },
        maxBatch = batch,
        sharing = if (rowsShared) Sharing.GROUPS else Sharing.NONE,
    )

    /**
     * LIST_ALL for offsets >= [DEEP_OFFSET]: the page's ids come from an index-only scan, so skipped rows cost no heap
     * fetch (conformance's offset=100000000 on the full seed: 26 ms instead of 3.6 s). Slower for small offsets
     * (one extra PK probe per row), which is all the workload sends.
     */
    val LIST_ALL_DEEP = ReadKind(
        "list_deep",
        list(
            "CASE WHEN EXISTS (SELECT 1 FROM articles c WHERE r.i >= 0 ORDER BY c.id OFFSET 999) THEN 1000 " +
                "ELSE (SELECT count(*) FROM articles c WHERE r.i >= 0) END",
            listOf("SELECT a.id FROM articles a ORDER BY a.id DESC LIMIT r.l OFFSET r.o", FOLLOWING),
        ),
        maxInflight = 1,
    )
    const val DEEP_OFFSET = 500L

    /** k = author username. Authors have few articles, so the plain capped count is cheapest. */
    val LIST_AUTHOR = ReadKind(
        "list_author",
        if (rowsShared) {
            sharedRowsList(
                pageKeysRep("SELECT u.id FROM users u WHERE u.username = kk.k") + ", " +
                    "cn AS MATERIALIZED (SELECT fk.k, (SELECT count(*) FROM (SELECT 1 FROM articles c " +
                    "WHERE c.author_id = fk.id LIMIT 1000) s) AS n FROM fk), " +
                    filteredPagesRep(
                        "SELECT a.id FROM articles a WHERE a.author_id = fk.id ORDER BY a.id DESC LIMIT pk.l OFFSET pk.o",
                    ),
                "JOIN cn ON cn.k = pk.k",
                GROUP_ON,
            )
        } else if (ReadShare.on) {
            sharedList(
                pageKeys("SELECT u.id FROM users u WHERE u.username = kk.k") + ", " +
                    "cn AS MATERIALIZED (SELECT fk.k, (SELECT count(*) FROM (SELECT 1 FROM articles c " +
                    "WHERE c.author_id = fk.id LIMIT 1000) s) AS n FROM fk), " +
                    filteredPages(
                        "SELECT a.id FROM articles a WHERE a.author_id = fk.id ORDER BY a.id DESC LIMIT pk.l OFFSET pk.o",
                    ),
                "JOIN cn ON cn.k = r.k",
                KEYED_PAGE_ON,
                ART_FOLLOWING,
            )
        } else {
            list(
                "(SELECT count(*) FROM (SELECT 1 FROM articles c WHERE c.author_id = " +
                    "(SELECT u.id FROM users u WHERE u.username = r.k) LIMIT 1000) s)",
                "SELECT $LIST_COLS, $FOLLOWING FROM (SELECT a.id, a.slug, a.title, a.description, a.created_at, " +
                    "a.updated_at, a.author_id FROM articles a WHERE a.author_id = " +
                    "(SELECT au.id FROM users au WHERE au.username = r.k) ORDER BY a.id DESC LIMIT r.l OFFSET r.o) a " +
                    "JOIN users u ON u.id = a.author_id ORDER BY a.id DESC",
            )
        },
        maxBatch = batch,
        sharing = if (rowsShared) Sharing.GROUPS else Sharing.NONE,
    )

    /** k = tag. Every seed tag has >= 1000 articles, so "a 1000th link exists" usually answers the count. */
    val LIST_TAG = ReadKind(
        "list_tag",
        if (rowsShared) {
            sharedRowsList(
                pageKeysRep("SELECT t.id FROM tags t WHERE t.name = kk.k") + ", " +
                    "cn AS MATERIALIZED (SELECT fk.k, CASE WHEN EXISTS (SELECT 1 FROM article_tags c " +
                    "WHERE c.tag_id = fk.id OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM " +
                    "(SELECT 1 FROM article_tags c WHERE c.tag_id = fk.id LIMIT 1000) s) END AS n FROM fk), " +
                    filteredPagesRep(
                        "SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = fk.id " +
                            "ORDER BY at.article_id DESC LIMIT pk.l OFFSET pk.o",
                    ),
                "JOIN cn ON cn.k = pk.k",
                GROUP_ON,
            )
        } else if (ReadShare.on) {
            sharedList(
                pageKeys("SELECT t.id FROM tags t WHERE t.name = kk.k") + ", " +
                    "cn AS MATERIALIZED (SELECT fk.k, CASE WHEN EXISTS (SELECT 1 FROM article_tags c " +
                    "WHERE c.tag_id = fk.id OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM " +
                    "(SELECT 1 FROM article_tags c WHERE c.tag_id = fk.id LIMIT 1000) s) END AS n FROM fk), " +
                    filteredPages(
                        "SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = fk.id " +
                            "ORDER BY at.article_id DESC LIMIT pk.l OFFSET pk.o",
                    ),
                "JOIN cn ON cn.k = r.k",
                KEYED_PAGE_ON,
                ART_FOLLOWING,
            )
        } else {
            list(
                "CASE WHEN EXISTS (SELECT 1 FROM article_tags c WHERE c.tag_id = " +
                    "(SELECT t.id FROM tags t WHERE t.name = r.k) OFFSET 999 LIMIT 1) THEN 1000::bigint " +
                    "ELSE (SELECT count(*) FROM (SELECT 1 FROM article_tags c WHERE c.tag_id = " +
                    "(SELECT t.id FROM tags t WHERE t.name = r.k) LIMIT 1000) s) END",
                listOf(
                    "SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = " +
                        "(SELECT t.id FROM tags t WHERE t.name = r.k) ORDER BY at.article_id DESC LIMIT r.l OFFSET r.o",
                    FOLLOWING,
                ),
            )
        },
        maxBatch = batch,
        sharing = if (rowsShared) Sharing.GROUPS else Sharing.NONE,
    )

    /**
     * k = username of the favoriting user. Per request even with [ReadShare]: its keys rarely repeat within a batch,
     * and the shared shape cost more (EXPLAIN, 60 requests, full seed: 128 vs 99 us per request).
     */
    val LIST_FAVORITED = ReadKind(
        "list_favorited",
        list(
            "(SELECT count(*) FROM (SELECT 1 FROM favorites c WHERE c.user_id = " +
                "(SELECT u.id FROM users u WHERE u.username = r.k) LIMIT 1000) s)",
            listOf(
                "SELECT f.article_id AS id FROM favorites f WHERE f.user_id = " +
                    "(SELECT fu.id FROM users fu WHERE fu.username = r.k) ORDER BY f.article_id DESC LIMIT r.l OFFSET r.o",
                FOLLOWING,
            ),
        ),
        maxBatch = batch,
    )

    /**
     * v = viewer. Page: each followee's newest (limit + offset) articles, merged and cut. `following` is the
     * constant true: every row was selected through the viewer's follows in the same snapshot. The app clamps
     * offsets so r.l + r.o can't overflow.
     */
    private val FEED_PAGE: String get() = listOf(
            "SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 " +
                    "WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT (r.l::bigint + r.o)) x " +
                    "WHERE fo.follower_id = r.v ORDER BY x.id DESC LIMIT r.l OFFSET r.o",
                "true",
            )

    /** The viewers (`r`: each one's `depth` = l + o and followee ids) and the hubs ([ReadShare.feedFloor]) of [feedFloor] and [feedShared]. */
    private const val FEED_CTES =
        "r0 AS MATERIALIZED (SELECT * FROM $U), " +
            "r AS MATERIALIZED (SELECT r0.i, r0.v, r0.l, r0.o, GREATEST(r0.l::bigint + r0.o, 1) AS depth, " +
            "ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r0.v) AS fids FROM r0), " +
            "hubs AS MATERIALIZED (SELECT h.fid, " +
            "(SELECT a.id FROM articles a WHERE a.author_id = h.fid ORDER BY a.id DESC LIMIT 1 OFFSET h.depth - 1) AS floor_id, " +
            "EXISTS (SELECT 1 FROM articles a WHERE a.author_id = h.fid OFFSET 999) AS capped " +
            "FROM (SELECT x.fid, max(r.depth) AS depth FROM r, unnest(r.fids) AS x(fid) " +
            "GROUP BY x.fid HAVING count(*) >= 2 ORDER BY count(*) DESC, x.fid LIMIT 16) h), " +
            "cap AS MATERIALIZED (SELECT array_agg(hubs.fid) AS ids FROM hubs WHERE hubs.capped)"

    /** A viewer's capped count `n` (column `n`, a lateral subquery of `r`): 1000 at once for a viewer who follows a capped hub. */
    private const val FEED_COUNT =
        "CROSS JOIN LATERAL (SELECT CASE WHEN r.fids && (SELECT cap.ids FROM cap) " +
            "THEN 1000::bigint ELSE (SELECT count(*) FROM (SELECT 1 FROM articles c2 WHERE c2.author_id = ANY (r.fids) " +
            "LIMIT 1000) s) END AS n OFFSET 0) c"

    /** [feedHeavy] plus the hub floors ([ReadShare.feedFloor]): `r` also carries each viewer's `depth` = l + o. */
    private fun feedFloor() =
        "WITH $FEED_CTES SELECT r.i, c.n, x.* FROM r $FEED_COUNT " +
            "LEFT JOIN LATERAL (${listOf(FLOOR_IDS, "true")}) x ON true"

    /**
     * [feedFloor] with each distinct page article decorated once ([ReadShare.feedShared]); the same columns and rows in
     * the same order. `cn`: the count per viewer, `pg`: the page ids per viewer, `ar`/`tg`/`fc`: the distinct articles
     * (with their authors), their tag names and their favorites counts, one `= ANY` probe each, `art`: those joined,
     * `fl`: the page articles each viewer favorited, one favorites_pkey probe per viewer. An empty page is one row with
     * NULLs after the count, as in [feedFloor].
     */
    private fun feedShared(narrow: Boolean): String {
        val ctes = "WITH $FEED_CTES, " +
            "cn AS MATERIALIZED (SELECT r.i, c.n FROM r $FEED_COUNT), " +
            "pg AS MATERIALIZED (SELECT r.i, x.id FROM r CROSS JOIN LATERAL ($FLOOR_IDS) x), " +
            "${distinctArticles("pg")}, " +
            "fl AS MATERIALIZED (SELECT g.i, x.article_id FROM (SELECT pg.i, r.v, array_agg(pg.id) AS aids FROM pg " +
            "JOIN r ON r.i = pg.i WHERE r.v > 0 GROUP BY pg.i, r.v) g CROSS JOIN LATERAL (SELECT f.article_id " +
            "FROM favorites f WHERE f.user_id = g.v AND f.article_id = ANY (g.aids) OFFSET 0) x) "
        if (narrow) return ctes + FEED_ROWS_SELECT
        return ctes +
            "SELECT cn.i, cn.n, art.slug, art.title, art.description, art.created_at, art.updated_at, art.tags, art.fc, " +
            "CASE WHEN art.id IS NOT NULL THEN fl.article_id IS NOT NULL END, art.username, art.bio, art.image, " +
            "CASE WHEN art.id IS NOT NULL THEN true END " +
            "FROM cn LEFT JOIN pg ON pg.i = cn.i LEFT JOIN art ON art.id = pg.id " +
            "LEFT JOIN fl ON fl.i = cn.i AND fl.article_id = pg.id ORDER BY cn.i, pg.id DESC"
    }

    /** NULL columns after the article id of a page or flag row (the width of [Cols.FEED_ROW] minus 3). */
    private val FEED_PAD = listOf("text", "text", "text", "timestamptz", "timestamptz", "text[]", "int8", "text", "text", "text")
        .joinToString("") { ", NULL::$it" }

    /**
     * The final SELECT of [feedShared] with [ReadShare.feedRows] ([Cols.FEED_ROW] layout): per request one count row
     * `(i, n, NULL)`, its page rows `(i, NULL, id)` (newest first; none for an empty page), then each distinct article once, then
     * the flag rows `(-1 - request, article id)` of the page articles the viewer favorited. No join back to the articles.
     */
    private val FEED_ROWS_SELECT: String get() =
        "(SELECT cn.i, cn.n, NULL::int8$FEED_PAD FROM cn) " +
            "UNION ALL (SELECT pg.i, NULL::int8, pg.id$FEED_PAD FROM pg ORDER BY pg.i, pg.id DESC) " +
            "UNION ALL (SELECT (-2147483648)::int4, art.id, art.author_id, art.slug, art.title, art.description, " +
            "art.created_at, art.updated_at, art.tags, art.fc, art.username, art.bio, art.image FROM art) " +
            "UNION ALL (SELECT -1 - fl.i, fl.article_id, NULL::int8$FEED_PAD FROM fl)"

    /** The page ids of [feedFloor]: per followee at most depth ids, none older than the viewer's hub floor. */
    private const val FLOOR_IDS =
        "SELECT y.id FROM (SELECT max(hb.floor_id) AS floor_id FROM hubs hb WHERE hb.fid = ANY (r.fids)) fl " +
            "CROSS JOIN LATERAL (SELECT z.id FROM unnest(r.fids) AS u(fid) CROSS JOIN LATERAL " +
            "(SELECT a2.id FROM articles a2 WHERE a2.author_id = u.fid AND a2.id >= COALESCE(fl.floor_id, 0::bigint) " +
            "ORDER BY a2.id DESC LIMIT r.depth) z ORDER BY z.id DESC LIMIT r.l OFFSET r.o) y"

    /** [FEED] with the heavy-author shortcut ([ReadShare.feedHeavy]): `r` carries each viewer's followee ids as `fids`. */
    private fun feedHeavy(page: String) =
        "WITH r0 AS MATERIALIZED (SELECT * FROM $U), " +
            "r AS MATERIALIZED (SELECT r0.i, r0.v, r0.l, r0.o, " +
            "ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r0.v) AS fids FROM r0), " +
            "hc AS MATERIALIZED (SELECT x.id FROM r CROSS JOIN LATERAL unnest(r.fids) AS x(id) " +
            "GROUP BY x.id HAVING count(*) >= 2 ORDER BY count(*) DESC LIMIT 8), " +
            "heavy AS MATERIALIZED (SELECT array_agg(hc.id) AS ids FROM hc " +
            "WHERE EXISTS (SELECT 1 FROM articles a WHERE a.author_id = hc.id OFFSET 999)) " +
            "SELECT r.i, c.n, x.* FROM r CROSS JOIN LATERAL (SELECT CASE WHEN r.fids && (SELECT h.ids FROM heavy h) " +
            "THEN 1000::bigint ELSE (SELECT count(*) FROM (SELECT 1 FROM articles c2 WHERE c2.author_id = ANY (r.fids) " +
            "LIMIT 1000) s) END AS n OFFSET 0) c LEFT JOIN LATERAL ($page) x ON true"

    val FEED = ReadKind(
        "feed",
        // per request even with [ReadShare]: feeds are per viewer, so there is nothing to share (EXPLAIN: 361 vs 352 us).
        // Tried and dropped (2026-10-28): taking the page from the count's id scan when below the cap. EXPLAIN 456 vs
        // 327 us per feed: most viewers reach the 1000 cap (mean 893 ids), so the per-followee page runs anyway.
        if (ReadShare.feedHeavy && ReadShare.feedFloor) {
            if (ReadShare.feedShared) feedShared(ReadShare.feedRows) else feedFloor()
        } else if (ReadShare.feedHeavy) {
            feedHeavy(FEED_PAGE)
        } else {
            list(
                "(SELECT count(*) FROM (SELECT 1 FROM articles c WHERE c.author_id = " +
                    "ANY (ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v)) LIMIT 1000) s)",
                FEED_PAGE,
            )
        },
        maxBatch = ReadShare.feedMaxBatch.takeIf { it > 0 } ?: batch,
        sharing = if (ReadShare.feedRows && ReadShare.feedShared && ReadShare.feedHeavy && ReadShare.feedFloor) Sharing.ARTICLES else Sharing.NONE,
    )

    val reads: List<ReadKind> = listOf(
        TAGS, ARTICLE_BY_SLUG, ARTICLE_BY_ID, COMMENTS, PROFILE, USER_BY_ID, USER_BY_EMAIL,
        LIST_ALL, LIST_ALL_DEEP, LIST_AUTHOR, LIST_TAG, LIST_FAVORITED, FEED,
    )

    private const val I8 = Oid.INT8
    private const val T = Oid.TEXT

    /**
     * $1 username, $2 email, $3 bcrypt hash. Row: id, email, username, bio, image. No row: username or email taken
     * (422); DO NOTHING (no conflict target covers both unique keys) means no 23505 in normal operation.
     */
    val USER_INSERT = WriteStmt(
        "user_insert",
        "INSERT INTO users (username, email, password_hash) VALUES (\$1, \$2, \$3) " +
            "ON CONFLICT DO NOTHING RETURNING id, email, username, bio, image",
        intArrayOf(T, T, T),
    )

    /** $1 id, $2 email, $3 username, $4 hash, $5 bio, $6 image (NULL = unchanged). Row: email, username, bio, image. */
    val USER_UPDATE = WriteStmt(
        "user_update",
        "UPDATE users SET email = COALESCE(\$2, email), username = COALESCE(\$3, username), " +
            "password_hash = COALESCE(\$4, password_hash), bio = COALESCE(\$5, bio), image = COALESCE(\$6, image) " +
            "WHERE id = \$1 RETURNING email, username, bio, image",
        intArrayOf(I8, T, T, T, T, T),
    )

    /** $1 viewer, $2 username. Row: username, bio, image (following is the constant true). No row: 404. */
    val FOLLOW = WriteStmt(
        "follow",
        "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = \$2), " +
            "w AS (INSERT INTO follows (follower_id, followee_id) SELECT \$1, t.id FROM t ON CONFLICT DO NOTHING) " +
            "SELECT t.username, t.bio, t.image FROM t",
        intArrayOf(I8, T),
    )

    /** $1 viewer, $2 username. Row: username, bio, image (following false). No row: 404. */
    val UNFOLLOW = WriteStmt(
        "unfollow",
        "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = \$2), " +
            "w AS (DELETE FROM follows fo USING t WHERE fo.follower_id = \$1 AND fo.followee_id = t.id) " +
            "SELECT t.username, t.bio, t.image FROM t",
        intArrayOf(I8, T),
    )

    /** $1 viewer, $2 slug. Row: article id (then ARTICLE_BY_ID after commit). No row: 404. */
    val FAVORITE = WriteStmt(
        "favorite",
        "WITH t AS (SELECT id FROM articles WHERE slug = \$2), " +
            "w AS (INSERT INTO favorites (user_id, article_id) SELECT \$1, t.id FROM t ON CONFLICT DO NOTHING) " +
            "SELECT t.id FROM t",
        intArrayOf(I8, T),
        // m favorites at once: $1 i, $2 viewers, $3 slugs. Rows: i, article id. DISTINCT: the same favorite twice in one group.
        batchSql = "WITH r AS (SELECT * FROM unnest(\$1::int4[], \$2::int8[], \$3::text[]) AS r(i, v, s)), " +
            "t AS (SELECT r.i, r.v, a.id FROM r JOIN articles a ON a.slug = r.s), " +
            "w AS (INSERT INTO favorites (user_id, article_id) SELECT DISTINCT t.v, t.id FROM t ON CONFLICT DO NOTHING) " +
            "SELECT t.i, t.id FROM t",
    )

    /** $1 viewer, $2 slug. Row: article id. No row: 404. */
    val UNFAVORITE = WriteStmt(
        "unfavorite",
        "WITH t AS (SELECT id FROM articles WHERE slug = \$2), " +
            "w AS (DELETE FROM favorites f USING t WHERE f.user_id = \$1 AND f.article_id = t.id) " +
            "SELECT t.id FROM t",
        intArrayOf(I8, T),
    )

    /**
     * $1 author, $2 slug prefix (slugify(title) + "-", computed in the app), $3 title, $4 description, $5 body,
     * $6 tagList. Article, missing tags and links in one statement (one transaction) returning the full article
     * (layout from column 0). Only missing tags are inserted, in name order (no burned ids, no deadlock inside a
     * statement); DO UPDATE returns a tag another transaction committed after this snapshot.
     */
    val ARTICLE_CREATE = WriteStmt(
        "article_create",
        "WITH n AS (SELECT nextval('articles_id_seq'::regclass) AS id), " +
            "a AS (INSERT INTO articles (id, slug, author_id, title, description, body) " +
            "SELECT n.id, \$2 || n.id, \$1, \$3, \$4, \$5 FROM n " +
            "RETURNING id, slug, title, description, body, created_at, updated_at, author_id), " +
            "e AS MATERIALIZED (SELECT id, name FROM tags WHERE name = ANY (\$6::text[])), " +
            "t AS (INSERT INTO tags (name) SELECT x.name FROM (SELECT DISTINCT unnest(\$6::text[]) AS name) x " +
            "WHERE NOT EXISTS (SELECT 1 FROM e WHERE e.name = x.name) ORDER BY x.name " +
            "ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id, name), " +
            "g AS (SELECT id, name FROM e UNION ALL SELECT id, name FROM t), " +
            "l AS (INSERT INTO article_tags (article_id, tag_id) SELECT a.id, g.id FROM a, g) " +
            "SELECT a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, " +
            "ARRAY(SELECT g.name FROM g ORDER BY 1), 0::int8, false, u.username, u.bio, u.image, " +
            "(SELECT true FROM follows fo WHERE fo.follower_id = \$1 AND fo.followee_id = \$1) IS NOT NULL " +
            "FROM a JOIN users u ON u.id = a.author_id",
        intArrayOf(I8, T, T, T, T, Oid.TEXT_ARRAY),
    )

    /**
     * $1 viewer, $2 slug, $3 title, $4 description, $5 body (NULL = unchanged), $6 new slug prefix (NULL unless the
     * title changes). Row: id, author_id. No row: 404; author_id != viewer: 403 (the UPDATE only fires for the
     * author); else ARTICLE_BY_ID after commit.
     */
    val ARTICLE_UPDATE = WriteStmt(
        "article_update",
        "WITH t AS (SELECT id, author_id FROM articles WHERE slug = \$2), " +
            "w AS (UPDATE articles a SET title = COALESCE(\$3, a.title), description = COALESCE(\$4, a.description), " +
            "body = COALESCE(\$5, a.body), slug = CASE WHEN \$6::text IS NULL THEN a.slug ELSE \$6 || a.id END, " +
            "updated_at = now() FROM t WHERE a.id = t.id AND t.author_id = \$1) " +
            "SELECT t.id, t.author_id FROM t",
        intArrayOf(I8, T, T, T, T, T),
    )

    /** $1 viewer, $2 slug. Row: author_id. No row: 404; author_id != viewer: 403; else deleted (204). */
    val ARTICLE_DELETE = WriteStmt(
        "article_delete",
        "WITH t AS (SELECT id, author_id FROM articles WHERE slug = \$2), " +
            "w AS (DELETE FROM articles a USING t WHERE a.id = t.id AND t.author_id = \$1) " +
            "SELECT t.author_id FROM t",
        intArrayOf(I8, T),
    )

    /**
     * $1 viewer, $2 slug, $3 body. Row: id, created_at, updated_at, username, bio, image (the body is echoed from the
     * request). No row: 404.
     */
    val COMMENT_CREATE = WriteStmt(
        "comment_create",
        "WITH t AS (SELECT id FROM articles WHERE slug = \$2), " +
            "c AS (INSERT INTO comments (article_id, author_id, body) SELECT t.id, \$1, \$3 FROM t " +
            "RETURNING id, created_at, updated_at, author_id) " +
            "SELECT c.id, c.created_at, c.updated_at, u.username, u.bio, u.image FROM c JOIN users u ON u.id = c.author_id",
        intArrayOf(I8, T, T),
        // m comments at once: $1 i, $2 viewers, $3 slugs, $4 bodies. Ids are drawn in request order (the sort is under the nextval).
        // Rows: i, id, created_at, updated_at, username, bio, image.
        batchSql = "WITH r AS (SELECT * FROM unnest(\$1::int4[], \$2::int8[], \$3::text[], \$4::text[]) AS r(i, v, s, b)), " +
            "m AS (SELECT x.*, nextval('comments_id_seq'::regclass) AS cid FROM " +
            "(SELECT r.i, r.v, r.b, a.id AS aid FROM r JOIN articles a ON a.slug = r.s ORDER BY r.i OFFSET 0) x), " +
            "c AS (INSERT INTO comments (id, article_id, author_id, body) SELECT m.cid, m.aid, m.v, m.b FROM m " +
            "RETURNING id, created_at, updated_at, author_id) " +
            "SELECT m.i, c.id, c.created_at, c.updated_at, u.username, u.bio, u.image " +
            "FROM c JOIN m ON m.cid = c.id JOIN users u ON u.id = c.author_id",
    )

    /**
     * $1 viewer, $2 slug, $3 comment id. Row: author_id. No row: 404 (also a comment of another article);
     * author_id != viewer: 403; else deleted (204).
     */
    val COMMENT_DELETE = WriteStmt(
        "comment_delete",
        "WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id " +
            "WHERE c.id = \$3 AND a.slug = \$2), " +
            "w AS (DELETE FROM comments c USING t WHERE c.id = t.id AND t.author_id = \$1) " +
            "SELECT t.author_id FROM t",
        intArrayOf(I8, T, I8),
    )

    val writes: List<WriteStmt> = listOf(
        USER_INSERT, USER_UPDATE, FOLLOW, UNFOLLOW, FAVORITE, UNFAVORITE,
        ARTICLE_CREATE, ARTICLE_UPDATE, ARTICLE_DELETE, COMMENT_CREATE, COMMENT_DELETE,
    )
}

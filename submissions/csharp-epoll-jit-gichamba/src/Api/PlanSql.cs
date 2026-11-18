using Conduit.Pg;

namespace Conduit.Api;

/// <summary>
/// The statements of the batch planner (<see cref="PlanFamily"/>). Phase A finds what each distinct key of the batch is
/// about. Phase B enriches the union of the articles phase A found, once each, and reads the viewers' flags. The
/// two-phase design follows rust-epoll-WorriedArrow.
///
/// Every phase A statement takes arrays of distinct keys and tags each row with the key's 1-based position n. A list
/// statement returns count rows and page rows in one layout: n, then id, author_id, slug, title, description, created_at,
/// updated_at. A count row has n &lt;= 0 (-n is the count key's position, 0 the global list's single count) and the count
/// in the id column, with NULL article columns. Pages and counts reuse the fragments of <see cref="ArticleSql"/>, so they
/// read the same rows.
/// </summary>
internal static class PlanSql {
    /// <summary>The article columns of a page row: id, author_id, slug, title, description, created_at, updated_at.</summary>
    private const string Columns = "a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at";

    /// <summary>NULLs for the article columns after the id, which a count row leaves empty.</summary>
    private const string NoArticle = "NULL::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz";

    /// <summary>Joins request row r to the articles of its page: the page ids, cut as in the control statements, then the article columns.</summary>
    private static string Page(string pageIds) =>
        "CROSS JOIN LATERAL (SELECT b.id FROM (" + pageIds + " " + ArticleSql.Cut + ") b ORDER BY b.id DESC LIMIT r.l) p " +
        "JOIN articles a ON a.id = p.id";

    /// <summary>A filtered list: $1 the distinct filters to count, $2 to $4 the distinct (filter, limit, offset) pages.</summary>
    private static string Filtered(string pageIds, string cappedCount) =>
        "SELECT -r.n, " + cappedCount + ", " + NoArticle + " FROM unnest($1::text[]) WITH ORDINALITY AS r(k, n) " +
        "UNION ALL " +
        "SELECT r.n, " + Columns + " FROM unnest($2::text[], $3::int8[], $4::int8[]) WITH ORDINALITY AS r(k, l, o, n) " + Page(pageIds);

    /// <summary>
    /// The count of a row set, capped at 1000 as SPEC.md asks. EXISTS with OFFSET 999 proves 1000 rows without the count
    /// aggregate, so only a smaller set is counted.
    /// </summary>
    private static string Capped(string rows) =>
        "(CASE WHEN EXISTS (" + rows + " OFFSET 999) THEN 1000::int8 ELSE (SELECT count(*) FROM (" + rows + " LIMIT 1000) s) END)";

    /// <summary>Prepared name of <see cref="Global"/>.</summary>
    public const string GlobalName = "p_global";

    /// <summary>
    /// The global list: one count for the batch, and $1, $2 the distinct (limit, offset) pages. The count walks the primary
    /// key from the oldest end, whose pages stay all-visible while new articles arrive, so it stays an index-only scan.
    /// </summary>
    public static readonly string Global =
        "SELECT 0::int8, (SELECT count(*) FROM (SELECT 1 FROM articles c2 ORDER BY c2.id LIMIT 1000) s), " + NoArticle + " " +
        "UNION ALL " +
        "SELECT r.n, " + Columns + " FROM unnest($1::int8[], $2::int8[]) WITH ORDINALITY AS r(l, o, n) " + Page(ArticleSql.PageAll);

    /// <summary>Prepared name of <see cref="Tag"/>.</summary>
    public const string TagName = "p_tag";

    /// <summary>Articles with a tag. $1 the distinct tags to count, $2 to $4 the distinct (tag, limit, offset) pages.</summary>
    public static readonly string Tag = Filtered(ArticleSql.PageTag, Capped(ArticleSql.TagRows));

    /// <summary>Prepared name of <see cref="Author"/>.</summary>
    public const string AuthorName = "p_author";

    /// <summary>Articles by an author. $1 the distinct usernames to count, $2 to $4 the distinct (username, limit, offset) pages.</summary>
    public static readonly string Author = Filtered(ArticleSql.PageAuthor, Capped(ArticleSql.AuthorRows));

    /// <summary>Prepared name of <see cref="Favorited"/>.</summary>
    public const string FavoritedName = "p_fav";

    /// <summary>Articles a user favorited. $1 the distinct usernames to count, $2 to $4 the distinct (username, limit, offset) pages.</summary>
    public static readonly string Favorited = Filtered(ArticleSql.PageFavorited, Capped(ArticleSql.FavoritedRows));

    /// <summary>Prepared name of <see cref="Feed"/>.</summary>
    public const string FeedName = "p_feed";

    /// <summary>
    /// Feeds: $1 the distinct viewers to count, $2 to $4 the distinct (viewer, limit, offset) pages. fv reads each counted
    /// viewer's followees once. A feed that includes an author with 1000 or more articles counts 1000. heavy takes the 8
    /// followees shared by the most viewers in the batch (at least 2) and keeps those with 1000 or more articles, checking
    /// each once. A viewer who follows one of them gets 1000 without a count scan.
    /// </summary>
    public static readonly string Feed =
        "WITH fv AS MATERIALIZED (SELECT r.v, r.n, ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v) AS fids " +
        "FROM unnest($1::int8[]) WITH ORDINALITY AS r(v, n)), " +
        "hc AS MATERIALIZED (SELECT x.id FROM fv CROSS JOIN LATERAL unnest(fv.fids) AS x(id) " +
        "GROUP BY x.id HAVING count(*) >= 2 ORDER BY count(*) DESC LIMIT 8), " +
        "heavy AS MATERIALIZED (SELECT array_agg(hc.id) AS ids FROM hc " +
        "WHERE EXISTS (SELECT 1 FROM articles a WHERE a.author_id = hc.id OFFSET 999)) " +
        "SELECT -fv.n, CASE WHEN fv.fids && (SELECT h.ids FROM heavy h) THEN 1000::int8 ELSE " +
        Capped("SELECT 1 FROM articles c2 WHERE c2.author_id = ANY (fv.fids)") + " END, " + NoArticle + " FROM fv " +
        "UNION ALL " +
        "SELECT r.n, " + Columns + " FROM unnest($2::int8[], $3::int8[], $4::int8[]) WITH ORDINALITY AS r(v, l, o, n) " + Page(ArticleSql.PageFeed);

    /// <summary>Prepared name of <see cref="Slug"/>.</summary>
    public const string SlugName = "p_slug";

    /// <summary>Single articles by slug ($1), with the body as a ninth column. A slug that matches nothing has no row.</summary>
    public const string Slug =
        "SELECT r.n, " + Columns + ", a.body FROM unnest($1::text[]) WITH ORDINALITY AS r(k, n) JOIN articles a ON a.slug = r.k";

    /// <summary>Prepared name of <see cref="Comments"/>.</summary>
    public const string CommentsName = "p_cmts";

    /// <summary>
    /// The newest 100 comments of each distinct slug ($1): n, comment id, body, created_at, updated_at, author_id, username,
    /// bio, image. An article without comments gives one row with a NULL comment id; an unknown slug gives no row.
    /// </summary>
    public const string Comments =
        "SELECT r.n, c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image " +
        "FROM unnest($1::text[]) WITH ORDINALITY AS r(k, n) JOIN articles a ON a.slug = r.k " +
        "LEFT JOIN LATERAL (SELECT c1.id, c1.body, c1.created_at, c1.updated_at, c1.author_id FROM comments c1 " +
        "WHERE c1.article_id = a.id ORDER BY c1.created_at DESC, c1.id DESC LIMIT 100) c ON true " +
        "LEFT JOIN users u ON u.id = c.author_id";

    /// <summary>Prepared name of <see cref="Articles"/>.</summary>
    public const string ArticlesName = "p_art";

    /// <summary>
    /// Phase B: each distinct article ($1) with its author ($2): id, tag ids in no order, favorites count, author username,
    /// bio, image. The names come from <see cref="TagTable"/>.
    /// </summary>
    public const string Articles =
        "SELECT r.id, ARRAY(SELECT att.tag_id FROM article_tags att WHERE att.article_id = r.id), " +
        "(SELECT count(*) FROM favorites f WHERE f.article_id = r.id), u.username, u.bio, u.image " +
        "FROM unnest($1::int8[], $2::int8[]) AS r(id, author) JOIN users u ON u.id = r.author";

    /// <summary>Prepared name of <see cref="TagTable"/>.</summary>
    public const string TagTableName = "p_tagtable";

    /// <summary>
    /// Phase B, after <see cref="Articles"/>: the whole tags table as one row of two arrays, ids and names, both in the
    /// database's name order, so the app orders each article's tags by position without comparing names itself (the
    /// collation may not be C). Both are NULL when there are no tags. Tags are never deleted, so every tag id the articles
    /// statement saw is here.
    /// </summary>
    public const string TagTable = "SELECT array_agg(t.id ORDER BY t.name), array_agg(t.name ORDER BY t.name) FROM tags t";

    /// <summary>Prepared name of <see cref="Flags"/>.</summary>
    public const string FlagsName = "p_flags";

    /// <summary>
    /// Phase B: which of the asked (viewer, article) pairs ($1, $2) are favorites and which (viewer, user) pairs ($3, $4) are
    /// follows. Rows: 0 or 1, viewer, article or user. Each viewer's pairs are one index range scan with = ANY.
    /// </summary>
    public const string Flags =
        "SELECT 0::int8, x.v, f.article_id FROM (SELECT q.v, array_agg(q.a) AS ids FROM unnest($1::int8[], $2::int8[]) AS q(v, a) GROUP BY q.v) x " +
        "CROSS JOIN LATERAL (SELECT f.article_id FROM favorites f WHERE f.user_id = x.v AND f.article_id = ANY (x.ids)) f " +
        "UNION ALL " +
        "SELECT 1::int8, y.v, fo.followee_id FROM (SELECT q.v, array_agg(q.u) AS ids FROM unnest($3::int8[], $4::int8[]) AS q(v, u) GROUP BY q.v) y " +
        "CROSS JOIN LATERAL (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = y.v AND fo.followee_id = ANY (y.ids)) fo";

    /// <summary>Two int8[]: the global list, and the articles statement.</summary>
    private static readonly uint[] Pairs = [PgOid.Int8Array, PgOid.Int8Array];
    /// <summary>Two text[] and two int8[]: the filtered lists.</summary>
    private static readonly uint[] Lists = [PgOid.TextArray, PgOid.TextArray, PgOid.Int8Array, PgOid.Int8Array];
    /// <summary>Four int8[]: the feed, and the flags statement.</summary>
    private static readonly uint[] Feeds = [PgOid.Int8Array, PgOid.Int8Array, PgOid.Int8Array, PgOid.Int8Array];
    /// <summary>One text[]: the slug and comments statements.</summary>
    private static readonly uint[] Texts = [PgOid.TextArray];

    /// <summary>Every planner statement with its parameter types, for the read connections to prepare.</summary>
    public static readonly (string Name, string Sql, uint[] Oids)[] All =
    [
        (GlobalName, Global, Pairs), (TagName, Tag, Lists), (AuthorName, Author, Lists), (FavoritedName, Favorited, Lists),
        (FeedName, Feed, Feeds), (SlugName, Slug, Texts), (CommentsName, Comments, Texts),
        (ArticlesName, Articles, Pairs), (TagTableName, TagTable, []), (FlagsName, Flags, Feeds),
    ];
}

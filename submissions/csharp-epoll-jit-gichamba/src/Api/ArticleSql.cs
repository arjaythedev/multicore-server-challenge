namespace Conduit.Api;

/// <summary>
/// SQL fragments shared by the planner (<see cref="PlanSql"/>) and the write path (<see cref="WriteSql"/>): the ordered
/// page ids of each list, the rows each filtered count reads, and the article columns from tag_list on. Request values
/// come from the row r: l limit, o offset, k text key, v viewer.
/// </summary>
internal static class ArticleSql {
    /// <summary>Tag names by primary key, sorted by name in the database, whose collation decides the order.</summary>
    internal const string TagNames = "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = att.tag_id) FROM article_tags att WHERE att.article_id = a.id ORDER BY 1) AS tag_list";

    /// <summary>The exact favorites count of article a, as the column favorites_count.</summary>
    internal const string FavoritesCount = "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count";

    /// <summary>
    /// Article columns from tag_list on: tags, exact favorites count, favorited probe, author profile, following. Needs
    /// aliases a (articles) and u (users). <paramref name="viewer"/> is the SQL expression of the viewer's id and
    /// <paramref name="following"/> the SQL of the following flag. <see cref="ArticleJson.WriteArticle"/> reads this layout.
    /// </summary>
    internal static string Tail(string following, string viewer) =>
        TagNames + ", " + FavoritesCount + ", " +
        "(SELECT true FROM favorites f WHERE f.user_id = " + viewer + " AND f.article_id = a.id) IS NOT NULL AS favorited, " +
        "u.username, u.bio, u.image, " + following + " AS following";

    /// <summary>
    /// How the page ids are cut after ORDER BY: OFFSET, then a constant LIMIT 100 (the most a page may ask for). A
    /// constant keeps the planner's row estimate bounded; the caller then takes the request's own limit.
    /// </summary>
    public const string Cut = "OFFSET r.o LIMIT 100";

    /// <summary>Ids of the global list.</summary>
    public const string PageAll = "SELECT a2.id FROM articles a2 ORDER BY a2.id DESC";

    /// <summary>Ids of the articles with tag r.k; an unknown tag gives no rows.</summary>
    public const string PageTag =
        "SELECT att.article_id AS id FROM article_tags att WHERE att.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.k) " +
        "ORDER BY att.article_id DESC";

    /// <summary>Ids of the articles written by r.k; an unknown user gives no rows.</summary>
    public const string PageAuthor =
        "SELECT a2.id FROM articles a2 WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = r.k) " +
        "ORDER BY a2.id DESC";

    /// <summary>Ids of the articles favorited by user r.k; an unknown user gives no rows.</summary>
    public const string PageFavorited =
        "SELECT f.article_id AS id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = r.k) " +
        "ORDER BY f.article_id DESC";

    /// <summary>
    /// Ids of the viewer's feed. Each followee contributes at most limit + offset ids, as in the reference SQL,
    /// then the page is cut from the merged list.
    /// </summary>
    public const string PageFeed =
        "SELECT x.id FROM follows fo CROSS JOIN LATERAL " +
        "(SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT r.l + r.o) x " +
        "WHERE fo.follower_id = r.v ORDER BY x.id DESC";

    /// <summary>The rows the tag filter counts, one per article with tag r.k.</summary>
    public const string TagRows =
        "SELECT 1 FROM article_tags c2 WHERE c2.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.k)";

    /// <summary>The rows the author filter counts.</summary>
    public const string AuthorRows =
        "SELECT 1 FROM articles c2 WHERE c2.author_id = (SELECT u2.id FROM users u2 WHERE u2.username = r.k)";

    /// <summary>The rows the favorited filter counts.</summary>
    public const string FavoritedRows =
        "SELECT 1 FROM favorites c2 WHERE c2.user_id = (SELECT u2.id FROM users u2 WHERE u2.username = r.k)";
}

package conduit

class SqlSuite extends munit.FunSuite:
  test("every batched read runs over its requests' parameters, each row tagged with its request"):
    for b <- Sql.batchKinds if !b.shared do
      val sql = b.batched.sql
      val n = b.paramTypes.length
      // The batch's own parameters are the arrays; the inner statement's are r.p1 ... r.pn.
      for i <- 1 to n do assert(sql.split("\\$" + i + "::").length == 2, s"$sql: the array $i once")
      assert(!sql.matches(".*\\$" + (n + 1) + "\\b.*"), sql)
      for i <- 1 to n do assert(sql.contains(s"r.p$i"), s"$sql: r.p$i")
      assert(sql.contains(" WITH ORDINALITY AS r("), sql)
      // A packed batch: the rows for all its requests, then each request's own.
      if b.packed then assert(sql.contains(" UNION ALL SELECT ") && sql.matches(".*[ ,][qr]\\.i FROM [qr]\\b.*"), sql)
      else assert(sql.startsWith("SELECT q.*, r.i FROM "), sql)

  test("the comments' batch reads each distinct article's comments once, then each request's following, packed"):
    val batch = Sql.batchOf(Sql.Comments)
    val sql = batch.batched.sql
    assert(batch.packed)
    assert(sql.contains("FROM articles a WHERE a.slug IN (SELECT p2 FROM r)"), sql)
    assert(sql.contains("ORDER BY c.article, c.created_at DESC, c.id DESC) UNION ALL SELECT"), sql)
    assert(sql.contains("fo.follower_id = r.p1 AND fo.followee_id = ANY(ca.authors)), r.i FROM r JOIN a ON a.slug = r.p2"), sql)

  test("the global list's batch reads each page once, each article once, and its count once, packed"):
    val batch = Sql.batchOf(Sql.ListAll)
    val listAll = batch.batched.sql
    assert(batch.packed)
    assert(listAll.contains("FROM (SELECT DISTINCT p2, p3 FROM r) r LEFT JOIN LATERAL"), listAll)
    assert(listAll.contains("SELECT DISTINCT id FROM kp"), listAll)
    // A scalar subquery, run once: as a join, the planner ran it for every row.
    assert(listAll.contains("r.p1, CASE WHEN EXISTS (SELECT 1 FROM articles LIMIT 1 OFFSET 999) THEN 1000::int8 " +
      "ELSE (SELECT count(*) FROM (SELECT 1 FROM articles) s) END AS n, kp.id FROM r JOIN kp"), listAll)
    // The articles' rows first, then the requests'; favorited and following are the request's own.
    assert(listAll.indexOf("FROM m UNION ALL SELECT q.n") > 0, listAll)
    assert(listAll.contains("f.user_id = q.p1 AND f.article_id = ANY(q.ids)"), listAll)
    assert(listAll.contains("fo.follower_id = q.p1 AND fo.followee_id = ANY(q.authors)"), listAll)

  test("a filtered list's batch resolves each filter once, and reads each page and each filter's count once"):
    for s <- Seq(Sql.ListByTag, Sql.ListByAuthor, Sql.ListByFavorited) do
      for sql <- Seq(Sql.batchOf(s).batched.sql, Sql.batchOf(s).plan.sql) do
        // The filter's name looked up once, in `kc`, not inlined into its count's and its pages' uses.
        assert(sql.split("WHERE t.name = |WHERE u.username = ").length == 2, sql)
        assert(sql.contains(" = d.p4) AS fid FROM (SELECT DISTINCT p4 FROM r) d OFFSET 0) r)"), sql)
        assert(sql.contains("FROM r JOIN kp ON kp.p2 = r.p2 AND kp.p3 = r.p3 AND kp.p4 = r.p4 JOIN kc c ON c.p4 = r.p4"), sql)
        // Every tag has thousands of articles: whether a 1,000th exists; a user's are counted to 1,000.
        assert(sql.contains("EXISTS (SELECT 1 ") == (s eq Sql.ListByTag), sql)
      val keys = "FROM (SELECT DISTINCT r.p2, r.p3, r.p4, c.fid FROM r JOIN kc c ON c.p4 = r.p4) r"
      assert(Sql.batchOf(s).batched.sql.contains(s"$keys LEFT JOIN LATERAL"), Sql.batchOf(s).batched.sql)
      assert(Sql.batchOf(s).batched.sql.contains("SELECT DISTINCT id FROM kp"), Sql.batchOf(s).batched.sql)
      assertPageArrays(Sql.batchOf(s).plan.sql, keys)

  test("a round's plan reads each distinct page as one array its requests share, the feed's per request"):
    assertPageArrays(Sql.batchOf(Sql.ListAll).plan.sql, "FROM (SELECT DISTINCT p2, p3 FROM r) r")
    val feed = Sql.batchOf(Sql.Feed).plan.sql
    assert(feed.contains("q AS MATERIALIZED ( SELECT r.i, c.n, ARRAY(SELECT * FROM (SELECT x.id FROM follows fo"), feed)
    assert(feed.contains("FROM (SELECT DISTINCT unnest(ids) AS id FROM q) d JOIN articles a"), feed)
    assert(!feed.contains("array_agg") && feed.contains("GROUP BY vf.f"), feed)

  /** A plan's pages: each distinct one an array (no row per request and article, no aggregate per request). */
  private def assertPageArrays(sql: String, keys: String): Unit =
    assert(sql.contains(" AS ids " + keys + "), m AS MATERIALIZED"), sql)
    assert(sql.contains("ARRAY(SELECT * FROM (SELECT "), sql)
    assert(sql.contains("FROM (SELECT DISTINCT unnest(ids) AS id FROM kp) d JOIN articles a"), sql)
    assert(sql.contains(", kp.ids FROM r JOIN kp ON kp.p2 = r.p2 AND kp.p3 = r.p3"), sql)
    assert(!sql.contains("array_agg") && !sql.contains("GROUP BY"), sql)

  test("every list is packed; the feed's viewer follows every author in it"):
    for s <- Seq(Sql.ListAll, Sql.Feed, Sql.ListByTag, Sql.ListByAuthor, Sql.ListByFavorited) do
      assert(Sql.batchOf(s).packed, s.sql)
    val feed = Sql.batchOf(Sql.Feed).batched.sql
    assert(feed.contains("ANY(q.ids)), NULL::int8[], q.i FROM q"), feed)
    // Its count: 1,000 without a walk for a viewer who follows one of the batch's most followed authors that has 1,000.
    assert(feed.contains("CASE WHEN x.k <= 4 THEN EXISTS (SELECT 1 FROM articles a WHERE a.author_id = x.f OFFSET 999)"), feed)
    assert(feed.contains("CASE WHEN fl.big THEN 1000::int8 ELSE (SELECT count(*) AS n FROM"), feed)
    // Its page: each followed author's walk stops at the viewer's floor, from the authors the batch's viewers share.
    assert(feed.contains("ORDER BY a.id DESC OFFSET x.d - 1 LIMIT 1) AS floor"), feed)
    assert(feed.contains("a2.author_id = fo.followee_id AND a2.id >= COALESCE(fl.floor, 0) ORDER BY a2.id DESC"), feed)
    assert(!Sql.Feed.sql.contains("floor"), Sql.Feed.sql)

  test("a shared batch is its statement, without parameters, once for all its requests"):
    val tags = Sql.batchOf(Sql.Tags)
    assert(tags.shared)
    assertEquals(tags.batched, Sql.Tags)
    for b <- Sql.batchKinds if b.shared do
      assertEquals(b.batched, b.single)
      assert(b.paramTypes.isEmpty, b.single.sql)

  test("only reads batch"):
    for b <- Sql.batchKinds do assert(b.single.sql.startsWith("SELECT"), b.single.sql)
    for s <- Seq(Sql.Favorite, Sql.Unfavorite, Sql.Follow, Sql.Unfollow, Sql.InsertArticle, Sql.UpdateArticle, Sql.DeleteArticle,
        Sql.CreateComment, Sql.DeleteComment, Sql.Register, Sql.Login, Sql.UpdateUser) do
      assertEquals(Sql.batchOf(s), null, s.sql)

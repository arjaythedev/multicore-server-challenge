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
      if b.packed then assert(sql.endsWith(", q.i FROM q"), sql)
      else assert(sql.startsWith("SELECT q.*, r.i FROM "), sql)

  test("the global list's batch reads each article once, and its count once, packed"):
    val batch = Sql.batchOf(Sql.ListAll)
    val listAll = batch.batched.sql
    assert(batch.packed)
    assert(listAll.contains("SELECT DISTINCT id FROM p"), listAll)
    assert(listAll.contains("SELECT count(*) AS n FROM (SELECT 1 FROM articles LIMIT 1000) s"), listAll)
    // The articles' rows first, then the requests'; favorited and following are the request's own.
    assert(listAll.indexOf("FROM m UNION ALL SELECT q.n") > 0, listAll)
    assert(listAll.contains("f.user_id = q.p1 AND f.article_id = ANY(q.ids)"), listAll)
    assert(listAll.contains("fo.follower_id = q.p1 AND fo.followee_id = ANY(q.authors)"), listAll)

  test("every list is packed; the feed's viewer follows every author in it"):
    for s <- Seq(Sql.ListAll, Sql.Feed, Sql.ListByTag, Sql.ListByAuthor, Sql.ListByFavorited) do
      assert(Sql.batchOf(s).packed, s.sql)
    val feed = Sql.batchOf(Sql.Feed).batched.sql
    assert(feed.contains("ANY(q.ids)), NULL::int8[], q.i FROM q"), feed)
    // Its count: 1,000 without a walk for a viewer who follows one of the batch's most followed authors that has 1,000.
    assert(feed.contains("WHERE EXISTS (SELECT 1 FROM articles a WHERE a.author_id = x.f OFFSET 999)"), feed)
    assert(feed.contains("THEN 1000::int8 ELSE (SELECT count(*) AS n FROM"), feed)

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

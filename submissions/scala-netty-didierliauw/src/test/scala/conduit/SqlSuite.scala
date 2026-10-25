package conduit

class SqlSuite extends munit.FunSuite:
  test("every batched read runs its single statement per request, with the request's parameters"):
    for b <- Sql.batchKinds do
      val sql = b.batched.sql
      val n = b.paramTypes.length
      // The batch's own parameters are the arrays (or the count, for none); the inner statement's are r.p1 ... r.pn.
      val outer = if n == 0 then 1 else n
      for i <- 1 to outer do assert(sql.split("\\$" + i + "::").length == 2, s"$sql: the array $i once")
      assert(!sql.matches(".*\\$" + (outer + 1) + "\\b.*"), sql)
      for i <- 1 to n do assert(sql.contains(s"r.p$i"), s"$sql: r.p$i")
      assert(sql.startsWith("SELECT q.*, r.i FROM "), sql)
      assert(sql.contains("CROSS JOIN LATERAL ("), sql)

  test("what has no parameter of its own depends on the request, so that Postgres runs it once per request"):
    // A part that depended on no parameter would run once per statement, its result shared by the batch's requests:
    // that is caching across requests (rule 5).
    val listAll = Sql.batchOf(Sql.ListAll).batched.sql
    assert(listAll.contains("SELECT 1 FROM articles WHERE r.i > 0"), listAll)
    val tags = Sql.batchOf(Sql.Tags).batched.sql
    assert(tags.contains("FROM tags WHERE r.i > 0"), tags)

  test("only reads batch"):
    for b <- Sql.batchKinds do assert(b.single.sql.startsWith("SELECT"), b.single.sql)
    for s <- Seq(Sql.Favorite, Sql.Unfavorite, Sql.Follow, Sql.Unfollow, Sql.InsertArticle, Sql.UpdateArticle, Sql.DeleteArticle,
        Sql.CreateComment, Sql.DeleteComment, Sql.Register, Sql.Login, Sql.UpdateUser) do
      assertEquals(Sql.batchOf(s), null, s.sql)

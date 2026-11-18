package conduit

import io.netty.buffer.Unpooled

import java.nio.charset.StandardCharsets.UTF_8

class PgSuite extends munit.FunSuite:
  test("DATABASE_URL"):
    assertEquals(
      PgConfig.parse("postgres://conduit:conduit@127.0.0.1:5432/conduit"),
      PgConfig("127.0.0.1", 5432, "conduit", "conduit", "conduit"),
    )
    assertEquals(PgConfig.parse("postgresql://u:p%40ss@db/x?sslmode=disable"), PgConfig("db", 5432, "u", "p@ss", "x"))

  test("SCRAM-SHA-256 as in RFC 7677's example"):
    val scram = Scram("pencil", user = "user", nonce = "rOprNGfwEbeRWgbNEkqO")
    assertEquals(scram.clientFirst, "n,,n=user,r=rOprNGfwEbeRWgbNEkqO")
    val reply = scram.clientFinal("r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096")
    assertEquals(reply, "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=")
    assert(scram.verify("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="))
    assert(!scram.verify("v=7rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="))
    assertEquals(Scram("pencil", nonce = "abc").clientFinal("r=xyz,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"), null)

  test("a Bind's parameters and an Execute, in binary"):
    val w = PgWriter()
    w.buf = Unpooled.buffer()
    val s = Statement(3, "SELECT $1, $2, $3, $4", Array(Oid.Int8, Oid.Text, Oid.Text, Oid.TextArray))
    w.bind(s).int8(5).text("é").nul().textArray(Seq("a", "bc")).execute()
    val b = w.buf
    assertEquals(b.readByte().toChar, 'B')
    val length = b.readInt()
    assertEquals(length, b.readableBytes + 4 - 10) // the Execute after it is 10 bytes
    assertEquals(b.readByte(), 0.toByte) // the unnamed portal
    assertEquals(b.readCharSequence(2, UTF_8).toString, "s3")
    assertEquals(b.readByte(), 0.toByte)
    assertEquals((b.readShort(), b.readShort(), b.readShort()), (1.toShort, 1.toShort, 4.toShort))
    assertEquals((b.readInt(), b.readLong()), (8, 5L))
    assertEquals(b.readInt(), 2)
    assertEquals(b.readCharSequence(2, UTF_8).toString, "é")
    assertEquals(b.readInt(), -1)
    assertEquals(b.readInt(), 4 * 5 + 4 + 1 + 4 + 2)
    assertEquals((b.readInt(), b.readInt(), b.readInt(), b.readInt(), b.readInt()), (1, 0, Oid.Text, 2, 1))
    assertEquals((b.readInt(), b.readByte().toChar), (1, 'a'))
    assertEquals((b.readInt(), b.readCharSequence(2, UTF_8).toString), (2, "bc"))
    assertEquals((b.readShort(), b.readShort()), (1.toShort, 1.toShort))
    assertEquals(b.readByte().toChar, 'E')

  test("a row's columns, read in place: numbers, text, nulls, timestamps and text arrays"):
    val b = Unpooled.buffer()
    b.writeShort(5)
    b.writeInt(8).writeLong(42)
    b.writeInt(3).writeBytes("a\"b".getBytes(UTF_8))
    b.writeInt(-1)
    b.writeInt(8).writeLong(0)
    val array = Unpooled.buffer()
    array.writeInt(1).writeInt(0).writeInt(Oid.Text).writeInt(2).writeInt(1)
    array.writeInt(3).writeBytes("dev".getBytes(UTF_8)).writeInt(2).writeBytes("go".getBytes(UTF_8))
    b.writeInt(array.readableBytes).writeBytes(array)
    val row = PgRow()
    row.load(b, 0)
    val out = Out()
    assertEquals((row.columns, row.int8(0), row.isNull(2), row.string(1)), (5, 42L, true, "a\"b"))
    row.text(1, out)
    out.byte(' ')
    row.textOrNull(2, out)
    out.byte(' ')
    row.timestamp(3, out)
    out.byte(' ')
    row.textArray(4, out)
    assertEquals(out.body, "\"a\\\"b\" null \"2000-01-01T00:00:00.000Z\" [\"dev\",\"go\"]")

  test("an empty text array"):
    val b = Unpooled.buffer()
    b.writeShort(1).writeInt(12).writeInt(0).writeInt(0).writeInt(Oid.Text)
    val row = PgRow()
    row.load(b, 0)
    val out = Out()
    row.textArray(0, out)
    assertEquals(out.body, "[]")

  /** A write that sends `statements` statements and records what it gets; of `client`, if known. */
  private final class Write(statements: Int, override val client: AnyRef = null) extends PgQuery:
    val rows = collection.mutable.ArrayBuffer[Int]()
    var resets = 0
    var error: PgError = null
    var answered = false
    def send(w: PgWriter): Unit = for _ <- 0 until statements do w.bind(Statement(0, "", Array())).execute()
    def row(statement: Int, row: PgRow): Unit = rows += statement
    def done(e: PgError): Unit =
      answered = true
      error = e
    override def reset(): Unit =
      resets += 1
      rows.clear()

  /** A pool without connections: what it is asked to send fails as unavailable. */
  private def noConnections =
    PgPool(null, PgConfig("", 0, "", "", ""), Vector.empty, PgReads(0, 1), 0, 0, classOf[io.netty.channel.socket.nio.NioSocketChannel])

  private def sent(writes: Array[Write]): WriteGroup =
    val group = WriteGroup(noConnections, writes.toArray[PgQuery])
    val w = PgWriter()
    w.buf = Unpooled.buffer()
    w.executes = 7 // the connection's before the group
    group.send(w)
    group

  test("a group of writes: each one's rows by its statements' place in the group"):
    val writes = Array(Write(1), Write(3), Write(2))
    val group = sent(writes)
    for s <- 0 until 6 do group.row(s, PgRow())
    assertEquals(writes.map(_.rows.toList).toList, List(List(0), List(0, 1, 2), List(0, 1)))
    group.done(null)
    assert(writes.forall(w => w.answered && w.error == null && w.resets == 0))

  test("a group rolled back for one write's error: each goes out again alone"):
    val writes = Array(Write(1), Write(2))
    val group = sent(writes)
    group.row(0, PgRow())
    group.done(PgError("23505", "duplicate key"))
    // Each forgot its rows and was sent again, alone: here, to a pool without connections.
    assert(writes.forall(w => w.resets == 1 && w.rows.isEmpty && (w.error eq PgError.Unavailable)))

  test("a group whose connection was lost: not sent again (it may have committed)"):
    val writes = Array(Write(1), Write(1))
    val group = sent(writes)
    group.done(PgError.ConnectionLost)
    assert(writes.forall(w => w.resets == 0 && (w.error eq PgError.ConnectionLost)))

  /** A follow by `viewer`, of client `client`: a write that merges with the follows in its group. */
  private final class Follow(viewer: Long, name: String, override val client: AnyRef) extends PgQuery:
    val rows = collection.mutable.ArrayBuffer[(Int, Long)]()
    var error: PgError = null
    override def write: Boolean = true
    override def merge: Sql.Merge = Sql.mergeOf(Sql.Follow)
    override def int8Param(p: Int): Long = viewer
    override def textParam(p: Int): String = name
    def send(w: PgWriter): Unit = w.bind(Sql.Follow).int8(viewer).text(name).execute()
    def row(statement: Int, row: PgRow): Unit = rows += statement -> row.int8(row.columns - 1)
    def done(e: PgError): Unit = error = e

  test("a group's follows of different clients: one statement, ordered after the rest, rows back by their place"):
    val a = Follow(1, "a", "client a")
    val b = Follow(2, "b", "client b")
    val other = Write(1, "client o")
    val group = WriteGroup(noConnections, Array[PgQuery](a, other, b))
    val w = PgWriter()
    w.buf = Unpooled.buffer()
    group.send(w)
    assertEquals(w.executes, 2) // the other write's statement, then the follows'
    group.row(0, PgRow())
    group.row(1, dataRow(text("b"), null, null, int8(2)))
    group.row(1, dataRow(text("a"), null, null, int8(1)))
    assertEquals((other.rows.toList, a.rows.toList, b.rows.toList), (List(0), List(0 -> 1L), List(0 -> 2L)))

  test("a group with two writes of one client: in the order they came, only runs merged"):
    val a = Follow(1, "a", "client a")
    val b = Follow(1, "b", "client a")
    val other = Write(1)
    val group = WriteGroup(noConnections, Array[PgQuery](a, other, b))
    val w = PgWriter()
    w.buf = Unpooled.buffer()
    group.send(w)
    assertEquals(w.executes, 3)
    group.row(0, dataRow(text("a"), null, null, int8(1)))
    group.row(1, PgRow())
    group.row(2, dataRow(text("b"), null, null, int8(1)))
    assertEquals((a.rows.toList, other.rows.toList, b.rows.toList), (List(0 -> 1L), List(0), List(0 -> 1L)))

  test("a shared batch's rows go to its first query when every query copies, the copies made before any is done"):
    final class Q(copies: Boolean, log: collection.mutable.Buffer[String], name: String) extends PgQuery:
      val rows = collection.mutable.Buffer[String]()
      def send(w: PgWriter): Unit = ()
      def row(statement: Int, row: PgRow): Unit = rows += row.string(0)
      override def copiesShared: Boolean = copies
      override def copyShared(first: PgQuery): Unit =
        rows ++= first.asInstanceOf[Q].rows
        log += s"$name copies"
      def done(error: PgError): Unit = log += s"$name done"
    val tags = Sql.batchOf(Sql.Tags)
    val log = collection.mutable.Buffer[String]()
    val copying = Array(Q(true, log, "a"), Q(true, log, "b"), Q(true, log, "c"))
    val batch = BatchQuery(tags, copying.asInstanceOf[Array[PgQuery]])
    batch.row(0, dataRow(text("x")))
    batch.row(0, dataRow(text("y")))
    assertEquals(copying.map(_.rows.toList).toList, List(List("x", "y"), Nil, Nil))
    batch.done(null)
    assertEquals(copying.map(_.rows.toList).toList, List.fill(3)(List("x", "y")))
    assertEquals(log.toList, List("b copies", "c copies", "a done", "b done", "c done"))
    // One that can't copy: every query gets every row, and nothing is copied.
    val mixed = Array(Q(true, log, "d"), Q(false, log, "e"))
    log.clear()
    val other = BatchQuery(tags, mixed.asInstanceOf[Array[PgQuery]])
    other.row(0, dataRow(text("x")))
    other.done(null)
    assertEquals((mixed.map(_.rows.toList).toList, log.toList), (List(List("x"), List("x")), List("d done", "e done")))
    // A failed batch copies nothing.
    val failing = Array(Q(true, log, "f"), Q(true, log, "g"))
    log.clear()
    BatchQuery(tags, failing.asInstanceOf[Array[PgQuery]]).done(PgError.ConnectionLost)
    assertEquals(log.toList, List("f done", "g done"))

  /** A DataRow's content: each column a value written by its function, or null. */
  private def dataRow(columns: (io.netty.buffer.ByteBuf => Unit)*): PgRow =
    val b = Unpooled.buffer()
    b.writeShort(columns.length)
    for c <- columns do
      if c == null then b.writeInt(-1)
      else
        val v = Unpooled.buffer()
        c(v)
        b.writeInt(v.readableBytes).writeBytes(v)
    val row = PgRow()
    row.load(b, 0)
    row

  private def int8(x: Long): io.netty.buffer.ByteBuf => Unit = _.writeLong(x)
  private def bool(x: Boolean): io.netty.buffer.ByteBuf => Unit = _.writeByte(if x then 1 else 0)
  private def text(s: String): io.netty.buffer.ByteBuf => Unit = _.writeBytes(s.getBytes(UTF_8))
  private def texts(s: String*): io.netty.buffer.ByteBuf => Unit = b =>
    b.writeInt(1).writeInt(0).writeInt(Oid.Text).writeInt(s.length).writeInt(1)
    for x <- s do b.writeInt(x.length).writeBytes(x.getBytes(UTF_8))
  private def int8s(xs: Long*): io.netty.buffer.ByteBuf => Unit = b =>
    if xs.isEmpty then b.writeInt(0).writeInt(0).writeInt(20)
    else
      b.writeInt(1).writeInt(0).writeInt(20).writeInt(xs.length).writeInt(1)
      for x <- xs do b.writeInt(8).writeLong(x)

  test("int8 arrays, read in place"):
    val row = dataRow(int8s(9, 7, 12), int8s(), null)
    assertEquals((row.int8ArrayLength(0), row.int8ArrayAt(0, 0), row.int8ArrayAt(0, 2)), (3, 9L, 12L))
    assert(row.int8ArrayHas(0, 7) && !row.int8ArrayHas(0, 8))
    assertEquals((row.int8ArrayLength(1), row.int8ArrayLength(2)), (0, 0))
    assert(!row.int8ArrayHas(1, 0) && !row.int8ArrayHas(2, 0))

  test("a packed batch's articles, copied with each viewer's flags, are the articles Render.article writes"):
    // slug, title, description, created_at, updated_at, tag_list, favorites_count, then the author's.
    def article(id: Long, author: Long, slug: String, bio: String) = Seq[io.netty.buffer.ByteBuf => Unit](
      text(slug), text("T \"q\""), text("dé"), int8(id * 1_000_000), int8(id * 2_000_000), texts("b", "a\\"),
      int8(id + 100), text(s"u$author"), if bio == null then null else text(bio), null,
    )
    val articles = Seq((7L, 3L, "seven", "bio"), (9L, 4L, "nine", null), (11L, 3L, "eleven", "x\ny"))
    val outs = Out.Pool()
    val packed = PackedArticles(outs)
    for (id, author, slug, bio) <- articles.reverse do
      packed.row(dataRow((null +: article(id, author, slug, bio)) ++ Seq(int8(id), int8(author), null, null, null, int8(0))*))
    val viewer = dataRow((int8(3) +: Seq.fill(12)(null)) ++ Seq(int8s(11, 9, 7), int8s(7), int8s(4), int8(1))*)
    val got = Out()
    val expected = Out()
    for k <- 0 until viewer.int8ArrayLength(13) do
      val id = viewer.int8ArrayAt(13, k)
      val (_, author, slug, bio) = articles.find(_._1 == id).get
      val a = packed.find(id)
      assertEquals(packed.author(a), author)
      packed.write(got, a, viewer.int8ArrayHas(14, id), viewer.int8ArrayHas(15, author))
      val (shared, ownerInfo) = article(id, author, slug, bio).splitAt(7)
      val listRow = dataRow((int8(3) +: shared) ++ (bool(id == 7) +: ownerInfo) :+ bool(author == 4)*)
      Render.article(expected, listRow, Columns.ListArticle, withBody = false)
    assertEquals(got.body, expected.body)
    assertEquals(packed.find(8), -1)
    packed.release()

  test("a packed batch's comments, copied with each viewer's following, are the comments Render.comment writes"):
    // id, body, created_at, updated_at, username, bio, image, then the article and the author.
    def comment(id: Long, body: String, author: Long, bio: String) = Seq[io.netty.buffer.ByteBuf => Unit](
      int8(id), text(body), int8(id * 1_000_000), int8(id * 2_000_000), text(s"u$author"), if bio == null then null else text(bio), null,
    )
    // Article 7's comments newest first, then article 9's.
    val comments = Seq((7L, 30L, "third \"q\"", 3L, "bio"), (7L, 20L, "second", 4L, null), (9L, 10L, "é\n", 3L, "x"))
    val outs = Out.Pool()
    val packed = PackedComments(outs)
    for (article, id, body, author, bio) <- comments do
      packed.row(dataRow(comment(id, body, author, bio) ++ Seq(int8(article), int8(author), null, int8(0))*))
    for (article, followed) <- Seq((7L, Seq(4L)), (9L, Seq(3L)), (8L, Seq())) do
      val got = Out()
      val expected = Out()
      var k = packed.first(article)
      while k >= 0 && k < packed.size && packed.article(k) == article do
        packed.write(got, k, followed.contains(packed.author(k)))
        k += 1
      for (a, id, body, author, bio) <- comments if a == article do
        Render.comment(expected, dataRow(comment(id, body, author, bio) :+ bool(followed.contains(author))*), followed.contains(author))
      assertEquals(got.body, expected.body)
    assertEquals(packed.first(8), -1)
    packed.release()

  test("a round's articles, put together from both phases with each viewer's flags, are the articles Render.article writes"):
    // id, author, slug, title, description, created_at, updated_at; the body; the tag names; favorites; the author's.
    case class A(id: Long, author: Long, slug: String, body: String, tags: Seq[String], favorites: Long)
    val articles = Seq(A(7, 3, "seven", "b7 \"q\"", Seq("b", "a\\"), 5), A(9, 4, "nine", "b9", Seq(), 0),
      A(11, 3, "eleven", "b11\n", Seq("c"), 12))
    val tagIds = Map("a\\" -> 30, "b" -> 4, "c" -> 17) // in name order: "a\\", "b", "c"
    val bios = Map(3L -> "bio", 4L -> null)
    def head(a: A) = Seq[io.netty.buffer.ByteBuf => Unit](int8(a.id), int8(a.author), text(a.slug), text("T \"q\""), text("dé"),
      int8(a.id * 1_000_000), int8(a.id * 2_000_000))
    val outs = Out.Pool()
    val round = RoundArticles(outs)
    // First phase: a list's articles (no body), then an article page's (with its body), one of them twice.
    for a <- articles do round.article(dataRow((null +: head(a)) ++ Seq(null, int8(0))*), withBody = false)
    val page = round.article(dataRow((null +: head(articles(0))) ++ Seq(text(articles(0).body), int8(1))*), withBody = true)
    assertEquals((round.size, round.find(7), page, round.find(8)), (3, 0, 0, -1))
    assertEquals((0 until round.authorCount).map(round.authorId).toSet, Set(3L, 4L))
    round.ask(1, 0, following = true)
    round.ask(1, 1, following = true)
    round.ask(2, 2, following = false)
    val (favorites, follows) = (round.favoritesAsked, round.followsAsked)
    assertEquals((favorites.size, favorites.count, follows.size, follows.count), (2, 3, 1, 2))
    assertEquals((0 until favorites.count).map(favorites.second), articles.map(_.id).toSeq)
    // Second phase: tag ids and favorites, authors, the tags in name order, the flags that hold.
    for a <- articles.reverse do round.enriched(dataRow(int8(a.id), int8s(a.tags.map(t => tagIds(t).toLong).reverse*), int8(a.favorites)))
    for (id, bio) <- bios do round.author(dataRow(int8(id), text(s"u$id"), if bio == null then null else text(bio), null))
    for t <- tagIds.keys.toSeq.sorted do round.tag(dataRow(_.writeInt(tagIds(t)), text(t)))
    round.flag(dataRow(int8(0), int8(1), int8(7)))
    round.flag(dataRow(int8(1), int8(1), int8(4)))
    round.assemble()
    def expected(a: A, viewer: Long, withBody: Boolean): String =
      val favorited = viewer == 1 && a.id == 7
      val following = viewer == 1 && a.author == 4
      val tail = Seq(int8(a.id * 1_000_000), int8(a.id * 2_000_000), texts(a.tags.sorted*), int8(a.favorites), bool(favorited),
        text(s"u${a.author}"), if bios(a.author) == null then null else text(bios(a.author)), null, bool(following))
      val row = dataRow((head(a).slice(2, 5) ++ (if withBody then Seq(text(a.body)) else Nil) ++ tail)*)
      val out = Out()
      Render.article(out, row, 0, withBody)
      out.body
    for viewer <- Seq(0L, 1L, 2L); a <- articles do
      val i = round.find(a.id)
      assert(round.ready(i))
      val got = Out()
      round.write(got, i, round.favorited(viewer, i), round.following(viewer, i))
      assertEquals(got.body, expected(a, viewer, withBody = false))
    val got = Out()
    round.writeWithBody(got, page, round.favorited(1, page), round.following(1, page))
    assertEquals(got.body, expected(articles(0), 1, withBody = true))
    round.release()

  test("a round's article whose second phase didn't name its tag or author isn't whole"):
    val round = RoundArticles(Out.Pool())
    val head = Seq[io.netty.buffer.ByteBuf => Unit](text("s"), text("t"), text("d"), int8(1), int8(2))
    round.article(dataRow((Seq(null, int8(5), int8(3)) ++ head ++ Seq(null, int8(0)))*), withBody = false)
    round.article(dataRow((Seq(null, int8(6), int8(4)) ++ head ++ Seq(null, int8(0)))*), withBody = false)
    round.enriched(dataRow(int8(5), int8s(99), int8(0)))
    round.enriched(dataRow(int8(6), int8s(), int8(0)))
    round.author(dataRow(int8(3), text("u3"), null, null))
    round.assemble()
    assert(!round.ready(round.find(5))) // tag 99 not among the tags read
    assert(!round.ready(round.find(6))) // author 4 not read
    round.release()

  test("pairs and ids, each once"):
    val set = PairSet()
    for i <- 0 until 500 do set.add(i % 50, i / 50)
    set.add(3, 0)
    assertEquals(set.size, 500)
    assert(set.has(49, 9) && !set.has(50, 0))
    val index = LongIndex()
    assertEquals((0 until 300).map(i => index.add(i * 7919L)), 0 until 300)
    assertEquals((index.add(7919L), index.find(299 * 7919L), index.find(1)), (1, 299, -1))

  test("pairs grouped by their first, as 1-based slices, in the order added"):
    val set = PairSet()
    for (a, b) <- Seq((7L, 1L), (3L, 2L), (7L, 3L), (9L, 4L), (3L, 5L), (7L, 6L)) do set.add(a, b)
    val s = PairSlices(set)
    assertEquals((0 until s.size).map(s.first), Seq(7L, 3L, 9L))
    assertEquals((0 until s.size).map(k => (s.start(k), s.end(k))), Seq((1L, 3L), (4L, 5L), (6L, 6L)))
    assertEquals((0 until s.count).map(s.second), Seq(1L, 3L, 6L, 2L, 5L, 4L))
    assertEquals((PairSlices(PairSet()).size, PairSlices(PairSet()).count), (0, 0))

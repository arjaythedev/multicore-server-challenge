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

  /** A write that sends `statements` statements and records what it gets. */
  private final class Write(statements: Int) extends PgQuery:
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
  private def noConnections = PgPool(null, PgConfig("", 0, "", "", ""), Vector.empty, 0, 1, classOf[io.netty.channel.socket.nio.NioSocketChannel])

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

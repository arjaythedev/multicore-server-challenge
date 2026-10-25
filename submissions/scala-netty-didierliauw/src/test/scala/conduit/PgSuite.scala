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

package conduit

import io.netty.channel.embedded.EmbeddedChannel

class ConnectionsSuite extends munit.FunSuite:
  /** A request that waits: its connection is busy until it is answered. */
  private final class Waiting extends Call:
    def start(): Unit = ()
    def send(w: PgWriter): Unit = ()
    def row(statement: Int, row: PgRow): Unit = ()
    def done(error: PgError): Unit = ()

  /** A connection on a channel of its own, active: counted by `connections`. */
  private def open(connections: Connections): (Connection, EmbeddedChannel) =
    val c = Connection(connections, null)
    (c, EmbeddedChannel(c))

  test("past the limit, idle connections are closed (but the newest), never one with a request waiting"):
    val connections = Connections(75, 3)
    val (a, aChannel) = open(connections)
    val (_, bChannel) = open(connections)
    val (_, cChannel) = open(connections)
    a.enqueue(Waiting())
    val (_, dChannel) = open(connections)
    assert(aChannel.isOpen, "a request waits on it")
    assert(!bChannel.isOpen && !cChannel.isOpen, "idle")
    assert(dChannel.isOpen, "the newest")
    assertEquals(connections.size, 2)
    assertEquals(connections.evicted, 2L)

  test("with every connection waiting, the loop is full, and an accepted one evicts nothing until one is idle"):
    val connections = Connections(75, 2)
    val (a, aChannel) = open(connections)
    val (b, bChannel) = open(connections)
    a.enqueue(Waiting())
    b.enqueue(Waiting())
    assert(connections.full)
    val (_, cChannel) = open(connections)
    assert(aChannel.isOpen && bChannel.isOpen && cChannel.isOpen)
    assertEquals(connections.evicted, 0L)
    assert(connections.full, "only the newest is idle")
    connections.idle(a)
    assert(!connections.full, "an idle connection makes room")
    val (_, eChannel) = open(connections)
    assert(!cChannel.isOpen && !aChannel.isOpen, "idle")
    assert(bChannel.isOpen && eChannel.isOpen)

  test("the sweep closes connections idle longer than the timeout, not those waiting"):
    val connections = Connections(2, 10)
    val (a, aChannel) = open(connections)
    val (_, bChannel) = open(connections)
    a.enqueue(Waiting())
    for _ <- 1 to 3 do connections.sweep()
    assert(aChannel.isOpen)
    assert(!bChannel.isOpen)
    assertEquals(connections.size, 1)

  test("a connection the client closed no longer counts"):
    val connections = Connections(75, 1)
    val (a, aChannel) = open(connections)
    a.enqueue(Waiting())
    assert(connections.full)
    aChannel.close()
    aChannel.runPendingTasks()
    assertEquals(connections.size, 0)
    assert(!connections.full)

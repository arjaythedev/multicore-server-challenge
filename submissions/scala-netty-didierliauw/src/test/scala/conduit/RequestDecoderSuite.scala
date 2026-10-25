package conduit

import io.netty.buffer.{ByteBuf, Unpooled}
import io.netty.channel.embedded.EmbeddedChannel

import java.nio.charset.StandardCharsets.{US_ASCII, UTF_8}

class RequestDecoderSuite extends munit.FunSuite:
  private def bytes(s: String): ByteBuf = Unpooled.copiedBuffer(s, US_ASCII)

  /** Feeds `chunks` one read at a time and returns the decoded requests. */
  private def decode(chunks: String*): (EmbeddedChannel, List[Request]) =
    val ch = EmbeddedChannel(RequestDecoder())
    chunks.foreach(c => ch.writeInbound(bytes(c)))
    (ch, Iterator.continually(ch.readInbound[Request]()).takeWhile(_ != null).toList)

  private def written(ch: EmbeddedChannel): String =
    Iterator
      .continually(ch.readOutbound[ByteBuf]())
      .takeWhile(_ != null)
      .map(b => try b.toString(US_ASCII) finally b.release())
      .mkString

  test("a GET with a query string and assorted headers"):
    val (_, List(req)) = decode("GET /api/articles?limit=10&offset=0 HTTP/1.1\r\nHost: a\r\nUser-Agent: k6\r\nAccept: */*\r\n\r\n"): @unchecked
    assertEquals((req.method, req.path, req.query, req.authorization, req.body.length), ("GET", "/api/articles", "limit=10&offset=0", null, 0))
    assert(req.keepAlive && !req.http10)
    val (_, List(plain)) = decode("DELETE /api/articles/a-1/favorite HTTP/1.1\r\n\r\n"): @unchecked
    assertEquals((plain.method, plain.path, plain.query), ("DELETE", "/api/articles/a-1/favorite", null))

  test("the API's methods and its commonest paths are constants"):
    for (method, path) <- Seq("GET" -> "/api/tags", "POST" -> "/api/articles", "PUT" -> "/api/user", "DELETE" -> "/api/articles/feed") do
      val (_, List(req)) = decode(s"$method $path?x HTTP/1.1\r\n\r\n"): @unchecked
      assert(req.method eq method, method)
      assert(req.path eq path, path)

  test("a POST with a body and an Authorization header, in any case"):
    val body = """{"body":"héllo"}"""
    val len = body.getBytes(UTF_8).length
    val ch = EmbeddedChannel(RequestDecoder())
    ch.writeInbound(bytes(s"POST /posts HTTP/1.1\r\nauthorization:   Token abc  \r\nCONTENT-LENGTH: $len\r\n\r\n"))
    ch.writeInbound(Unpooled.copiedBuffer(body, UTF_8))
    val req = ch.readInbound[Request]()
    assertEquals((req.method, req.path, req.authorization), ("POST", "/posts", "Token abc"))
    assertEquals(String(req.body, UTF_8), body)

  test("requests split at every byte, and pipelined requests"):
    val two = "GET /feed HTTP/1.1\r\n\r\nPOST /posts/1/like HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}"
    val (_, split) = decode(two.map(_.toString)*)
    assertEquals(split.map(r => (r.method, r.path)), List(("GET", "/feed"), ("POST", "/posts/1/like")))
    val (_, pipelined) = decode(two + two)
    assertEquals(pipelined.size, 4)

  test("each head is parsed alone: a short one after a long one, and one longer than the buffer"):
    val long = s"POST /posts/12345/like HTTP/1.1\r\nAuthorization: Bearer ${"x" * 300}\r\nConnection: close\r\n\r\n"
    val (_, List(first, second)) = decode(long + "GET /feed HTTP/1.1\r\n\r\n"): @unchecked
    assertEquals((first.method, first.path, first.keepAlive), ("POST", "/posts/12345/like", false))
    assertEquals((second.method, second.path, second.authorization, second.keepAlive), ("GET", "/feed", null, true))
    val huge = s"GET /posts/1 HTTP/1.1\r\nX-Pad: ${"y" * 20_000}\r\n\r\n"
    val (_, List(third, fourth)) = decode(huge + "GET /posts/2 HTTP/1.1\r\n\r\n"): @unchecked
    assertEquals((third.path, fourth.path), ("/posts/1", "/posts/2"))

  test("keep-alive rules for HTTP/1.0 and 1.1"):
    def keepAlive(version: String, connection: String) =
      val header = if connection == null then "" else s"Connection: $connection\r\n"
      decode(s"GET / $version\r\n$header\r\n")._2.head.keepAlive
    assert(keepAlive("HTTP/1.1", null))
    assert(!keepAlive("HTTP/1.1", "close"))
    assert(!keepAlive("HTTP/1.1", "Close"))
    assert(!keepAlive("HTTP/1.0", null))
    assert(keepAlive("HTTP/1.0", "Keep-Alive"))
    assert(decode("GET / HTTP/1.0\r\n\r\n")._2.head.http10)

  test("answers Expect: 100-continue before the body arrives"):
    val (ch, reqs) = decode("POST /posts HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 2\r\n\r\n")
    assertEquals(reqs, Nil)
    assertEquals(written(ch), "HTTP/1.1 100 Continue\r\n\r\n")
    ch.writeInbound(bytes("{}"))
    assertEquals(String(ch.readInbound[Request]().body, UTF_8), "{}")

  test("rejects malformed requests with a 400 and closes"):
    for bad <- Seq("garbage\r\n\r\n", "GET /\r\n\r\n", "GET / HTTP/2.0\r\n\r\n", "GET / http/1.1\r\n\r\n", "GET / HTTP/1.10\r\n\r\n",
        "GET / HTTP/1.1\r\nNoColon\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: x\r\n\r\n", "POST / HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n{}",
        "POST / HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: x\r\n\r\n{}") do
      val (ch, reqs) = decode(bad)
      assertEquals(reqs, Nil, bad)
      assert(written(ch).startsWith("HTTP/1.1 400 Bad Request\r\n"), bad)
      assert(!ch.isOpen, bad)

  test("a request must arrive whole within the deadline, which each request starts anew"):
    var now = 0L
    val ch = EmbeddedChannel(new RequestDecoder {
      override protected def deadlineSeconds: Long = 30
      override protected def clock: Long = now
    })
    ch.writeInbound(bytes("GET /feed HTTP/1.1\r\n"))
    now = 29
    ch.writeInbound(bytes("Host: a\r\n\r\n")) // whole after 29 s
    assertEquals(ch.readInbound[Request]().path, "/feed")
    now = 100 // the next request has its own deadline
    ch.writeInbound(bytes("GET /feed HTTP/1.1\r\n"))
    now = 130
    ch.writeInbound(bytes("Host: a\r\n\r\n"))
    assertEquals(ch.readInbound[Request](), null)
    assert(written(ch).startsWith("HTTP/1.1 408 Request Timeout\r\n"))
    assert(!ch.isOpen)

  test("accepts the same Content-Length twice"):
    val (_, List(req)) = decode("POST /posts HTTP/1.1\r\nContent-Length: 2\r\ncontent-length: 2\r\n\r\n{}"): @unchecked
    assertEquals(String(req.body, UTF_8), "{}")

  test("rejects chunked bodies and oversized requests"):
    val (chunked, _) = decode("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")
    assert(written(chunked).startsWith("HTTP/1.1 501 "))
    val (big, _) = decode("POST / HTTP/1.1\r\nContent-Length: 9999999\r\n\r\n")
    assert(written(big).startsWith("HTTP/1.1 413 "))
    val (longHead, _) = decode("GET / HTTP/1.1\r\nX: " + "a" * 20000)
    assert(written(longHead).startsWith("HTTP/1.1 413 "))

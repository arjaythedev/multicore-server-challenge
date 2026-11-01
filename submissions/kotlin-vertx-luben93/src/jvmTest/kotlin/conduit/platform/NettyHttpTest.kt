package conduit.platform

import conduit.http.HttpEngine

private val nettyPort: Int by lazy {
    val p = NioHttpTest.freePort(3101)
    check(startNettyServer("127.0.0.1", p, 2, HttpEngine { NioHttpTest.handle(it) }, codec = false)) { "netty epoll unavailable" }
    p
}

private val nettyCodecPort: Int by lazy {
    val p = NioHttpTest.freePort(3101)
    check(startNettyServer("127.0.0.1", p, 2, HttpEngine { NioHttpTest.handle(it) }, codec = true)) { "netty epoll unavailable" }
    p
}

private val nettyVtPort: Int by lazy {
    val p = NioHttpTest.freePort(3101)
    check(startNettyServer("127.0.0.1", p, 2, HttpEngine { NioHttpTest.handle(it) }, codec = true, vt = true)) {
        "netty epoll unavailable"
    }
    p
}

/** The NIO end-to-end cases on Netty's native epoll transport under our engine (HTTP_IO=netty). */
class NettyHttpTest : NioHttpTest() {
    override val port: Int get() = nettyPort
}

/** The same with Netty's HTTP/1.1 decoder in front of the handler (HTTP_IO=netty-http). */
class NettyCodecHttpTest : NioHttpTest() {
    override val port: Int get() = nettyCodecPort
}

/** HTTP_IO=netty-http with each handler started on a virtual thread (NETTY_HANDLER=vt). */
class NettyVirtualHttpTest : NioHttpTest() {
    override val port: Int get() = nettyVtPort
}

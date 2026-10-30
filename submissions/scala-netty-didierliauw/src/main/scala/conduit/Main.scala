package conduit

import io.netty.bootstrap.ServerBootstrap
import io.netty.channel.epoll.{Epoll, EpollIoHandler, EpollServerSocketChannel, EpollSocketChannel}
import io.netty.channel.nio.NioIoHandler
import io.netty.channel.socket.nio.{NioServerSocketChannel, NioSocketChannel}
import io.netty.channel.uring.{IoUring, IoUringIoHandler, IoUringServerSocketChannel, IoUringSocketChannel}
import io.netty.channel.unix.Errors
import io.netty.channel.{Channel, ChannelHandlerContext, ChannelInboundHandlerAdapter, ChannelOption, EventLoop, IoHandlerFactory, MultiThreadIoEventLoopGroup, ServerChannel, ServerChannelRecvByteBufAllocator}

import com.sun.management.UnixOperatingSystemMXBean

import java.lang.management.ManagementFactory
import java.nio.charset.StandardCharsets.UTF_8
import java.util.concurrent.TimeUnit
import java.util.logging.{Level, LogRecord, SimpleFormatter}
import scala.jdk.CollectionConverters.*
import scala.util.control.NonFatal

object Main:
  def main(args: Array[String]): Unit =
    val database = PgConfig.parse(requiredEnv("DATABASE_URL"))
    val jwt = Jwt(requiredEnv("JWT_SECRET").getBytes(UTF_8))
    val host = sys.env.getOrElse("HOST", "127.0.0.1")
    val port = sys.env.getOrElse("PORT", "3000").toInt

    // Out of descriptors, any file the process opens fails, even the time-zone data the JDK reads the first time
    // it formats a log line's timestamp (Netty logs through java.util.logging). Read it now. (Log writes UTC times,
    // which need no time-zone data.)
    SimpleFormatter().format(LogRecord(Level.INFO, "startup"))
    val settings =
      try Settings.all
      catch case e: ExceptionInInitializerError => throw e.getCause // a value that isn't valid: say which
    Log.info("settings", settings*)
    require(Bcrypt.Initial(0) == 0x243f6a88, "Blowfish's constants are wrong") // computed at startup, checked once

    val transport = Transport.pick(Settings.transport)
    val group = MultiThreadIoEventLoopGroup(Settings.loops, transport.ioHandler)
    val loops = group.iterator().asScala.map(_.asInstanceOf[EventLoop]).toVector
    val passwords = Passwords(Settings.bcryptThreads, Settings.bcryptWaitMillis, Settings.bcryptNice)
    val maxConnections = Settings.maxConnections.getOrElse(connectionDescriptors() / loops.length)
    Log.info("connection limits", "maxConnectionsPerLoop" -> maxConnections, "loops" -> loops.length)

    try
      val pools = startPools(loops, database, transport)
      // Each loop serves its share of the connections with its own Postgres connections: nothing is shared
      // between loops but the password threads.
      val servers = loops.zip(pools).map: (loop, pool) =>
        val connections = Connections(Settings.idleTimeoutSeconds, maxConnections, Settings.requestDeadlineSeconds)
        loop.scheduleAtFixedRate(() => connections.sweep(), 1, 1, TimeUnit.SECONDS)
        if Settings.lagMonitor then LagMonitor.start(loop)
        if Settings.stats then
          loop.scheduleAtFixedRate(() => Log.info("postgres queries", (("loop" -> Thread.currentThread.getName) +: pool.stats())*), 10, 10, TimeUnit.SECONDS)
          loop.scheduleAtFixedRate(() => Log.info("connections", "loop" -> Thread.currentThread.getName,
            "open" -> connections.size, "evicted" -> connections.evicted, "full" -> connections.full), 10, 10, TimeUnit.SECONDS)
        (loop, connections, Api(jwt, pool, passwords, loop))

      var nextLoop = 0
      val channel = ServerBootstrap()
        .group(group)
        .channel(transport.serverChannel)
        .option(ChannelOption.SO_BACKLOG, Integer.valueOf(Settings.listenBacklog))
        // By default Netty 4.2 accepts one connection per pass of the event loop: its epoll is level-triggered,
        // and the listening socket's allocator stops after one accept, guessing from the new descriptor's number
        // that nothing more is waiting. Keep accepting until the queue is empty, up to a bound so that a flood
        // can't hold up the other connections.
        .option(
          ChannelOption.RECVBUF_ALLOCATOR,
          ServerChannelRecvByteBufAllocator().respectMaybeMoreData(false).maxMessagesPerRead(Settings.acceptsPerPass),
        )
        .option(ChannelOption.SO_REUSEADDR, java.lang.Boolean.TRUE)
        .handler(new ChannelInboundHandlerAdapter {
          // Each accepted connection gets its Connection and is registered here, on the next loop in turn, instead
          // of by Netty's acceptor (next in this pipeline, which it never reaches): that one adds a ChannelInitializer,
          // which adds the handler and removes itself, a pipeline context, a set entry and a promise more per
          // connection.
          override def channelRead(ctx: ChannelHandlerContext, msg: AnyRef): Unit =
            val child = msg.asInstanceOf[Channel]
            var tries = 1
            while servers(nextLoop)._2.full && tries < servers.length do
              nextLoop = (nextLoop + 1) % servers.length
              tries += 1
            val (loop, connections, api) = servers(nextLoop)
            nextLoop = (nextLoop + 1) % servers.length
            child.pipeline.addLast("connection", Connection(connections, api)) // not the varargs one: no array
            // With the channel's void promise: if registering fails, Netty closes the channel itself.
            loop.register(child.voidPromise())
            if connections.full && servers.forall(_._2.full) then pause(ctx)

          // Out of descriptors (some still closing), Netty's acceptor stops accepting for a second; this one too,
          // for a pause, instead of failing an accept on every pass.
          override def exceptionCaught(ctx: ChannelHandlerContext, cause: Throwable): Unit = cause match
            case e: Errors.NativeIoException if e.expectedErr == -EMFILE || e.expectedErr == -ENFILE => pause(ctx)
            case _ => ctx.fireExceptionCaught(cause)

          /** Stops accepting until a loop has room, looked at every [[AcceptPauseMillis]]: meanwhile new connections
            * wait in the listen queue.
            */
          private def pause(ctx: ChannelHandlerContext): Unit =
            val config = ctx.channel.config
            if config.isAutoRead then
              config.setAutoRead(false)
              lazy val check: Runnable = () =>
                if servers.exists(!_._2.full) then config.setAutoRead(true)
                else ctx.executor.schedule(check, AcceptPauseMillis, TimeUnit.MILLISECONDS)
              ctx.executor.schedule(check, AcceptPauseMillis, TimeUnit.MILLISECONDS)
        })
        .childHandler(new ChannelInboundHandlerAdapter) // required by ServerBootstrap, never reached: see above
        .bind(host, port)
        .sync()
        .channel()
      Log.info("listening", "host" -> host, "port" -> port, "transport" -> transport.name)
      channel.closeFuture().sync()
    finally group.shutdownGracefully()

  /** Every loop's Postgres connections, prepared. Postgres may still be starting: retries for up to 50 s. */
  private def startPools(loops: Vector[EventLoop], database: PgConfig, transport: Transport): Vector[PgPool] =
    val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(50)
    var pools: Vector[PgPool] = null
    while pools == null do
      def share(total: Int, i: Int) = total / loops.length + (if i < total % loops.length then 1 else 0)
      val attempt = loops.zipWithIndex.map((loop, i) =>
        PgPool(loop, database, Sql.statements, share(Settings.pgConnections, i).max(1), Settings.pgDepth, transport.socketChannel,
          Settings.batchSize, Settings.pgWriteConnections, Settings.writeGroupSize, Settings.pgDrain,
          Settings.pgRoundSize, Settings.pgGatherMicros)
      )
      try
        attempt.map(_.start()).foreach(_.get(30, TimeUnit.SECONDS))
        pools = attempt
      catch
        case NonFatal(e) =>
          attempt.foreach(_.close())
          if System.nanoTime() > deadline then throw IllegalStateException("can't connect to Postgres", e)
          Log.warn("Postgres isn't ready, retrying", "error" -> String.valueOf(e.getCause))
          Thread.sleep(1000)
    Log.info("connected to Postgres", "connections" -> pools.map(_.size).sum, "statements" -> Sql.statements.length)
    pools

  /** The descriptors connections can use: the file-descriptor limit, minus what's already open (jars, epoll) and
    * headroom for the listening socket, Postgres's connections and anything else the process opens later.
    */
  private def connectionDescriptors(): Int =
    ManagementFactory.getOperatingSystemMXBean match
      case os: UnixOperatingSystemMXBean =>
        val limit = os.getMaxFileDescriptorCount - os.getOpenFileDescriptorCount - 1024 - Settings.pgConnections -
          Settings.loops * Settings.pgWriteConnections
        math.max(limit, 64).min(Int.MaxValue).toInt
      case _ => Int.MaxValue

  private val EMFILE = 24
  /** How often a listening socket that stopped accepting looks for room again. */
  private val AcceptPauseMillis = 100L
  private val ENFILE = 23

  /** How the event loops talk to the kernel: for the server's sockets and for Postgres's. */
  private final case class Transport(
      name: String,
      ioHandler: IoHandlerFactory,
      serverChannel: Class[? <: ServerChannel],
      socketChannel: Class[? <: Channel],
  )

  private object Transport:
    /** `preferred` ("io_uring" or "epoll") if the kernel offers it, else epoll, else NIO (macOS, for development). */
    def pick(preferred: String): Transport =
      // Read by Netty's io_uring classes when they load (a -D on the command line wins): with tens of thousands of
      // connections a pass can complete more than the default queue holds (the first runs logged overflows at 4,096).
      if preferred == "io_uring" && System.getProperty("io.netty.iouring.cqSize") == null then
        System.setProperty("io.netty.iouring.cqSize", "65536")
      if preferred == "io_uring" && IoUring.isAvailable then
        val ioHandler = Registrations.factory(IoUringIoHandler.newFactory(), classOf[IoUringIoHandler])
        Transport("io_uring", ioHandler, classOf[IoUringServerSocketChannel], classOf[IoUringSocketChannel])
      else if Epoll.isAvailable then
        val ioHandler = Registrations.factory(EpollIoHandler.newFactory(), classOf[EpollIoHandler])
        Transport("epoll", ioHandler, classOf[EpollServerSocketChannel], classOf[EpollSocketChannel])
      else Transport("nio", NioIoHandler.newFactory(), classOf[NioServerSocketChannel], classOf[NioSocketChannel])

  private def requiredEnv(name: String): String =
    sys.env.getOrElse(name, throw IllegalStateException(s"$name is not set"))

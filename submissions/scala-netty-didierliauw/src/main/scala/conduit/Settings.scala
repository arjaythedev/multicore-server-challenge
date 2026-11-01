package conduit

/** Every setting besides the challenge's four environment variables (`DATABASE_URL`, `JWT_SECRET`, `HOST`, `PORT`,
  * read in [[Main]]): JVM system properties, defaulting to what the benchmark box runs. Set them without editing
  * `start.sh` through `JAVA_TOOL_OPTIONS`, e.g. `JAVA_TOOL_OPTIONS="-Dconduit.loops=4" bash start.sh`; `README.md`
  * lists them. A value that isn't valid stops the server at startup.
  */
object Settings:
  private val cpus = Runtime.getRuntime.availableProcessors

  /** `io_uring`, which falls back to epoll where the kernel or a seccomp filter doesn't allow it, or `epoll`. Either
    * falls back to NIO off Linux.
    */
  val transport: String = sys.props.getOrElse("conduit.transport", "io_uring") match
    case t @ ("io_uring" | "epoll") => t
    case other => throw IllegalArgumentException(s"""-Dconduit.transport must be io_uring or epoll, not "$other"""")
  /** Event loop threads. Each serves its share of the connections start to finish, with Postgres connections of its
    * own. Postgres needs most of the box's CPU, so few: one per 4 CPUs.
    */
  val loops: Int = int("conduit.loops", math.max(1, cpus / 4))
  /** Postgres connections per loop that take only writes, on top of [[pgConnections]]: each commits the writes that
    * waited for it together ([[WriteGroup]]), and the reads never wait behind a commit. 0: writes go as reads do.
    */
  val pgWriteConnections: Int = sys.props.get("conduit.pgWriteConnections").fold(1)(v =>
    v.trim.toIntOption.filter(_ >= 0).getOrElse(throw IllegalArgumentException(s"""-Dconduit.pgWriteConnections must be 0 or more, not "$v""""))
  )
  /** The read connections in all, split evenly over the loops: one per CPU, so that Postgres's backends, each kept
    * busy by pipelining, don't take turns on the CPUs (4 connections on 4 CPUs cost Postgres 5-13% less per request
    * than 16, and the server 7% less; 8 saved nothing over 16). The box's Postgres allows 100, and the spec asks for
    * 95 at most, write connections included.
    */
  val pgConnections: Int = int("conduit.pgConnections", math.min(95 - loops * pgWriteConnections, math.max(loops, cpus)))
  /** The most writes in one transaction ([[WriteGroup]]); 1: each its own. */
  val writeGroupSize: Int = int("conduit.writeGroupSize", 128)
  /** A read connection takes queries only when it has none in flight, and then every read that waits, each kind's
    * together ([[PgPool]]): one round of statements in flight per connection, so that the reads that arrive meanwhile
    * go out in batches. 3-8% less CPU per request than 16 queries in flight per connection.
    */
  val pgDrain: Boolean = sys.props.get("conduit.pgDrain").fold(true)(v =>
    v.trim.toBooleanOption.getOrElse(throw IllegalArgumentException(s"""-Dconduit.pgDrain must be true or false, not "$v""""))
  )
  /** With [[pgDrain]]: the most reads a connection takes in a round, the oldest first whatever their kind (each kind's
    * still together, in batches of up to [[batchSize]]), so that every kind waits alike. 0: up to [[batchSize]] of
    * every kind, oldest or not: under overload the two most frequent kinds fell rounds behind and failed the holds.
    * 32 and 64 cut the batches too small; with no cap, one connection took thousands of reads while the other served
    * newer ones. 512, so that [[pgGatherMicros]]'s rounds aren't cut short near the limit.
    */
  val pgRoundSize: Int = sys.props.get("conduit.pgRoundSize").fold(512)(v =>
    v.trim.toIntOption.filter(_ >= 0).getOrElse(throw IllegalArgumentException(s"""-Dconduit.pgRoundSize must be 0 or more, not "$v""""))
  )
  /** With [[pgDrain]] and [[pgRoundSize]]: how long the oldest waiting read waits for others before an idle read
    * connection takes them as a round ([[PgPool]]), unless a round's worth waits first; reads that waited that long
    * for a connection go as soon as one is free. 0: a free connection takes what waits at once, and a read that
    * finds one free goes alone. 10 ms: 9-11% less of Postgres's CPU per request near the limit, where the batches
    * were what arrived while every connection was busy; 15 ms with rounds of 512 another 6.5%, the packed batches
    * paying with their size (20 ms 7%, its p95 higher).
    */
  val pgGatherMicros: Int = sys.props.get("conduit.pgGatherMicros").fold(15_000)(v =>
    v.trim.toIntOption.filter(_ >= 0).getOrElse(throw IllegalArgumentException(s"""-Dconduit.pgGatherMicros must be 0 or more, not "$v""""))
  )
  /** Without [[pgDrain]]: the most requests in flight on one Postgres connection; past that they wait in their loop's
    * queue, in order.
    */
  val pgDepth: Int = int("conduit.pgDepth", 16)
  /** The most requests of a kind that wait for a Postgres connection to go out as one statement ([[Sql.Batch]]); 1:
    * each its own statement. 128, for [[pgGatherMicros]]'s batches.
    */
  val batchSize: Int = int("conduit.batchSize", 128)
  /** Threads that hash and check passwords (bcrypt), off the event loops. */
  val bcryptThreads: Int = int("conduit.bcryptThreads", math.max(1, cpus / 4))
  /** How long a hash may wait for others to run with it, four at a time ([[Passwords]]). */
  val bcryptWaitMillis: Int = sys.props.get("conduit.bcryptWaitMillis").fold(400)(v =>
    v.trim.toIntOption.filter(_ >= 0).getOrElse(throw IllegalArgumentException(s"""-Dconduit.bcryptWaitMillis must be 0 or more, not "$v""""))
  )
  /** The bcrypt threads' nice value: 0 runs them as every other thread, up to 19 lets them wait whenever Postgres or
    * an event loop has work ([[Passwords]]).
    */
  val bcryptNice: Int = sys.props.get("conduit.bcryptNice").fold(0)(v =>
    v.trim.toIntOption.filter(n => n >= 0 && n <= 19).getOrElse(throw IllegalArgumentException(s"""-Dconduit.bcryptNice must be 0 to 19, not "$v""""))
  )
  /** The most connections each loop holds; past it the longest-idle are evicted, and with none idle the server stops
    * accepting until one is. Unset, its share of descriptors.
    */
  val maxConnections: Option[Int] = sys.props.get("conduit.maxConnections").map(positive("conduit.maxConnections", _))
  /** Idle keep-alive connections are closed after this. The spec asks for at least 65 s. */
  val idleTimeoutSeconds: Int = int("conduit.idleTimeoutSeconds", 75)
  /** A request must arrive whole within this many seconds of its first bytes, or it gets a 408
    * ([[RequestDecoder.deadlineSeconds]]).
    */
  val requestDeadlineSeconds: Int = int("conduit.requestDeadlineSeconds", 30)
  /** The most new connections accepted per pass of the accepting event loop. */
  val acceptsPerPass: Int = int("conduit.acceptsPerPass", 1024)
  /** The listen backlog asked for; the kernel caps it at `net.core.somaxconn` (65,535 on the box). */
  val listenBacklog: Int = int("conduit.listenBacklog", 65535)
  /** Logs every 10 s each loop's queries to Postgres (how many waited for a connection, and the batches they went in)
    * and its connections (open, evicted so far, and whether it is full).
    */
  val stats: Boolean = java.lang.Boolean.getBoolean("conduit.stats")
  /** Logs every 10 s how long each event loop went without getting to its tasks ([[LagMonitor]]). */
  val lagMonitor: Boolean = java.lang.Boolean.getBoolean("conduit.lagMonitor")

  /** The settings, for the startup log. */
  def all: Seq[(String, Any)] = Seq(
    "cpus" -> cpus,
    "transport" -> transport,
    "loops" -> loops,
    "pgConnections" -> pgConnections,
    "pgWriteConnections" -> pgWriteConnections,
    "writeGroupSize" -> writeGroupSize,
    "pgDepth" -> pgDepth,
    "pgDrain" -> pgDrain,
    "pgRoundSize" -> pgRoundSize,
    "batchSize" -> batchSize,
    "pgGatherMicros" -> pgGatherMicros,
    "bcryptThreads" -> bcryptThreads,
    "bcryptWaitMillis" -> bcryptWaitMillis,
    "bcryptNice" -> bcryptNice,
    "maxConnections" -> maxConnections.fold("the descriptors'")(_.toString),
    "idleTimeoutSeconds" -> idleTimeoutSeconds,
    "requestDeadlineSeconds" -> requestDeadlineSeconds,
    "acceptsPerPass" -> acceptsPerPass,
    "listenBacklog" -> listenBacklog,
    "lagMonitor" -> lagMonitor,
    "stats" -> stats,
  )

  private def int(key: String, default: Int): Int = sys.props.get(key).fold(default)(positive(key, _))

  private def positive(key: String, value: String): Int =
    value.trim.toIntOption.filter(_ > 0).getOrElse(throw IllegalArgumentException(s"""-D$key must be a positive integer, not "$value""""))

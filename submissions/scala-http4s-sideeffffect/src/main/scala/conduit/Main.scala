package conduit

import cats.effect.*
import cats.effect.std.Console
import cats.syntax.all.*
import com.comcast.ip4s.{Host, Port}
import org.http4s.ember.server.EmberServerBuilder
import org.typelevel.otel4s.metrics.MeterProvider
import org.typelevel.otel4s.trace.TracerProvider
import skunk.Session
import skunk.telemetry.{QueryCaptureConfig, TelemetryConfig}

import java.net.URI
import java.util.concurrent.Executors
import scala.concurrent.ExecutionContext
import scala.concurrent.duration.*

final case class Config(
    databaseUrl: String,
    jwtSecret: String,
    host: Host,
    port: Port,
    readSessions: Int,
    writeSessions: Int,
    bcryptThreads: Int,
    maxConnections: Int
)

object Config:
  def fromEnv: IO[Config] = IO {
    def env(name: String) = sys.env.get(name).filter(_.nonEmpty)
    def required(name: String) = env(name).getOrElse(sys.error(s"$name is not set"))
    val cores = Runtime.getRuntime.availableProcessors
    Config(
      databaseUrl = required("DATABASE_URL"),
      jwtSecret = required("JWT_SECRET"),
      host = env("HOST").flatMap(Host.fromString).getOrElse(Host.fromString("0.0.0.0").get),
      port = env("PORT").flatMap(Port.fromString).getOrElse(Port.fromInt(80).get),
      readSessions = env("DB_READ_SESSIONS").flatMap(_.toIntOption).getOrElse(32),
      writeSessions = env("DB_WRITE_SESSIONS").flatMap(_.toIntOption).getOrElse(8),
      bcryptThreads = env("BCRYPT_THREADS").flatMap(_.toIntOption).getOrElse((cores / 2).max(1)),
      maxConnections = env("MAX_CONNECTIONS").flatMap(_.toIntOption).getOrElse(150_000)
    )
  }

object Main extends IOApp.Simple:

  // The server is CPU-bound by design; the starvation checker's warnings would only add noise under load.
  override protected def runtimeConfig =
    super.runtimeConfig.copy(cpuStarvationCheckInitialDelay = Duration.Inf)

  /** Half the cores: Postgres runs on the same box and needs the rest (measured: 4 of 8 cores beat 6 and 8 on both CPU
    * per request and tail latency). `COMPUTE_THREADS` overrides it.
    */
  override protected def computeWorkerThreadCount: Int =
    sys.env
      .get("COMPUTE_THREADS")
      .flatMap(_.toIntOption)
      .getOrElse((Runtime.getRuntime.availableProcessors / 2).max(2))

  // No tracing or metrics: skunk instruments every statement through otel4s, and the no-op providers plus disabled
  // pool and protocol spans make that free.
  private given TracerProvider[IO] = TracerProvider.noop[IO]
  private given MeterProvider[IO] = MeterProvider.noop[IO]

  /** `postgres://user:password@host:port/db` as a skunk session. */
  private def session(databaseUrl: String): Resource[IO, Session[IO]] =
    val uri = URI(databaseUrl)
    val (user, password) = Option(uri.getUserInfo).map(_.split(":", 2)) match
      case Some(Array(u, p)) => (u, p)
      case Some(Array(u))    => (u, "")
      case _                 => ("postgres", "")
    Session
      .Builder[IO]
      .withHost(uri.getHost)
      .withPort(if uri.getPort > 0 then uri.getPort else 5432)
      .withUserAndPassword(user, password)
      .withDatabase(uri.getPath.stripPrefix("/"))
      // Session-level settings (rule 2): the same plan for every execution of a prepared statement instead of five
      // custom plans first, no JIT compilation, and no parallel workers for these short index lookups.
      .withConnectionParameters(
        Session.DefaultConnectionParameters ++ Map(
          "plan_cache_mode" -> "force_generic_plan",
          "jit" -> "off",
          "max_parallel_workers_per_gather" -> "0"
        )
      )
      .withTelemetryConfig(
        TelemetryConfig.default
          .withCaptureQuery(QueryCaptureConfig.disabled)
          .withPoolSpans(TelemetryConfig.PoolSpans.Disabled)
          .withProtocolSpans(TelemetryConfig.ProtocolSpans.Disabled)
      )
      .single

  private def fixedThreadPool(threads: Int): Resource[IO, ExecutionContext] =
    Resource
      .make(IO(Executors.newFixedThreadPool(threads)))(pool => IO.blocking(pool.shutdown()))
      .map(ExecutionContext.fromExecutorService)

  def run: IO[Unit] =
    val server = for
      config <- Resource.eval(Config.fromEnv)
      // Writes get their own sessions, so a burst of reads can't queue them (or the other way round).
      reads <- SessionPool(config.readSessions, session(config.databaseUrl))
      writes <- SessionPool(config.writeSessions, session(config.databaseUrl))
      bcryptPool <- fixedThreadPool(config.bcryptThreads)
      // The two lookups of an article page, the most common page: merged across concurrent requests (Batcher).
      articles <- Batcher(maxBatch = 64, concurrency = 8)((keys: List[(Long, String)]) =>
        reads.use(Sql.articlesBySlug(_)(keys))
      )
      comments <- Batcher(maxBatch = 64, concurrency = 8)((keys: List[(Long, String)]) =>
        reads.use(Sql.commentsBySlugs(_)(keys))
      )
      // A feed depends only on its viewer, so feeds batch the same way. (The global list doesn't: requests for the same
      // page would share one result, which is caching between requests.)
      feeds <- Batcher(maxBatch = 64, concurrency = 8)((keys: List[(Long, Sql.Page)]) => reads.use(Sql.feeds(_)(keys)))
      api = Api(
        Db(reads, writes),
        Jwt(config.jwtSecret),
        bcryptPool,
        Lookups(articles(_), comments(_), feeds(_).map(_.getOrElse((Nil, 0L))))
      )
      _ <- EmberServerBuilder
        .default[IO]
        .withHost(config.host)
        .withPort(config.port)
        .withHttpApp(api.app)
        .withMaxConnections(config.maxConnections)
        // Users think for up to 70 s between pages; keep their keep-alive connections open until they close them.
        // A finite idle timeout would race a timer against every socket read.
        .withIdleTimeout(Duration.Inf)
        // Requests are small; a small read buffer keeps tens of thousands of idle connections cheap.
        .withReceiveBufferSize(8 * 1024)
        .withShutdownTimeout(1.second)
        .build
      raised <- Resource.eval(ListenBacklog.raise(config.port.value, 65535))
      _ <- Resource.eval(IO.unlessA(raised)(Console[IO].errorln("could not raise the listen backlog")))
    yield ()
    server.useForever.void

package conduit

import cats.effect.*
import cats.effect.std.Console
import cats.syntax.all.*
import com.comcast.ip4s.{Host, Port}
import com.zaxxer.hikari.HikariConfig
import doobie.hikari.HikariTransactor
import doobie.util.ExecutionContexts
import doobie.util.transactor.{Strategy, Transactor}
import org.http4s.ember.server.EmberServerBuilder

import java.net.URI
import scala.concurrent.duration.*

final case class Config(
    databaseUrl: String,
    jwtSecret: String,
    host: Host,
    port: Port,
    poolSize: Int,
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
      poolSize = env("DB_POOL_SIZE").flatMap(_.toIntOption).getOrElse(4 * cores),
      bcryptThreads = env("BCRYPT_THREADS").flatMap(_.toIntOption).getOrElse((cores / 2).max(1)),
      maxConnections = env("MAX_CONNECTIONS").flatMap(_.toIntOption).getOrElse(150_000)
    )
  }

object Main extends IOApp.Simple:

  // The server is CPU-bound by design; the starvation checker's warnings would only add noise under load.
  override protected def runtimeConfig =
    super.runtimeConfig.copy(cpuStarvationCheckInitialDelay = Duration.Inf)

  /** `postgres://user:password@host:port/db` as HikariCP settings for the Postgres JDBC driver. */
  private def hikariConfig(config: Config): HikariConfig =
    val uri = URI(config.databaseUrl)
    val (user, password) = Option(uri.getUserInfo).map(_.split(":", 2)) match
      case Some(Array(u, p)) => (u, p)
      case Some(Array(u))    => (u, "")
      case _                 => ("", "")
    val port = if uri.getPort > 0 then uri.getPort else 5432
    val hikari = HikariConfig()
    hikari.setJdbcUrl(s"jdbc:postgresql://${uri.getHost}:$port${uri.getPath}")
    hikari.setUsername(user)
    hikari.setPassword(password)
    hikari.setMaximumPoolSize(config.poolSize)
    hikari.setMinimumIdle(config.poolSize)
    hikari.setAutoCommit(true)
    hikari.setConnectionTimeout(10_000)
    // Server-side prepared statements from the first execution: every query here runs thousands of times.
    hikari.addDataSourceProperty("prepareThreshold", "1")
    hikari.addDataSourceProperty("preparedStatementCacheQueries", "1024")
    hikari.addDataSourceProperty("ApplicationName", "conduit-scala-http4s")
    hikari

  def run: IO[Unit] =
    val server = for
      config <- Resource.eval(Config.fromEnv)
      tx <- HikariTransactor.fromHikariConfig[IO](hikariConfig(config))
      bcryptPool <- ExecutionContexts.fixedThreadPool[IO](config.bcryptThreads)
      // Single statements run in autocommit mode: no BEGIN/COMMIT round trips around them.
      db = Transactor.strategy.set(tx, Strategy.void)
      api = Api(db, tx, Jwt(config.jwtSecret), bcryptPool)
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

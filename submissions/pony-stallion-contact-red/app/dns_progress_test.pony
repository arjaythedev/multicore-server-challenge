use "net"
use pg = "postgres"

actor \nodoc\ _DNSProgressTest is _TestStatusNotify
  let _env: Env
  let _session: _TestSession

  new create(auth: TCPConnectAuth, config: _Config, env: Env) =>
    _env = env
    _session = _TestSession(
      pg.ServerConnectInfo(auth, config.dbhost, config.dbport),
      pg.DatabaseConnectInfo(config.user, config.password, config.database),
      this)
    this.progress()

  be progress() =>
    _env.out.print("scheduler progressed")

  be pg_session_authenticated(session: _TestSession) =>
    _session.close()

  be pg_transaction_status(session: _TestSession,
    status: pg.TransactionStatus) => None

  be pg_session_connection_failed(session: _TestSession,
    reason: pg.ConnectionFailureReason)
  =>
    _env.err.print("connection failed")
    _env.exitcode(1)

  be pg_session_shutdown(session: _TestSession) => None

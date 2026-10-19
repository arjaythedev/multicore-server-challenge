use "collections"
use "cli"
use "net"
use "time"
use pg = "postgres"

use @access[I32](path: Pointer[U8] tag, mode: I32)

actor \nodoc\ _SessionShutdownTest is (_TestStatusNotify &
  _TestPrepareReceiver & _TestResultReceiver & _TestDiagReceiver)
  let _env: Env
  let _session: _TestSession
  var _next: U8 = 0
  var _diag_checked: Bool = false

  new create(auth: TCPConnectAuth, config: _Config, env: Env) =>
    _env = env
    _session = _TestSession(
      pg.ServerConnectInfo(auth, config.dbhost, config.dbport),
      pg.DatabaseConnectInfo(config.user, config.password, config.database),
      this)

  be pg_session_authenticated(session: _TestSession) =>
    session.execute(pg.PreparedQuery("SELECT pg_sleep(2)", _P.none()), this)
    session.prepare("later", "SELECT 1", this)
    session.execute(pg.PreparedQuery("SELECT 1", _P.none()), this)
    session.close()
    session.prepare("after", "SELECT 2", this)
    session.execute(pg.PreparedQuery("SELECT 2", _P.none()), this)

  be pg_query_result(session: _TestSession, result: pg.Result) =>
    _fail("closed query succeeded")

  be pg_query_failed(session: _TestSession, query': pg.Query,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError))
  =>
    if not (failure is pg.SessionClosed) then
      _fail("wrong query failure")
      return
    end
    let sql = try (query' as pg.PreparedQuery).string
      else "" end
    if ((_next == 0) and (sql == "SELECT pg_sleep(2)")) or
      ((_next == 2) and (sql == "SELECT 1")) or
      ((_next == 5) and (sql == "SELECT 2")) then
      _next = _next + 1
      _complete()
    else _fail("wrong query failure order") end

  be pg_statement_prepared(session: _TestSession, name: String) =>
    _fail("closed preparation succeeded")

  be pg_prepare_failed(session: _TestSession, name: String,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError))
  =>
    if (_next == 1) and (name == "later") and
      (failure is pg.SessionClosed) then
      _next = 2
    elseif (_next == 4) and (name == "after") and
      (failure is pg.SessionClosed) then
      _next = 5
    else _fail("wrong preparation failure order") end

  be pg_transaction_status(session: _TestSession,
    status: pg.TransactionStatus) => None

  be pg_session_connection_failed(session: _TestSession,
    reason: pg.ConnectionFailureReason)
  =>
    _fail("session connection failed")

  be pg_session_shutdown(session: _TestSession) =>
    if _next == 3 then
      _next = 4
      ifdef "conduit_diagnostic" then
        session.diag_snapshot(0, 0, 0, this)
      end
    else _fail("shutdown before command failures") end

  be pg_diag_snapshot(session: _TestSession, snapshot: pg.DiagSnapshot) =>
    ifdef "conduit_diagnostic" then
      try
        if (snapshot.counters(3)? != 1) or
          (snapshot.histograms(6)?.count != 1) or
          (snapshot.histograms(7)?.count == 0) or
          (snapshot.histograms(7)?.sum == 0)
        then
          _fail("missing terminal socket wait")
          return
        end
      else
        _fail("invalid terminal diagnostic snapshot")
        return
      end
      _diag_checked = true
      _complete()
    end

  fun ref _complete() =>
    if _next == 6 then
      ifdef "conduit_diagnostic" then
        if _diag_checked then
          _env.out.print("session shutdown settled commands")
        end
      else
        _env.out.print("session shutdown settled commands")
      end
    end

  fun ref _fail(message: String) =>
    _env.err.print(message)
    _env.exitcode(1)
    _session.close()

actor \nodoc\ _SessionResumeAfterCloseTest is (_TestStatusNotify &
  _TestPrepareReceiver)
  let _env: Env
  let _session: _TestSession
  var _rejected: Bool = false

  new create(auth: TCPConnectAuth, config: _Config, env: Env) =>
    _env = env
    _session = _TestSession(
      pg.ServerConnectInfo(auth, config.dbhost, config.dbport),
      pg.DatabaseConnectInfo(config.user, config.password, config.database),
      this)

  be pg_session_authenticated(session: _TestSession) =>
    session.prepare("bad\0name", "SELECT 1", this)
    session.close()

  be pg_statement_prepared(session: _TestSession, name: String) =>
    _fail("invalid preparation succeeded")

  be pg_prepare_failed(session: _TestSession, name: String,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError))
  =>
    if (name != "bad\0name") or not (failure is pg.DataError) then
      _fail("wrong preparation failure")
      return
    end
    _rejected = true

  be pg_transaction_status(session: _TestSession,
    status: pg.TransactionStatus) => None

  be pg_session_connection_failed(session: _TestSession,
    reason: pg.ConnectionFailureReason)
  =>
    _fail("session connection failed")

  be pg_session_shutdown(session: _TestSession) =>
    if _rejected then _env.out.print("rejected preparation closed")
    else _fail("session closed before preparation rejection") end

  fun ref _fail(message: String) =>
    _env.err.print(message)
    _env.exitcode(1)
    _session.close()

actor \nodoc\ _ConnectionNulTest is
  (_TestStatusNotify & _TestStartReceiver)
  let _env: Env
  let _valid: _TestSession
  embed _counts: MapIs[_TestSession, U64] = MapIs[_TestSession, U64]
  embed _closed: SetIs[_TestSession] = SetIs[_TestSession]
  embed _failed: SetIs[_TestSession] = SetIs[_TestSession]
  var _ready: Bool = false

  new create(auth: TCPConnectAuth, config: _Config, env: Env) =>
    _env = env
    let host = pg.ServerConnectInfo(auth, config.dbhost, config.dbport)
    let database = pg.DatabaseConnectInfo(config.user, config.password,
      config.database)
    _TestSession(pg.ServerConnectInfo(auth, config.dbhost + "\0bad",
      config.dbport), database, this)
    _TestSession(pg.ServerConnectInfo(auth, config.dbhost,
      config.dbport + "\0bad"), database, this)
    _TestSession(host, pg.DatabaseConnectInfo(config.user + "\0bad",
      config.password, config.database), this)
    _TestSession(host, pg.DatabaseConnectInfo(config.user,
      config.password + "\0bad", config.database), this)
    _TestSession(host, pg.DatabaseConnectInfo(config.user, config.password,
      config.database + "\0bad"), this)
    _valid = _TestSession(host, database, this)

  be pg_session_authenticated(session: _TestSession) =>
    if (session isnt _valid) or _ready then
      _fail("invalid startup readiness")
    else _ready = true end
    session.close()

  be pg_transaction_status(session: _TestSession,
    status: pg.TransactionStatus)
  =>
    if (session isnt _valid) or (status isnt pg.TransactionIdle) then
      _fail("invalid startup transaction status")
    end

  be pg_session_connection_failed(session: _TestSession,
    reason: pg.ConnectionFailureReason)
  =>
    if (session is _valid) or _failed.contains(session) then
      _fail("unexpected startup failure")
    end
    _failed.set(session)
    _complete()

  be pg_session_shutdown(session: _TestSession) =>
    if _closed.contains(session) then _fail("duplicate startup shutdown") end
    _closed.set(session)
    session.native_starts(this)
    _complete()

  be pg_native_starts(session: _TestSession, count: U64) =>
    if _counts.contains(session) then _fail("duplicate startup count") end
    let expected: U64 = if session is _valid then 1 else 0 end
    if count != expected then _fail("unexpected native startup count") end
    _counts(session) = count
    _complete()

  fun ref _complete() =>
    if _ready and (_failed.size() == 5) and (_closed.size() == 6) and
      (_counts.size() == 6) then
      _env.out.print("connection fields rejected NUL")
    end

  fun ref _fail(message: String) =>
    _env.err.print(message)
    _env.exitcode(1)
    _valid.close()

actor \nodoc\ _StartupShutdownTest is (_TestStatusNotify &
  _TestPrepareReceiver & _TestResultReceiver)
  let _env: Env
  let _session: _TestSession
  let _marker: String
  let _timers: Timers = Timers
  var _next: U8 = 0

  new create(auth: TCPConnectAuth, config: _Config, env: Env) =>
    _env = env
    _session = _TestSession(
      pg.ServerConnectInfo(auth, config.dbhost, config.dbport),
      pg.DatabaseConnectInfo(config.user, config.password, config.database),
      this)
    _marker = try EnvVars(env.vars)("CONDUIT_DNS_MARKER")?
      else "" end
    _session.execute(pg.PreparedQuery("SELECT 1", _P.none()), this)
    _session.prepare("queued", "SELECT 1", this)
    this.check_marker()

  be check_marker() =>
    if (_marker.size() > 0) and (@access(_marker.cstring(), 0) == 0) then
      _session.close()
      _session.prepare("after", "SELECT 2", this)
      _session.execute(pg.PreparedQuery("SELECT 2", _P.none()), this)
    else
      _timers(Timer(_CheckDNSMarker(this), 1_000_000))
    end

  be pg_session_authenticated(session: _TestSession) =>
    _fail("startup completed after close")

  be pg_query_result(session: _TestSession, result: pg.Result) =>
    _fail("closed query succeeded")

  be pg_query_failed(session: _TestSession, query': pg.Query,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError))
  =>
    let sql = try (query' as pg.PreparedQuery).string
      else "" end
    if ((_next == 0) and (sql == "SELECT 1")) or
      ((_next == 5) and (sql == "SELECT 2")) then
      if not (failure is pg.SessionClosed) then
        _fail("wrong startup query failure")
        return
      end
      _next = _next + 1
      if sql == "SELECT 2" then
        _env.out.print("startup shutdown settled commands")
      end
    else _fail("wrong startup query failure") end

  be pg_statement_prepared(session: _TestSession, name: String) =>
    _fail("closed preparation succeeded")

  be pg_prepare_failed(session: _TestSession, name: String,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError))
  =>
    if (_next == 1) and (name == "queued") and
      (failure is pg.SessionClosed) then
      _next = 2
    elseif (_next == 4) and (name == "after") and
      (failure is pg.SessionClosed) then
      _next = 5
    else _fail("wrong startup preparation failure") end

  be pg_transaction_status(session: _TestSession,
    status: pg.TransactionStatus) =>
    _fail("closed startup reported ready")

  be pg_session_connection_failed(session: _TestSession,
    reason: pg.ConnectionFailureReason)
  =>
    if _next == 2 then _next = 3
    else _fail("wrong startup lifecycle order") end

  be pg_session_shutdown(session: _TestSession) =>
    if _next == 3 then _next = 4
    else _fail("shutdown before startup failures") end

  fun ref _fail(message: String) =>
    _env.err.print(message)
    _env.exitcode(1)
    _session.close()

class \nodoc\ _CheckDNSMarker is TimerNotify
  let _test: _StartupShutdownTest

  new iso create(test': _StartupShutdownTest) => _test = test'

  fun ref apply(timer: Timer, count: U64): Bool =>
    _test.check_marker()
    false

actor \nodoc\ _QueueDrainTest is (_TestStatusNotify &
  _TestResultReceiver)
  let _env: Env
  let _session: _TestSession
  var _failures: USize = 0
  var _first: Bool = false

  new create(auth: TCPConnectAuth, config: _Config, env: Env) =>
    _env = env
    _session = _TestSession(
      pg.ServerConnectInfo(auth, config.dbhost, config.dbport),
      pg.DatabaseConnectInfo(config.user, config.password, config.database),
      this)

  be pg_session_authenticated(session: _TestSession) =>
    session.execute(pg.PreparedQuery("SELECT pg_sleep(3)", _P.none()), this)
    let params: Array[pg.FieldDataTypes] val = [as pg.FieldDataTypes:
      "x\0y"]
    let rejected = pg.PreparedQuery("SELECT $1", params)
    for _ in Range(0, 40_000) do session.execute(rejected, this) end
    session.execute(pg.PreparedQuery("SELECT 1", _P.none()), this)

  be pg_query_result(session: _TestSession, result: pg.Result) =>
    let sql = try (result.query() as pg.PreparedQuery).string
      else "" end
    if (sql == "SELECT pg_sleep(3)") and not _first then
      _first = true
    elseif (sql == "SELECT 1") and _first and (_failures == 40_000) then
      _env.out.print("deep rejection queue drained")
      _session.close()
    else _fail("wrong queue result") end

  be pg_query_failed(session: _TestSession, query': pg.Query,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError))
  =>
    if (failure is pg.DataError) and (_failures < 40_000) then
      _failures = _failures + 1
    else _fail("wrong queue failure") end

  be pg_transaction_status(session: _TestSession,
    status: pg.TransactionStatus) =>
    if not (status is pg.TransactionIdle) then
      _fail("wrong queue transaction status")
    end

  be pg_session_connection_failed(session: _TestSession,
    reason: pg.ConnectionFailureReason)
  =>
    _fail("session connection failed")

  be pg_session_shutdown(session: _TestSession) => None

  fun ref _fail(message: String) =>
    _env.err.print(message)
    _env.exitcode(1)
    _session.close()

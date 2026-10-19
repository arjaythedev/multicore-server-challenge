use "net"
use pg = "postgres"

actor \nodoc\ _SessionBoundaryTest is (_TestStatusNotify &
  _TestPrepareReceiver & _TestResultReceiver)
  let _env: Env
  let _session: _TestSession
  var _stage: U8 = 0
  var _outcome: Bool = false

  new create(auth: TCPConnectAuth, config: _Config, env: Env) =>
    _env = env
    _session = _TestSession(
      pg.ServerConnectInfo(auth, config.dbhost, config.dbport),
      pg.DatabaseConnectInfo(config.user, config.password, config.database),
      this)

  be pg_session_authenticated(session: _TestSession) => None

  be pg_statement_prepared(session: _TestSession, name: String) =>
    if (_stage == 3) and (name == "boundary") then _outcome = true
    else _fail("unexpected preparation success") end

  be pg_prepare_failed(session: _TestSession, name: String,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError))
  =>
    if ((_stage == 1) or (_stage == 2)) and (failure is pg.DataError) then
      _outcome = true
    else _fail("unexpected preparation failure") end

  be pg_query_result(session: _TestSession, result: pg.Result) =>
    if (_stage == 6) or (_stage == 8) then _outcome = true
    else _fail("unexpected query success") end

  be pg_query_failed(session: _TestSession, query': pg.Query,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError))
  =>
    if ((_stage == 4) or (_stage == 5) or (_stage == 7)) and
      (failure is pg.DataError) then
      _outcome = true
    else _fail("unexpected query failure") end

  be pg_transaction_status(session: _TestSession,
    status: pg.TransactionStatus)
  =>
    if (_stage == 0) and (status is pg.TransactionIdle) then
      _stage = 1
      session.prepare("bad\0name", "SELECT 1", this)
      return
    end
    if not _outcome then
      _fail("missing operation outcome")
      return
    end
    _outcome = false
    if (_stage == 1) and (status is pg.TransactionIdle) then
      _stage = 2
      session.prepare("boundary", "SELECT 1\0SELECT 2", this)
    elseif (_stage == 2) and (status is pg.TransactionIdle) then
      _stage = 3
      session.prepare("boundary", "SELECT 1", this)
    elseif (_stage == 3) and (status is pg.TransactionIdle) then
      _stage = 4
      session.execute(pg.NamedPreparedQuery("boundary\0suffix", _P.none()),
        this)
    elseif (_stage == 4) and (status is pg.TransactionIdle) then
      _stage = 5
      session.execute(pg.PreparedQuery("SELECT 1\0SELECT 2", _P.none()), this)
    elseif (_stage == 5) and (status is pg.TransactionIdle) then
      _stage = 6
      session.execute(pg.PreparedQuery("BEGIN", _P.none()), this)
    elseif (_stage == 6) and (status is pg.TransactionInBlock) then
      _stage = 7
      let params: Array[pg.FieldDataTypes] val = [as pg.FieldDataTypes:
        "a\0b"]
      session.execute(pg.PreparedQuery("SELECT $1", params), this)
    elseif (_stage == 7) and (status is pg.TransactionInBlock) then
      _stage = 8
      session.execute(pg.PreparedQuery("ROLLBACK", _P.none()), this)
    elseif (_stage == 8) and (status is pg.TransactionIdle) then
      _env.out.print("session boundaries passed")
      _session.close()
    else
      _fail("wrong transaction status")
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

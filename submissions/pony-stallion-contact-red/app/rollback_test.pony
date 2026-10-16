use "net"
use pg = "postgres"

actor \nodoc\ _RollbackTest is (pg.SessionStatusNotify &
  pg.PrepareReceiver & pg.ResultReceiver)
  let _env: Env
  let _session: pg.Session
  var _stage: U8 = 0
  var _saw_division_error: Bool = false
  var _saw_rollback_result: Bool = false

  new create(auth: TCPConnectAuth, config: _Config, env: Env) =>
    _env = env
    _session = pg.Session(
      pg.ServerConnectInfo(auth, config.dbhost, config.dbport),
      pg.DatabaseConnectInfo(config.user, config.password, config.database),
      this)

  be pg_session_authenticated(session: pg.Session) =>
    session.prepare(_Catalog.name(_Rollback), _Catalog.sql(_Rollback), this)

  be pg_statement_prepared(session: pg.Session, name: String) =>
    if name != _Catalog.name(_Rollback) then
      fail("wrong prepared statement")
      return
    end
    _stage = 1
    session.execute(pg.PreparedQuery("BEGIN", _P.none()), this)

  be pg_prepare_failed(session: pg.Session, name: String,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError))
  =>
    fail("rollback preparation failed")

  be pg_query_result(session: pg.Session, result: pg.Result) =>
    if _stage == 3 then _saw_rollback_result = true end

  be pg_query_failed(session: pg.Session, query': pg.Query,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError))
  =>
    if _stage != 2 then
      fail("unexpected query failure")
      return
    end
    match failure
    | let f: pg.ErrorResponseMessage =>
      if f.code == "22012" then _saw_division_error = true
      else fail("wrong SQLSTATE " + f.code) end
    else
      fail("client query failure")
    end

  be pg_transaction_status(session: pg.Session,
    status: pg.TransactionStatus)
  =>
    if (_stage == 1) and (status is pg.TransactionInBlock) then
      _stage = 2
      session.execute(pg.PreparedQuery("SELECT 1/0", _P.none()), this)
    elseif (_stage == 2) and (status is pg.TransactionFailed) then
      if not _saw_division_error then
        fail("failed transaction without query error")
        return
      end
      _stage = 3
      session.execute(pg.NamedPreparedQuery(_Catalog.name(_Rollback),
        _P.none()), this)
    elseif (_stage == 3) and (status is pg.TransactionIdle) then
      if not _saw_rollback_result then
        fail("rollback returned no result")
        return
      end
      _stage = 4
      _env.out.print("named rollback after failed transaction passed")
      _session.close()
    end

  be pg_session_connection_failed(session: pg.Session,
    reason: pg.ConnectionFailureReason)
  =>
    fail("rollback test connection failed")

  fun ref fail(message: String) =>
    _env.err.print(message)
    _env.exitcode(1)
    _session.close()

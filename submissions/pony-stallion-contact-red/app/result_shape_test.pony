use "net"
use pg = "postgres"

actor \nodoc\ _ResultShapeTest is (_TestStatusNotify &
  _TestResultReceiver)
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

  be pg_query_result(session: _TestSession, result: pg.Result) =>
    if _stage != 2 then
      _fail("multidimensional array was accepted")
      return
    end
    try
      let rows = (result as pg.ResultSet).rows()
      let first = rows(0)?.fields(0)?.value as pg.PgTimestamp
      let second = rows(0)?.fields(1)?.value as pg.PgTimestamp
      if (first.microseconds == I64.max_value()) and
        (second.microseconds == I64.min_value()) then
        _outcome = true
      else _fail("wrong timestamp infinity values") end
    else _fail("wrong timestamp result shape") end

  be pg_query_failed(session: _TestSession, query': pg.Query,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError))
  =>
    if (_stage == 1) and (failure is pg.DataError) then
      _outcome = true
    else _fail("wrong result failure") end

  be pg_transaction_status(session: _TestSession,
    status: pg.TransactionStatus)
  =>
    if _stage == 0 then
      _stage = 1
      session.execute(pg.PreparedQuery(
        "SELECT ARRAY[['a','b'],['c','d']]::text[][]", _P.none()), this)
      return
    end
    if not _outcome or not (status is pg.TransactionIdle) then
      _fail("missing result outcome or wrong status")
      return
    end
    _outcome = false
    if _stage == 1 then
      _stage = 2
      session.execute(pg.PreparedQuery(
        "SELECT 'infinity'::timestamptz, '-infinity'::timestamp",
        _P.none()), this)
    elseif _stage == 2 then
      _env.out.print("result shapes passed")
      _session.close()
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

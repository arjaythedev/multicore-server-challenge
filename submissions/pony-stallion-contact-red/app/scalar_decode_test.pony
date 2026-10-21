use "net"
use "cli"
use pg = "postgres"

primitive \nodoc\ _DecodeError

class \nodoc\ val _ScalarDecodeCase
  let query: pg.PreparedQuery
  let expected: (pg.FieldData | _DecodeError)

  new val scalar(vars: (Array[String] val | None)) ? =>
    let e = EnvVars(vars)
    let oid = e("CONDUIT_TEST_DECODE_OID")?.u32()?
    let sql_type = match oid
      | 20 => "bigint"
      | 21 => "smallint"
      | 23 => "integer"
      | 16 => "boolean"
      | 1114 => "timestamp"
      | 1184 => "timestamptz"
      else error
      end
    let source = match oid
      | 16 => "true"
      | 1114 | 1184 => "'2000-01-01 00:00:00'"
      else "1"
      end
    query = pg.PreparedQuery("SELECT " + source + "::" + sql_type, _P.none())
    let value = e("CONDUIT_TEST_DECODE_VALUE")?
    expected = match e("CONDUIT_TEST_DECODE_KIND")?
      | "i64" => value.i64()?
      | "i32" => value.i32()?
      | "timestamp" => pg.PgTimestamp(value.i64()?)
      | "bool" =>
        match value
        | "true" => true
        | "false" => false
        else error
        end
      | "none" => None
      | "error" => _DecodeError
      else error
      end

  new val atomic(vars: (Array[String] val | None)) ? =>
    let name = EnvVars(vars)("CONDUIT_TEST_DECODE_ATOMIC_CASE")?
    let expression = match name
      | "integer-late-column" | "integer-late-row" => "11::bigint"
      | "timestamp-late-column" | "timestamp-late-row" =>
        "'2000-01-01 00:00:00'::timestamp"
      else error
      end
    query = pg.PreparedQuery(
      "SELECT label, NULL::text, value FROM (VALUES (1, 'first'::text, "
        + expression + "), (2, 'second'::text, " + expression
        + ")) AS source(id, label, value) ORDER BY id", _P.none())
    expected = _DecodeError

actor \nodoc\ _ScalarDecodeTest is (_TestStatusNotify &
  _TestResultReceiver & _TestStartReceiver)
  let _env: Env
  let _session: _TestSession
  let _case: _ScalarDecodeCase
  let _following: pg.PreparedQuery =
    pg.PreparedQuery("SELECT 73::bigint", _P.none())
  var _stage: U8 = 0
  var _results: USize = 0
  var _failures: USize = 0
  var _completions: USize = 0
  var _closed: Bool = false

  new create(auth: TCPConnectAuth, config: _Config, env: Env,
    case': _ScalarDecodeCase)
  =>
    _env = env
    _case = case'
    _session = _TestSession(
      pg.ServerConnectInfo(auth, config.dbhost, config.dbport),
      pg.DatabaseConnectInfo(config.user, config.password, config.database),
      this)

  be pg_session_authenticated(session: _TestSession) => None

  be pg_query_result(session: _TestSession, result: pg.Result) =>
    if _closed then return end
    try
      _assert((_stage == 1) or (_stage == 2))?
      _assert((_results + _failures) == 0)?
      let set = result as pg.ResultSet
      _assert(set.query() is (if _stage == 1 then _case.query
        else _following end))?
      _assert(set.rows().size() == 1)?
      let row = set.rows()(0)?
      _assert(row.fields.size() == 1)?
      if _stage == 1 then
        match _case.expected
        | _DecodeError => error
        | let expected: pg.FieldData =>
          _DecodedValueTest(row.fields(0)?, expected, _env)?
        end
      else
        _DecodedValueTest(row.fields(0)?, I64(73), _env)?
      end
      _results = _results + 1
    else _fail("wrong scalar result") end

  be pg_query_failed(session: _TestSession, query': pg.Query,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError))
  =>
    if _closed then return end
    try
      _assert(_stage == 1)?
      _assert((_results + _failures) == 0)?
      _assert(query' is _case.query)?
      _assert(_case.expected is _DecodeError)?
      _assert(failure is pg.DataError)?
      _failures = _failures + 1
    else _fail("wrong scalar failure") end

  be pg_transaction_status(session: _TestSession,
    status: pg.TransactionStatus)
  =>
    if _closed then return end
    try
      _assert(status is pg.TransactionIdle)?
      if _stage == 0 then
        _assert(_completions == 0)?
        _stage = 1
        session.execute(_case.query, this)
        return
      end
      _assert((_stage == 1) or (_stage == 2))?
      let failed = (_stage == 1) and (_case.expected is _DecodeError)
      _assert(_results == (if failed then USize(0) else 1 end))?
      _assert(_failures == (if failed then USize(1) else 0 end))?
      _completions = _completions + 1
      _assert(_completions == _stage.usize())?
      if _stage == 1 then
        _stage = 2
        _results = 0
        _failures = 0
        session.execute(_following, this)
      else
        _stage = 3
        session.native_starts(this)
      end
    else _fail("wrong scalar completion") end

  be pg_native_starts(session: _TestSession, count: U64) =>
    if _closed then return end
    try
      _assert(_stage == 3)?
      _assert(count == 1)?
      _assert(_completions == 2)?
      _env.out.print("scalar decoding and recovery passed")
      _closed = true
      _session.close()
    else _fail("wrong scalar connection count") end

  be pg_session_connection_failed(session: _TestSession,
    reason: pg.ConnectionFailureReason)
  =>
    _fail("scalar session connection failed")

  be pg_session_shutdown(session: _TestSession) =>
    if not _closed then _fail("scalar session shut down") end

  fun _assert(condition: Bool, loc: SourceLoc = __loc) ? =>
    if not condition then
      _env.err.print(loc.file() + ":" + loc.line().string()
        + ": scalar assertion failed")
      error
    end

  fun ref _fail(message: String) =>
    _closed = true
    _env.err.print(message)
    _env.exitcode(1)
    _session.close()

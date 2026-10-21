use "net"
use pg = "postgres"

actor \nodoc\ _ResultShapeTest is (_TestStatusNotify &
  _TestResultReceiver)
  let _env: Env
  let _session: _TestSession
  var _stage: U8 = 0
  var _outcome: Bool = false
  var _completions: USize = 0
  var _retained: (pg.Rows | None) = None
  var _replacement: (pg.Rows | None) = None
  var _query: (pg.Query | None) = None
  var _closed: Bool = false

  new create(auth: TCPConnectAuth, config: _Config, env: Env) =>
    _env = env
    _session = _TestSession(
      pg.ServerConnectInfo(auth, config.dbhost, config.dbport),
      pg.DatabaseConnectInfo(config.user, config.password, config.database),
      this)

  be pg_session_authenticated(session: _TestSession) => None

  be pg_query_result(session: _TestSession, result: pg.Result) =>
    if _closed then return end
    try
      _assert(not _outcome)?
      let set = result as pg.ResultSet
      _assert(set.query() is _query)?
      let rows = set.rows()
      match _stage
      | 2 =>
        _row(rows, [as pg.FieldData: pg.PgTimestamp(I64.max_value())
          pg.PgTimestamp(I64.min_value())])?
      | 3 => _retained = rows
      | 4 => _replacement = rows
      | 5 => _assert(rows.size() == 0)?
      else error
      end
      _outcome = true
    else _fail("wrong result shape") end

  be pg_query_failed(session: _TestSession, query': pg.Query,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError))
  =>
    if _closed then return end
    try
      _assert(_stage == 1)?
      _assert(not _outcome)?
      _assert(query' is _query)?
      _assert(failure is pg.DataError)?
      _outcome = true
    else _fail("wrong result failure") end

  be pg_transaction_status(session: _TestSession,
    status: pg.TransactionStatus)
  =>
    if _closed then return end
    try
      _assert(status is pg.TransactionIdle)?
      if _stage == 0 then
        _execute("SELECT ARRAY[['a','b'],['c','d']]::text[][]")
        return
      end
      _assert(_outcome)?
      _completions = _completions + 1
      _assert(_completions == _stage.usize())?
      match _stage
      | 1 =>
        _execute("SELECT 'infinity'::timestamptz, '-infinity'::timestamp")
      | 2 => _execute(_sql())
      | 3 =>
        _retained_values()?
        _execute("SELECT repeat('z',8192), ARRAY[repeat('q',8192)]")
      | 4 =>
        _retained_values()?
        let text: String val = "z".repeat_str(8192)
        let element: String val = "q".repeat_str(8192)
        _row(_replacement as pg.Rows, [as pg.FieldData: text
          pg.PgArray(25, [as pg.FieldData: element])])?
        _execute("SELECT 1::bigint WHERE false")
      | 5 =>
        _assert(_completions == 5)?
        _env.out.print("result shapes passed")
        _closed = true
        _session.close()
      else error
      end
    else _fail("missing result outcome or wrong status") end

  fun ref _execute(sql: String) =>
    _stage = _stage + 1
    _outcome = false
    let query' = pg.PreparedQuery(sql, _P.none())
    _query = query'
    _session.execute(query', this)

  fun _retained_values() ? =>
    _row(_retained as pg.Rows, [as pg.FieldData:
      I64.min_value(); I64.max_value(); I64(0); I64(-1); None
      I32.min_value(); I32.max_value(); I32(0); I32(-1); None
      I32(-32768); I32(32767); I32(0); I32(-1); None
      true; false; None; ""; "héllo 雪"; None
      "123e4567-e89b-12d3-a456-426614174000"
      pg.PgTimestamp(0); pg.PgTimestamp(-1); pg.PgTimestamp(1)
      pg.PgTimestamp(100000); pg.PgTimestamp(I64.max_value())
      pg.PgTimestamp(I64.min_value()); None
      pg.PgTimestamp(0); pg.PgTimestamp(-1); pg.PgTimestamp(1)
      pg.PgTimestamp(100000); pg.PgTimestamp(I64.max_value())
      pg.PgTimestamp(I64.min_value()); None
      pg.PgArray(25, recover val Array[pg.FieldData] end)
      pg.PgArray(25, [as pg.FieldData: "héllo"; ""; None; "NULL"
        "comma,value"; "quote\""; "back\\slash"; "{braces}"])])?

  fun _row(rows: pg.Rows, expected: Array[pg.FieldData] val) ? =>
    _assert(rows.size() == 1)?
    let row = rows(0)?
    _assert(row.fields.size() == expected.size())?
    for (index, value) in expected.pairs() do
      _DecodedValueTest(row.fields(index)?, value, _env)?
    end

  fun _sql(): String =>
    "SELECT '-9223372036854775808'::bigint, "
      + "'9223372036854775807'::bigint, 0::bigint, -1::bigint, NULL::bigint, "
      + "'-2147483648'::integer, 2147483647::integer, 0::integer, "
      + "-1::integer, NULL::integer, '-32768'::smallint, 32767::smallint, "
      + "0::smallint, -1::smallint, NULL::smallint, true, false, "
      + "NULL::boolean, ''::text, 'héllo 雪'::text, NULL::text, "
      + "'123e4567-e89b-12d3-a456-426614174000'::uuid, "
      + "'2000-01-01 00:00:00'::timestamp, "
      + "'1999-12-31 23:59:59.999999'::timestamp, "
      + "'2000-01-01 00:00:00.000001'::timestamp, "
      + "'2000-01-01 00:00:00.1'::timestamp, 'infinity'::timestamp, "
      + "'-infinity'::timestamp, NULL::timestamp, "
      + "'2000-01-01 00:00:00+00'::timestamptz, "
      + "'1999-12-31 23:59:59.999999+00'::timestamptz, "
      + "'2000-01-01 00:00:00.000001+00'::timestamptz, "
      + "'2000-01-01 00:00:00.1+00'::timestamptz, "
      + "'infinity'::timestamptz, '-infinity'::timestamptz, "
      + "NULL::timestamptz, ARRAY[]::text[], ARRAY['héllo', '', NULL, "
      + "'NULL', 'comma,value', 'quote'||chr(34), "
      + "'back'||chr(92)||'slash', '{braces}']"

  fun _assert(condition: Bool, loc: SourceLoc = __loc) ? =>
    if not condition then
      _env.err.print(loc.file() + ":" + loc.line().string()
        + ": result shape assertion failed")
      error
    end

  be pg_session_connection_failed(session: _TestSession,
    reason: pg.ConnectionFailureReason)
  =>
    _fail("session connection failed")

  be pg_session_shutdown(session: _TestSession) =>
    if not _closed then _fail("result shape session shut down") end

  fun ref _fail(message: String) =>
    _closed = true
    _env.err.print(message)
    _env.exitcode(1)
    _session.close()

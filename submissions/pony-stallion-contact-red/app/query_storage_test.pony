use "cli"
use "collections"
use "net"
use pg = "postgres"
use "time"
use "lib:dl"

use @conduit_query_storage_read[I64](record: U32, field: U32)
use @conduit_query_storage_registered[I32](address: USize)
use @conduit_query_storage_final[None]()
use @conduit_query_storage_final_count[USize]()
use @pony_ctx[Pointer[None]]()
use @pony_triggergc[None](ctx: Pointer[None])

class \nodoc\ val _StorageOptions
  let mode: String
  let named: Bool
  let count: USize
  let scenario: U32
  let marker: String
  let control: String

  new val create(vars: (Array[String] val | None)) ? =>
    let e = EnvVars(vars)
    mode = e("CONDUIT_QUERY_CASE")?
    match mode
    | "boundary" | "fresh" | "property" | "send0" | "flush-error"
    | "writing" | "replacement" | "reject-writing" | "reject-reading"
    | "pending" | "root" | "validate" | "close-result"
    | "close-failure" | "close-completion" => None
    else error
    end
    named = match e("CONDUIT_QUERY_API")?
      | "plain" => false
      | "named" => true
      else error
      end
    count = e("CONDUIT_QUERY_COUNT")?.usize()?
    if (count != 1) and (count != 3) and (count != 9) then error end
    scenario = e("CONDUIT_QUERY_SCENARIO")?.u32()?
    let expected: U32 = match mode
      | "send0" => 1
      | "flush-error" => 2
      | "writing" => 3
      | "replacement" => 4
      | "reject-writing" => 5
      | "reject-reading" => 6
      | "pending" => 7
      | "root" => 8
      | "validate" | "close-failure" => 9
      | "close-result" => 10
      | "close-completion" => 12
      else 0
      end
    if scenario != expected then error end
    marker = e("CONDUIT_QUERY_MARKER")?
    if (marker.size() == 0) or marker.contains("\0") then error end
    control = try e("CONDUIT_QUERY_ROOT_CONTROL")? else "clear" end
    if (control != "clear") and (control != "held") and
      (control != "never") then error end
    if scenario != 0 then
      if @conduit_query_storage_read(U32.max_value(), 0) != 1 then error end
      if @conduit_query_storage_read(U32.max_value(), 1) != 0 then error end
      if @conduit_query_storage_read(U32.max_value(), 2) != 0 then error end
      if @conduit_query_storage_read(U32.max_value(), 3) != scenario.i64()
        then error end
      if @conduit_query_storage_read(0, 0) != I64.min_value() then error end
      if @conduit_query_storage_read(U32.max_value(), 4) !=
        I64.min_value() then error end
    end

class \nodoc\ val _StorageInput
  let params: Array[pg.FieldDataTypes] val
  let expected: Array[(String | None)] val
  let sql: String

  new val create(count: USize, variant: USize, token: String,
    large: Bool = false)
  =>
    let values = recover iso Array[pg.FieldDataTypes] end
    let outputs = recover iso Array[(String | None)] end
    let text = recover iso String end
    text.append("SELECT ")
    if count == 0 then text.append("'zero'::text") end
    for p in Range[USize](0, count) do
      let descriptor = if large or (variant == 103) then
        if p == 0 then USize(2) elseif p == 1 then 0
        elseif p == 2 then 1 else 2 end
      elseif variant == 102 then if p == 7 then USize(2) else p end
      elseif variant == 100 then USize(2)
      elseif variant == 101 then USize(0)
      else (p + variant) % 7 end
      match descriptor
      | 0 => values.push(None); outputs.push(None)
      | 1 => values.push(""); outputs.push("")
      | 2 =>
        let s: String val = if large and (p == 0) then
          "x".repeat_str(16 * 1024 * 1024)
        else token + ":" + p.string() end
        values.push(s)
        outputs.push(s)
      | 3 => values.push(I32.min_value()); outputs.push("-2147483648")
      | 4 => values.push(I32.max_value()); outputs.push("2147483647")
      | 5 => values.push(I64.min_value())
        outputs.push("-9223372036854775808")
      | 6 => values.push(I64.max_value())
        outputs.push("9223372036854775807")
      end
      if p > 0 then text.append(", ") end
      let parameter: String val = "$" + (p + 1).string() + "::text"
      if large and (p == 0) then
        text.append("md5(" + parameter + ")")
      else text.append(parameter) end
      text.append(", (" + parameter + ") IS NULL, length(" + parameter
        + ")")
    end
    params = consume values
    expected = consume outputs
    sql = consume text

class \nodoc\ _StorageSentinel
  fun _final() => @conduit_query_storage_final()

actor \nodoc\ _QueryStorageTest is (AsioEventNotify & _PGOwner)
  let _env: Env
  let _options: _StorageOptions
  let _server: pg.ServerConnectInfo
  let _database: pg.DatabaseConnectInfo
  embed _events: _PGEvents
  var _connection: (_PGConnection | None) = None
  var _target: (_PGConnection | None) = None
  var _recovering: Bool = false
  var _input: (_StorageInput | None) = None
  var _query: (pg.Query | None) = None
  var _command: (_PGCommand box | None) = None
  var _old: (_PGCommand box | None) = None
  var _old_value: (pg.Query | (String, String) | None) = None
  var _old_started: U64 = 0
  var _old_seen: Bool = false
  var _started: U64 = 0
  var _replacement: Bool = false
  var _replacement_records: I64 = 0
  var _preparing: Bool = false
  var _prepared: Bool = false
  var _bootstrap: Bool = false
  var _selected_prepared: Bool = false
  var _preparing_selected: Bool = false
  var _step: USize = 0
  var _results: USize = 0
  var _failures: USize = 0
  var _completions: USize = 0
  var _shutdowns: USize = 0
  var _expected_shutdown: Bool = false
  var _failed: Bool = false
  var _done: Bool = false
  var _warm: (USize, USize) = (0, 0)
  var _address: USize = 0
  var _held: (String | None) = None
  var _witnesses: USize = 0
  var _final_count: USize = 0
  var _released: Bool = false
  embed _sentinels: Array[_StorageSentinel] = Array[_StorageSentinel]
  embed _buckets: Map[USize, USize] = Map[USize, USize]
  embed _payloads: Set[String] = Set[String]
  embed _demands: Set[USize] = Set[USize]
  embed _descriptors: Set[USize] = Set[USize]
  embed _counts: Array[USize] = Array[USize].init(0, 10)
  var _retained_sends: USize = 0
  var _fallback_sends: USize = 0
  var _eight_nine: USize = 0
  var _nine_one: USize = 0
  var _last_count: USize = 0
  var _selected: Bool = false
  var _metric_active: Bool = false
  var _metric_local: Bool = false
  var _metric_starts: U64 = 0
  var _metric_terminals: U64 = 0
  var _metric_failures: U64 = 0
  var _metric_shutdowns: U64 = 0
  var _metric_native: U64 = 0
  var _metric_decode: U64 = 0
  var _metric_lifetime: U64 = 0
  var _metric_flush_base: U64 = 0
  var _metric_track_flush: Bool = false

  new create(auth: TCPConnectAuth, config: _Config, env: Env,
    options: _StorageOptions)
  =>
    _env = env
    _options = options
    _server = pg.ServerConnectInfo(auth, config.dbhost, config.dbport)
    _database = pg.DatabaseConnectInfo(config.user, config.password,
      config.database)
    _events = _PGEvents(this)
    let connection = _PGConnection(this, _events, 0, 0)
    _connection = connection
    connection.start(_server, _database)

  be _event_notify(event: AsioEventID, flags: U32, arg: U32) =>
    _events.notify(event, flags)
    if not _metrics() then return end
    if _failed or _done or _expected_shutdown then return end
    try
      _empty()?
      if _replacement then
        _assert(_conn()?.phase_code() == 3)?
        _assert(_conn()?._test_writing())?
        _assert(_conn()?._test_command() is _command)?
        _assert(_ledger_count() == _replacement_records)?
        _old_unchanged()?
        _replacement = false
      end
      _active()?
      _reject_if_reading()?
    else _fail("event-return state") end

  fun ref pg_ready(connection: _PGConnection ref) =>
    if not _metrics() then return end
    try
      _assert(connection is _connection)?
      _assert(connection.phase_code() == 2)?
      _assert(connection._test_send_storage()._3 == 0)?
      _assert(connection._test_send_storage()._4 == 0)?
      if _recovering then
        let input = _StorageInput(0, 0, "recovery")
        _input = input
        _query = pg.PreparedQuery(input.sql, input.params)
        _execute()?
      elseif _options.named and (_options.mode == "replacement") then
        _bootstrap = true
        _preparing = true
        _preparing_selected = true
        if not _starting(true) then return end
        connection.prepare(_options.marker,
          _StorageInput(_options.count, 0, "bootstrap").sql)
      else _next()? end
    else _fail("ready state") end

  fun ref _next() ? =>
    _results = 0
    _failures = 0
    _prepared = false
    _command = None
    let mode = _options.mode
    let count = if mode == "boundary" then
      [as USize: 0; 1; 8; 8; 8; 9; 16; 3; 1; 0; 1; 1; 1; 1; 1; 1; 1](
        _step)?
    elseif mode == "fresh" then [as USize: 9; 8; 0](_step)?
    elseif mode == "property" then
      if _step == 0 then USize(8) else ((_step - 1) % 9) + 1 end
    elseif (mode == "pending") and (_step > 0) then
      if _step == 1 then USize(1) else 0 end
    else _options.count end
    let variant = if (mode == "fresh") or
      ((mode == "property") and (_step == 0)) or
      ((mode == "boundary") and
        ((_step == 2) or (_step == 5) or (_step == 6))) then USize(100)
    elseif (mode == "boundary") and (_step == 3) then USize(101)
    elseif (mode == "boundary") and (_step == 4) then USize(102)
    elseif mode == "property" then (_step - 1) / 9
    elseif (mode == "boundary") and (_step >= 10) then _step - 10
    elseif _options.scenario != 0 then USize(103)
    else _step % 7 end
    let token: String val = if (mode == "property") and (_step > 0) then
      (if _options.named then "n" else "p" end) + ":" + variant.string()
        + ":" + count.string()
    else _options.named.string() + ":" + _step.string() end
    let input = _StorageInput(count, variant, token,
      ((mode == "pending") and (_step == 0)) or (mode == "root"))
    _input = input
    let selected = (_options.scenario != 0) and
      ((mode != "replacement") or (_step == 1)) and
      ((mode != "pending") or (_step == 0)) and
      ((mode != "validate") or ((_step % 2) == 0))
    _selected = selected
    let name: String val = if selected then _options.marker
      else "storage_" + _step.string() end
    let sql: String val = input.sql + if selected and not _options.named
      then " /*storage*/" else "" end
    let actual_sql = if selected and not _options.named then
      _options.marker else sql end
    _query = if _options.named then pg.NamedPreparedQuery(name, input.params)
      else pg.PreparedQuery(actual_sql, input.params) end
    if mode == "root" then
      let source = input.params(0)? as String
      _address = source.cpointer().usize()
      _assert(@conduit_query_storage_registered(_address) == 1)?
      if _options.control == "held" then _held = source end
      if _options.control == "never" then
        _query = pg.PreparedQuery(_options.marker,
          [as pg.FieldDataTypes: "never-target"])
      end
    end
    if ((mode == "validate") and ((_step % 2) == 0)) or
      (mode == "close-failure") then
      if (_step == 8) or (_step == 10) then
        _preparing = false
        if not _starting(false) then return end
        if _step == 8 then
          _conn()?.prepare("invalid\0name", "SELECT 1")
        else _conn()?.prepare("invalid_sql", "SELECT\0invalid") end
        return
      end
      _query = match _step
        | 0 => pg.PreparedQuery(_options.marker + "\0invalid", input.params)
        | 2 =>
          let bad: Array[pg.FieldDataTypes] val = [as pg.FieldDataTypes:
            "invalid\0value"]
          if _options.named then pg.NamedPreparedQuery(name, bad)
          else pg.PreparedQuery(_options.marker, bad) end
        | 4 =>
          let bad: Array[pg.FieldDataTypes] val = [as pg.FieldDataTypes:
            pg.PgArray(25, [as pg.FieldData: "unsupported"])]
          if _options.named then pg.NamedPreparedQuery(name, bad)
          else pg.PreparedQuery(_options.marker, bad) end
        else
          if _options.named then
            pg.NamedPreparedQuery(name + "\0invalid", input.params)
          else pg.PreparedQuery(_options.marker + "\0invalid", input.params)
          end
        end
    end
    if _options.named and not (selected and _selected_prepared) then
      _preparing = true
      _preparing_selected = selected
      if not _starting(true) then return end
      _conn()?.prepare(name, input.sql)
    else _execute()?
    end

  fun ref pg_prepared(connection: _PGConnection ref) =>
    if not _metrics() then return end
    try
      _empty()?
      _assert(_preparing)?
      _assert(not _prepared)?
      _prepared = true
      if _preparing_selected then _selected_prepared = true end
    else _fail("prepare callback") end

  fun ref _execute() ? =>
    let step = _step
    let query' = _query as pg.Query
    if not _recovering and ((_options.mode == "send0") or
      (_options.mode == "flush-error") or (_options.mode == "root")) then
      _expected_shutdown = true
    end
    if not _starting(not (((_options.mode == "validate") and
      ((_step % 2) == 0)) or (_options.mode == "close-failure")), _selected)
    then return end
    _conn()?.execute(query')
    if not _metrics() then return end
    _empty()?
    if (_step != step) or _preparing then return end
    if _expected_shutdown then
      _closed()?
      if _options.mode == "root" then
        _input = None
        _query = None
        _command = None
        _old = None
        if _options.control == "never" then _conn()?.close() end
        _witness()
      elseif (_options.mode == "send0") or
        (_options.mode == "flush-error") then _recover()?
      else this._finish() end
      return
    end
    if (_options.mode == "boundary") or (_options.mode == "fresh") or
      (_options.mode == "property") then _capacity()? end
    _command = _conn()?._test_command()
    _assert(_command isnt None)?
    _started = (_command as _PGCommand box).started
    _active()?
    if (_options.mode == "reject-writing") then
      _assert(_conn()?.phase_code() == 3)?
      _reject()?
    end

  fun ref pg_result(connection: _PGConnection ref, result: pg.Result) =>
    if _failed then return end
    if not _metrics() then return end
    try
      _empty()?
      _assert(connection.phase_code() == 4)?
      _assert((connection._test_command() as _PGCommand box).seen)?
      _assert(not _preparing)?
      _assert((_results + _failures) == 0)?
      let set = result as pg.ResultSet
      _assert(set.query() is _query)?
      let rows = set.rows()
      _assert(rows.size() == 1)?
      let fields = rows(0)?.fields
      let input = _input as _StorageInput
      _assert(fields.size() == if input.params.size() == 0 then USize(1)
        else input.params.size() * 3 end)?
      if input.params.size() == 0 then
        _assert((fields(0)? as String) == "zero")?
      end
      for (p, expected) in input.expected.pairs() do
        _assert((fields((p * 3) + 1)? as Bool) == (expected is None))?
        match expected
        | None =>
          _assert(fields(p * 3)? is None)?
          _assert(fields((p * 3) + 2)? is None)?
        | let text: String =>
          let large = (_options.mode == "pending") and (_step == 0)
            and (p == 0)
          _assert((fields(p * 3)? as String) == if large then
            "d4760a6c6500b8c7fbb09e4c65bc558a" else text end)?
          _assert((fields((p * 3) + 2)? as I32).usize() == text.size())?
        end
      end
      _results = _results + 1
      if _options.mode == "replacement" then
        if _step == 0 then
          _old = connection._test_command()
          let old = _old as _PGCommand box
          _old_value = old.value
          _old_started = old.started
          _old_seen = old.seen
        end
      end
      if _options.mode == "close-result" then
        _expected_shutdown = true
        connection.close()
        _closed()?
        this._finish()
      end
      _metric_decode = _metric_decode + 1
    else _fail("result values") end

  fun ref pg_failed(connection: _PGConnection ref,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError))
  =>
    if _failed then return end
    _metric_active = false
    _metric_local = true
    _metric_lifetime = _metric_lifetime + 1
    if not _metrics() then return end
    try
      _empty()?
      _assert((_options.mode == "validate") or
        (_options.mode == "close-failure"))?
      _assert(failure is pg.DataError)?
      _assert(connection.phase_code() == 2)?
      _assert(connection._test_command() is None)?
      _assert((_results + _failures) == 0)?
      _failures = _failures + 1
      if _options.mode == "close-failure" then
        _expected_shutdown = true
        connection.close()
        _closed()?
        this._finish()
      end
      _metric_terminals = _metric_terminals + 1
      _metric_failures = _metric_failures + 1
    else _fail("failure callback") end

  fun ref pg_complete(connection: _PGConnection ref,
    status: pg.TransactionStatus)
  =>
    if _failed then return end
    _metric_active = false
    if not _metric_local then
      _metric_terminals = _metric_terminals + 1
      _metric_lifetime = _metric_lifetime + 1
    end
    _metric_local = false
    if not _metrics() then return end
    try
      _empty()?
      _assert(status is pg.TransactionIdle)?
      _assert(connection.phase_code() == 2)?
      _assert(connection._test_command() is None)?
      if _preparing then
        _assert(_prepared)?
        _preparing = false
        if _bootstrap then
          _bootstrap = false
          _next()?
        else _execute()? end
        return
      end
      let invalid = (_options.mode == "validate") and ((_step % 2) == 0)
      _assert(_results == (if invalid then USize(0) else 1 end))?
      _assert(_failures == (if invalid then USize(1) else 0 end))?
      _completions = _completions + 1
      if _recovering then
        let target = _target as _PGConnection
        _assert(target.phase_code() == 5)?
        _assert(target._test_command() is None)?
        _assert(target._test_send_storage()._1 == 0)?
        _assert(target._test_send_storage()._2 == 0)?
        _assert(_completions == 1)?
        _expected_shutdown = true
        connection.close()
        this._finish()
        return
      end
      _capacity()?
      _property()?
      let mode = _options.mode
      let total: USize = match mode
        | "boundary" => 17
        | "fresh" | "pending" => 3
        | "property" => 64
        | "replacement" => 2
        | "validate" => 12
        else 1
        end
      _step = _step + 1
      if _step < total then
        _next()?
        if (mode == "replacement") and (_step == 1) then
          _assert(connection.phase_code() == 3)?
          _assert(connection._test_writing())?
          _assert(connection._test_command() is _command)?
          _assert(_command isnt _old)?
          _old_unchanged()?
          _replacement_records = _ledger_count()
          _replacement = true
        end
      else
        if mode == "property" then
          _assert(_buckets.size() == 315)?
          _assert(_payloads.size() == 45)?
          _assert(_descriptors.size() == 7)?
          _assert(_retained_sends == 56)?
          _assert(_fallback_sends == 7)?
          _assert(_eight_nine == 7)?
          _assert(_nine_one == 6)?
          _assert(_completions == 64)?
          for count in Range[USize](1, 10) do
            _assert(_counts(count)? == 7)?
          end
          for demand in [as USize: 16; 17; 134; 135].values() do
            _assert(_demands.contains(demand))?
          end
        end
        _expected_shutdown = true
        connection.close()
        this._finish()
      end
    else _fail("completion callback") end

  fun ref _capacity() ? =>
    let storage = _conn()?._test_send_storage()
    let mode = _options.mode
    if (mode == "fresh") and (_step == 0) then
      _assert(storage._3 == 0)?
      _assert(storage._4 == 0)?
    elseif (mode == "pending") and (_step == 0) and
      (_options.count == 9) then
      _assert(storage._3 == 0)?
      _assert(storage._4 == 0)?
    elseif (mode == "pending") and ((_step == 0) or
      ((_step == 1) and (_warm._1 == 0))) then
      _assert(storage._3 > 0)?
      _assert(storage._4 > 0)?
      _warm = (storage._3, storage._4)
    elseif ((mode == "fresh") and (_step == 1)) or
      ((mode == "property") and (_step == 0)) or
      ((mode == "boundary") and (_step == 2)) then
      _assert(storage._3 > 0)?
      _assert(storage._4 > 0)?
      _warm = (storage._3, storage._4)
    elseif (_warm._1 > 0) then
      _assert(storage._3 == _warm._1)?
      _assert(storage._4 == _warm._2)?
    elseif (mode == "boundary") and (_step == 0) then
      _assert(storage._3 == 0)?
      _assert(storage._4 == 0)?
    end

  fun ref _property() ? =>
    if (_options.mode != "property") or (_step == 0) then return end
    let count = ((_step - 1) % 9) + 1
    let rotation = (_step - 1) / 9
    let input = _input as _StorageInput
    _counts(count)? = _counts(count)? + 1
    if count <= 8 then _retained_sends = _retained_sends + 1
    else _fallback_sends = _fallback_sends + 1 end
    if (_last_count == 8) and (count == 9) then
      _eight_nine = _eight_nine + 1
    elseif (_last_count == 9) and (count == 1) then
      _nine_one = _nine_one + 1
    end
    _last_count = count
    var roots: USize = 0
    for p in Range[USize](0, count) do
      let descriptor = (p + rotation) % 7
      _descriptors.set(descriptor)
      if descriptor != 0 then roots = roots + 1 end
      let key = (((count * 10) + p) * 7) + descriptor
      _assert(not _buckets.contains(key))?
      _buckets(key) = 1
      if descriptor == 2 then
        let text = input.expected(p)? as String
        _assert(not _payloads.contains(text))?
        _payloads.set(text)
      end
    end
    _demands.set((count * 16) + roots)

  fun ref _active() ? =>
    if _command is None then return end
    _assert(_conn()?._test_command() is _command)?
    let command = _command as _PGCommand box
    _assert(command.value is _query)?
    _assert(command.started == _started)?
    let code = _conn()?.phase_code()
    _assert((code == 3) or (code == 4))?
    _assert(_conn()?._test_writing() == (code == 3))?
    if code == 3 then _assert(not command.seen)? end

  fun ref _reject_if_reading() ? =>
    if (_options.mode == "reject-reading") and not _preparing and
      (_command isnt None) and
      (_conn()?.phase_code() == 4) then
      _assert(not (_conn()?._test_command() as _PGCommand box).seen)?
      _reject()?
    end

  fun ref _reject() ? =>
    let before = _ledger_count()
    let input = _input as _StorageInput
    let params = recover iso Array[pg.FieldDataTypes] end
    params.append(input.params)
    try params(0)? = "second query"
    else _Unreachable() end
    let different: Array[pg.FieldDataTypes] val = consume params
    let second: pg.Query = if _options.named then
      pg.NamedPreparedQuery(_options.marker, different)
    else pg.PreparedQuery(_options.marker, different) end
    _old = _command
    let old = _old as _PGCommand box
    _old_value = old.value
    _old_started = old.started
    _old_seen = old.seen
    _expected_shutdown = true
    _conn()?.execute(second)
    _closed()?
    _old_unchanged()?
    _assert(_ledger_count() == before)?
    _assert(_results == 0)?
    _assert(_failures == 0)?
    _assert(_completions == 0)?
    _command = None
    this._finish()

  fun _old_unchanged() ? =>
    let old = _old as _PGCommand box
    _assert(old.value is _old_value)?
    _assert(old.started == _old_started)?
    _assert(old.seen == _old_seen)?

  fun ref _empty() ? =>
    let storage = _conn()?._test_send_storage()
    _assert(storage._1 == 0)?
    _assert(storage._2 == 0)?

  fun ref _closed() ? =>
    _assert(_conn()?.phase_code() == 5)?
    _assert(_conn()?._test_command() is None)?
    _assert(_shutdowns == 1)?
    _empty()?

  fun ref pg_shutdown(connection: _PGConnection ref) =>
    _shutdowns = _shutdowns + 1
    _command = None
    if _failed then return end
    if _metric_active then
      _metric_terminals = _metric_terminals + 1
      _metric_lifetime = _metric_lifetime + 1
      _metric_active = false
    end
    _metric_shutdowns = _metric_shutdowns + 1
    if not _metrics() then return end
    try
      _assert(_expected_shutdown)?
      _closed()?
    else _fail("shutdown callback") end

  fun ref _witness() =>
    _final_count = @conduit_query_storage_final_count()
    _sentinels.push(_StorageSentinel)
    _sentinels.clear()
    @pony_triggergc(@pony_ctx())
    this._collected()

  be _collected() =>
    if _failed then return end
    try
      _closed()?
      let finalized = @conduit_query_storage_final_count()
      _assert(finalized > _final_count)?
      _witnesses = _witnesses + 1
      let registered = @conduit_query_storage_registered(_address) == 1
      if _options.control == "held" then _assert(registered)?
      elseif not registered then _released = true end
      if _witnesses < 9 then _witness()
      else
        if _options.control != "held" then _assert(_released)? end
        _held = None
        this._finish()
      end
    else _fail("root-release witness") end

  fun _ledger_count(): I64 =>
    @conduit_query_storage_read(U32.max_value(), 1)

  be _finish() =>
    if _failed or _done then return end
    if not _metrics() then return end
    try
      _closed()?
      if _options.scenario != 0 then
        _assert(@conduit_query_storage_read(U32.max_value(), 0) == 1)?
        _assert(@conduit_query_storage_read(U32.max_value(), 2) == 0)?
        _assert(@conduit_query_storage_read(U32.max_value(), 3) ==
          _options.scenario.i64())?
        let size = _ledger_count()
        _assert((size >= 0) and (size <= 256))?
        _assert(@conduit_query_storage_read(size.u32(), 0) ==
          I64.min_value())?
        _assert(@conduit_query_storage_read(0, 4) == I64.min_value())?
        for i in Range[I64](0, size) do
          _env.out.print("ledger " + i.string() + " "
            + @conduit_query_storage_read(i.u32(), 0).string() + " "
            + @conduit_query_storage_read(i.u32(), 1).string() + " "
            + @conduit_query_storage_read(i.u32(), 2).string() + " "
            + @conduit_query_storage_read(i.u32(), 3).string())
        end
      end
      _done = true
      _env.out.print("query storage passed " + _options.mode)
    else _fail("terminal ledger") end

  fun ref _starting(native: Bool, track_flush: Bool = false): Bool =>
    _metric_active = true
    _metric_local = false
    _metric_starts = _metric_starts + 1
    if native then _metric_native = _metric_native + 1 end
    _metric_track_flush = track_flush
    ifdef "conduit_diagnostic" then
      try
        _metric_flush_base = _conn()?.snapshot(1, Time.nanos(),
          recover val Array[U64] end).histograms(1)?.count
      else _fail("diagnostic starting snapshot") end
    end
    not _failed

  fun ref _recover() ? =>
    _assert(_results == 0)?
    _assert(_failures == 0)?
    _assert(_completions == 0)?
    _assert(not _recovering)?
    _target = _connection
    _recovering = true
    _input = None
    _query = None
    _command = None
    _preparing = false
    _prepared = false
    _selected = false
    _shutdowns = 0
    _expected_shutdown = false
    _metric_active = false
    _metric_local = false
    _metric_starts = 0
    _metric_terminals = 0
    _metric_failures = 0
    _metric_shutdowns = 0
    _metric_native = 0
    _metric_decode = 0
    _metric_lifetime = 0
    _metric_flush_base = 0
    _metric_track_flush = false
    let connection = _PGConnection(this, _events, 0, 0)
    _assert(connection isnt _target)?
    _connection = connection
    connection.start(_server, _database)

  fun ref _metrics(): Bool =>
    if _failed then return false end
    ifdef "conduit_diagnostic" then
      try
        let stats = _conn()?.snapshot(1, Time.nanos(),
          recover val Array[U64] end)
        _assert(stats.owner == 2)?
        _assert(stats.slot == 0)?
        _assert(stats.generation == 0)?
        _assert(stats.counters.size() == 4)?
        _assert(stats.histograms.size() == 8)?
        _assert(not stats.overflow)?
        _assert(stats.invalid_clock == 0)?
        _assert(stats.counters(0)? == _metric_starts)?
        _assert(stats.counters(1)? == _metric_terminals)?
        _assert(stats.counters(2)? == _metric_failures)?
        _assert(stats.counters(3)? == _metric_shutdowns)?
        _assert(stats.histograms(0)?.count == _metric_native)?
        _assert(stats.histograms(5)?.count == _metric_decode)?
        _assert(stats.histograms(6)?.count == _metric_lifetime)?
        if _metric_track_flush then
          var flushes: U64 = 0
          for i in Range[I64](0, _ledger_count()) do
            if @conduit_query_storage_read(i.u32(), 1) == 3 then
              flushes = flushes + 1
            end
          end
          _assert(stats.histograms(1)?.count ==
            (_metric_flush_base + flushes))?
        end
      else _fail("diagnostic metric boundary") end
    end

    not _failed

  fun _assert(condition: Bool, loc: SourceLoc = __loc) ? =>
    if not condition then
      _env.err.print(loc.file() + ":" + loc.line().string()
        + ": query storage assertion failed at step " + _step.string())
      error
    end

  fun ref _fail(message: String) =>
    if _failed then return end
    _failed = true
    _env.err.print("query storage " + _options.mode + ": " + message)
    _env.exitcode(1)
    match _connection | let connection: _PGConnection => connection.close() end

  fun ref _conn(): _PGConnection ref ? => _connection as _PGConnection

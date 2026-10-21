use "collections"
use pg = "postgres"
use "time"
use net = "net"
use "lib:pq"

use @pony_asio_event_create[AsioEventID](owner: AsioEventNotify,
  fd: U32, flags: U32, nsec: U64, noisy: Bool)
use @conduit_pq_start[I32](host: Pointer[U8] tag, port: Pointer[U8] tag,
  user: Pointer[U8] tag, password: Pointer[U8] tag,
  database: Pointer[U8] tag)
use @conduit_pq_take[Pointer[None] tag](socket: I32)
use @conduit_pq_cancel[None](socket: I32)
use @conduit_pq_timestamp[I64](value: Pointer[U8] tag)
use @conduit_pq_i64_decimal[I32](value: Pointer[U8] tag, length: USize,
  output: Pointer[I64])
use @strcmp[I32](left: Pointer[U8] tag, right: Pointer[U8] tag)
use @PQconnectPoll[I32](conn: Pointer[None] tag)
use @PQstatus[I32](conn: Pointer[None] tag)
use @PQsocket[I32](conn: Pointer[None] tag)
use @PQsetnonblocking[I32](conn: Pointer[None] tag, value: I32)
use @PQsendPrepare[I32](conn: Pointer[None] tag, name: Pointer[U8] tag,
  sql: Pointer[U8] tag, count: I32, types: Pointer[U32] tag)
use @PQsendQueryPrepared[I32](conn: Pointer[None] tag,
  name: Pointer[U8] tag, count: I32,
  values: Pointer[Pointer[U8] tag] tag, lengths: Pointer[I32] tag,
  formats: Pointer[I32] tag, result_format: I32)
use @PQsendQueryParams[I32](conn: Pointer[None] tag,
  sql: Pointer[U8] tag, count: I32, types: Pointer[U32] tag,
  values: Pointer[Pointer[U8] tag] tag, lengths: Pointer[I32] tag,
  formats: Pointer[I32] tag, result_format: I32)
use @PQflush[I32](conn: Pointer[None] tag)
use @PQconsumeInput[I32](conn: Pointer[None] tag)
use @PQisBusy[I32](conn: Pointer[None] tag)
use @PQgetResult[Pointer[None] tag](conn: Pointer[None] tag)
use @PQresultStatus[I32](result: Pointer[None] tag)
use @PQresultErrorField[Pointer[U8] val](result: Pointer[None] tag,
  code: I32)
use @PQresultErrorMessage[Pointer[U8] val](result: Pointer[None] tag)
use @PQntuples[I32](result: Pointer[None] tag)
use @PQnfields[I32](result: Pointer[None] tag)
use @PQftype[U32](result: Pointer[None] tag, column: I32)
use @PQgetisnull[I32](result: Pointer[None] tag, row: I32, column: I32)
use @PQgetlength[I32](result: Pointer[None] tag, row: I32, column: I32)
use @PQgetvalue[Pointer[U8] val](result: Pointer[None] tag,
  row: I32, column: I32)
use @PQclear[None](result: Pointer[None] tag)
use @PQtransactionStatus[I32](conn: Pointer[None] tag)
use @PQfinish[None](conn: Pointer[None] tag)

interface ref _PGOwner
  fun ref pg_ready(connection: _PGConnection ref)
  fun ref pg_prepared(connection: _PGConnection ref)
  fun ref pg_result(connection: _PGConnection ref, result: pg.Result)
  fun ref pg_failed(connection: _PGConnection ref,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError))
  fun ref pg_complete(connection: _PGConnection ref,
    status: pg.TransactionStatus)
  fun ref pg_shutdown(connection: _PGConnection ref)

class _PGRegistration
  let connection: _PGConnection ref
  let event: AsioEventID

  new create(connection': _PGConnection ref, event': AsioEventID) =>
    connection = connection'
    event = event'

class _PGEvents
  let _actor: AsioEventNotify
  embed _registrations: Map[USize, _PGRegistration] =
    Map[USize, _PGRegistration]

  new create(actor': AsioEventNotify) => _actor = actor'

  fun ref add(connection: _PGConnection ref, fd: I32,
    writing: Bool): AsioEventID
  =>
    let event = @pony_asio_event_create(_actor, fd.u32(),
      (if writing then AsioEvent.write() else AsioEvent.read() end)
        or AsioEvent.oneshot(), 0, true)
    _registrations(event.usize()) = _PGRegistration(connection, event)
    event

  fun ref notify(event: AsioEventID, flags: U32) =>
    try
      let registration = _registrations(event.usize())?
      if AsioEvent.disposable(flags) then
        _registrations.remove(event.usize())?
        net.PonyAsio.destroy(registration.event)
      else
        registration.connection.event(event, flags)
      end
    end

class _PGCommand is _PGPhase
  let value: (pg.Query | (String, String))
  var seen: Bool = false
  let started: U64
  var _phase: _PGCommandPhase = _PGWriting

  new create(value': (pg.Query | (String, String))) =>
    value = value'
    started = ifdef "conduit_diagnostic" then Time.nanos() else 0 end

  fun code(): U64 => _phase.code()
  fun active_command(): _PGCommand box => this
  fun ref event(c: _PGConnection ref, flags: U32) => _phase.event(c, this)
  fun ref send(c: _PGConnection ref, command: _PGCommand ref) =>
    c.shutdown()
  fun ref reading() => _phase = _PGReading

trait ref _PGPhase
  fun code(): U64
  fun active_command(): (_PGCommand box | None)
  fun ref event(c: _PGConnection ref, flags: U32)
  fun ref send(c: _PGConnection ref, command: _PGCommand ref)
  fun ref close(c: _PGConnection ref) => c.shutdown()

class _PGResolving is _PGPhase
  fun code(): U64 => 0
  fun active_command(): None => None
  fun ref event(c: _PGConnection ref, flags: U32) => c.resolved()
  fun ref send(c: _PGConnection ref, command: _PGCommand ref) =>
    c.shutdown()

class _PGConnecting is _PGPhase
  fun code(): U64 => 1
  fun active_command(): None => None
  fun ref event(c: _PGConnection ref, flags: U32) => c.connect()
  fun ref send(c: _PGConnection ref, command: _PGCommand ref) =>
    c.shutdown()

class _PGIdle is _PGPhase
  fun code(): U64 => 2
  fun active_command(): None => None
  fun ref event(c: _PGConnection ref, flags: U32) => c.read_idle()
  fun ref send(c: _PGConnection ref, command: _PGCommand ref) =>
    c.send(command)

trait val _PGCommandPhase
  fun code(): U64
  fun event(c: _PGConnection ref, command: _PGCommand ref)

primitive _PGWriting is _PGCommandPhase
  fun code(): U64 => 3
  fun event(c: _PGConnection ref, command: _PGCommand ref) =>
    c.flush(command)

primitive _PGReading is _PGCommandPhase
  fun code(): U64 => 4
  fun event(c: _PGConnection ref, command: _PGCommand ref) =>
    c.read(command)

class _PGClosed is _PGPhase
  fun code(): U64 => 5
  fun active_command(): None => None
  fun ref event(c: _PGConnection ref, flags: U32) => None
  fun ref send(c: _PGConnection ref, command: _PGCommand ref) => None

class _PGConnection
  let slot: USize
  let generation: U64
  let _owner: _PGOwner ref
  let _events: _PGEvents ref
  embed _idle: _PGIdle = _PGIdle
  embed _send_strings: Array[String] = Array[String]
  embed _send_values: Array[Pointer[U8] tag] = Array[Pointer[U8] tag]
  var _phase: _PGPhase = _PGResolving
  var _conn: Pointer[None] tag = Pointer[None]
  var _event: AsioEventID = AsioEvent.none()
  var _fd: I32 = -1
  var _writing: Bool = false
  var _resolver: I32 = -1
  var _starts: U64 = 0
  var _armed_at: U64 = 0
  var _diag: (pg.DiagState | None) = None

  new create(owner: _PGOwner ref, events: _PGEvents ref,
    slot': USize, generation': U64)
  =>
    _owner = owner
    _events = events
    slot = slot'
    generation = generation'
    ifdef "conduit_diagnostic" then _diag = pg.DiagState(4, 8) end

  fun ref start(server: pg.ServerConnectInfo,
    database: pg.DatabaseConnectInfo)
  =>
    if server.host.contains("\0") or server.port.contains("\0") or
      database.user.contains("\0") or database.password.contains("\0") or
      database.database.contains("\0") then
      shutdown()
      return
    end
    _starts = _starts + 1
    _resolver = @conduit_pq_start(server.host.cstring(),
      server.port.cstring(), database.user.cstring(),
      database.password.cstring(), database.database.cstring())
    if _resolver < 0 then shutdown()
    else _event = _events.add(this, _resolver, false) end

  fun ref event(event': AsioEventID, flags: U32) =>
    if _closed() or (event' isnt _event) then return end
    _socket_wait()
    if AsioEvent.errored(flags) then shutdown()
    else _phase.event(this, flags) end

  fun ref resolved() =>
    _unsubscribe()
    _conn = @conduit_pq_take(_resolver)
    _resolver = -1
    if _conn.is_null() then shutdown()
    else
      _phase = _PGConnecting
      connect()
    end

  fun ref connect() =>
    match @PQconnectPoll(_conn)
    | 1 => _arm(false)
    | 2 => _arm(true)
    | 3 =>
      if (@PQstatus(_conn) != 0) or (@PQsetnonblocking(_conn, 1) != 0) then
        shutdown()
        return
      end
      _phase = _idle
      _owner.pg_ready(this)
    else shutdown()
    end

  fun ref execute(query': pg.Query) =>
    _phase.send(this, _PGCommand(query'))

  fun ref prepare(name: String, sql: String) =>
    _phase.send(this, _PGCommand((name, sql)))

  fun ref send(command: _PGCommand ref) =>
    _phase = command
    _count(0)
    let start' = ifdef "conduit_diagnostic" then Time.nanos() else 0 end
    let sent = match command.value
      | (let name: String, let sql: String) =>
        if name.contains("\0") or sql.contains("\0") then
          _local_error()
          return
        end
        @PQsendPrepare(_conn, name.cstring(), sql.cstring(),
          0, Pointer[U32])
      | let query': pg.Query =>
        if not _valid(query') then
          _local_error()
          return
        end
        _send(query')
      end
    _observe(0, start')
    if sent != 1 then shutdown()
    else flush(command) end

  fun _valid(query': pg.Query): Bool =>
    let params = match query'
      | let named: pg.NamedPreparedQuery =>
        if named.name.contains("\0") then return false end
        named.params
      | let plain: pg.PreparedQuery =>
        if plain.string.contains("\0") then return false end
        plain.params
      end
    for param in params.values() do
      match param
      | let s: String if s.contains("\0") => return false
      | let _: pg.PgArray => return false
      end
    end
    true

  fun ref _send(query': pg.Query): I32 =>
    let params = match query'
      | let named: pg.NamedPreparedQuery => named.params
      | let plain: pg.PreparedQuery => plain.params
      end
    if params.size() <= 8 then
      _send_with(query', params, _send_strings, _send_values)
    else
      _send_with(query', params, Array[String](params.size()),
        Array[Pointer[U8] tag](params.size()))
    end

  fun ref _send_with(query': pg.Query, params: Array[pg.FieldDataTypes] val,
    strings: Array[String] ref, values: Array[Pointer[U8] tag] ref): I32
  =>
    for param in params.values() do
      match param
      | None => values.push(Pointer[U8])
      | let s: String =>
        strings.push(s)
        values.push(s.cstring())
      | let n: I64 =>
        let s: String val = n.string()
        strings.push(s)
        values.push(s.cstring())
      | let n: I32 =>
        let s: String val = n.string()
        strings.push(s)
        values.push(s.cstring())
      else _Unreachable()
      end
    end
    let sent = match query'
    | let named: pg.NamedPreparedQuery =>
      @PQsendQueryPrepared(_conn, named.name.cstring(), params.size().i32(),
        values.cpointer(), Pointer[I32], Pointer[I32], 0)
    | let plain: pg.PreparedQuery =>
      @PQsendQueryParams(_conn, plain.string.cstring(), params.size().i32(),
        Pointer[U32], values.cpointer(), Pointer[I32], Pointer[I32], 0)
    end
    // libpq copies parameter data into its output buffer before returning.
    strings.clear()
    values.clear()
    sent

  fun ref _local_error() =>
    match _phase.active_command()
    | let command: _PGCommand box => _observe(6, command.started)
    end
    _phase = _idle
    _owner.pg_failed(this, pg.DataError)
    _count(1)
    _count(2)
    _complete()

  fun ref flush(command: _PGCommand ref) =>
    let start' = ifdef "conduit_diagnostic" then Time.nanos() else 0 end
    let status = @PQflush(_conn)
    _observe(1, start')
    match status
    | 0 =>
      command.reading()
      _arm(false)
    | 1 =>
      _arm(true)
    else shutdown()
    end

  fun ref read_idle() =>
    if @PQconsumeInput(_conn) != 1 then shutdown()
    else _arm(false) end

  fun ref read(command: _PGCommand ref) =>
    let start' = ifdef "conduit_diagnostic" then Time.nanos() else 0 end
    let consumed = @PQconsumeInput(_conn)
    _observe(2, start')
    if consumed != 1 then shutdown(); return end
    while not _closed() do
      let busy_start = ifdef "conduit_diagnostic" then Time.nanos()
        else 0 end
      let busy = @PQisBusy(_conn)
      _observe(3, busy_start)
      if busy != 0 then _arm(false); return end
      let result_start = ifdef "conduit_diagnostic" then Time.nanos()
        else 0 end
      let raw = @PQgetResult(_conn)
      _observe(4, result_start)
      if raw.is_null() then
        if not command.seen then shutdown(); return end
        _phase = _idle
        _count(1)
        _observe(6, command.started)
        _complete()
        return
      end
      if command.seen then
        @PQclear(raw)
        shutdown()
        return
      end
      command.seen = true
      _handle(command, raw)
      @PQclear(raw)
    end

  fun ref _handle(command: _PGCommand ref, raw: Pointer[None] tag) =>
    let status = @PQresultStatus(raw)
    match status
    | 1 | 2 =>
      match command.value
      | let query': pg.Query =>
        if status == 2 then
          let start' = ifdef "conduit_diagnostic" then Time.nanos()
            else 0 end
          try _owner.pg_result(this, pg.ResultSet(query', _decode(raw)?))
          else _owner.pg_failed(this, pg.DataError) end
          _observe(5, start')
        else _owner.pg_result(this, pg.SimpleResult(query')) end
      | (let name: String, let sql: String) =>
        if status == 1 then _owner.pg_prepared(this)
        else _owner.pg_failed(this, pg.ProtocolViolation) end
      end
    | 7 =>
      _count(2)
      let code = @PQresultErrorField(raw, 67)
      if code.is_null() then _owner.pg_failed(this, pg.DataError)
      else
        _owner.pg_failed(this, pg.ErrorResponseMessage(_copy(code),
          _copy(@PQresultErrorMessage(raw))))
      end
    else
      shutdown()
    end

  fun ref _complete() =>
    if _closed() then return end
    match @PQtransactionStatus(_conn)
    | 0 => _owner.pg_complete(this, pg.TransactionIdle)
    | 2 => _owner.pg_complete(this, pg.TransactionInBlock)
    | 3 => _owner.pg_complete(this, pg.TransactionFailed)
    else shutdown()
    end
    match _phase | let _: _PGIdle => _arm(false) end

  fun ref _arm(writing: Bool) =>
    let fd = @PQsocket(_conn)
    if fd < 0 then shutdown(); return end
    ifdef "conduit_diagnostic" then
      if _phase.active_command() isnt None then _armed_at = Time.nanos() end
    end
    if (fd != _fd) or _event.is_null() or (writing != _writing) then
      _unsubscribe()
      _fd = fd
      _writing = writing
      _event = _events.add(this, fd, writing)
    elseif writing then
      net.PonyAsio.set_unwriteable(_event)
      net.PonyAsio.resubscribe_write(_event)
    else
      net.PonyAsio.set_unreadable(_event)
      net.PonyAsio.resubscribe_read(_event)
    end

  fun ref _unsubscribe() =>
    if not _event.is_null() then
      net.PonyAsio.unsubscribe(_event)
      _event = AsioEvent.none()
    end

  fun ref close() => _phase.close(this)

  fun ref shutdown() =>
    if _closed() then return end
    _socket_wait()
    match _phase.active_command()
    | let command: _PGCommand box =>
      _count(1)
      _observe(6, command.started)
    end
    _phase = _PGClosed
    _count(3)
    _unsubscribe()
    if _resolver >= 0 then
      @conduit_pq_cancel(_resolver)
      _resolver = -1
    end
    _owner.pg_shutdown(this)

  fun _closed(): Bool =>
    match _phase | let _: _PGClosed box => true else false end

  fun phase_code(): U64 => _phase.code()

  fun _test_send_storage(): (USize, USize, USize, USize) =>
    (_send_strings.size(), _send_values.size(),
      _send_strings.space(), _send_values.space())

  fun _test_command(): (_PGCommand box | None) => _phase.active_command()

  fun _test_writing(): Bool => _writing

  fun native_starts(): U64 => _starts

  fun ref _socket_wait() =>
    ifdef "conduit_diagnostic" then
      if _armed_at != 0 then
        _observe(7, _armed_at)
        _armed_at = 0
      end
    end

  fun ref _count(index: USize) =>
    ifdef "conduit_diagnostic" then
      match _diag | let stats: pg.DiagState => stats.count(index) end
    end

  fun ref _observe(index: USize, start': U64) =>
    ifdef "conduit_diagnostic" then
      match _diag
      | let stats: pg.DiagState =>
        stats.observe(index, start', Time.nanos())
      end
    end

  fun box snapshot(request: U64, observed: U64,
    gauges: Array[U64] val): pg.DiagSnapshot
  =>
    match _diag
    | let stats: pg.DiagState box =>
      stats.snapshot(2, slot, generation, request, observed, gauges)
    else
      pg.DiagSnapshot(2, slot, generation, request, observed,
        recover val Array[U64] end, gauges,
        recover val Array[pg.DiagHistogramValue] end, false, 0)
    end

  fun _copy(ptr: Pointer[U8] val): String val =>
    recover val String.copy_cstring(ptr) end

  fun _decode(raw: Pointer[None] tag): pg.Rows ? =>
    let rows = recover iso Array[pg.Row] end
    var row: I32 = 0
    while row < @PQntuples(raw) do
      let fields = recover iso Array[pg.FieldData] end
      var column: I32 = 0
      while column < @PQnfields(raw) do
        let value: pg.FieldData = if @PQgetisnull(raw, row, column) != 0 then
          None
        else
          let ptr = @PQgetvalue(raw, row, column)
          match @PQftype(raw, column)
          | 16 => @strcmp(ptr, "t".cstring()) == 0
          | 20 => _integer(ptr, @PQgetlength(raw, row, column))?
          | 21 | 23 => _integer32(ptr, @PQgetlength(raw, row, column))?
          | 1114 | 1184 =>
            if @strcmp(ptr, "infinity".cstring()) == 0 then
              pg.PgTimestamp(I64.max_value())
            elseif @strcmp(ptr, "-infinity".cstring()) == 0 then
              pg.PgTimestamp(I64.min_value())
            else
              let us = @conduit_pq_timestamp(ptr)
              if us == I64.min_value() then error end
              pg.PgTimestamp(us)
            end
          | 1009 => _decode_array(_copy(ptr))?
          else _copy(ptr)
          end
        end
        fields.push(value)
        column = column + 1
      end
      rows.push(pg.Row(consume fields))
      row = row + 1
    end
    consume rows

  fun _integer(ptr: Pointer[U8] val, length: I32): I64 ? =>
    if length < 0 then error end
    var value: I64 = 0
    if @conduit_pq_i64_decimal(ptr, length.usize(), addressof value) == 1 then
      value
    else
      _copy(ptr).i64()?
    end

  fun _integer32(ptr: Pointer[U8] val, length: I32): I32 ? =>
    if length < 0 then error end
    var value: I64 = 0
    if (@conduit_pq_i64_decimal(ptr, length.usize(), addressof value) == 1)
      and (value >= I32.min_value().i64())
      and (value <= I32.max_value().i64())
    then
      value.i32()
    else
      _copy(ptr).i32()?
    end

  fun _decode_array(value: String): pg.PgArray ? =>
    if (value.size() < 2) or (value(0)? != '{') or
      (value(value.size() - 1)? != '}') then error end
    let elements = recover iso Array[(pg.FieldData | None)] end
    var part = String
    var quoted = false
    var escaped = false
    var was_quoted = false
    var i: USize = 1
    while i < (value.size() - 1) do
      let ch = value(i)?
      if escaped then
        part.push(ch)
        escaped = false
      elseif quoted and (ch == '\\') then
        escaped = true
      elseif ch == '"' then
        quoted = not quoted
        was_quoted = true
      elseif ((ch == '{') or (ch == '}')) and not quoted then
        error
      elseif (ch == ',') and not quoted then
        if (part == "NULL") and not was_quoted then
          elements.push(None)
        else elements.push(part.clone()) end
        part.clear()
        was_quoted = false
      else part.push(ch)
      end
      i = i + 1
    end
    if quoted or escaped then error end
    if value.size() > 2 then
      if (part == "NULL") and not was_quoted then
        elements.push(None)
      else elements.push(part.clone()) end
    end
    pg.PgArray(25, consume elements)

  fun _final() =>
    if not _conn.is_null() then @PQfinish(_conn) end

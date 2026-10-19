use "collections"
use "time"
use pg = "postgres"

interface tag _TestResultReceiver
  be pg_query_result(session: _TestSession, result: pg.Result)
  be pg_query_failed(session: _TestSession, query': pg.Query,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError))

interface tag _TestPrepareReceiver
  be pg_statement_prepared(session: _TestSession, name: String)
  be pg_prepare_failed(session: _TestSession, name: String,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError))

interface tag _TestStatusNotify
  be pg_session_authenticated(session: _TestSession)
  be pg_transaction_status(session: _TestSession,
    status: pg.TransactionStatus)
  be pg_session_connection_failed(session: _TestSession,
    reason: pg.ConnectionFailureReason)
  be pg_session_shutdown(session: _TestSession)

interface tag _TestDiagReceiver
  be pg_diag_snapshot(session: _TestSession, snapshot: pg.DiagSnapshot)

interface tag _TestStartReceiver
  be pg_native_starts(session: _TestSession, count: U64)

class \nodoc\ val _TestPrepare
  let name: String
  let sql: String
  let receiver: _TestPrepareReceiver
  new val create(name': String, sql': String,
    receiver': _TestPrepareReceiver)
  =>
    name = name'
    sql = sql'
    receiver = receiver'

class \nodoc\ val _TestExecute
  let query: pg.Query
  let receiver: _TestResultReceiver
  new val create(query': pg.Query, receiver': _TestResultReceiver) =>
    query = query'
    receiver = receiver'

type _TestCommand is (_TestPrepare | _TestExecute)

class \nodoc\ _TestActive
  let command: _TestCommand
  var reported: Bool = false
  new create(command': _TestCommand) => command = command'

actor \nodoc\ _TestSession is (AsioEventNotify & _PGOwner)
  let _notify: _TestStatusNotify
  embed _events: _PGEvents
  var _connection: (_PGConnection | None) = None
  embed _queue: List[_TestCommand] = List[_TestCommand]
  var _active: (_TestActive | None) = None
  var _ready: Bool = false
  var _closed: Bool = false
  var _starting: Bool = false
  var _continuation: Bool = false

  new create(server: pg.ServerConnectInfo,
    database: pg.DatabaseConnectInfo, notify: _TestStatusNotify)
  =>
    _notify = notify
    _events = _PGEvents(this)
    let connection = _PGConnection(this, _events, 0, 0)
    _connection = connection
    connection.start(server, database)

  be _event_notify(event: AsioEventID, flags: U32, arg: U32) =>
    _events.notify(event, flags)

  be prepare(name: String, sql: String, receiver: _TestPrepareReceiver) =>
    _accept(_TestPrepare(name, sql, receiver))

  be execute(query': pg.Query, receiver: _TestResultReceiver) =>
    _accept(_TestExecute(query', receiver))

  fun ref _accept(command: _TestCommand) =>
    if _closed then _fail_command(command, pg.SessionClosed)
    else
      _queue.push(command)
      _next()
    end

  fun ref _next() =>
    if _closed or not _ready or (_active isnt None) or
      (_queue.size() == 0) or _starting then return end
    _starting = true
    var budget: USize = 64
    while not _closed and (_active is None) and
      (_queue.size() > 0) and (budget > 0) do
      budget = budget - 1
      try
        let command = _queue.shift()?
        _active = _TestActive(command)
        match _connection
        | let connection: _PGConnection =>
          match command
          | let p: _TestPrepare => connection.prepare(p.name, p.sql)
          | let e: _TestExecute => connection.execute(e.query)
          end
        else _Unreachable()
        end
      else _Unreachable() end
    end
    _starting = false
    if not _closed and (_active is None) and (_queue.size() > 0) and
      not _continuation then
      _continuation = true
      this._resume()
    end

  be _resume() =>
    _continuation = false
    _next()

  fun ref pg_ready(connection: _PGConnection ref) =>
    _ready = true
    _notify.pg_session_authenticated(this)
    _notify.pg_transaction_status(this, pg.TransactionIdle)
    _next()

  fun ref pg_prepared(connection: _PGConnection ref) =>
    match _active
    | let active: _TestActive =>
      match active.command
      | let command: _TestPrepare =>
        active.reported = true
        command.receiver.pg_statement_prepared(this, command.name)
      else _Unreachable()
      end
    else _Unreachable()
    end

  fun ref pg_result(connection: _PGConnection ref, result: pg.Result) =>
    match _active
    | let active: _TestActive =>
      match active.command
      | let command: _TestExecute =>
        active.reported = true
        command.receiver.pg_query_result(this, result)
      else _Unreachable()
      end
    else _Unreachable()
    end

  fun ref pg_failed(connection: _PGConnection ref,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError))
  =>
    match _active
    | let active: _TestActive =>
      if not active.reported then
        active.reported = true
        _fail_command(active.command, failure)
      else _Unreachable()
      end
    else _Unreachable()
    end

  fun ref pg_complete(connection: _PGConnection ref,
    status: pg.TransactionStatus)
  =>
    _active = None
    _notify.pg_transaction_status(this, status)
    _next()

  fun ref pg_shutdown(connection: _PGConnection ref) =>
    if _closed then return end
    _closed = true
    match _active
    | let active: _TestActive if not active.reported =>
      _fail_command(active.command, pg.SessionClosed)
    end
    _active = None
    for command in _queue.values() do
      _fail_command(command, pg.SessionClosed)
    end
    _queue.clear()
    if not _ready then
      _notify.pg_session_connection_failed(this, pg.ConnectionError)
    end
    _notify.pg_session_shutdown(this)

  fun ref _fail_command(command: _TestCommand,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError))
  =>
    match command
    | let p: _TestPrepare =>
      p.receiver.pg_prepare_failed(this, p.name, failure)
    | let e: _TestExecute =>
      e.receiver.pg_query_failed(this, e.query, failure)
    end

  be close() =>
    match _connection
    | let connection: _PGConnection => connection.close()
    end

  be native_starts(receiver: _TestStartReceiver) =>
    match _connection
    | let connection: _PGConnection =>
      receiver.pg_native_starts(this, connection.native_starts())
    end

  be diag_snapshot(request: U64, generation: U64, slot: USize,
    receiver: _TestDiagReceiver)
  =>
    ifdef "conduit_diagnostic" then
      match _connection
      | let connection: _PGConnection =>
        receiver.pg_diag_snapshot(this,
          connection.snapshot(request, Time.nanos(),
            recover val Array[U64] end))
      end
    end

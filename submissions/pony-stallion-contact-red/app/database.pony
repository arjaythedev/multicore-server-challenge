use "collections"
use "net"
use "time"
use pg = "postgres"

interface tag _QueryClient
  be db_result(id: U64, result: pg.Result)
  be db_failed(id: U64, failure: _DBFailure)

interface tag _WorkerBarrier
  be worker_barrier(pending: USize)

class val _SQLFailure
  let code: String
  new val create(code': String) => code = code'

primitive _DataFailure
primitive _ConnectionLost

type _DBFailure is (_SQLFailure | _DataFailure | _ConnectionLost)

interface ref _Next
  fun ref apply(operation: _Operation ref, result: pg.Result) ?

type _Pending is (_QueryClient, U64, _RequestStatement,
  Array[_Param] val)

class _Job
  var client: (_QueryClient | None)
  let id: U64
  let query: pg.Query
  var next: (_Job | None) = None
  var result: (pg.Result | None) = None
  var failure: (_DBFailure | None) = None
  var reported: Bool = false
  var tombstone: Bool = false

  new create(client': _QueryClient, id': U64, query': pg.Query) =>
    client = client'
    id = id'
    query = query'

  fun ref report_failure(failure': _DBFailure) =>
    if reported then return end
    reported = true
    let recipient = client
    client = None
    match recipient
    | let current: _QueryClient => current.db_failed(id, failure')
    end

  fun ref report_result(result': pg.Result) =>
    if reported then return end
    reported = true
    let recipient = client
    client = None
    match recipient
    | let current: _QueryClient => current.db_result(id, result')
    end

primitive _Connecting
primitive _Ready
primitive _Retiring
primitive _Backoff
primitive _Stopped

class _Preparing
  let index: USize
  var prepared: Bool = false
  var ready: Bool = false

  new create(index': USize) => index = index'

type _WorkerState is
  (_Connecting | _Preparing | _Ready | _Retiring | _Backoff | _Stopped)

class iso _Retry is TimerNotify
  let _worker: _Worker
  let _generation: U64

  new iso create(worker: _Worker, generation: U64) =>
    _worker = worker
    _generation = generation

  fun ref apply(timer: Timer, count: U64): Bool =>
    _worker.retry(_generation)
    false

actor _Worker is (pg.SessionStatusNotify & pg.ResultReceiver &
  pg.PrepareReceiver)
  let _auth: TCPConnectAuth
  let _config: _Config
  let _timers: Timers
  let _err: OutStream
  var _session: pg.Session
  var _state: _WorkerState = _Connecting
  var _generation: U64 = 0
  embed _pending: List[_Pending] = List[_Pending]
  var _head: (_Job | None) = None
  var _tail: (_Job | None) = None

  new create(auth: TCPConnectAuth, config: _Config, timers: Timers,
    err: OutStream)
  =>
    _auth = auth
    _config = config
    _timers = timers
    _err = err
    _session = pg.Session(
      pg.ServerConnectInfo(_auth, _config.dbhost, _config.dbport),
      pg.DatabaseConnectInfo(_config.user, _config.password,
        _config.database), this)

  fun ref _connect(): pg.Session =>
    pg.Session(
      pg.ServerConnectInfo(_auth, _config.dbhost, _config.dbport),
      pg.DatabaseConnectInfo(_config.user, _config.password,
        _config.database), this)

  be query(client: _QueryClient, id: U64, statement: _RequestStatement,
    params: Array[_Param] val)
  =>
    match _state
    | let _: _Ready => _submit(client, id, statement, params)
    | let _: _Stopped => client.db_failed(id, _ConnectionLost)
    else _pending.push((client, id, statement, params))
    end

  be cancel(client: _QueryClient) =>
    let count = _pending.size()
    for i in Range(0, count) do
      try
        let pending = _pending.shift()?
        if not (pending._1 is client) then _pending.push(pending) end
      else _Unreachable()
      end
    end
    var current = _head
    while true do
      match current
      | let job: _Job =>
        if job.client is client then job.client = None end
        current = job.next
      else break
      end
    end

  be barrier(probe: _WorkerBarrier) =>
    probe.worker_barrier(_pending.size())

  fun ref _submit(client: _QueryClient, id: U64,
    statement: _RequestStatement, params: Array[_Param] val)
  =>
    let query' = pg.NamedPreparedQuery(_Catalog.name(statement), params)
    let job = _Job(client, id, query')
    match _tail
    | let tail: _Job => tail.next = job
    else _head = job
    end
    _tail = job
    _session.execute(query', this)

  fun ref _pop(): _Job ? =>
    let job = _head as _Job
    _head = job.next
    job.next = None
    if _head is None then _tail = None end
    job

  fun ref _prepare(index: USize) =>
    try
      let statement = _Catalog.all()(index)?
      _state = _Preparing(index)
      _session.prepare(_Catalog.name(statement), _Catalog.sql(statement),
        this)
    else
      _state = _Ready
      while _pending.size() > 0 do
        try
          (let client, let id, let statement, let params) =
            _pending.shift()?
          _submit(client, id, statement, params)
        else _Unreachable()
        end
      end
    end

  fun ref _advance(preparing: _Preparing) =>
    if preparing.prepared and preparing.ready then
      _prepare(preparing.index + 1)
    end

  fun ref _retire() =>
    match _state
    | let _: _Retiring | let _: _Backoff | let _: _Stopped => return
    end
    _state = _Retiring
    while _head isnt None do
      try _pop()?.report_failure(_ConnectionLost)
      else _Unreachable() end
    end
    _session.close()

  be retry(generation: U64) =>
    if (generation == _generation) and (_state is _Backoff) then
      _session = _connect()
      _state = _Connecting
    end

  be close() =>
    if _state is _Stopped then return end
    _state = _Stopped
    while _head isnt None do
      try _pop()?.report_failure(_ConnectionLost)
      else _Unreachable() end
    end
    for pending in _pending.values() do
      pending._1.db_failed(pending._2, _ConnectionLost)
    end
    _pending.clear()
    _session.close()

  fun ref _match_callback(query': pg.Query): _Job ? =>
    while true do
      match _head
      | let first: _Job if first.tombstone and
          (not (first.query is query')) =>
        _pop()?
      else break
      end
    end
    let job = _head as _Job
    if not (job.query is query') then error end
    if job.tombstone or (job.result isnt None)
      or (job.failure isnt None) then error end
    job

  be pg_query_result(session: pg.Session, result: pg.Result) =>
    if not (session is _session) then return end
    if not (_state is _Ready) then return end
    try _match_callback(result.query())?.result = result
    else _retire() end

  be pg_query_failed(session: pg.Session, query': pg.Query,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError))
  =>
    if not (session is _session) then return end
    if not (_state is _Ready) then return end
    match failure
    | let _: pg.SessionClosed | let _: pg.ProtocolViolation =>
      _retire()
      return
    end
    try
      let job = _match_callback(query')?
      match failure
      | let server: pg.ErrorResponseMessage =>
        job.failure = _SQLFailure(server.code)
        _err.print("Database error " + server.code + ": " +
          server.message)
      | let _: pg.DataError =>
        job.tombstone = true
        job.report_failure(_DataFailure)
      else _retire()
      end
    else _retire()
    end

  be pg_transaction_status(session: pg.Session,
    status: pg.TransactionStatus)
  =>
    if not (session is _session) then return end
    match _state
    | let _: _Connecting =>
      if status is pg.TransactionIdle then _prepare(0)
      else _retire() end
    | let preparing: _Preparing =>
      if status is pg.TransactionIdle then
        preparing.ready = true
        _advance(preparing)
      else _retire()
      end
    | let _: _Ready =>
      try
        let job = _pop()?
        if not (status is pg.TransactionIdle) then
          _retire()
          job.report_failure(_ConnectionLost)
          return
        end
        if not job.reported then
          match job.result
          | let result: pg.Result =>
            job.report_result(result)
          else
            match job.failure
            | let failure': _DBFailure =>
              job.report_failure(failure')
            else
              _retire()
              job.report_failure(_ConnectionLost)
            end
          end
        end
      else _retire()
      end
    end

  be pg_statement_prepared(session: pg.Session, name: String) =>
    if not (session is _session) then return end
    match _state
    | let preparing: _Preparing =>
      try
        let statement = _Catalog.all()(preparing.index)?
        if name != _Catalog.name(statement) then error end
        preparing.prepared = true
        _advance(preparing)
      else _retire()
      end
    else _retire()
    end

  be pg_prepare_failed(session: pg.Session, name: String,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError))
  =>
    if not (session is _session) then return end
    match failure
    | let server: pg.ErrorResponseMessage =>
      _err.print("Database prepare " + name + " failed " + server.code +
        ": " + server.message)
    | let _: pg.ClientQueryError =>
      _err.print("Database prepare " + name +
        " failed: client query error")
    end
    _retire()

  be pg_session_connection_failed(session: pg.Session,
    reason: pg.ConnectionFailureReason)
  =>
    if not (session is _session) then return end
    _err.print("Postgres connection failed")
    _retire()

  be pg_session_shutdown(session: pg.Session) =>
    if not (session is _session) then return end
    if _state is _Stopped then return end
    _err.print("Postgres session shutdown")
    _retire()
    _state = _Backoff
    _generation = _generation + 1
    let timer = Timer(_Retry(this, _generation), 1_000_000_000)
    _timers(consume timer)

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

class _Recipient
  var client: (_QueryClient | None)
  var outstanding: USize = 0

  new create(client': _QueryClient) => client = client'

primitive _AwaitingResult
primitive _ReportedDataFailure

type _JobOutcome is
  (_AwaitingResult | pg.Result | _DBFailure | _ReportedDataFailure)

class _Job
  let recipient: _Recipient
  let id: U64
  let query: pg.Query
  let kind: USize
  let enqueued: U64
  var started: U64 = 0
  var outcome: _JobOutcome = _AwaitingResult
  var _next: (_Job ref | None) = None

  new create(recipient': _Recipient, id': U64, query': pg.Query,
    kind': USize, enqueued': U64)
  =>
    recipient = recipient'
    id = id'
    query = query'
    kind = kind'
    enqueued = enqueued'

  fun ref _pending_link(next': _Job ref) => _next = next'

  fun ref _pending_take_next(): (_Job ref | None) => _next = None

  fun _pending_next(): (_Job box | None) => _next

trait ref _SlotPhase
  fun connection(): (_PGConnection box | None)
  fun job(): (_Job box | None)
  fun code(): U64
  fun ref ready(slot: _PoolSlot ref)
  fun ref prepared(slot: _PoolSlot ref)
  fun ref result(slot: _PoolSlot ref, value: pg.Result)
  fun ref failed(slot: _PoolSlot ref,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError))
  fun ref complete(slot: _PoolSlot ref, status: pg.TransactionStatus)
  fun ref dispatch(slot: _PoolSlot ref, job': _Job ref)
  fun ref retry(slot: _PoolSlot ref, token: _RetryToken)
  fun ref close(slot: _PoolSlot ref)

trait ref _LiveSlot is _SlotPhase
  fun connection(): _PGConnection box
  fun ref retry(slot: _PoolSlot ref, token: _RetryToken) => None
  fun ref close(slot: _PoolSlot ref) => slot.owner.stop_slot(slot)

class _ConnectingSlot is _LiveSlot
  let conn: _PGConnection ref
  new create(conn': _PGConnection ref) => conn = conn'
  fun connection(): _PGConnection box => conn
  fun code(): U64 => 0
  fun ref ready(slot: _PoolSlot ref) => slot.owner.prepare(slot, conn, 0)

  fun job(): None => None
  fun ref prepared(slot: _PoolSlot ref) =>
    slot.owner.retire(slot)
  fun ref result(slot: _PoolSlot ref, value: pg.Result) =>
    slot.owner.retire(slot)
  fun ref failed(slot: _PoolSlot ref,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError)) =>
    slot.owner.retire(slot)
  fun ref complete(slot: _PoolSlot ref, status: pg.TransactionStatus) =>
    slot.owner.retire(slot)
  fun ref dispatch(slot: _PoolSlot ref, job': _Job ref) =>
    _Unreachable()

primitive _PrepareAwaiting
primitive _PrepareDone
primitive _PrepareFailed

class _PreparingSlot is _LiveSlot
  let conn: _PGConnection ref
  let index: USize
  var outcome: (_PrepareAwaiting | _PrepareDone | _PrepareFailed) =
    _PrepareAwaiting

  new create(conn': _PGConnection ref, index': USize) =>
    conn = conn'
    index = index'

  fun connection(): _PGConnection box => conn
  fun code(): U64 => 1
  fun ref prepared(slot: _PoolSlot ref) =>
    if outcome is _PrepareAwaiting then outcome = _PrepareDone
    else slot.owner.retire(slot) end

  fun ref failed(slot: _PoolSlot ref,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError))
  =>
    outcome = _PrepareFailed
    slot.owner.log_prepare(index, failure)

  fun ref complete(slot: _PoolSlot ref, status: pg.TransactionStatus) =>
    if (outcome is _PrepareDone) and (status is pg.TransactionIdle) then
      slot.owner.prepare(slot, conn, index + 1)
    else slot.owner.retire(slot) end

  fun job(): None => None
  fun ref ready(slot: _PoolSlot ref) =>
    slot.owner.retire(slot)
  fun ref result(slot: _PoolSlot ref, value: pg.Result) =>
    slot.owner.retire(slot)
  fun ref dispatch(slot: _PoolSlot ref, job': _Job ref) =>
    _Unreachable()

class _IdleSlot is _LiveSlot
  let conn: _PGConnection ref
  new create(conn': _PGConnection ref) => conn = conn'
  fun connection(): _PGConnection box => conn
  fun code(): U64 => 2
  fun ref dispatch(slot: _PoolSlot ref, job': _Job ref) =>
    slot.phase = _BusySlot(this, job')
    conn.execute(job'.query)

  fun job(): None => None
  fun ref ready(slot: _PoolSlot ref) =>
    slot.owner.retire(slot)
  fun ref prepared(slot: _PoolSlot ref) =>
    slot.owner.retire(slot)
  fun ref result(slot: _PoolSlot ref, value: pg.Result) =>
    slot.owner.retire(slot)
  fun ref failed(slot: _PoolSlot ref,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError)) =>
    slot.owner.retire(slot)
  fun ref complete(slot: _PoolSlot ref, status: pg.TransactionStatus) =>
    slot.owner.retire(slot)

class _BusySlot is _LiveSlot
  let idle: _IdleSlot ref
  let conn: _PGConnection ref
  let active: _Job ref

  new create(idle': _IdleSlot ref, job': _Job ref) =>
    idle = idle'
    conn = idle'.conn
    active = job'

  fun connection(): _PGConnection box => conn
  fun job(): _Job box => active
  fun code(): U64 => 3

  fun ref result(slot: _PoolSlot ref, value: pg.Result) =>
    if active.outcome is _AwaitingResult then active.outcome = value
    else slot.owner.retire(slot) end

  fun ref failed(slot: _PoolSlot ref,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError))
  =>
    if not (active.outcome is _AwaitingResult) then
      slot.owner.retire(slot)
      return
    end
    match failure
    | let server: pg.ErrorResponseMessage =>
      active.outcome = _SQLFailure(server.code)
      slot.owner.log_failure(server)
    | pg.DataError =>
      active.outcome = _ReportedDataFailure
      slot.owner.notify_failed(active, _DataFailure)
    else slot.owner.retire(slot)
    end

  fun ref complete(slot: _PoolSlot ref, status: pg.TransactionStatus) =>
    if (not (status is pg.TransactionIdle)) or
      (active.outcome is _AwaitingResult) then
      slot.owner.retire(slot)
      return
    end
    let missing_statement = match active.outcome
      | let failure: _SQLFailure => failure.code == "26000"
      else false
      end
    slot.phase = idle
    slot.owner.settle(active)
    if missing_statement then slot.owner.retire(slot)
    else slot.owner.available(slot) end

  fun ref ready(slot: _PoolSlot ref) =>
    slot.owner.retire(slot)
  fun ref prepared(slot: _PoolSlot ref) =>
    slot.owner.retire(slot)
  fun ref dispatch(slot: _PoolSlot ref, job': _Job ref) =>
    _Unreachable()

class val _RetryToken
  new val create() => None

class _BackoffSlot is _SlotPhase
  let token: _RetryToken
  let timer: Timer tag
  new create(token': _RetryToken, timer': Timer tag) =>
    token = token'
    timer = timer'
  fun connection(): None => None
  fun job(): None => None
  fun code(): U64 => 4
  fun ref ready(slot: _PoolSlot ref) => None
  fun ref prepared(slot: _PoolSlot ref) => None
  fun ref result(slot: _PoolSlot ref, value: pg.Result) => None
  fun ref failed(slot: _PoolSlot ref,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError)) => None
  fun ref complete(slot: _PoolSlot ref, status: pg.TransactionStatus) => None
  fun ref dispatch(slot: _PoolSlot ref, job': _Job ref) => _Unreachable()
  fun ref retry(slot: _PoolSlot ref, token': _RetryToken) =>
    if token' is token then
      slot.owner.cancel_timer(timer)
      slot.owner.connect(slot)
    end
  fun ref close(slot: _PoolSlot ref) =>
    slot.owner.cancel_timer(timer)
    slot.phase = _StoppedSlot

class _StoppedSlot is _SlotPhase
  fun connection(): None => None
  fun job(): None => None
  fun code(): U64 => 5
  fun ref ready(slot: _PoolSlot ref) => None
  fun ref prepared(slot: _PoolSlot ref) => None
  fun ref result(slot: _PoolSlot ref, value: pg.Result) => None
  fun ref failed(slot: _PoolSlot ref,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError)) => None
  fun ref complete(slot: _PoolSlot ref, status: pg.TransactionStatus) => None
  fun ref dispatch(slot: _PoolSlot ref, job': _Job ref) => _Unreachable()
  fun ref retry(slot: _PoolSlot ref, token: _RetryToken) => None
  fun ref close(slot: _PoolSlot ref) => None

primitive _SharedRole
primitive _ReadRole
primitive _WriteRole

type _SessionRole is (_SharedRole | _ReadRole | _WriteRole)

class _PoolSlot
  let index: USize
  let role: _SessionRole
  let owner: _Worker ref
  var generation: U64 = 0
  var phase: _SlotPhase = _StoppedSlot

  new create(index': USize, role': _SessionRole, owner': _Worker ref) =>
    index = index'
    role = role'
    owner = owner'

class iso _Retry is TimerNotify
  let _worker: _Worker
  let _slot: USize
  let _generation: U64
  let _token: _RetryToken

  new iso create(worker: _Worker, slot: USize, generation: U64,
    token: _RetryToken)
  =>
    _worker = worker
    _slot = slot
    _generation = generation
    _token = token

  fun ref apply(timer: Timer, count: U64): Bool =>
    _worker.retry(_slot, _generation, _token)
    false

actor _Worker is (AsioEventNotify & _PGOwner)
  let _auth: TCPConnectAuth
  let _config: _Config
  let _timers: Timers
  let _err: OutStream
  let _retry_delay: U64
  embed _events: _PGEvents
  embed _slots: Array[_PoolSlot] = Array[_PoolSlot]
  embed _pending: _PendingJobs = _PendingJobs
  embed _idle: Array[USize]
  embed _write_pending: _PendingJobs = _PendingJobs
  embed _write_idle: Array[USize]
  let _split: Bool
  var _prefer_write: Bool = false
  embed _recipients: MapIs[_QueryClient, _Recipient] =
    MapIs[_QueryClient, _Recipient]
  var _stopped: Bool = false
  var _dispatching: Bool = false
  var _continuation: Bool = false
  var _diag: (pg.DiagState | None) = None
  var _pending_peak: U64 = 0
  var _inflight: U64 = 0
  let _csv: (_WorkerCSV | None)
  let _worker_id: USize
  var _csv_timer: (Timer tag | None) = None
  var _sampling: Bool = false
  let _password_observer: (_PasswordApplicationObserver | None)

  new create(auth: TCPConnectAuth, config: _Config, timers: Timers,
    err: OutStream, allocation: _SessionAllocation,
    retry_delay: U64 = 1_000_000_000,
    csv: (_WorkerCSV | None) = None, worker_id: USize = 0,
    password_observer: (_PasswordApplicationObserver | None) = None)
  =>
    _auth = auth
    _config = config
    _timers = timers
    _err = err
    _retry_delay = retry_delay
    _csv = csv
    _worker_id = worker_id
    _password_observer = password_observer
    (let pool_size, let reads, let writes) = match allocation
    | let shared: _SharedSessions => (shared.total, shared.total, USize(0))
    | let split: _SplitSessions => (split.total, split.reads, split.writes)
    end
    _split = writes > 0
    _idle = Array[USize](reads)
    _write_idle = Array[USize](writes)
    _events = _PGEvents(this)
    ifdef "conduit_diagnostic" then _diag = pg.DiagState(10, 33) end
    for index in Range(0, pool_size) do
      let role: _SessionRole = if not _split then _SharedRole
        elseif index < reads then _ReadRole else _WriteRole end
      let current = _PoolSlot(index, role, this)
      _slots.push(current)
      connect(current)
    end
    if _csv isnt None then
      _sampling = true
      let timer = Timer(_WorkerCSVTick(this), 1_000_000_000, 1_000_000_000)
      _csv_timer = timer
      _timers(consume timer)
    end

  be csv_tick() => _sample_csv()

  fun ref _sample_csv() =>
    if _stopped or not _sampling then return end
    match _csv
    | let csv: _WorkerCSV => csv.sample(_csv_snapshot())
    end

  fun _csv_snapshot(): _WorkerSample =>
    let now = Time.nanos()
    let phases = _phase_counts()
    try
      _WorkerSample(now, _worker_id, phases(0)?, phases(1)?, phases(2)?,
        phases(3)?, phases(4)?, phases(5)?, _pending_size())
    else
      _Unreachable()
      _csv_snapshot()
    end

  fun _phase_counts(): Array[U64] ref =>
    let phases = Array[U64].init(0, 6)
    for slot in _slots.values() do
      try
        let code = slot.phase.code().usize()
        phases(code)? = phases(code)? + 1
      else _Unreachable() end
    end
    phases

  be stop_sampling() => _stop_sampling()

  fun ref _stop_sampling() =>
    _sampling = false
    match _csv_timer
    | let timer: Timer tag => _timers.cancel(timer)
    end
    _csv_timer = None

  be _test_csv_sample(request: U64, receiver: _PoolProbe) =>
    receiver.csv_sample(request, _csv_snapshot())

  be _test_csv_tick_fence(request: U64) =>
    _sample_csv()
    match _csv
    | let csv: _WorkerCSV => csv._test_fence(request)
    end

  be _test_sampling(request: U64, receiver: _PoolProbe) =>
    receiver.sampling(request, _worker_id, _sampling, _stopped)

  be _event_notify(event: AsioEventID, flags: U32, arg: U32) =>
    _events.notify(event, flags)

  fun ref connect(slot: _PoolSlot ref) =>
    if _stopped then return end
    let conn = _PGConnection(this, _events, slot.index, slot.generation)
    slot.phase = _ConnectingSlot(conn)
    conn.start(pg.ServerConnectInfo(_auth, _config.dbhost, _config.dbport),
      pg.DatabaseConnectInfo(_config.user, _config.password,
        _config.database))

  fun ref _slot(conn: _PGConnection ref): _PoolSlot ref ? =>
    let slot = _slots(conn.slot)?
    if (slot.generation != conn.generation) or
      (slot.phase.connection() isnt conn) then error end
    slot

  fun ref pg_ready(conn: _PGConnection ref) =>
    try let slot = _slot(conn)?; slot.phase.ready(slot) end

  fun ref pg_prepared(conn: _PGConnection ref) =>
    try let slot = _slot(conn)?; slot.phase.prepared(slot) end

  fun ref pg_result(conn: _PGConnection ref, result: pg.Result) =>
    try let slot = _slot(conn)?; slot.phase.result(slot, result) end

  fun ref pg_failed(conn: _PGConnection ref,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError))
  =>
    try let slot = _slot(conn)?; slot.phase.failed(slot, failure) end

  fun ref pg_complete(conn: _PGConnection ref,
    status: pg.TransactionStatus)
  =>
    try let slot = _slot(conn)?; slot.phase.complete(slot, status) end

  fun ref pg_shutdown(conn: _PGConnection ref) =>
    try retire(_slot(conn)?) end

  fun ref prepare(slot: _PoolSlot ref, conn: _PGConnection ref,
    index: USize)
  =>
    if index == _Catalog.all().size() then
      slot.phase = _IdleSlot(conn)
      available(slot)
    else
      try
        let statement = _Catalog.all()(index)?
        slot.phase = _PreparingSlot(conn, index)
        conn.prepare(_Catalog.name(statement), _Catalog.sql(statement))
      else _Unreachable() end
    end

  fun ref available(slot: _PoolSlot ref) =>
    if slot.role is _WriteRole then _write_idle.push(slot.index)
    else _idle.push(slot.index) end
    _dispatch()

  fun _pending_size(): USize => _pending.size() + _write_pending.size()

  fun _can_dispatch(): Bool =>
    ((_pending.size() > 0) and (_idle.size() > 0)) or
      ((_write_pending.size() > 0) and (_write_idle.size() > 0))

  fun ref _dispatch() =>
    if _stopped or _dispatching then return end
    _dispatching = true
    var budget: USize = 64
    while _can_dispatch() and (budget > 0) do
      budget = budget - 1
      let write = (_write_pending.size() > 0) and
        (_write_idle.size() > 0) and (_prefer_write or
          (_pending.size() == 0) or (_idle.size() == 0))
      _prefer_write = not write
      if write then _dispatch_one(_write_pending, _write_idle)
      else _dispatch_one(_pending, _idle) end
    end
    _dispatching = false
    if (budget == 0) and _can_dispatch() and
      (not _continuation) then
      _continuation = true
      this._resume()
    end

  fun ref _dispatch_one(pending: _PendingJobs ref, idle: Array[USize] ref) =>
    try
      let job = pending.shift()?
      let slot = _slots(idle.pop()?)?
      job.started = _now()
      _count(1)
      _inflight = _inflight + 1
      _observe(1, job.enqueued, job.started)
      slot.phase.dispatch(slot, job)
    else _Unreachable() end

  be _resume() =>
    _continuation = false
    _dispatch()

  be query(client: _QueryClient, id: U64, statement: _RequestStatement,
    params: Array[_Param] val, sent: U64 = 0)
  =>
    let now = _now()
    if sent != 0 then _observe(0, sent, now) end
    if _stopped then
      _count(4)
      _count(5)
      client.db_failed(id, _ConnectionLost)
      return
    end
    for param in params.values() do
      match param
      | let s: String if s.contains("\0") =>
        _reject(client, id)
        return
      | let _: pg.PgArray =>
        _reject(client, id)
        return
      end
    end
    _enqueue(client, id,
      pg.NamedPreparedQuery(_Catalog.name(statement), params),
      _Catalog.kind(statement), now, _Catalog.statement_class(statement))
    _dispatch()

  fun ref _enqueue(client: _QueryClient, id: U64, query': pg.Query,
    kind: USize, now: U64, statement_class: _StatementClass)
  =>
    match _password_observer
    | let observer: _PasswordApplicationObserver =>
      observer.application_sql(client, id, kind)
    end
    let recipient = try _recipients(client)?
      else
        let fresh = _Recipient(client)
        _recipients(client) = fresh
        fresh
      end
    recipient.outstanding = recipient.outstanding + 1
    let job = _Job(recipient, id, query', kind, now)
    if _split and (statement_class is _WriteClass) then
      _write_pending.push(job)
    else _pending.push(job) end
    _count(0)
    _pending_peak = _pending_peak.max(_pending_size().u64())

  fun ref _reject(client: _QueryClient, id: U64) =>
    _count(4)
    _count(5)
    client.db_failed(id, _DataFailure)

  be cancel(client: _QueryClient) =>
    match _password_observer
    | let observer: _PasswordApplicationObserver =>
      observer.application_cancel(client)
    end
    try
      (_, let recipient) = _recipients.remove(client)?
      recipient.client = None
      _count(6)
    end

  be _password_fence(client: _QueryClient, request: U64) =>
    match _password_observer
    | let observer: _PasswordApplicationObserver =>
      observer.application_fence(client, request)
    end

  be barrier(probe: _WorkerBarrier) =>
    probe.worker_barrier(_pending_size())

  fun ref notify_failed(job: _Job ref, failure: _DBFailure) =>
    match job.recipient.client
    | let client: _QueryClient =>
      _count(5)
      client.db_failed(job.id, failure)
    end

  fun ref settle(job: _Job ref) =>
    _count(2)
    _inflight = _inflight - 1
    let now = _now()
    _observe(2, job.enqueued, now)
    if job.started != 0 then _observe(3 + job.kind, job.started, now) end
    match job.outcome
    | let result: pg.Result =>
      match job.recipient.client
      | let client: _QueryClient =>
        _count(5)
        client.db_result(job.id, result)
      end
      _count(7)
    | let failure: _DBFailure =>
      notify_failed(job, failure)
      _count(8)
    | _ReportedDataFailure => _count(8)
    else _Unreachable()
    end
    let recipient = job.recipient
    recipient.outstanding = recipient.outstanding - 1
    if recipient.outstanding == 0 then
      match recipient.client
      | let client: _QueryClient =>
        try
          if _recipients(client)? is recipient then
            _recipients.remove(client)?
          end
        else _Unreachable() end
        recipient.client = None
      end
    end

  fun ref _remove_idle(slot: _PoolSlot box) =>
    let idle = if slot.role is _WriteRole then _write_idle else _idle end
    for (position, candidate) in idle.pairs() do
      if candidate == slot.index then
        try
          idle(position)? = idle(idle.size() - 1)?
          idle.pop()?
        else _Unreachable() end
        return
      end
    end

  fun ref retire(slot: _PoolSlot ref) =>
    let old = slot.phase
    match old.connection()
    | None => return
    end
    _remove_idle(slot)
    try slot.generation = slot.generation +? 1
    else _Unreachable() end
    let token = _RetryToken
    let timer = Timer(_Retry(this, slot.index, slot.generation, token),
      _retry_delay)
    slot.phase = _BackoffSlot(token, timer)
    _timers(consume timer)
    _finish_lost(old)
    match old
    | let live: _ConnectingSlot => live.conn.close()
    | let live: _PreparingSlot => live.conn.close()
    | let live: _IdleSlot => live.conn.close()
    | let live: _BusySlot => live.conn.close()
    end
    _count(9)

  fun ref _finish_lost(phase: _SlotPhase ref) =>
    match phase
    | let busy: _BusySlot =>
      if not (busy.active.outcome is _ReportedDataFailure) then
        busy.active.outcome = _ConnectionLost
      end
      settle(busy.active)
    end

  fun ref stop_slot(slot: _PoolSlot ref) =>
    let old = slot.phase
    slot.phase = _StoppedSlot
    _remove_idle(slot)
    _finish_lost(old)
    match old
    | let live: _ConnectingSlot => live.conn.close()
    | let live: _PreparingSlot => live.conn.close()
    | let live: _IdleSlot => live.conn.close()
    | let live: _BusySlot => live.conn.close()
    end

  fun ref cancel_timer(timer: Timer tag) => _timers.cancel(timer)

  be retry(index: USize, generation: U64, token: _RetryToken) =>
    if _stopped then return end
    try
      let slot = _slots(index)?
      if slot.generation == generation then slot.phase.retry(slot, token) end
    else _Unreachable() end

  be close() =>
    if _stopped then return end
    _stopped = true
    _stop_sampling()
    for slot in _slots.values() do slot.phase.close(slot) end
    _close_pending(_pending)
    _close_pending(_write_pending)
    _recipients.clear()

  fun ref _close_pending(pending: _PendingJobs ref) =>
    while pending.size() > 0 do
      try
        let job = pending.shift()?
        _count(3)
        _inflight = _inflight + 1
        job.outcome = _ConnectionLost
        settle(job)
      else _Unreachable() end
    end

  fun ref log_failure(failure: (pg.ErrorResponseMessage |
    pg.ClientQueryError))
  =>
    match failure
    | let server: pg.ErrorResponseMessage =>
      _err.print("Database error " + server.code + ": " + server.message)
    else _err.print("Database client query error")
    end

  fun ref log_prepare(index: USize,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError))
  =>
    try
      let name = _Catalog.name(_Catalog.all()(index)?)
      match failure
      | let server: pg.ErrorResponseMessage =>
        _err.print("Database prepare " + name + " failed " + server.code +
          ": " + server.message)
      else
        _err.print("Database prepare " + name + " failed: client query error")
      end
    else _Unreachable() end

  fun _now(): U64 =>
    ifdef "conduit_diagnostic" then Time.nanos() else 0 end

  fun ref _count(index: USize) =>
    ifdef "conduit_diagnostic" then
      match _diag | let stats: pg.DiagState => stats.count(index) end
    end

  fun ref _observe(index: USize, start': U64, end': U64) =>
    ifdef "conduit_diagnostic" then
      match _diag
      | let stats: pg.DiagState => stats.observe(index, start', end')
      end
    end

  be diag_snapshot(request: U64, reporter: _DiagRecordReceiver,
    selected: USize = 0)
  =>
    ifdef "conduit_diagnostic" then
      let now = Time.nanos()
      let phases = _phase_counts()
      let pending = _pending_size().u64()
      let peak = _pending_peak
      let inflight = _inflight
      let read_age = try now - _pending.front()?.enqueued else 0 end
      let write_age = try now - _write_pending.front()?.enqueued else 0 end
      let oldest = read_age.max(write_age)
      let gauges: Array[U64] iso = recover iso Array[U64] end
      gauges.>push(pending).>push(inflight).>push(oldest).>push(peak)
      for value in phases.values() do gauges.push(value) end
      match _diag
      | let stats: pg.DiagState =>
        reporter.diag_record(stats.snapshot(1, selected, 0,
          request, now, consume gauges))
      end
      try
        let slot = _slots(selected)?
        let code = slot.phase.code()
        let age = match slot.phase.job()
          | let job: _Job box => now - job.started
          else 0
          end
        let progress = match slot.phase
          | let preparing: _PreparingSlot => preparing.index.u64()
          else _Catalog.all().size().u64()
          end
        let transport = match slot.phase.connection()
          | let connection: _PGConnection box => connection.phase_code()
          else U64(5)
          end
        let slot_gauges: Array[U64] val = [code; age; progress; transport]
        match slot.phase
        | let live: _ConnectingSlot =>
          reporter.diag_record(live.conn.snapshot(request, now, slot_gauges))
        | let live: _PreparingSlot =>
          reporter.diag_record(live.conn.snapshot(request, now, slot_gauges))
        | let live: _IdleSlot =>
          reporter.diag_record(live.conn.snapshot(request, now, slot_gauges))
        | let live: _BusySlot =>
          reporter.diag_record(live.conn.snapshot(request, now, slot_gauges))
        else reporter.diag_missing(selected, slot.generation, request,
          "unavailable")
        end
      else _Unreachable() end
    end

  be _test_state(request: U64, receiver: _PoolStateReceiver) =>
    let queued: Array[U64] iso = recover iso Array[U64] end
    let write_queued: Array[U64] iso = recover iso Array[U64] end
    let roles: Array[U64] iso = recover iso Array[U64] end
    let read_idle: Array[USize] iso = recover iso Array[USize] end
    let write_idle: Array[USize] iso = recover iso Array[USize] end
    let active: Array[(USize, U64, U64)] iso =
      recover iso Array[(USize, U64, U64)] end
    let idle: Array[USize] iso = recover iso Array[USize] end
    let phases: Array[U64] iso = recover iso Array[U64] end
    let generations: Array[U64] iso = recover iso Array[U64] end
    let tokens: Array[(_RetryToken | None)] iso =
      recover iso Array[(_RetryToken | None)] end
    let recipients = SetIs[_Recipient box]
    for job in _pending.values() do
      queued.push(job.id)
      recipients.set(job.recipient)
    end
    for job in _write_pending.values() do
      write_queued.push(job.id)
      recipients.set(job.recipient)
    end
    for slot in _slots.values() do
      roles.push(match slot.role
        | _SharedRole => 0
        | _ReadRole => 1
        | _WriteRole => 2
        end)
      phases.push(slot.phase.code())
      generations.push(slot.generation)
      match slot.phase
      | let backoff: _BackoffSlot => tokens.push(backoff.token)
      else tokens.push(None)
      end
      match slot.phase.job()
      | let job: _Job box =>
        let outcome: U64 = match job.outcome
          | _AwaitingResult => 0
          | let _: pg.Result => 1
          | let _: _SQLFailure => 2
          | _ReportedDataFailure => 3
          else 4
          end
        active.push((slot.index, job.id, outcome))
        recipients.set(job.recipient)
      end
    end
    for index in _idle.values() do
      idle.push(index)
      read_idle.push(index)
    end
    for index in _write_idle.values() do
      idle.push(index)
      write_idle.push(index)
    end
    var outstanding: USize = 0
    for recipient in recipients.values() do
      outstanding = outstanding + recipient.outstanding
    end
    receiver.state(_PoolTestState(request, consume queued, consume active,
      consume idle, consume phases, consume generations, consume tokens,
      _recipients.size(), outstanding, _worker_id, consume write_queued,
      consume roles, consume read_idle, consume write_idle))

  be _test_fence(request: U64, clients: Array[_PoolClient] val) =>
    for client in clients.values() do client.fence(request) end

  be _test_retire(index: USize) =>
    try retire(_slots(index)?) else _Unreachable() end

  be _test_query(client: _QueryClient, id: U64, query': pg.Query,
    statement_class: _StatementClass)
  =>
    if _stopped then
      _count(4)
      _count(5)
      client.db_failed(id, _ConnectionLost)
      return
    end
    _enqueue(client, id, query', 29, _now(), statement_class)
    _dispatch()

  be _test_bad_batch(count: USize, client: _QueryClient,
    request: U64, receiver: _PoolProbe)
  =>
    if _stopped then _Unreachable(); return end
    for index in Range(0, count) do
      _enqueue(client, 100_000 + index.u64(),
        pg.PreparedQuery("bad\0query", _P.none()), 29, _now(), _ReadClass)
    end
    this._test_state(request, receiver)
    _dispatch()

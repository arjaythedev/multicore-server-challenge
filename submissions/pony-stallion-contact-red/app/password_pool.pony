use "cli"
use "collections"

use @conduit_password_batch[I32](count: USize, kinds: Pointer[U8] tag,
  passwords: Pointer[Pointer[U8] tag] tag, lengths: Pointer[USize] tag,
  hashes: Pointer[Pointer[U8] tag] tag, hash_lengths: Pointer[USize] tag,
  outputs: Pointer[Pointer[U8] tag] tag, statuses: Pointer[U8] tag,
  execution: Pointer[USize] tag)
use @conduit_password_selftest[I32]()
use @conduit_password_test_batch[I32](count: USize, kinds: Pointer[U8] tag,
  passwords: Pointer[Pointer[U8] tag] tag, lengths: Pointer[USize] tag,
  hashes: Pointer[Pointer[U8] tag] tag, hash_lengths: Pointer[USize] tag,
  outputs: Pointer[Pointer[U8] tag] tag, statuses: Pointer[U8] tag,
  execution: Pointer[USize] tag, reject: I32)

interface val _PasswordStartupCheck
  fun apply(): Bool

primitive _NativePasswordStartupCheck is _PasswordStartupCheck
  fun apply(): Bool => @conduit_password_selftest() == 1

primitive _PasswordInline
primitive _PasswordScalar
primitive _PasswordInterleaved

type _PasswordMode is
  (_PasswordInline | _PasswordScalar | _PasswordInterleaved)

class val _PasswordOptions
  let mode: _PasswordMode
  let workers: USize

  new val create(vars: (Array[String] val | None), schedulers: USize) ? =>
    let e = EnvVars(vars)
    mode = match try e("BCRYPT_MODE")? else "batch" end
    | "inline" => _PasswordInline
    | "scalar" => _PasswordScalar
    | "batch" => _PasswordInterleaved
    else error
    end
    let text = try e("BCRYPT_WORKERS")? else schedulers.min(3).string() end
    if text.size() == 0 then error end
    for c in text.values() do
      if (c < '0') or (c > '9') then error end
    end
    workers = _Input.decimal(text)?.usize()
    if (workers < 1) or (workers > schedulers.min(8)) then error end

primitive _PasswordFailed
  fun string(): String => "Password processing failed"
primitive _PasswordVerified
primitive _PasswordRejected

type _HashOutcome is (String | _PasswordFailed)
type _VerifyOutcome is
  (_PasswordVerified | _PasswordRejected | _PasswordFailed)

interface tag _PasswordClient
  be password_hashed(id: U64, outcome: _HashOutcome)
  be password_verified(id: U64, outcome: _VerifyOutcome)

class val _PasswordHashJob
  let client: _PasswordClient
  let id: U64
  let password: String
  new val create(client': _PasswordClient, id': U64, password': String) =>
    client = client'
    id = id'
    password = password'

class val _PasswordVerifyJob
  let client: _PasswordClient
  let id: U64
  let password: String
  let hash: String
  new val create(client': _PasswordClient, id': U64, password': String,
    hash': String)
  =>
    client = client'
    id = id'
    password = password'
    hash = hash'

type _PasswordJob is (_PasswordHashJob | _PasswordVerifyJob)

class val _PasswordHashReply
  let job: _PasswordHashJob
  let outcome: _HashOutcome
  new val create(job': _PasswordHashJob, outcome': _HashOutcome) =>
    job = job'
    outcome = outcome'
  fun deliver() => job.client.password_hashed(job.id, outcome)

class val _PasswordVerifyReply
  let job: _PasswordVerifyJob
  let outcome: _VerifyOutcome
  new val create(job': _PasswordVerifyJob, outcome': _VerifyOutcome) =>
    job = job'
    outcome = outcome'
  fun deliver() => job.client.password_verified(job.id, outcome)

type _PasswordReply is (_PasswordHashReply | _PasswordVerifyReply)

interface tag _PasswordCompute
  be compute(jobs: Array[_PasswordJob] val)

interface tag _PasswordComputeOwner
  be computed(index: USize, replies: Array[_PasswordReply] val,
    interleaved: USize, scalar: USize)

interface val _PasswordComputeFactory
  fun apply(owner: _PasswordComputeOwner, index: USize,
    mode: _PasswordMode): _PasswordCompute

primitive _NativePasswordFactory is _PasswordComputeFactory
  fun apply(owner: _PasswordComputeOwner, index: USize,
    mode: _PasswordMode): _PasswordCompute
  =>
    _NativePasswordCompute(owner, index, mode)

interface tag _PasswordObserver
  be password_created(index: USize)
  be password_enqueued(id: U64)
  be password_selected(index: USize, count: USize)
  be password_completed(index: USize, interleaved: USize, scalar: USize)
  be password_stopped()
  be password_state(request: U64, pending: USize, busy: USize,
    idle: USize, stopped: Bool)

actor _PasswordDispatcher is _PasswordComputeOwner
  embed _pending: List[_PasswordJob] = List[_PasswordJob]
  embed _workers: Array[_PasswordCompute] = Array[_PasswordCompute]
  embed _idle: Array[USize] = Array[USize]
  embed _busy: Array[Bool] = Array[Bool]
  let _observer: (_PasswordObserver | None)
  var _continuation: Bool = false
  var _stopped: Bool = false
  var _inflight: USize = 0

  new create(options: _PasswordOptions,
    factory: _PasswordComputeFactory = _NativePasswordFactory,
    observer: (_PasswordObserver | None) = None)
  =>
    _observer = observer
    for index in Range(0, options.workers) do
      _workers.push(factory(this, index, options.mode))
      _busy.push(false)
      _idle.push(index)
      match _observer
      | let observer': _PasswordObserver => observer'.password_created(index)
      end
    end

  be submit(job: _PasswordJob) =>
    if _stopped then
      _failure(job).deliver()
      return
    end
    _pending.push(job)
    match _observer
    | let observer: _PasswordObserver =>
      observer.password_enqueued(match job
        | let h: _PasswordHashJob => h.id
        | let v: _PasswordVerifyJob => v.id
        end)
    end
    _schedule()

  fun ref _schedule() =>
    if (not _stopped) and (not _continuation) and
      (_pending.size() > 0) and (_idle.size() > 0)
    then
      _continuation = true
      _flush()
    end

  be _flush() =>
    _continuation = false
    if _stopped or (_pending.size() == 0) or (_idle.size() == 0) then
      return
    end
    try
      let index = _idle.pop()?
      let jobs = recover iso Array[_PasswordJob](4) end
      while (jobs.size() < 4) and (_pending.size() > 0) do
        jobs.push(_pending.shift()?)
      end
      _busy(index)? = true
      _inflight = _inflight + 1
      match _observer
      | let observer: _PasswordObserver =>
        observer.password_selected(index, jobs.size())
      end
      _workers(index)?.compute(consume jobs)
    else _Unreachable()
    end
    _schedule()

  be computed(index: USize, replies: Array[_PasswordReply] val,
    interleaved: USize, scalar: USize)
  =>
    try
      if not _busy(index)? then _Unreachable(); return end
      _busy(index)? = false
      _inflight = _inflight - 1
      for reply in replies.values() do reply.deliver() end
      match _observer
      | let observer: _PasswordObserver =>
        observer.password_completed(index, interleaved, scalar)
      end
      if _stopped then
        if _inflight == 0 then _report_stopped() end
      else
        _idle.push(index)
        _schedule()
      end
    else _Unreachable()
    end

  be stop() =>
    if _stopped then return end
    _stopped = true
    try
      while _pending.size() > 0 do _failure(_pending.shift()?).deliver() end
    else _Unreachable()
    end
    _idle.clear()
    if _inflight == 0 then _report_stopped() end

  fun _report_stopped() =>
    match _observer
    | let observer: _PasswordObserver => observer.password_stopped()
    end

  be _test_state(request: U64) =>
    match _observer
    | let observer: _PasswordObserver =>
      observer.password_state(request, _pending.size(), _inflight,
        _idle.size(), _stopped)
    end

  fun _failure(job: _PasswordJob): _PasswordReply =>
    match job
    | let h: _PasswordHashJob => _PasswordHashReply(h, _PasswordFailed)
    | let v: _PasswordVerifyJob => _PasswordVerifyReply(v, _PasswordFailed)
    end

actor _NativePasswordCompute is _PasswordCompute
  let _owner: _PasswordComputeOwner
  let _index: USize
  let _mode: _PasswordMode
  embed _native: _PasswordNative = _PasswordNative

  new create(owner: _PasswordComputeOwner, index: USize,
    mode: _PasswordMode)
  =>
    _owner = owner
    _index = index
    _mode = mode

  be _test_reject_next() =>
    ifdef "conduit_password_test" then _native._test_reject_next() end

  be compute(jobs: Array[_PasswordJob] val) =>
    if (jobs.size() == 0) or (jobs.size() > 4) then
      _Unreachable()
      return
    end
    if _mode is _PasswordInterleaved then
      (let replies, let interleaved, let scalar) = _native(jobs)
      _owner.computed(_index, replies, interleaved, scalar)
    else
      let replies = recover iso Array[_PasswordReply](jobs.size()) end
      for job in jobs.values() do
        match job
        | let h: _PasswordHashJob =>
          let outcome: _HashOutcome = try _Password.hash(h.password)?
            else _PasswordFailed end
          replies.push(_PasswordHashReply(h, outcome))
        | let v: _PasswordVerifyJob =>
          replies.push(_PasswordVerifyReply(v,
            if _Password.verify(v.password, v.hash) then _PasswordVerified
            else _PasswordRejected end))
        end
      end
      _owner.computed(_index, consume replies, 0, jobs.size())
    end

class _PasswordNative
  var _test_reject: Bool = false
  embed _kinds: Array[U8] = Array[U8].init(0, 4)
  embed _passwords: Array[Pointer[U8] tag] =
    Array[Pointer[U8] tag].init(Pointer[U8], 4)
  embed _lengths: Array[USize] = Array[USize].init(0, 4)
  embed _hashes: Array[Pointer[U8] tag] =
    Array[Pointer[U8] tag].init(Pointer[U8], 4)
  embed _hash_lengths: Array[USize] = Array[USize].init(0, 4)
  embed _buffers: Array[Array[U8]] = Array[Array[U8]]
  embed _outputs: Array[Pointer[U8] tag] = Array[Pointer[U8] tag]
  embed _statuses: Array[U8] = Array[U8].init(0, 4)
  embed _execution: Array[USize] = Array[USize].init(0, 2)

  new create() =>
    for index in Range(0, 4) do
      let buffer = Array[U8].init(0, 60)
      _outputs.push(buffer.cpointer())
      _buffers.push(buffer)
    end

  fun ref _test_reject_next() =>
    ifdef "conduit_password_test" then _test_reject = true
    else _Unreachable() end

  fun ref apply(jobs: Array[_PasswordJob] val):
    (Array[_PasswordReply] val, USize, USize)
  =>
    let replies = recover iso Array[_PasswordReply](jobs.size()) end
    try
      for index in Range(0, jobs.size()) do
        match jobs(index)?
        | let h: _PasswordHashJob =>
          _kinds(index)? = 0
          _passwords(index)? = h.password.cpointer()
          _lengths(index)? = h.password.size()
          _hashes(index)? = Pointer[U8]
          _hash_lengths(index)? = 0
        | let v: _PasswordVerifyJob =>
          _kinds(index)? = 1
          _passwords(index)? = v.password.cpointer()
          _lengths(index)? = v.password.size()
          _hashes(index)? = v.hash.cpointer()
          _hash_lengths(index)? = v.hash.size()
        end
      end
      let okay = ifdef "conduit_password_test" then
        let reject: I32 = if _test_reject then 1 else 0 end
        _test_reject = false
        @conduit_password_test_batch(jobs.size(), _kinds.cpointer(),
          _passwords.cpointer(), _lengths.cpointer(), _hashes.cpointer(),
          _hash_lengths.cpointer(), _outputs.cpointer(),
          _statuses.cpointer(), _execution.cpointer(), reject) == 1
      else
        @conduit_password_batch(jobs.size(), _kinds.cpointer(),
          _passwords.cpointer(), _lengths.cpointer(), _hashes.cpointer(),
          _hash_lengths.cpointer(), _outputs.cpointer(),
          _statuses.cpointer(), _execution.cpointer()) == 1
      end
      for index in Range(0, jobs.size()) do
        let status = if okay then _statuses(index)? else U8(4) end
        match jobs(index)?
        | let h: _PasswordHashJob =>
          let outcome: _HashOutcome = if status == 1 then
            let bytes: Array[U8] val = _buffers(index)?.clone()
            String.from_array(bytes)
          else _PasswordFailed end
          replies.push(_PasswordHashReply(h, outcome))
        | let v: _PasswordVerifyJob =>
          let outcome: _VerifyOutcome = match status
            | 2 => _PasswordVerified
            | 3 => _PasswordRejected
            else _PasswordFailed
            end
          replies.push(_PasswordVerifyReply(v, outcome))
        end
      end
      (consume replies, if okay then _execution(0)? else 0 end,
        if okay then _execution(1)? else 0 end)
    else
      _Unreachable()
      (recover val Array[_PasswordReply] end, 0, 0)
    end

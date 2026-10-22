use "collections"
use "net"
use "time"
use pg = "postgres"

class \nodoc\ iso _PasswordProbeInput is InputNotify
  let _owner: _PasswordProbe
  new iso create(owner: _PasswordProbe) => _owner = owner
  fun ref apply(data: Array[U8] iso) => _owner.input(consume data)
  fun ref dispose() => _owner.quit()

class \nodoc\ val _HeldPasswordFactory is _PasswordComputeFactory
  let _owner: _PasswordProbe
  new val create(owner: _PasswordProbe) => _owner = owner
  fun apply(owner: _PasswordComputeOwner, index: USize,
    mode: _PasswordMode): _PasswordCompute
  =>
    _HeldPasswordCompute(owner, index, mode, _owner)

actor \nodoc\ _HeldPasswordCompute is _PasswordCompute
  let _owner: _PasswordComputeOwner
  let _index: USize
  let _probe: _PasswordProbe
  var _jobs: (Array[_PasswordJob] val | None) = None
  let _native: _NativePasswordCompute

  new create(owner: _PasswordComputeOwner, index: USize, mode: _PasswordMode,
    probe: _PasswordProbe)
  =>
    _owner = owner
    _index = index
    _probe = probe
    _native = _NativePasswordCompute(owner, index, mode)
    _probe.compute_created(index, this)

  be compute(jobs: Array[_PasswordJob] val) =>
    if _jobs isnt None then _Unreachable() end
    _jobs = jobs
    let ids = recover iso Array[U64] end
    for job in jobs.values() do
      ids.push(match job
        | let h: _PasswordHashJob => h.id
        | let v: _PasswordVerifyJob => v.id
        end)
    end
    _probe.held(_index, consume ids)

  be release(kind: String) =>
    match _jobs = None
    | let jobs: Array[_PasswordJob] val =>
      if (kind == "real") or (kind == "reject") then
        if kind == "reject" then _native._test_reject_next() end
        _native.compute(jobs)
      else
        let replies = recover iso Array[_PasswordReply] end
        for job in jobs.values() do
          match job
          | let h: _PasswordHashJob =>
            replies.push(_PasswordHashReply(h, _PasswordFailed))
          | let v: _PasswordVerifyJob =>
            let outcome: _VerifyOutcome = match kind
              | "verified" => _PasswordVerified
              | "rejected" => _PasswordRejected
              else _PasswordFailed
              end
            replies.push(_PasswordVerifyReply(v, outcome))
          end
        end
        _owner.computed(_index, consume replies, 0, 0)
      end
    else _Unreachable()
    end

  be discard() =>
    if _jobs isnt None then release("fail") end

actor \nodoc\ _PasswordProbeClient is _PasswordClient
  let _owner: _PasswordProbe
  let _index: USize
  new create(owner: _PasswordProbe, index: USize) =>
    _owner = owner
    _index = index
  be password_hashed(id: U64, outcome: _HashOutcome) =>
    _owner.hash_reply(_index, id, outcome)
  be password_verified(id: U64, outcome: _VerifyOutcome) =>
    _owner.verify_reply(_index, id, outcome)
  be checkpoint(request: U64) => _owner.client_checkpoint(_index, request)

primitive \nodoc\ _FailedPasswordStartup is _PasswordStartupCheck
  fun apply(): Bool => false

actor \nodoc\ _PasswordProbe is
  (_PasswordObserver & _PasswordApplicationObserver & _QueryClient &
    _PasswordStartupObserver & _PasswordComputeOwner)
  let _env: Env
  var _passwords: (_PasswordDispatcher | None) = None
  var _listener: (_Listener | None) = None
  var _workers: Array[_Worker] val = recover val Array[_Worker] end
  embed _computes: Map[USize, _HeldPasswordCompute] =
    Map[USize, _HeldPasswordCompute]
  embed _connections: Array[_Connection] = Array[_Connection]
  embed _indices: MapIs[_Connection, USize] = MapIs[_Connection, USize]
  embed _clients: Array[_PasswordProbeClient] = Array[_PasswordProbeClient]
  embed _expected: Map[String, String] = Map[String, String]
  embed _retained: Array[(String, String, String)] =
    Array[(String, String, String)]
  embed _buffer: String ref = String
  embed _native: _PasswordNative = _PasswordNative
  var _quitting: Bool = false

  new create(env: Env, options: _PasswordOptions,
    config: (_Config | None) = None)
  =>
    _env = env
    _passwords = _PasswordDispatcher(options, _HeldPasswordFactory(this), this)
    for index in Range(0, 2) do _clients.push(_PasswordProbeClient(this, index))
    end
    match config
    | let c: _Config =>
      let worker = _Worker(TCPConnectAuth(env.root), c, Timers, env.err, 1
        where password_observer = this)
      _workers = recover val [worker] end
      _listener = _Listener(TCPListenAuth(env.root), c, _workers, env,
        recover val Array[_DiagReporter] end, _passwords, this)
    end
    env.input(_PasswordProbeInput(this))
    _emit("started")

  new startup(env: Env) => _env = env

  fun _emit(event: String, fields: String = "") =>
    _env.out.print("{\"event\":\"" + event + "\"" + fields + "}")

  fun _number(name: String, value: U64): String =>
    ",\"" + name + "\":" + value.string()

  fun _boolean(name: String, value: Bool): String =>
    ",\"" + name + "\":" + value.string()

  fun _ids(values: Array[U64] val): String =>
    let text = String.>append("[")
    var first = true
    for value in values.values() do
      if not first then text.append(",") end
      first = false
      text.append(value.string())
    end
    text.append("]")
    text.clone()

  fun ref _index(connection: _Connection): USize =>
    try _indices(connection)?
    else
      let index = _connections.size()
      _connections.push(connection)
      _indices(connection) = index
      index
    end

  be compute_created(index: USize, compute: _HeldPasswordCompute) =>
    _computes(index) = compute

  be held(index: USize, ids: Array[U64] val) =>
    _emit("held", _number("worker", index.u64()) + ",\"ids\":" + _ids(ids))

  be password_created(index: USize) =>
    _emit("created", _number("worker", index.u64()))

  be password_enqueued(id: U64) => _emit("enqueued", _number("id", id))

  be password_selected(index: USize, count: USize) =>
    _emit("selected", _number("worker", index.u64()) +
      _number("count", count.u64()))

  be password_completed(index: USize, interleaved: USize, scalar: USize) =>
    _emit("completed", _number("worker", index.u64()) +
      _number("interleaved", interleaved.u64()) +
      _number("scalar", scalar.u64()))

  be computed(index: USize, replies: Array[_PasswordReply] val,
    interleaved: USize, scalar: USize)
  =>
    for reply in replies.values() do reply.deliver() end
    _emit("actual", _number("interleaved", interleaved.u64()) +
      _number("scalar", scalar.u64()))

  be password_stopped() =>
    _emit("stopped")

  be client_checkpoint(client: USize, request: U64) =>
    _emit("client_checkpoint", _number("client", client.u64()) +
      _number("request", request))

  be password_state(request: U64, pending: USize, busy: USize,
    idle: USize, stopped: Bool)
  =>
    _emit("pool", _number("request", request) +
      _number("pending", pending.u64()) + _number("busy", busy.u64()) +
      _number("idle", idle.u64()) + _boolean("stopped", stopped))

  be password_startup(mode: _PasswordMode, workers: USize,
    passwords: (_PasswordDispatcher | None))
  =>
    _passwords = passwords
    _emit("startup", _number("workers", workers.u64()) +
      _boolean("inline", mode is _PasswordInline) +
      _boolean("pool", passwords isnt None))

  be password_server(workers: Array[_Worker] val, listener: _Listener) =>
    _workers = workers
    _listener = listener
    if _quitting then
      for worker in workers.values() do worker.close() end
      listener.dispose()
      return
    end
    _env.input(_PasswordProbeInput(this))
    _emit("started")

  be password_listener_closed() => _emit("listener_closed")

  be application_accepted(connection: _Connection, id: U64, queued: Bool,
    epoch: U64, pending: Array[U64] val)
  =>
    _emit("accepted", _number("connection", _index(connection).u64()) +
      _number("id", id) + _boolean("queued", queued) +
      _number("epoch", epoch) + ",\"pending\":" + _ids(pending))

  be application_wait(connection: _Connection, id: U64, hash: Bool) =>
    _emit("wait", _number("connection", _index(connection).u64()) +
      _number("id", id) + _boolean("hash", hash))

  be application_database(connection: _Connection, id: U64, queued: Bool) =>
    _emit("database", _number("connection", _index(connection).u64()) +
      _number("id", id) + _boolean("queued", queued))

  be application_physical_close(connection: _Connection, operations: USize,
    responders: USize, body: USize)
  =>
    _emit("physical", _number("connection", _index(connection).u64()) +
      _number("operations", operations.u64()) +
      _number("responders", responders.u64()) + _number("body", body.u64()))

  be application_state(connection: _Connection, request: U64,
    accepted: U64, operations: USize, responders: USize, body: USize,
    pending: USize, waiting: U64, hash: Bool, closed: Bool)
  =>
    _emit("connection", _number("connection", _index(connection).u64()) +
      _number("request", request) + _number("accepted", accepted) +
      _number("operations", operations.u64()) +
      _number("responders", responders.u64()) + _number("body", body.u64()) +
      _number("pending", pending.u64()) + _number("waiting", waiting) +
      _boolean("hash", hash) + _boolean("closed", closed))

  be application_paused(connection: _Connection, epoch: U64,
    pending: Array[U64] val)
  =>
    _emit("paused", _number("connection", _index(connection).u64()) +
      _number("epoch", epoch) + ",\"pending\":" + _ids(pending))

  be application_logical_close(connection: _Connection) =>
    _emit("logical", _number("connection", _index(connection).u64()))

  be application_sql(client: _QueryClient, id: U64, kind: USize) =>
    match client
    | let connection: _Connection =>
      _emit("sql", _number("connection", _index(connection).u64()) +
        _number("id", id) + _number("kind", kind.u64()))
    end

  be application_cancel(client: _QueryClient) =>
    match client
    | let connection: _Connection =>
      _emit("cancel", _number("connection", _index(connection).u64()))
    end

  be application_fence(client: _QueryClient, request: U64) =>
    match client
    | let connection: _Connection =>
      _emit("fence", _number("connection", _index(connection).u64()) +
        _number("request", request))
    end

  be db_result(id: U64, result: pg.Result) =>
    _emit("barrier", _number("id", id))

  be db_failed(id: U64, failure: _DBFailure) =>
    _env.err.print("Password probe database barrier failed")
    _env.exitcode(1)
    quit()

  be hash_reply(client: USize, id: U64, outcome: _HashOutcome) =>
    var valid = true
    for (password, hash, copy) in _retained.values() do
      valid = valid and (hash == copy) and _Password.verify(password, hash)
    end
    let kind = match outcome
      | let hash: String =>
        try
          let password = _expected(client.string() + ":" + id.string())?
          valid = valid and (hash.size() == 60) and
            _Password.verify(password, hash)
          let copy: String val = hash.clone()
          _retained.push((password, hash, copy))
        else valid = false end
        "hashed"
      else "failed"
      end
    _emit("reply", _number("client", client.u64()) + _number("id", id) +
      ",\"kind\":\"" + kind + "\"" + _boolean("valid", valid) +
      _boolean("hash", true))

  be verify_reply(client: USize, id: U64, outcome: _VerifyOutcome) =>
    let kind = match outcome
      | _PasswordVerified => "verified"
      | _PasswordRejected => "rejected"
      else "failed"
      end
    _emit("reply", _number("client", client.u64()) + _number("id", id) +
      ",\"kind\":\"" + kind + "\"" + _boolean("hash", false))

  fun _key(kind: String, id: U64): String =>
    match kind
    | "empty" => ""
    | "nul" => "a\0b" + id.string()
    | "utf8" => "pässwörd" + id.string()
    | "utf72" | "utf73" =>
      let text = String
      for i in Range(0, 36) do text.append("é") end
      if kind == "utf73" then text.push('x') end
      text.clone()
    | "71" => String.from_array(recover val Array[U8].init('p', 71) end)
    | "72" => String.from_array(recover val Array[U8].init('p', 72) end)
    | "73" => String.from_array(recover val Array[U8].init('p', 73) end)
    else "probe-" + id.string()
    end

  fun ref _job(words: Array[String] box): _PasswordJob ? =>
    let client = words(1)?.usize()?
    let id = words(2)?.u64()?
    let password = _key(words(4)?, id)
    _expected(client.string() + ":" + id.string()) = password
    if words(3)? == "hash" then
      _PasswordHashJob(_clients(client)?, id, password)
    else
      let hash = _Password.hash(password)?
      _PasswordVerifyJob(_clients(client)?, id,
        if words(3)? == "wrong" then password + "!" else password end, hash)
    end

  be input(data: Array[U8] val) =>
    _buffer.append(String.from_array(data))
    while true do
      let position = try _buffer.find("\n")? else break end
      let line: String val = _buffer.substring(0, position)
      _buffer.delete(0, position.usize() + 1)
      try _command(line)?
      else
        _env.err.print("Invalid password probe command")
        _env.exitcode(1)
        quit()
      end
    end

  fun ref _command(line: String) ? =>
    let w: Array[String] val = line.split()
    match w(0)?
    | "job" => (_passwords as _PasswordDispatcher).submit(_job(w)?)
    | "release" => _computes(w(1)?.usize()?)?.release(w(2)?)
    | "state" => (_passwords as _PasswordDispatcher)._test_state(w(1)?.u64()?)
    | "clients" =>
      for client in _clients.values() do client.checkpoint(w(1)?.u64()?) end
    | "stop" => (_passwords as _PasswordDispatcher).stop()
    | "adapter" | "compute" =>
      let jobs = recover iso Array[_PasswordJob] end
      let n = w(1)?.usize()?
      for i in Range(0, n) do
        let id: String val = (w(2)?.u64()? + i.u64()).string()
        let kind = w(3)?
        let scenario = w(4)?
        let command: Array[String] val = recover val
          ["job"; "0"; id; kind; scenario]
        end
        jobs.push(_job(command)?)
      end
      if w(0)? == "compute" then
        _NativePasswordCompute(this, 99,
          if w(5)? == "scalar" then _PasswordScalar
          else _PasswordInterleaved end).compute(consume jobs)
      else
        (let replies, let interleaved, let scalar) = _native(consume jobs)
        for reply in replies.values() do reply.deliver() end
        _emit("adapter", _number("interleaved", interleaved.u64()) +
          _number("scalar", scalar.u64()))
      end
    | "reject-next" => _native._test_reject_next()
    | "check-hash" =>
      _emit("checked", _boolean("valid", _Password.verify(w(1)?, w(2)?)))
    | "connstate" =>
      _connections(w(1)?.usize()?)?._password_state(w(2)?.u64()?)
    | "drain" =>
      _connections(w(1)?.usize()?)?._password_release_drain(w(2)?.u64()?)
    | "pause-drains" =>
      _connections(w(1)?.usize()?)?._password_pause_drains()
    | "close" => _connections(w(1)?.usize()?)?._password_close_transport()
    | "repeatclose" => _connections(w(1)?.usize()?)?._password_repeat_close()
    | "handler-close" =>
      _connections(w(1)?.usize()?)?._password_close_handler_probe()
    | "listener-close" =>
      (_listener as _Listener).dispose()
    | "continuation-error" =>
      _connections(w(1)?.usize()?)?._password_continuation_error()
    | "replay" => _connections(w(1)?.usize()?)?._password_replay_operation()
    | "bad-hash" =>
      _connections(w(1)?.usize()?)?.password_hashed(w(2)?.u64()?,
        _PasswordFailed)
    | "bad-verify" =>
      _connections(w(1)?.usize()?)?.password_verified(w(2)?.u64()?,
        _PasswordVerified)
    | "late-db" =>
      _connections(w(1)?.usize()?)?.db_failed(w(2)?.u64()?, _DataFailure)
    | "bad-row" =>
      let row = pg.Row(recover val [as pg.FieldData: "bad"] end)
      let rows: pg.Rows = recover val [row] end
      _connections(w(1)?.usize()?)?.db_result(w(2)?.u64()?,
        pg.ResultSet(pg.PreparedQuery("", _P.none()), rows))
    | "barrier" => _workers(0)?.query(this, w(1)?.u64()?, _Tags, _P.none())
    | "quit" => quit()
    else error
    end

  be quit() =>
    if _quitting then return end
    _quitting = true
    match _passwords | let pool: _PasswordDispatcher => pool.stop() end
    match _listener | let listener: _Listener => listener.dispose() end
    for connection in _connections.values() do
      connection._password_release_all()
      connection._password_close_transport()
    end
    for compute in _computes.values() do compute.discard() end
    for worker in _workers.values() do worker.close() end
    _env.input.dispose()

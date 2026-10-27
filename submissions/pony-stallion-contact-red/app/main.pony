use "cli"
use "collections"
use "net"
use "time"
use pg = "postgres"
use runtime = "runtime_info"
use stallion = "stallion"
use uri = "uri"

actor Main
  """Runs the Conduit API server."""
  new create(env: Env) =>
    """Run a requested test mode or start the HTTP listener."""
    let production = match _DatabaseOptions(env.args,
      runtime.Scheduler.schedulers(runtime.SchedulerInfoAuth(env.root)).usize())
    | let layout: _DatabaseLayout => layout
    | let failure: _WorkerCountError =>
      env.err.print(failure.string())
      env.exitcode(1)
      return
    end
    try
      var test_http = false
      var password_startup = false
      var password_startup_failure = false
      for arg in env.args.values() do
        if arg == "--self-test" then
          _SelfTest(env)
          return
        elseif arg == "--test-pending-jobs" then
          _PendingJobsTest(env)?
          return
        elseif arg == "--test-query-storage" then
          let config = _Config(env.vars)?
          let options = _StorageOptions(env.vars)?
          _QueryStorageTest(TCPConnectAuth(env.root), config, env, options)
          return
        elseif arg == "--test-diag-arithmetic" then
          _DiagArithmeticTest(env)
          return
        elseif arg == "--test-csv-tick" then
          _WorkerCSVTickTest(env)
          return
        elseif (arg == "--test-pool") or (arg == "--test-pool-csv") or
          (arg == "--test-listener-csv") then
          let config = _Config(env.vars)?
          let layout = _TestDatabaseLayout(env.vars,
            if arg == "--test-listener-csv" then 4 else 1 end)?
          _PoolProbe(TCPConnectAuth(env.root), config, env, layout,
            arg != "--test-pool", arg == "--test-listener-csv")
          return
        elseif arg == "--test-named-rollback" then
          let config = _Config(env.vars)?
          _RollbackTest(TCPConnectAuth(env.root), config, env)
          return
        elseif arg == "--test-session-boundary" then
          let config = _Config(env.vars)?
          _SessionBoundaryTest(TCPConnectAuth(env.root), config, env)
          return
        elseif arg == "--test-dns-progress" then
          let config = _Config(env.vars)?
          _DNSProgressTest(TCPConnectAuth(env.root), config, env)
          return
        elseif arg == "--test-session-shutdown" then
          let config = _Config(env.vars)?
          _SessionShutdownTest(TCPConnectAuth(env.root), config, env)
          return
        elseif arg == "--test-session-resume-close" then
          let config = _Config(env.vars)?
          _SessionResumeAfterCloseTest(TCPConnectAuth(env.root), config, env)
          return
        elseif arg == "--test-startup-shutdown" then
          let config = _Config(env.vars)?
          _StartupShutdownTest(TCPConnectAuth(env.root), config, env)
          return
        elseif arg == "--test-connection-nul" then
          let config = _Config(env.vars)?
          _ConnectionNulTest(TCPConnectAuth(env.root), config, env)
          return
        elseif arg == "--test-queue-drain" then
          let config = _Config(env.vars)?
          _QueueDrainTest(TCPConnectAuth(env.root), config, env)
          return
        elseif arg == "--test-result-shapes" then
          let config = _Config(env.vars)?
          _ResultShapeTest(TCPConnectAuth(env.root), config, env)
          return
        elseif (arg == "--test-decode-scalar") or
          (arg == "--test-decode-atomic") then
          let config = _Config(env.vars)?
          let case' = if arg == "--test-decode-scalar" then
            _ScalarDecodeCase.scalar(env.vars)?
          else _ScalarDecodeCase.atomic(env.vars)? end
          _ScalarDecodeTest(TCPConnectAuth(env.root), config, env, case')
          return
        elseif arg == "--test-worker-data-error" then
          let config = _Config(env.vars)?
          _WorkerDataErrorTest(TCPConnectAuth(env.root), config, env,
            _TestDatabaseLayout(env.vars, 1)?, false)
          return
        elseif arg == "--test-worker-decode-error" then
          let config = _Config(env.vars)?
          _WorkerDataErrorTest(TCPConnectAuth(env.root), config, env,
            _TestDatabaseLayout(env.vars, 1)?, true)
          return
        elseif arg == "--test-worker-overlap" then
          let config = _Config(env.vars)?
          _WorkerOverlapTest(TCPConnectAuth(env.root), config, env,
            _TestDatabaseLayout(env.vars, 1)?)
          return
        elseif arg == "--test-worker-close-drain" then
          let config = _Config(env.vars)?
          _WorkerCloseTest(TCPConnectAuth(env.root), config, env,
            _TestDatabaseLayout(env.vars, 1)?)
          return
        elseif arg == "--test-worker-pending-cancel" then
          let config = _Config(env.vars)?
          _WorkerPendingCancelTest(TCPConnectAuth(env.root), config, env,
            _TestDatabaseLayout(env.vars, 1)?)
          return
        elseif arg == "--test-http" then
          test_http = true
        elseif (arg == "--test-password-async") or
          (arg == "--test-password-http") then
          let options = _PasswordOptions(env.vars,
            runtime.Scheduler.schedulers(runtime.SchedulerInfoAuth(env.root))
              .usize())?
          _PasswordProbe(env, options,
            if arg == "--test-password-http" then _Config(env.vars)?
            else None end)
          return
        elseif (arg == "--test-password-startup") or
          (arg == "--test-password-startup-failure") then
          password_startup = true
          password_startup_failure = arg == "--test-password-startup-failure"
        elseif arg == "--test-worker-diagnostic" then
          ifdef "conduit_diagnostic" then
            let config = _Config(env.vars)?
            _WorkerDiagnosticTest(TCPConnectAuth(env.root), config, env,
              _TestDatabaseLayout(env.vars, 1)?)
          else
            env.err.print("This test requires a diagnostic build")
            env.exitcode(1)
          end
          return
        end
      end
      let layout = if test_http then
        _TestDatabaseLayout(env.vars, production.sizes.size())?
      else production end
      if password_startup then
        _start(env, _Config(env.vars)?, layout, test_http,
          _PasswordProbe.startup(env) where password_check =
            if password_startup_failure then _FailedPasswordStartup
            else _NativePasswordStartupCheck end)
      else _start(env, _Config(env.vars)?, layout, test_http) end
    else
      env.err.print("Invalid configuration: DATABASE_URL and JWT_SECRET "
        + "are required; HOST and PORT must be valid. In worker and HTTP "
        + "test modes, CONDUIT_TEST_POOL_SIZE must be 1..95 (default 1), "
        + "with at most 95 total connections.")
      env.exitcode(1)
    end

  fun _start(env: Env, config: _Config, layout: _DatabaseLayout,
    csv_sampling: Bool,
    password_observer: (_PasswordStartupObserver | None) = None,
    password_factory: _PasswordComputeFactory = _NativePasswordFactory,
    password_check: _PasswordStartupCheck = _NativePasswordStartupCheck)
  =>
    let password_options = try
      _PasswordOptions(env.vars,
        runtime.Scheduler.schedulers(runtime.SchedulerInfoAuth(env.root))
          .usize())?
    else
      env.err.print("Invalid BCRYPT_MODE or BCRYPT_WORKERS: modes are "
        + "inline, scalar, batch; workers must be 1..min(8, schedulers).")
      env.exitcode(1)
      return
    end
    if (password_options.mode is _PasswordInterleaved) and
      (not password_check())
    then
      env.err.print("Bcrypt batch self-test failed")
      env.exitcode(1)
      return
    end
    let passwords: (_PasswordDispatcher | None) =
      if password_options.mode is _PasswordInline then None
      else _PasswordDispatcher(password_options, password_factory,
        password_observer) end
    match password_observer
    | let observer: _PasswordStartupObserver =>
      observer.password_startup(password_options.mode,
        password_options.workers, passwords)
    end
    let db_auth = TCPConnectAuth(env.root)
    let timers = Timers
    let csv = ifdef "conduit_diagnostic" then
      _WorkerCSV(env.out)
    else
      if csv_sampling then _WorkerCSV(env.out) else None end
    end
    let workers = recover iso Array[_Worker] end
    let reporters = recover iso Array[_DiagReporter] end
    let actor_count = layout.sizes.size()
    for index in Range(0, actor_count) do
      let worker = _Worker(db_auth, config, timers, env.err,
        layout.pool_size(index) where csv = csv, worker_id = index)
      workers.push(worker)
      ifdef "conduit_diagnostic" then
        let reporter = _DiagReporter(env.out, timers, layout.pool_size(index),
          index, actor_count, layout.total)
        reporter.register(worker)
        reporters.push(reporter)
      end
    end
    let shared_workers: Array[_Worker] val = consume workers
    let listener = _Listener(TCPListenAuth(env.root), config,
      shared_workers, env,
      consume reporters, passwords
      where startup_observer = password_observer)
    match password_observer
    | let observer: _PasswordStartupObserver =>
      observer.password_server(shared_workers, listener)
    end

  fun @runtime_override_defaults(rto: RuntimeOptions) =>
    rto.ponynoblock = true
    rto.ponynoscale = true
    rto.ponypin     = true

class val _Config
  let host: String
  let port: String
  let secret: String
  let dbhost: String
  let dbport: String
  let user: String
  let password: String
  let database: String
  let http: stallion.ServerConfig

  new val create(vars: (Array[String] val | None)) ? =>
    let e = EnvVars(vars)
    host = try e("HOST")? else "127.0.0.1" end
    port = try e("PORT")? else "3000" end
    let p = _Input.decimal(port)?
    if (p < 1) or (p > 65535) or (host.size() == 0) then error end
    http = stallion.ServerConfig(host, port where
      idle_timeout' = MakeIdleTimeout(75_000) as IdleTimeout)
    secret = e("JWT_SECRET")?
    if secret.size() == 0 then error end
    let url = uri.ParseURI(e("DATABASE_URL")?) as uri.URI
    match url.scheme
    | "postgres" | "postgresql" => None
    else error
    end
    let a = url.authority as uri.URIAuthority
    let host': String val = a.host
    dbhost = if host'.at("[") then
      host'.substring(1, host'.size().isize() - 1)
    else host'
    end
    dbport = match a.port
      | let n: U16 => n.string()
      else "5432"
      end
    let credentials = (a.userinfo as String).split(":" where n = 2)
    user = uri.PercentDecode(credentials(0)?) as String
    password = uri.PercentDecode(credentials(1)?) as String
    let path: String val = url.path.substring(1)
    database = uri.PercentDecode(path) as String
    if (dbhost.size() == 0) or (user.size() == 0)
      or (database.size() == 0) then error end
    if dbhost.contains("\0") or user.contains("\0") or
      password.contains("\0") or database.contains("\0") then error end

actor _Listener is TCPListenerActor
  var _tcp: TCPListener = TCPListener.none()
  let _auth: TCPServerAuth
  let _config: stallion.ServerConfig
  let _workers: Array[_Worker] val
  var _next_worker: USize = 0
  let _env: Env
  let _secret: String
  let _diag_reporters: Array[_DiagReporter] val
  let _passwords: (_PasswordDispatcher | None)
  let _password_observer: (_PasswordApplicationObserver | None)
  let _startup_observer: (_PasswordStartupObserver | None)

  new create(auth: TCPListenAuth, config: _Config,
    workers: Array[_Worker] val, env: Env,
    reporters: Array[_DiagReporter] val,
    passwords: (_PasswordDispatcher | None) = None,
    password_observer: (_PasswordApplicationObserver | None) = None,
    startup_observer: (_PasswordStartupObserver | None) = None)
  =>
    _auth = TCPServerAuth(auth)
    _config = config.http
    _workers = workers
    _env = env
    _secret = config.secret
    _diag_reporters = reporters
    _passwords = passwords
    _password_observer = password_observer
    _startup_observer = startup_observer
    _tcp = TCPListener(auth, config.host, config.port, this)

  fun ref _listener(): TCPListener => _tcp

  fun ref _on_accept(fd: U32): TCPConnectionActor ? =>
    try
      let worker = _workers(_next_worker)?
      _next_worker = (_next_worker + 1) % _workers.size()
      _Connection(_auth, fd, _config, worker, _secret, _passwords,
        _password_observer)
    else
      _Unreachable()
      error
    end

  fun ref _on_listen_failure() =>
    match _passwords
    | let passwords: _PasswordDispatcher => passwords.stop()
    end
    for reporter in _diag_reporters.values() do reporter.stop() end
    _env.err.print("Unable to listen")
    _env.exitcode(1)
    for worker in _workers.values() do worker.close() end

  fun ref _on_closed() =>
    for reporter in _diag_reporters.values() do reporter.stop() end
    for worker in _workers.values() do worker.stop_sampling() end
    match _startup_observer
    | let observer: _PasswordStartupObserver =>
      observer.password_listener_closed()
    end

actor _Connection is
  (stallion.HTTPServerActor & _QueryClient & _PasswordClient)
  var _http: stallion.HTTPServer = stallion.HTTPServer.none()
  let _worker: _Worker
  let _secret: String
  let _passwords: (_PasswordDispatcher | None)
  let _password_observer: (_PasswordApplicationObserver | None)
  var _drain_epoch: U64 = 0
  var _paused_epoch: U64 = 0
  var _test_pause_drains: Bool = false
  var _test_replay_password: Bool = false
  embed _application_events: List[_ApplicationEvent] = List[_ApplicationEvent]
  var _password_wait: (_ConnectionPasswordWait | None) = None
  var _draining_application: Bool = false
  var _transport_closed: Bool = false
  var _application_closed: Bool = false
  embed _operations: Map[U64, _Operation] = Map[U64, _Operation]
  embed _responders: Map[U64, stallion.Responder] =
    Map[U64, stallion.Responder]
  var _body: Array[U8] iso = recover iso Array[U8](1024) end
  var _id: U64 = 0

  new create(auth: TCPServerAuth, fd: U32, config: stallion.ServerConfig,
    worker: _Worker, secret: String,
    passwords: (_PasswordDispatcher | None) = None,
    password_observer: (_PasswordApplicationObserver | None) = None)
  =>
    _worker = worker
    _secret = secret
    _passwords = passwords
    _password_observer = password_observer
    _http = stallion.HTTPServer(auth, fd, this, config)

  fun ref _http_connection(): stallion.HTTPServer => _http

  fun ref on_body_chunk(data: Array[U8] val) =>
    if _transport_closed then return end
    let offset = _body.size()
    _body.undefined(offset + data.size())
    _body.copy_from(data, 0, offset, data.size())

  fun ref on_request_complete(request': stallion.Request val,
    responder: stallion.Responder)
  =>
    if _transport_closed then return end
    let body = _body = recover iso Array[U8](1024) end
    let text: String val = String.from_iso_array(consume body)
    _id = _id + 1
    _responders(_id) = responder
    let request'' = (_RequestTag, this, _id, request', text, _secret)
    let operation = _Operation(request'', _worker, _passwords)
    _operations(_id) = operation
    let queued = _defer_application()
    let epoch = _paused_epoch
    if queued then _queue_application(_StartApplication(_id))
    else _start_application(_id) end
    match _password_observer
    | let observer: _PasswordApplicationObserver =>
      observer.application_accepted(this, _id, queued, epoch, _pending_ids())
    end

  be db_result(id: U64, result: pg.Result) =>
    if _transport_closed then return end
    let queued = _defer_application()
    if queued then
      _queue_application(_DatabaseApplicationResult(id, result))
    else _result_application(id, result) end
    match _password_observer
    | let observer: _PasswordApplicationObserver =>
      observer.application_database(this, id, queued)
    end

  fun ref _start_application(id: U64) =>
    try
      let operation = _operations(id)?
      operation.start()
      _observe_password(id, operation)
      _settle(id)
    else _Unreachable()
    end

  be db_failed(id: U64, failure: _DBFailure) =>
    if _transport_closed then return end
    let queued = _defer_application()
    if queued then
      _queue_application(_DatabaseApplicationFailure(id, failure))
    else _failed_application(id, failure) end
    match _password_observer
    | let observer: _PasswordApplicationObserver =>
      observer.application_database(this, id, queued)
    end

  fun ref _result_application(id: U64, result: pg.Result) =>
    try
      let operation = _operations(id)?
      operation.result(result)
      _observe_password(id, operation)
      _settle(id)
    end

  fun ref _failed_application(id: U64, failure: _DBFailure) =>
    try
      _operations(id)?.failed(failure)
      _settle(id)
    end

  fun ref _observe_password(id: U64, operation: _Operation) =>
    match operation.password_waiting()
    | _HashWaiting => _install_password_wait(id, true)
    | _VerifyWaiting => _install_password_wait(id, false)
    end

  fun ref _install_password_wait(id: U64, hash: Bool) =>
    _password_wait = _ConnectionPasswordWait(id, hash)
    match _password_observer
    | let observer: _PasswordApplicationObserver =>
      observer.application_wait(this, id, hash)
    end

  fun _pending_ids(): Array[U64] val =>
    let ids = recover iso Array[U64] end
    for event in _application_events.values() do
      match event
      | let start: _StartApplication => ids.push(start.id)
      | let result: _DatabaseApplicationResult => ids.push(result.id)
      | let failure: _DatabaseApplicationFailure => ids.push(failure.id)
      else ids.push(0)
      end
    end
    consume ids

  fun _defer_application(): Bool =>
    (_password_wait isnt None) or _draining_application or
      (_application_events.size() > 0)

  fun ref _queue_application(event: _ApplicationEvent) =>
    _application_events.push(event)
    _schedule_application()

  fun ref _schedule_application() =>
    if (not _application_closed) and (not _draining_application) and
      (_password_wait is None) and (_application_events.size() > 0)
    then
      _draining_application = true
      _drain_application()
    end

  be _drain_application() =>
    var remaining: USize = 64
    try
      while (remaining > 0) and (_password_wait is None) and
        (not _application_closed) and (_application_events.size() > 0)
      do
        _application_events.shift()?.apply(this)
        remaining = remaining - 1
      end
    else _Unreachable()
    end
    if _test_pause_drains and (remaining == 0) and (_password_wait is None) and
      (not _application_closed) and (_application_events.size() > 0)
    then
      match _password_observer
      | let observer: _PasswordApplicationObserver =>
        _drain_epoch = _drain_epoch + 1
        _paused_epoch = _drain_epoch
        observer.application_paused(this, _paused_epoch, _pending_ids())
        return
      end
    end
    _draining_application = false
    _schedule_application()

  be _password_pause_drains() => _test_pause_drains = true

  be _password_release_drain(epoch: U64) =>
    if (epoch != 0) and (_paused_epoch == epoch) then
      _paused_epoch = 0
      _drain_application()
    end

  be _password_state(request: U64) =>
    match _password_observer
    | let observer: _PasswordApplicationObserver =>
      let waiting: U64 = match _password_wait
        | let wait: _ConnectionPasswordWait => wait.id else 0 end
      let hash = match _password_wait
        | let wait: _ConnectionPasswordWait => wait.hash else false end
      observer.application_state(this, request, _id, _operations.size(),
        _responders.size(), _body.size(), _application_events.size(),
        waiting, hash, _application_closed)
      _worker._password_fence(this, request)
    end

  be _password_close_transport() => _http.close()

  be _password_release_all() =>
    if _paused_epoch != 0 then
      _paused_epoch = 0
      _drain_application()
    end

  be _password_repeat_close() => on_closed()

  be _password_close_handler_probe() =>
    try
      let responder = _responders(_id)?
      let request = _operations(_id)?._test_request()
      on_closed()
      on_body_chunk(recover val [as U8: 'x'] end)
      on_request_complete(request, responder)
    else _Unreachable()
    end

  be _password_continuation_error() =>
    match _password_wait
    | let wait: _ConnectionPasswordWait =>
      try _operations(wait.id)?._test_password_continuation_error()
      else _Unreachable() end
    end

  be _password_replay_operation() => _test_replay_password = true

  be password_hashed(id: U64, outcome: _HashOutcome) =>
    match _password_wait
    | let wait: _ConnectionPasswordWait if (wait.id == id) and wait.hash =>
      _password_wait = None
      try
        let operation = _operations(id)?
        operation.hashed(outcome)
        if _test_replay_password then
          _test_replay_password = false
          operation.hashed(outcome)
        end
        _observe_password(id, operation)
        _settle(id)
      else _Unreachable()
      end
      _schedule_application()
    end

  be password_verified(id: U64, outcome: _VerifyOutcome) =>
    match _password_wait
    | let wait: _ConnectionPasswordWait if (wait.id == id) and
      (not wait.hash) =>
      _password_wait = None
      try
        let operation = _operations(id)?
        operation.verified(outcome)
        if _test_replay_password then
          _test_replay_password = false
          operation.verified(outcome)
        end
        _observe_password(id, operation)
        _settle(id)
      else _Unreachable()
      end
      _schedule_application()
    end

  fun ref _settle(id: U64) =>
    try
      match _operations(id)?.outcome()
      | (let status: U16, let body: String) =>
        _operations.remove(id)?
        _reply(id, status, body)
      end
    end

  be reply(id: U64, status: U16, body: String) =>
    _reply(id, status, body)

  fun ref _reply(id: U64, status: U16, body: String) =>
    try
      (_, let responder) = _responders.remove(id)?
      let s: stallion.Status = match status
        | 200 => stallion.StatusOK
        | 201 => stallion.StatusCreated
        | 204 => stallion.StatusNoContent
        | 401 => stallion.StatusUnauthorized
        | 403 => stallion.StatusForbidden
        | 404 => stallion.StatusNotFound
        | 422 => stallion.StatusUnprocessableEntity
        | 503 => stallion.StatusServiceUnavailable
        else stallion.StatusInternalServerError
        end
      responder.respond(stallion.ResponseBuilder(s)
        .add_header("Content-Type", "application/json")
        .add_header("Content-Length", body.size().string())
        .finish_headers().add_chunk(body).build())
    end

  fun ref on_closed() =>
    if _transport_closed then return end
    _transport_closed = true
    _responders.clear()
    _body.clear()
    match _password_observer
    | let observer: _PasswordApplicationObserver =>
      observer.application_physical_close(this, _operations.size(),
        _responders.size(), _body.size())
    end
    if _defer_application() then _queue_application(_CloseApplication)
    else _close_application() end

  fun ref _close_application() =>
    if _application_closed then return end
    if _operations.size() > 0 then _worker.cancel(this) end
    _operations.clear()
    _application_events.clear()
    _application_closed = true
    match _password_observer
    | let observer: _PasswordApplicationObserver =>
      observer.application_logical_close(this)
      _worker._password_fence(this, 0)
    end

primitive _RequestTag

type _Request is
  (_RequestTag, _Connection, U64, stallion.Request, String, String)

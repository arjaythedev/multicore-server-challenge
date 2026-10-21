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
      _start(env, _Config(env.vars)?, layout, test_http)
    else
      env.err.print("Invalid configuration: DATABASE_URL and JWT_SECRET "
        + "are required; HOST and PORT must be valid. In worker and HTTP "
        + "test modes, CONDUIT_TEST_POOL_SIZE must be 1..95 (default 1), "
        + "with at most 95 total connections.")
      env.exitcode(1)
    end

  fun _start(env: Env, config: _Config, layout: _DatabaseLayout,
    csv_sampling: Bool)
  =>
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
    _Listener(TCPListenAuth(env.root), config, consume workers, env,
      consume reporters)

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

  new create(auth: TCPListenAuth, config: _Config,
    workers: Array[_Worker] val, env: Env,
    reporters: Array[_DiagReporter] val)
  =>
    _auth = TCPServerAuth(auth)
    _config = config.http
    _workers = workers
    _env = env
    _secret = config.secret
    _diag_reporters = reporters
    _tcp = TCPListener(auth, config.host, config.port, this)

  fun ref _listener(): TCPListener => _tcp

  fun ref _on_accept(fd: U32): TCPConnectionActor ? =>
    try
      let worker = _workers(_next_worker)?
      _next_worker = (_next_worker + 1) % _workers.size()
      _Connection(_auth, fd, _config, worker, _secret)
    else
      _Unreachable()
      error
    end

  fun ref _on_listen_failure() =>
    for reporter in _diag_reporters.values() do reporter.stop() end
    _env.err.print("Unable to listen")
    _env.exitcode(1)
    for worker in _workers.values() do worker.close() end

  fun ref _on_closed() =>
    for reporter in _diag_reporters.values() do reporter.stop() end
    for worker in _workers.values() do worker.stop_sampling() end

actor _Connection is (stallion.HTTPServerActor & _QueryClient)
  var _http: stallion.HTTPServer = stallion.HTTPServer.none()
  let _worker: _Worker
  let _secret: String
  embed _operations: Map[U64, _Operation] = Map[U64, _Operation]
  embed _responders: Map[U64, stallion.Responder] =
    Map[U64, stallion.Responder]
  var _body: Array[U8] iso = recover iso Array[U8] end
  var _id: U64 = 0

  new create(auth: TCPServerAuth, fd: U32, config: stallion.ServerConfig,
    worker: _Worker, secret: String)
  =>
    _worker = worker
    _secret = secret
    _http = stallion.HTTPServer(auth, fd, this, config)

  fun ref _http_connection(): stallion.HTTPServer => _http

  fun ref on_body_chunk(data: Array[U8] val) =>
    let offset = _body.size()
    _body.undefined(offset + data.size())
    _body.copy_from(data, 0, offset, data.size())

  fun ref on_request_complete(request': stallion.Request val,
    responder: stallion.Responder)
  =>
    let body = _body = recover iso Array[U8] end
    let text: String val = String.from_iso_array(consume body)
    _id = _id + 1
    _responders(_id) = responder
    let request'' = (_RequestTag, this, _id, request', text, _secret)
    let operation = _Operation(request'', _worker)
    _operations(_id) = operation
    operation.start()
    _settle(_id)

  be db_result(id: U64, result: pg.Result) =>
    try
      _operations(id)?.result(result)
      _settle(id)
    end

  be db_failed(id: U64, failure: _DBFailure) =>
    try
      _operations(id)?.failed(failure)
      _settle(id)
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
    if _operations.size() > 0 then _worker.cancel(this) end
    _responders.clear()
    _operations.clear()

primitive _RequestTag

type _Request is
  (_RequestTag, _Connection, U64, stallion.Request, String, String)

use "cli"
use "collections"
use "net"
use "time"
use pg = "postgres"
use stallion = "stallion"
use uri = "uri"

actor Main
  """Runs the Conduit API server."""
  new create(env: Env) =>
    """Run a requested test mode or start the HTTP listener."""
    try
      for arg in env.args.values() do
        if arg == "--self-test" then
          _SelfTest(env)
          return
        elseif arg == "--test-named-rollback" then
          let config = _Config(env.vars)?
          _RollbackTest(TCPConnectAuth(env.root), config, env)
          return
        elseif arg == "--test-worker-data-error" then
          let config = _Config(env.vars)?
          _WorkerDataErrorTest(TCPConnectAuth(env.root), config, env, false)
          return
        elseif arg == "--test-worker-decode-error" then
          let config = _Config(env.vars)?
          _WorkerDataErrorTest(TCPConnectAuth(env.root), config, env, true)
          return
        elseif arg == "--test-worker-foreign-callback" then
          let config = _Config(env.vars)?
          _WorkerForeignCallbackTest(TCPConnectAuth(env.root), config, env)
          return
        elseif arg == "--test-worker-overlap" then
          let config = _Config(env.vars)?
          _WorkerOverlapTest(TCPConnectAuth(env.root), config, env)
          return
        elseif arg == "--test-worker-submitted-loss" then
          let config = _Config(env.vars)?
          _WorkerSubmittedLossTest(TCPConnectAuth(env.root), config, env)
          return
        elseif arg == "--test-worker-close-drain" then
          let config = _Config(env.vars)?
          _WorkerSubmittedLossTest(TCPConnectAuth(env.root), config, env,
            true)
          return
        elseif arg == "--test-worker-pending-cancel" then
          let config = _Config(env.vars)?
          _WorkerPendingCancelTest(TCPConnectAuth(env.root), config, env)
          return
        end
      end
      let config = _Config(env.vars)?
      let db_auth = TCPConnectAuth(env.root)
      let timers = Timers
      let workers: Array[_Worker] iso = recover iso Array[_Worker] end
      let first = _Worker(db_auth, config, timers, env.err)
      workers.push(first)
      for i in Range(1, config.dbworkers) do
        workers.push(_Worker(db_auth, config, timers, env.err))
      end
      _Listener(TCPListenAuth(env.root), config, first,
        consume workers, env)
    else
      env.err.print("Invalid configuration: DATABASE_URL and JWT_SECRET "
        + "are required; HOST, PORT, and DB_WORKERS must be valid.")
      env.exitcode(1)
    end

  fun @runtime_override_defaults(rto: RuntimeOptions) => rto.ponynoblock = true

class val _Config
  let host: String
  let port: String
  let secret: String
  let dbhost: String
  let dbport: String
  let user: String
  let password: String
  let database: String
  let dbworkers: USize
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
    let count = _Input.decimal(
      try e("DB_WORKERS")? else "95" end)?
    if (count < 1) or (count > 95) then error end
    dbworkers = count.usize()

actor _Listener is TCPListenerActor
  var _tcp: TCPListener = TCPListener.none()
  let _auth: TCPServerAuth
  let _config: stallion.ServerConfig
  let _first: _Worker
  let _workers: Array[_Worker] ref
  var _next_worker: USize = 0
  let _env: Env
  let _secret: String

  new create(auth: TCPListenAuth, config: _Config, first: _Worker,
    workers: Array[_Worker] iso, env: Env)
  =>
    _auth = TCPServerAuth(auth)
    _config = config.http
    _first = first
    _workers = consume workers
    _env = env
    _secret = config.secret
    _tcp = TCPListener(auth, config.host, config.port, this)

  fun ref _listener(): TCPListener => _tcp

  fun ref _on_accept(fd: U32): TCPConnectionActor =>
    let worker = try _workers(_next_worker)?
      else
        _Unreachable()
        _first
      end
    _next_worker = (_next_worker + 1) % _workers.size()
    _Connection(_auth, fd, _config, worker, _secret)

  fun ref _on_listen_failure() =>
    _env.err.print("Unable to listen")
    _env.exitcode(1)
    for worker in _workers.values() do worker.close() end

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
    _responders.clear()
    _operations.clear()
    _worker.cancel(this)

primitive _RequestTag

type _Request is
  (_RequestTag, _Connection, U64, stallion.Request, String, String)

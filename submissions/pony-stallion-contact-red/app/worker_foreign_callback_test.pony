use "net"
use "time"
use pg = "postgres"

actor \nodoc\ _WorkerForeignCallbackTest is
  (_QueryClient & pg.SessionStatusNotify)
  let _env: Env
  let _worker: _Worker
  let _foreign: pg.Session
  var _first: Bool = false

  new create(auth: TCPConnectAuth, config: _Config, env: Env) =>
    _env = env
    _worker = _Worker(auth, config, Timers, env.err)
    _foreign = pg.Session(
      pg.ServerConnectInfo(auth, config.dbhost, config.dbport),
      pg.DatabaseConnectInfo(config.user, config.password,
        config.database), this)
    _worker.query(this, 1, _Tags, _P.none())

  be pg_session_authenticated(session: pg.Session) =>
    if session is _foreign then session.close() end

  be db_result(id: U64, result: pg.Result) =>
    if id == 1 then
      if _first then
        _fail("duplicate first result")
        return
      end
      _first = true
      let query' = pg.NamedPreparedQuery(_Catalog.name(_Tags), _P.none())
      _worker.pg_query_failed(_foreign, query', pg.SessionClosed)
      _worker.query(this, 2, _Tags, _P.none())
    elseif (id == 2) and _first then
      _env.out.print("foreign session callback ignored")
      _worker.close()
    else
      _fail("unexpected query result")
    end

  be db_failed(id: U64, failure: _DBFailure) =>
    _fail("unexpected query failure")

  fun ref _fail(message: String) =>
    _env.err.print(message)
    _env.exitcode(1)
    _worker.close()

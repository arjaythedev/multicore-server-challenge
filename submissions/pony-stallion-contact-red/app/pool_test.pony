use "collections"
use "cli"
use "net"
use "time"
use pg = "postgres"

interface tag _PoolStateReceiver
  be state(value: _PoolTestState)

primitive \nodoc\ _PoolStatement
  fun apply(name: String): _RequestStatement ? =>
    match name
    | "tags" => _Tags
    | "register_user" => _RegisterUser
    | "login_user" => _LoginUser
    | "current_user" => _CurrentUser
    | "update_user" => _UpdateUser
    | "profile" => _Profile
    | "follow_target" => _FollowTarget
    | "follow_insert" => _FollowInsert
    | "follow_delete" => _FollowDelete
    | "article_page_all" => _ArticlePageAll
    | "article_page_feed" => _ArticlePageFeed
    | "article_page_tag" => _ArticlePageTag
    | "article_page_author" => _ArticlePageAuthor
    | "article_page_favorited" => _ArticlePageFavorited
    | "article_full_by_slug" => _ArticleFullBySlug
    | "article_full_by_id" => _ArticleFullById
    | "article_insert" => _ArticleInsert
    | "article_id_and_author_by_slug" => _ArticleIdAndAuthorBySlug
    | "article_update_input" => _ArticleUpdateInput
    | "article_update" => _ArticleUpdate
    | "article_delete" => _ArticleDelete
    | "article_id_by_slug" => _ArticleIdBySlug
    | "favorite_insert" => _FavoriteInsert
    | "favorite_delete" => _FavoriteDelete
    | "comments_by_slug" => _CommentsBySlug
    | "comment_input" => _CommentInput
    | "comment_insert" => _CommentInsert
    | "comment_owner" => _CommentOwner
    | "comment_delete" => _CommentDelete
    else error end

class \nodoc\ val _PoolTestState
  let request: U64
  let worker: USize
  let queued: Array[U64] val
  let write_queued: Array[U64] val
  let roles: Array[U64] val
  let read_idle: Array[USize] val
  let write_idle: Array[USize] val
  let active: Array[(USize, U64, U64)] val
  let idle: Array[USize] val
  let phases: Array[U64] val
  let generations: Array[U64] val
  let tokens: Array[(_RetryToken | None)] val
  let recipients: USize
  let outstanding: USize

  new val create(request': U64, queued': Array[U64] val,
    active': Array[(USize, U64, U64)] val, idle': Array[USize] val,
    phases': Array[U64] val, generations': Array[U64] val,
    tokens': Array[(_RetryToken | None)] val, recipients': USize,
    outstanding': USize, worker': USize, write_queued': Array[U64] val,
    roles': Array[U64] val, read_idle': Array[USize] val,
    write_idle': Array[USize] val)
  =>
    request = request'
    worker = worker'
    write_queued = write_queued'
    roles = roles'
    read_idle = read_idle'
    write_idle = write_idle'
    queued = queued'
    active = active'
    idle = idle'
    phases = phases'
    generations = generations'
    tokens = tokens'
    recipients = recipients'
    outstanding = outstanding'

  fun string(): String =>
    let line = String
      .>append("{\"event\":\"state\",\"request\":")
      .>append(request.string())
      .>append(",\"worker\":" + worker.string())
      .>append(",\"queued\":" + _numbers[U64](queued))
      .>append(",\"write_queued\":" + _numbers[U64](write_queued))
      .>append(",\"roles\":" + _numbers[U64](roles))
      .>append(",\"read_idle\":" + _numbers[USize](read_idle))
      .>append(",\"write_idle\":" + _numbers[USize](write_idle))
      .>append(",\"idle\":" + _numbers[USize](idle))
      .>append(",\"phases\":" + _numbers[U64](phases))
      .>append(",\"generations\":" + _numbers[U64](generations))
      .>append(",\"active\":[")
    var first = true
    for (slot, id, outcome) in active.values() do
      if not first then line.append(",") end
      first = false
      line.append("[" + slot.string() + "," + id.string() + "," +
        outcome.string() + "]")
    end
    line.append("],\"recipients\":" + recipients.string() +
      ",\"outstanding\":" + outstanding.string() + "}")
    line.clone()

  fun _numbers[A: Stringable #read](values: Array[A] val): String =>
    let line = String.>append("[")
    var first = true
    for value in values.values() do
      if not first then line.append(",") end
      first = false
      line.append(value.string())
    end
    line.>append("]").clone()

class \nodoc\ iso _PoolInput is InputNotify
  let _owner: _PoolProbe
  new iso create(owner: _PoolProbe) => _owner = owner
  fun ref apply(data: Array[U8] iso) => _owner.input(consume data)
  fun ref dispose() => _owner.quit()

actor \nodoc\ _PoolClient is _QueryClient
  let _owner: _PoolProbe
  let _index: USize
  var _callbacks: USize = 0
  new create(owner: _PoolProbe, index: USize) =>
    _owner = owner
    _index = index

  be db_result(id: U64, result: pg.Result) =>
    _callbacks = _callbacks + 1
    _owner.result(_index, id, "ok")

  be db_failed(id: U64, failure: _DBFailure) =>
    _callbacks = _callbacks + 1
    let kind = match failure
      | let sql: _SQLFailure => sql.code
      | _DataFailure => "data"
      | _ConnectionLost => "lost"
      end
    _owner.result(_index, id, kind)

  be fence(request: U64) =>
    _owner.fenced(request, _index, _callbacks)

actor \nodoc\ _PoolProbe is _PoolStateReceiver
  let _env: Env
  let _worker: _Worker
  let _workers: Array[_Worker] val
  let _listener: (_Listener | None)
  let _clients: Array[_PoolClient] val
  embed _states: Map[U64, _PoolTestState] = Map[U64, _PoolTestState]
  embed _buffer: String ref = String

  new create(auth: TCPConnectAuth, config: _Config, env: Env,
    layout: _DatabaseLayout, csv: Bool = false, listener: Bool = false)
  =>
    _env = env
    let delay = try
        EnvVars(env.vars)("CONDUIT_TEST_RETRY_NS")?.u64()?
      else 1_000_000_000 end
    let sink = if csv then _WorkerCSV(env.out) else None end
    _worker = _Worker(auth, config, Timers, env.err, layout.sessions(0),
      delay, sink)
    let workers = recover iso Array[_Worker] end
    workers.push(_worker)
    if listener then
      for index in Range(1, 4) do
        workers.push(_Worker(auth, config, Timers, env.err,
          layout.sessions(index), delay, sink, index))
      end
    end
    _workers = consume workers
    _listener = if listener then
      _Listener(TCPListenAuth(env.root), config, _workers, env,
        recover val Array[_DiagReporter] end)
    else None end
    let clients: Array[_PoolClient] iso = recover iso Array[_PoolClient] end
    for index in Range(0, 4) do clients.push(_PoolClient(this, index)) end
    _clients = consume clients
    _env.input(_PoolInput(this))
    _env.out.print("{\"event\":\"started\"}")

  be input(data: Array[U8] val) =>
    _buffer.append(String.from_array(data))
    while true do
      let position = try _buffer.find("\n")? else break end
      let line: String val = _buffer.substring(0, position)
      _buffer.delete(0, position.usize() + 1)
      _command(line)
    end

  fun ref _command(line: String) =>
    try
      let words = line.split()
      match words(0)?
      | "typed" =>
        _worker.query(_clients(_number(words(2)?)?.usize())?,
          _number(words(1)?)?, _PoolStatement(words(3)?)?, _P.none())
      | "tags" | "user" | "register" | "invalid" =>
        let kind = words(0)?
        let id = _number(words(1)?)?
        let client = _clients(_number(words(2)?)?.usize())?
        if kind == "tags" then
          _worker.query(client, id, _Tags, _P.none())
        elseif kind == "user" then
          _worker.query(client, id, _CurrentUser, _P.one(I64(0)))
        elseif kind == "invalid" then
          _worker.query(client, id, _CurrentUser, _P.one("bad\0value"))
        else
          let name: String val = words(3)?.clone()
          _worker.query(client, id, _RegisterUser,
            _P.three(name, name + "@pool.test", "test-hash"))
        end
      | "begin" | "deallocate" =>
        let sql = if words(0)? == "begin" then "BEGIN"
          else "DEALLOCATE ALL" end
        _worker._test_query(_clients(_number(words(2)?)?.usize())?,
          _number(words(1)?)?, pg.PreparedQuery(sql, _P.none()), _ReadClass)
      | "badbatch" =>
        _worker._test_bad_batch(_number(words(1)?)?.usize(),
          _clients(0)?, _number(words(2)?)?, this)
      | "cancel" =>
        _worker.cancel(_clients(_number(words(1)?)?.usize())?)
      | "state" =>
        let worker = if words.size() > 2 then
          _workers(_number(words(2)?)?.usize())?
        else _worker end
        worker._test_state(_number(words(1)?)?, this)
      | "fence" =>
        _worker._test_fence(_number(words(1)?)?, _clients)
      | "retire" =>
        _worker._test_retire(_number(words(1)?)?.usize())
      | "retry" =>
        let index = _number(words(1)?)?.usize()
        let previous = _states(_number(words(2)?)?)?
        let generation = _number(words(3)?)?
        let token = previous.tokens(index)? as _RetryToken
        _worker.retry(index, generation, token)
      | "close" => _worker.close()
      | "stop-csv" => _worker.stop_sampling()
      | "csv-sample" =>
        _worker._test_csv_sample(_number(words(1)?)?, this)
      | "csv-tick-fence" =>
        _worker._test_csv_tick_fence(_number(words(1)?)?)
      | "sampling" =>
        let request = _number(words(1)?)?
        for worker in _workers.values() do
          worker._test_sampling(request, this)
        end
      | "listener-close" =>
        match _listener | let listener: _Listener => listener.dispose() end
      | "quit" => this.quit()
      else error
      end
    else
      _env.err.print("Invalid pool test command")
      _env.exitcode(1)
      this.quit()
    end

  fun _number(value: String): U64 ? =>
    let number = _Input.decimal(value)?
    if number < 0 then error end
    number.u64()

  be csv_sample(request: U64, value: _WorkerSample) =>
    _env.out.print("{\"event\":\"csv_sample\",\"request\":" +
      request.string() + ",\"row\":\"" + value.string() + "\"}")

  be sampling(request: U64, worker: USize, running: Bool, stopped: Bool) =>
    _env.out.print("{\"event\":\"sampling\",\"request\":" +
      request.string() + ",\"worker_id\":" + worker.string() +
      ",\"running\":" + running.string() + ",\"stopped\":" +
      stopped.string() + "}")

  be state(value: _PoolTestState) =>
    _states(value.request) = value
    _env.out.print(value.string())

  be result(client: USize, id: U64, kind: String) =>
    _env.out.print("{\"event\":\"result\",\"client\":" + client.string() +
      ",\"id\":" + id.string() + ",\"kind\":\"" + kind + "\"}")

  be fenced(request: U64, client: USize, callbacks: USize) =>
    _env.out.print("{\"event\":\"fence\",\"request\":" + request.string() +
      ",\"client\":" + client.string() + ",\"callbacks\":" +
      callbacks.string() + "}")

  be quit() =>
    for worker in _workers.values() do worker.close() end
    match _listener | let listener: _Listener => listener.dispose() end
    _env.input.dispose()

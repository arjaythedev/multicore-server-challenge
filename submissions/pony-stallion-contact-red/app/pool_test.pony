use "collections"
use "cli"
use "net"
use "time"
use pg = "postgres"

class \nodoc\ val _PoolTestState
  let request: U64
  let queued: Array[U64] val
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
    outstanding': USize)
  =>
    request = request'
    queued = queued'
    active = active'
    idle = idle'
    phases = phases'
    generations = generations'
    tokens = tokens'
    recipients = recipients'
    outstanding = outstanding'

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
    let payload = try
      (_Output.first(result)? as pg.Row).fields(0)? as String
    else None end
    _owner.result(_index, id, "ok", payload)

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

actor \nodoc\ _PoolProbe is _DiagRecordReceiver
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
    _worker = _Worker(auth, config, Timers, env.err, layout.pool_size(0),
      delay, sink)
    let workers = recover iso Array[_Worker] end
    workers.push(_worker)
    if listener then
      for index in Range(1, 4) do
        workers.push(_Worker(auth, config, Timers, env.err,
          layout.pool_size(index), delay, sink, index))
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
      | "tags" | "tags-extra-parameter" | "user" | "register" | "invalid" =>
        let kind = words(0)?
        let id = _number(words(1)?)?
        let client = _clients(_number(words(2)?)?.usize())?
        if kind == "tags" then
          _worker.query(client, id, _Tags, _P.none())
        elseif kind == "tags-extra-parameter" then
          _worker.query(client, id, _Tags, _P.one(I64(0)))
        elseif kind == "user" then
          _worker.query(client, id, _CurrentUser, _P.one(I64(0)))
        elseif kind == "invalid" then
          _worker.query(client, id, _CurrentUser, _P.one("bad\0value"))
        else
          let name: String val = words(3)?.clone()
          _worker.query(client, id, _RegisterUser,
            _P.three(name, name + "@pool.test", "test-hash"))
        end
      | "tags-nul" | "tags-array" =>
        let param: _Param = if words(0)? == "tags-nul" then "bad\0value"
          else pg.PgArray(25, [as pg.FieldData: "unsupported"]) end
        _worker.query(_clients(_number(words(2)?)?.usize())?,
          _number(words(1)?)?, _Tags, _P.one(param))
      | "begin" | "deallocate" | "tags-error-deallocate"
      | "tags-error-prepare" =>
        let sql = match words(0)?
          | "begin" => "BEGIN"
          | "tags-error-deallocate" => "DEALLOCATE tags"
          | "tags-error-prepare" => "PREPARE tags AS SELECT 1 / 0"
          else "DEALLOCATE ALL"
          end
        _worker._test_query(_clients(_number(words(2)?)?.usize())?,
          _number(words(1)?)?, pg.PreparedQuery(sql, _P.none()))
      | "badbatch" =>
        _worker._test_bad_batch(_number(words(1)?)?.usize(),
          _clients(0)?, _number(words(2)?)?, this)
      | "tagbatch" =>
        _worker._test_tag_batch(_number(words(1)?)?.usize(),
          _number(words(2)?)? == 1, _clients(0)?,
          _number(words(3)?)?, this)
      | "tagzero" =>
        _worker._test_tag_zero_budget(_clients(0)?,
          _number(words(1)?)?, this)
      | "diag" => _worker.diag_snapshot(_number(words(1)?)?, this)
      | "cancel" =>
        _worker.cancel(_clients(_number(words(1)?)?.usize())?)
      | "state" =>
        _worker._test_state(_number(words(1)?)?, this)
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
    let line = String
    line.append("{\"event\":\"state\",\"request\":")
    line.append(value.request.string())
    line.append(",\"queued\":[")
    var first = true
    for id in value.queued.values() do
      if not first then line.append(",") end
      first = false
      line.append(id.string())
    end
    line.append("],\"active\":[")
    first = true
    for (slot, id, outcome) in value.active.values() do
      if not first then line.append(",") end
      first = false
      line.append("[" + slot.string() + "," + id.string() + "," +
        outcome.string() + "]")
    end
    line.append("],\"idle\":[")
    first = true
    for index in value.idle.values() do
      if not first then line.append(",") end
      first = false
      line.append(index.string())
    end
    line.append("],\"phases\":[")
    first = true
    for code in value.phases.values() do
      if not first then line.append(",") end
      first = false
      line.append(code.string())
    end
    line.append("],\"generations\":[")
    first = true
    for generation in value.generations.values() do
      if not first then line.append(",") end
      first = false
      line.append(generation.string())
    end
    line.append("],\"recipients\":" + value.recipients.string() +
      ",\"outstanding\":" + value.outstanding.string() + "}")
    _env.out.print(line.clone())

  be result(client: USize, id: U64, kind: String,
    payload: (String | None) = None)
  =>
    let line = String
    line.append("{\"event\":\"result\",\"client\":" + client.string() +
      ",\"id\":" + id.string() + ",\"kind\":\"" + kind + "\",\"payload\":")
    match payload
    | let value: String => _Output._quoted(line, value)
    else line.append("null")
    end
    line.append("}")
    _env.out.print(line.clone())

  be diag_record(value: pg.DiagSnapshot) =>
    if value.owner != 1 then return end
    let line = String
    line.append("{\"event\":\"diag\",\"request\":" + value.request.string())
    for (name, values) in [as (String, Array[U64] val):
      ("counters", value.counters); ("gauges", value.gauges)].values()
    do
      line.append(",\"" + name + "\":[")
      var first = true
      for number in values.values() do
        if not first then line.append(",") end
        first = false
        line.append(number.string())
      end
      line.append("]")
    end
    line.append(",\"histograms\":[")
    var first = true
    for histogram in value.histograms.values() do
      if not first then line.append(",") end
      first = false
      line.append(histogram.count.string())
    end
    line.append("]}")
    _env.out.print(line.clone())

  be diag_missing(slot: USize, generation: U64, request: U64,
    reason: String) => None

  be fenced(request: U64, client: USize, callbacks: USize) =>
    _env.out.print("{\"event\":\"fence\",\"request\":" + request.string() +
      ",\"client\":" + client.string() + ",\"callbacks\":" +
      callbacks.string() + "}")

  be quit() =>
    for worker in _workers.values() do worker.close() end
    match _listener | let listener: _Listener => listener.dispose() end
    _env.input.dispose()

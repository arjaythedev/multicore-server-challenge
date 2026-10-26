use "net"
use "time"
use pg = "postgres"

actor \nodoc\ _WorkerDataErrorTest is (_QueryClient & _WorkerBarrier)
  let _env: Env
  let _worker: _Worker
  let _decode: Bool
  var _failed_first: Bool = false
  var _failed_second: Bool = false
  var _results: U8 = 0

  new create(auth: TCPConnectAuth, config: _Config, env: Env,
    layout: _DatabaseLayout, decode: Bool)
  =>
    _env = env
    _decode = decode
    _worker = _Worker(auth, config, Timers, env.err, layout.pool_size(0))
    let bad = pg.PgArray(26,
      recover val [as (pg.FieldData | None): "not-an-oid"] end)
    let params: Array[_Param] val = if decode then _P.none()
      else recover val [as _Param: bad] end
      end
    _worker.query(this, 1, _Tags, params)
    if decode then
      _worker.query(this, 2, _CurrentUser, _P.one(I64(0)))
    else
      _worker.query(this, 2, _Tags, _P.one("before\0after"))
      _worker.query(this, 3, _Tags, _P.none())
    end

  be db_result(id: U64, result: pg.Result) =>
    if (id != (if _decode then 2 else 3 end)) or
      (not _failed_first) or ((not _decode) and (not _failed_second))
    then
      _fail("unexpected query result")
      return
    end
    _results = _results + 1
    _worker.barrier(this)

  be worker_barrier(pending: USize) =>
    if (pending != 0) or (_results != 1) or (not _failed_first) or
      ((not _decode) and (not _failed_second))
    then
      _fail("unexpected query callback count")
      return
    end
    _env.out.print(if _decode then
        "worker decode error followed by query passed"
      else
        "worker data errors followed by query passed"
      end)
    _worker.close()

  be db_failed(id: U64, failure: _DBFailure) =>
    if not (failure is _DataFailure) then
      _fail("unexpected query failure")
      return
    end
    if (id == 1) and (not _failed_first) then
      _failed_first = true
    elseif (id == 2) and (not _decode) and _failed_first and
      (not _failed_second)
    then
      _failed_second = true
    else
      _fail("duplicate or unexpected query failure")
    end

  fun ref _fail(message: String) =>
    _env.err.print(message)
    _env.exitcode(1)
    _worker.close()

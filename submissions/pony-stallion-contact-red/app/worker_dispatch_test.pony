use "collections"
use "net"
use "time"
use pg = "postgres"

actor \nodoc\ _CanceledQueryClient is _QueryClient
  let _owner: _WorkerOverlapTest

  new create(owner: _WorkerOverlapTest) => _owner = owner

  be db_result(id: U64, result: pg.Result) =>
    _owner.unexpected_first()

  be db_failed(id: U64, failure: _DBFailure) =>
    _owner.unexpected_first()

actor \nodoc\ _WorkerOverlapTest is (_QueryClient & _WorkerBarrier)
  let _env: Env
  let _worker: _Worker
  let _first: _CanceledQueryClient
  var _barrier: Bool = false
  var _second: Bool = false

  new create(auth: TCPConnectAuth, config: _Config, env: Env,
    layout: _DatabaseLayout) =>
    _env = env
    _worker = _Worker(auth, config, Timers, env.err, layout.pool_size(0))
    _first = _CanceledQueryClient(this)
    _worker.query(this, 0, _CurrentUser, _P.one(I64(0)))

  be db_result(id: U64, result: pg.Result) =>
    if id == 0 then
      _worker.query(_first, 1, _Tags, _P.none())
      _worker.query(this, 1, _Profile,
        _P.two(I64(0), "worker-overlap-missing-user"))
      _worker.cancel(_first)
      _worker.barrier(this)
    elseif id == 1 then
      try
        if _Output.rows(result)?.size() != 0 then
          _fail("unexpected second-client result")
          return
        end
      else
        _fail("invalid second-client result")
        return
      end
      _second = true
      if _barrier then _done() end
    else
      _fail("unexpected query id")
    end

  be db_failed(id: U64, failure: _DBFailure) =>
    _fail("unexpected second-client failure")

  be worker_barrier(pending: USize) =>
    if pending != 1 then
      _fail("unexpected pending overlap work")
      return
    end
    _barrier = true
    _env.out.print("overlap accepted")
    if _second then _done() end

  be unexpected_first() => _fail("canceled client received a callback")

  fun ref _done() =>
    _env.out.print("surviving client passed")
    _worker.close()

  fun ref _fail(message: String) =>
    _env.err.print(message)
    _env.exitcode(1)
    _worker.close()

actor \nodoc\ _WorkerCloseTest is (_QueryClient & _WorkerBarrier)
  let _env: Env
  let _worker: _Worker
  var _barrier: Bool = false
  var _failures: USize = 0
  let _seen: Array[Bool] = [false; false; false]

  new create(auth: TCPConnectAuth, config: _Config, env: Env,
    layout: _DatabaseLayout) =>
    _env = env
    _worker = _Worker(auth, config, Timers, env.err, layout.pool_size(0))
    _worker.query(this, 0, _CurrentUser, _P.one(I64(0)))

  be db_result(id: U64, result: pg.Result) =>
    if id == 0 then
      for i in Range[U64](1, 4) do
        _worker.query(this, i, _Tags, _P.none())
      end
      _worker.barrier(this)
    else
      _fail("submitted query unexpectedly succeeded")
    end

  be db_failed(id: U64, failure: _DBFailure) =>
    if (id < 1) or (id > 3) or
      (not (failure is _ConnectionLost)) then
      _fail("unexpected submitted-query failure")
      return
    end
    try
      if _seen(id.usize() - 1)? then
        _fail("duplicate submitted-query failure")
        return
      end
      _seen(id.usize() - 1)? = true
    else
      _fail("invalid submitted-query id")
      return
    end
    _failures = _failures + 1
    if _barrier and (_failures == 3) then _done() end

  be worker_barrier(pending: USize) =>
    if pending != 2 then
      _fail("unexpected shared queue depth")
      return
    end
    _barrier = true
    _env.out.print("submitted work accepted")
    _worker.close()
    if _failures == 3 then _done() end

  fun ref _done() =>
    _env.out.print("submitted work failed once")
    _worker.close()

  fun ref _fail(message: String) =>
    _env.err.print(message)
    _env.exitcode(1)
    _worker.close()

actor \nodoc\ _PendingCanceledClient is _QueryClient
  let _owner: _WorkerPendingCancelTest

  new create(owner: _WorkerPendingCancelTest) => _owner = owner

  be db_result(id: U64, result: pg.Result) =>
    _owner.unexpected_first()

  be db_failed(id: U64, failure: _DBFailure) =>
    _owner.unexpected_first()

actor \nodoc\ _WorkerPendingCancelTest is (_QueryClient & _WorkerBarrier)
  let _env: Env
  let _worker: _Worker
  let _first: _PendingCanceledClient
  var _stage: U8 = 0

  new create(auth: TCPConnectAuth, config: _Config, env: Env,
    layout: _DatabaseLayout) =>
    _env = env
    _worker = _Worker(auth, config, Timers, env.err, layout.pool_size(0))
    _first = _PendingCanceledClient(this)
    _worker.query(_first, 1, _Tags, _P.none())
    _worker.query(this, 1, _Tags, _P.none())
    _worker.barrier(this)

  be worker_barrier(pending: USize) =>
    if (_stage == 0) and (pending == 2) then
      _stage = 1
      _worker.cancel(_first)
      _worker.barrier(this)
    elseif (_stage == 1) and (pending == 2) then
      _stage = 2
      _env.out.print("pending cancellation accepted")
    else
      _fail("unexpected pending queue size")
    end

  be db_result(id: U64, result: pg.Result) =>
    if (id != 1) or (_stage != 2) then
      _fail("unexpected surviving query result")
      return
    end
    _env.out.print("surviving pending client passed")
    _worker.close()

  be db_failed(id: U64, failure: _DBFailure) =>
    _fail("unexpected pending query failure")

  be unexpected_first() => _fail("canceled pending client received callback")

  fun ref _fail(message: String) =>
    _env.err.print(message)
    _env.exitcode(1)
    _worker.close()

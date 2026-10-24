use "net"
use "time"
use pg = "postgres"

actor \nodoc\ _WorkerDiagnosticTest is
  (_QueryClient & _WorkerBarrier & _DiagRecordReceiver)
  let _env: Env
  let _worker: _Worker
  var _failures: USize = 0
  let _seen: Array[Bool] = [false; false; false]
  var _snapshot: (pg.DiagSnapshot | None) = None
  var _unavailable: Bool = false

  new create(auth: TCPConnectAuth, config: _Config, env: Env,
    layout: _DatabaseLayout) =>
    _env = env
    _worker = _Worker(auth, config, Timers, env.err, layout.pool_size(0))
    _worker.query(this, 1, _Tags, _P.none())
    _worker.query(this, 2, _Tags, _P.none())
    _worker.barrier(this)

  be worker_barrier(pending: USize) =>
    if pending != 2 then
      _fail("diagnostic pending queue was not ready")
      return
    end
    _worker.close()
    _worker.query(this, 3, _Tags, _P.none())

  be db_result(id: U64, result: pg.Result) =>
    _fail("diagnostic query unexpectedly succeeded")

  be db_failed(id: U64, failure: _DBFailure) =>
    if (id < 1) or (id > 3) or
      (not (failure is _ConnectionLost)) then
      _fail("unexpected diagnostic query failure")
      return
    end
    try
      if _seen(id.usize() - 1)? then
        _fail("duplicate diagnostic query failure")
        return
      end
      _seen(id.usize() - 1)? = true
    else
      _fail("invalid diagnostic query id")
      return
    end
    _failures = _failures + 1
    if _failures == 3 then _worker.diag_snapshot(1, this) end

  be diag_record(snapshot: pg.DiagSnapshot) =>
    if (snapshot.owner == 2) and (snapshot.request == 0) then return end
    if (snapshot.owner != 1) or (snapshot.slot != 0) or
      (snapshot.generation != 0) or (snapshot.request != 1) then
      _fail("unexpected diagnostic snapshot")
      return
    end
    _snapshot = snapshot
    _emit()

  be diag_missing(slot: USize, generation: U64, request: U64,
    reason: String)
  =>
    if (slot != 0) or (generation != 0) or (request != 1) or
      (reason != "unavailable") then
      _fail("incorrect unavailable Session identity")
      return
    end
    _unavailable = true
    _emit()

  fun ref _emit() =>
    if not _unavailable then return end
    let snapshot = match _snapshot
      | let current: pg.DiagSnapshot => current
      else return
      end
    try
      _env.out.print("{\"callbacks\":" + snapshot.counters(5)?.string() +
        ",\"pending_close\":" + snapshot.counters(3)?.string() +
        ",\"stopped_rejection\":" + snapshot.counters(4)?.string() + "}")
    else
      _fail("missing direct callback counters")
      return
    end

  fun ref _fail(message: String) =>
    _env.err.print(message)
    _env.exitcode(1)

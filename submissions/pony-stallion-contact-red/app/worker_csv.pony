use "time"

class val _WorkerSample
  let monotonic_ns: U64
  let worker_id: USize
  let connecting: U64
  let preparing: U64
  let idle: U64
  let busy: U64
  let backoff: U64
  let stopped: U64
  let pending: USize

  new val create(time': U64, worker': USize, connecting': U64,
    preparing': U64, idle': U64, busy': U64, backoff': U64,
    stopped': U64, pending': USize)
  =>
    monotonic_ns = time'
    worker_id = worker'
    connecting = connecting'
    preparing = preparing'
    idle = idle'
    busy = busy'
    backoff = backoff'
    stopped = stopped'
    pending = pending'

  fun string(): String =>
    monotonic_ns.string() + "," + worker_id.string() + "," +
      connecting.string() + "," + preparing.string() + "," + idle.string() +
      "," + busy.string() + "," + backoff.string() + "," + stopped.string() +
      "," + pending.string()

actor _WorkerCSV
  let _out: OutStream

  new create(out: OutStream) =>
    _out = out
    _out.print("monotonic_ns,worker_id,connecting,preparing,idle,busy," +
      "backoff,stopped,pending")

  be sample(value: _WorkerSample) => _out.print(value.string())

  be _test_fence(request: U64) =>
    _out.print("{\"event\":\"csv_fence\",\"request\":" +
      request.string() + "}")

interface tag _WorkerCSVSource
  be csv_tick()

class iso _WorkerCSVTick is TimerNotify
  let _worker: _WorkerCSVSource

  new iso create(worker: _WorkerCSVSource) => _worker = worker

  fun ref apply(timer: Timer, count: U64): Bool =>
    _worker.csv_tick()
    true

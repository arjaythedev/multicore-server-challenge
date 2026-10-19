use "collections"
use "time"
use pg = "postgres"

interface tag _DiagRecordReceiver
  be diag_record(snapshot: pg.DiagSnapshot)
  be diag_missing(slot: USize, generation: U64, request: U64,
    reason: String)

class iso _DiagTick is TimerNotify
  let _reporter: _DiagReporter

  new iso create(reporter: _DiagReporter) => _reporter = reporter

  fun ref apply(timer: Timer, count: U64): Bool =>
    _reporter.tick()
    true

actor _DiagReporter is _DiagRecordReceiver
  let _out: OutStream
  let _timers: Timers
  var _worker: (_Worker | None) = None
  let _worker_id: USize
  let _connection_count: USize
  let _outstanding: Array[U64] ref
  var _timer: (Timer tag | None) = None
  var _running: Bool = true
  var _next_slot: USize = 0
  var _next_request: U64 = 1

  new create(out: OutStream, timers: Timers, worker_count: USize,
    worker_id: USize, actor_count: USize, total_connections: USize)
  =>
    _out = out
    _timers = timers
    _connection_count = worker_count
    _worker_id = worker_id
    _outstanding = Array[U64].init(0, worker_count)
    _out.print("{\"kind\":\"conduit_diag\",\"schema\":3," +
      "\"worker_id\":" + _worker_id.string() +
      ",\"owner\":0,\"database_actor_count\":" + actor_count.string() +
      ",\"connection_count\":" + worker_count.string() +
      ",\"total_connection_count\":" + total_connections.string() +
      ",\"period_ns\":10000000000}")
    let interval = (10_000_000_000 / worker_count.u64()).max(1)
    let timer = Timer(_DiagTick(this), interval, interval)
    _timer = timer
    _timers(consume timer)

  be register(worker: _Worker) => _worker = worker

  be stop() =>
    if not _running then return end
    _running = false
    match _timer
    | let timer: Timer tag => _timers.cancel(timer)
    end
    _timer = None

  be tick() =>
    if not _running then return end
    let slot = _next_slot
    _next_slot = (_next_slot + 1) % _connection_count
    if _next_slot == 0 then
      _out.print("{\"kind\":\"conduit_diag\",\"schema\":3," +
        "\"worker_id\":" + _worker_id.string() +
        ",\"owner\":0,\"report_ns\":" + Time.nanos().string() +
        ",\"next_request\":" + _next_request.string() + "}")
    end
    try
      if _outstanding(slot)? != 0 then
        _missing(1, slot, None, _outstanding(slot)?, "overdue")
        return
      end
      match _worker
      | let worker: _Worker =>
        let request = _next_request
        try _next_request = _next_request +? 1
        else _Unreachable() end
        _outstanding(slot)? = request
        worker.diag_snapshot(request, this, slot)
      end
    else _Unreachable()
    end

  be diag_record(snapshot: pg.DiagSnapshot) =>
    if not _running then return end
    if snapshot.owner == 1 then
      try
        if _outstanding(snapshot.slot)? != snapshot.request then return end
        _outstanding(snapshot.slot)? = 0
      else return end
    end
    let line = String(16_384)
    line.append("{\"kind\":\"conduit_diag\",\"schema\":3,")
    line.append("\"worker_id\":")
    line.append(_worker_id.string())
    line.append(",")
    line.append("\"owner\":")
    line.append(snapshot.owner.string())
    line.append(",\"slot\":")
    line.append(snapshot.slot.string())
    line.append(",\"generation\":")
    line.append(snapshot.generation.string())
    line.append(",\"request\":")
    line.append(snapshot.request.string())
    line.append(",\"observed_ns\":")
    line.append(snapshot.observed.string())
    line.append(",\"report_ns\":")
    line.append(Time.nanos().string())
    line.append(",\"overflow\":")
    line.append(snapshot.overflow.string())
    line.append(",\"invalid_clock\":")
    line.append(snapshot.invalid_clock.string())
    line.append(",\"counters\":")
    _append_numbers(line, snapshot.counters)
    line.append(",\"gauges\":")
    _append_numbers(line, snapshot.gauges)
    line.append(",\"histograms\":[")
    var first = true
    for value in snapshot.histograms.values() do
      if not first then line.append(",") end
      first = false
      line.append("{\"count\":")
      line.append(value.count.string())
      line.append(",\"sum_ns\":")
      line.append(value.sum.string())
      line.append(",\"max_ns\":")
      line.append(value.maximum.string())
      line.append(",\"overflow\":")
      line.append(value.overflow.string())
      line.append(",\"buckets\":")
      _append_numbers(line, value.buckets)
      line.append("}")
    end
    line.append("]}")
    let finished: String iso = line.clone()
    _out.print(consume finished)

  be diag_missing(slot: USize, generation: U64, request: U64,
    reason: String)
  =>
    if not _running then return end
    _missing(2, slot, generation, request, reason)

  fun ref _missing(owner: U8, slot: USize, generation: (U64 | None),
    request: U64, reason: String)
  =>
    let generation_text = match generation
      | let value: U64 => value.string()
      | None => "null"
      end
    _out.print("{\"kind\":\"conduit_diag\",\"schema\":3," +
      "\"worker_id\":" + _worker_id.string() +
      ",\"owner\":" + owner.string() +
      ",\"slot\":" + slot.string() +
      ",\"generation\":" + generation_text +
      ",\"request\":" + request.string() +
      ",\"report_ns\":" + Time.nanos().string() +
      ",\"missing\":true,\"reason\":\"" + reason + "\"}")

  fun _append_numbers(line: String ref, values: Array[U64] val) =>
    line.append("[")
    var first = true
    for value in values.values() do
      if not first then line.append(",") end
      first = false
      line.append(value.string())
    end
    line.append("]")

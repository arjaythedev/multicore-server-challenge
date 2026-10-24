use "cli"
use "collections"

class val _SharedSessions
  let total: USize

  new val create(total': USize) ? =>
    if (total' < 1) or (total' > 95) then error end
    total = total'

class val _SplitSessions
  let reads: USize
  let writes: USize
  let total: USize

  new val create(reads': USize, writes': USize) ? =>
    if (reads' < 1) or (reads' > 95) or (writes' < 1) or
      (writes' > (95 - reads')) then error end
    reads = reads'
    writes = writes'
    total = reads' + writes'

type _SessionAllocation is (_SharedSessions | _SplitSessions)

class val _DatabaseLayout
  let sizes: Array[USize] val
  let total: USize
  let _sessions: Array[_SessionAllocation] val

  new val production(count: USize, writes: USize = 0) ? =>
    if (count < 1) or (count > 95) then error end
    total = 95
    sizes = recover val
      let result = Array[USize](count)
      for index in Range(0, count) do
        result.push((95 / count) + if index < (95 % count) then 1 else 0 end)
      end
      result
    end
    _sessions = _SessionAllocations(sizes, total, writes)?

  new val fixture(count: USize, size: USize, writes: USize = 0) ? =>
    if (count < 1) or (count > 95) or (size < 1) or
      (size > (95 / count)) then error end
    total = count * size
    sizes = recover val Array[USize].init(size, count) end
    _sessions = _SessionAllocations(sizes, total, writes)?

  fun pool_size(index: USize): USize =>
    try sizes(index)? else _Unreachable(); 0 end

  fun sessions(index: USize): _SessionAllocation =>
    try _sessions(index)? else _Unreachable(); sessions(index) end

primitive _SessionAllocations
  fun apply(sizes: Array[USize] val, total: USize, writes: USize)
    : Array[_SessionAllocation] val ?
  =>
    let count = sizes.size()
    if (writes != 0) and
      ((writes < count) or (writes > (total - count))) then error end
    recover val
      let result = Array[_SessionAllocation](count)
      for (index, size) in sizes.pairs() do
        if writes == 0 then result.push(_SharedSessions(size)?)
        else
          let reserved = (writes / count) +
            if index < (writes % count) then USize(1) else USize(0) end
          result.push(_SplitSessions(size - reserved, reserved)?)
        end
      end
      result
    end

primitive _WorkerCountError
  fun string(): String =>
    "Invalid --db-worker-count: specify once, with an integer from 1 to 95."

primitive _WriteSessionsError
  fun string(): String =>
    "Invalid --db-write-sessions: specify once, with an integer from 0 to 95."

primitive _FixtureSizeError
  fun string(): String =>
    "Invalid CONDUIT_TEST_POOL_SIZE: use 1..95, with at most 95 total "
      + "connections."

class val _ReservationError
  let total: USize
  let workers: USize
  let writes: USize

  new val create(total': USize, workers': USize, writes': USize) =>
    total = total'
    workers = workers'
    writes = writes'

  fun string(): String =>
    let allowed = if workers <= (total - workers) then
      "0 or " + workers.string() + ".." + (total - workers).string()
    else "0" end
    "Invalid --db-write-sessions=" + writes.string() + ": "
      + total.string() + " sessions across " + workers.string()
      + " workers permit " + allowed + "."

type _DatabaseLayoutResult is
  (_DatabaseLayout | _FixtureSizeError | _ReservationError)

class val _DatabaseSelection
  let workers: USize
  let writes: USize

  new val create(workers': USize, writes': USize) ? =>
    if (workers' < 1) or (workers' > 95) or (writes' > 95) then error end
    workers = workers'
    writes = writes'

  fun production(): _DatabaseLayoutResult =>
    try _DatabaseLayout.production(workers, writes)?
    else _ReservationError(95, workers, writes) end

  fun fixture(vars: (Array[String] val | None), count: USize)
    : _DatabaseLayoutResult
  =>
    let size = try
      _Input.decimal(
        try EnvVars(vars)("CONDUIT_TEST_POOL_SIZE")? else "1" end)?
    else return _FixtureSizeError end
    if (count < 1) or (count > 95) or (size < 1) or
      (size > (95 / count).i64()) then return _FixtureSizeError end
    fixed(count, size.usize())

  fun fixed(count: USize, size: USize): _DatabaseLayoutResult =>
    if (count < 1) or (count > 95) or (size < 1) or
      (size > (95 / count)) then return _FixtureSizeError end
    try _DatabaseLayout.fixture(count, size, writes)?
    else _ReservationError(count * size, count, writes) end

primitive _DatabaseOptions
  fun apply(args: Array[String] val, schedulers: USize)
    : (_DatabaseSelection | _WorkerCountError | _WriteSessionsError)
  =>
    var count = schedulers.min(8)
    var writes: USize = 0
    var seen_count = false
    var seen_writes = false
    var index: USize = 1
    while index < args.size() do
      let arg = try args(index)?
        else _Unreachable(); return _WorkerCountError end
      let worker_flag = (arg == "--db-worker-count") or
        arg.at("--db-worker-count=")
      let write_flag = (arg == "--db-write-sessions") or
        arg.at("--db-write-sessions=")
      if worker_flag or write_flag then
        let failure = if worker_flag then _WorkerCountError
          else _WriteSessionsError end
        if (worker_flag and seen_count) or (write_flag and seen_writes) then
          return failure
        end
        let value = try
          if (arg == "--db-worker-count") or
            (arg == "--db-write-sessions") then
            index = index + 1
            args(index)?
          else arg.substring(if worker_flag then 18 else 20 end) end
        else return failure end
        let parsed = try _Input.decimal(value)? else return failure end
        if (parsed > 95) or (worker_flag and (parsed < 1)) then
          return failure
        end
        if worker_flag then
          count = parsed.usize()
          seen_count = true
        else
          writes = parsed.usize()
          seen_writes = true
        end
      end
      index = index + 1
    end
    try _DatabaseSelection(count, writes)? else _WorkerCountError end

primitive _TestDatabaseLayout
  fun apply(vars: (Array[String] val | None), count: USize)
    : _DatabaseLayout ?
  =>
    _DatabaseSelection(count, 0)?.fixture(vars, count) as _DatabaseLayout

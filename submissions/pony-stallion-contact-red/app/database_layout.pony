use "cli"
use "collections"

class val _DatabaseLayout
  let sizes: Array[USize] val
  let total: USize

  new val production(count: USize) ? =>
    if (count < 1) or (count > 95) then error end
    total = 95
    sizes = recover val
      let result = Array[USize](count)
      for index in Range(0, count) do
        result.push((95 / count) + if index < (95 % count) then 1 else 0 end)
      end
      result
    end

  new val fixture(count: USize, size: USize) ? =>
    if (count < 1) or (count > 95) or (size < 1) or
      (size > (95 / count)) then error end
    total = count * size
    sizes = recover val Array[USize].init(size, count) end

  fun pool_size(index: USize): USize =>
    try sizes(index)? else _Unreachable(); 0 end

primitive _WorkerCountError
  fun string(): String =>
    "Invalid --db-worker-count: specify once, with an integer from 1 to 95."

primitive _DatabaseOptions
  fun apply(args: Array[String] val, schedulers: USize)
    : (_DatabaseLayout | _WorkerCountError)
  =>
    try
      var count = schedulers.min(8)
      var seen = false
      var index: USize = 1
      while index < args.size() do
        let arg = args(index)?
        if (arg == "--db-worker-count") or
          arg.at("--db-worker-count=") then
          if seen then return _WorkerCountError end
          seen = true
          let value = if arg == "--db-worker-count" then
            index = index + 1
            args(index)?
          else arg.substring(18) end
          let parsed = _Input.decimal(value)?
          if (parsed < 1) or (parsed > 95) then
            return _WorkerCountError
          end
          count = parsed.usize()
        end
        index = index + 1
      end
      _DatabaseLayout.production(count)?
    else _WorkerCountError end

primitive _TestDatabaseLayout
  fun apply(vars: (Array[String] val | None), count: USize)
    : _DatabaseLayout ?
  =>
    let size = _Input.decimal(
      try EnvVars(vars)("CONDUIT_TEST_POOL_SIZE")? else "1" end)?
    if (size < 1) or (size > 95) then error end
    _DatabaseLayout.fixture(count, size.usize())?

use "collections"
use @pony_os_stderr[Pointer[U8]]()
use @fprintf[I32](stream: Pointer[U8] tag, fmt: Pointer[U8] tag, ...)
use @exit[None](status: I32)

primitive _Unreachable
  fun apply(loc: SourceLoc = __loc) =>
    @fprintf(@pony_os_stderr(),
      "Unreachable code at %s:%lu in %s.%s\n".cstring(),
      loc.file().cstring(), loc.line(), loc.type_name().cstring(),
      loc.method_name().cstring())
    @exit(1)

class val DiagHistogramValue
  """A cumulative duration histogram in nanoseconds."""
  let buckets: Array[U64] val
  let count: U64
  let sum: U64
  let maximum: U64
  let overflow: Bool

  new val create(buckets': Array[U64] val, count': U64, sum': U64,
    maximum': U64, overflow': Bool)
  =>
    """Preserve the supplied buckets and totals without copying them."""
    buckets = buckets'
    count = count'
    sum = sum'
    maximum = maximum'
    overflow = overflow'

class val DiagSnapshot
  """Numeric diagnostic state observed by one actor at one instant."""
  let owner: U8
  let slot: USize
  let generation: U64
  let request: U64
  let observed: U64
  let counters: Array[U64] val
  let gauges: Array[U64] val
  let histograms: Array[DiagHistogramValue] val
  let overflow: Bool
  let invalid_clock: U64

  new val create(owner': U8, slot': USize, generation': U64,
    request': U64, observed': U64, counters': Array[U64] val,
    gauges': Array[U64] val, histograms': Array[DiagHistogramValue] val,
    overflow': Bool, invalid_clock': U64)
  =>
    """Retain the supplied immutable arrays without copying them."""
    owner = owner'
    slot = slot'
    generation = generation'
    request = request'
    observed = observed'
    counters = counters'
    gauges = gauges'
    histograms = histograms'
    overflow = overflow'
    invalid_clock = invalid_clock'

class DiagHistogram
  """Accumulates a fixed 27-bucket duration distribution."""
  embed _buckets: Array[U64] = Array[U64].init(0, 27)
  var _count: U64 = 0
  var _sum: U64 = 0
  var _maximum: U64 = 0
  var _overflow: Bool = false

  fun ref add(value: U64) =>
    """Record one duration in nanoseconds."""
    let bucket = if value == 0 then 0
    elseif value < 1_000 then 1
    else
      var edge: U64 = 1_000
      var index: USize = 2
      while (index < 26) and (value >= (edge * 2)) do
        edge = edge * 2
        index = index + 1
      end
      if value >= (edge * 2) then 26 else index end
    end
    try
      let previous = _buckets(bucket)?
      if previous == U64.max_value() then _overflow = true
      else _buckets(bucket)? = previous + 1 end
    else _Unreachable()
    end
    if _count == U64.max_value() then _overflow = true
    else _count = _count + 1 end
    if value > (U64.max_value() - _sum) then
      _sum = U64.max_value()
      _overflow = true
    else _sum = _sum + value end
    if value > _maximum then _maximum = value end

  fun box snapshot(): DiagHistogramValue =>
    """Copy the current cumulative histogram into an immutable value."""
    let size' = _buckets.size()
    let values: Array[U64] iso = recover iso Array[U64](size') end
    for value in _buckets.values() do values.push(value) end
    DiagHistogramValue(consume values, _count, _sum, _maximum, _overflow)

class DiagState
  """Actor-local counters and fixed duration histograms."""
  embed _counters: Array[U64]
  embed _histograms: Array[DiagHistogram]
  var _overflow: Bool = false
  var _invalid_clock: U64 = 0

  new create(counter_count: USize, histogram_count: USize) =>
    """Allocate the requested numbers of counters and histograms at zero."""
    _counters = Array[U64].init(0, counter_count)
    _histograms = Array[DiagHistogram](histogram_count)
    for _ in Range(0, histogram_count) do
      _histograms.push(DiagHistogram)
    end

  fun ref count(index: USize) =>
    """Increment one counter, saturating at the maximum U64 value."""
    try
      let previous = _counters(index)?
      if previous == U64.max_value() then _overflow = true
      else _counters(index)? = previous + 1 end
    else _Unreachable()
    end

  fun ref observe(index: USize, start: U64, finish: U64) =>
    """Record an interval or count it as invalid when clocks reverse."""
    if finish < start then
      if _invalid_clock == U64.max_value() then _overflow = true
      else _invalid_clock = _invalid_clock + 1 end
      return
    end
    try _histograms(index)?.add(finish - start)
    else _Unreachable() end

  fun box snapshot(owner: U8, slot: USize, generation: U64,
    request: U64, observed: U64, gauges': Array[U64] val)
    : DiagSnapshot
  =>
    """Copy actor-local state and attach the supplied identity and gauges."""
    let count_size = _counters.size()
    let histogram_size = _histograms.size()
    let counts: Array[U64] iso = recover iso Array[U64](count_size) end
    for value in _counters.values() do counts.push(value) end
    let histograms': Array[DiagHistogramValue] iso =
      recover iso Array[DiagHistogramValue](histogram_size) end
    for histogram in _histograms.values() do
      histograms'.push(histogram.snapshot())
    end
    DiagSnapshot(owner, slot, generation, request, observed,
      consume counts, gauges', consume histograms', _overflow,
      _invalid_clock)

use "collections"

class \nodoc\ _PGDecodeTest
  let _env: Env

  new create(env: Env) ? =>
    _env = env
    _boundaries()?
    _generated()?

  fun _boundaries() ? =>
    for pair in [("0", I64(0)); ("-0", I64(0)); ("1", I64(1))
      ("-1", I64(-1)); ("00012", I64(12))
      ("-9223372036854775808", I64.min_value())
      ("9223372036854775807", I64.max_value())].values()
    do
      _success(pair._1, pair._1.size(), pair._2)?
    end
    for source in [""; "-"; "+1"; " 1"; "1 "; "1x"; "/"; ":"; "_"
      "12\0x"; "é"; "9223372036854775808"
      "-9223372036854775809"].values()
    do
      _decline(source, source.size())?
    end
    for suffix in ["x"; "9"; "\0"].values() do
      for pair in [(USize(1), I64(1)); (USize(2), I64(12))
        (USize(3), I64(123))].values()
      do
        _success("123" + suffix, pair._1, pair._2)?
      end
      _success("-12" + suffix, 2, -1)?
      _success("-12" + suffix, 3, -12)?
    end
    _decline("123x", 4)?
    _decline("-12x", 1)?
    _decline("-12x", 4)?
    _decline("unused", 0)?
    let bytes: Array[U8] val = [as U8: '7'; '8']
    var value: I64 = 0
    _assert(@conduit_pq_i64_decimal(bytes.cpointer(), bytes.size(),
      addressof value) == 1, "array status")?
    _assert(value == 78, "array value")?

  fun _generated() ? =>
    let values = Array[I64].>push(0).>push(I64.min_value())
      .>push(I64.max_value())
    var power: I64 = 1
    for bit in Range[USize](0, 63) do
      for delta in [as I64: -1; 0; 1].values() do
        values.push(power + delta)
        values.push(-(power + delta))
      end
      if bit < 62 then power = power * 2 end
    end
    power = 1
    for exponent in Range[USize](0, 19) do
      for delta in [as I64: -1; 0; 1].values() do
        values.push(power + delta)
        values.push(-(power + delta))
      end
      if exponent < 18 then power = power * 10 end
    end
    let widths = Array[Bool].init(false, 20)
    var positive = false
    var negative = false
    var zero = false
    var below_i32 = false
    var above_i32 = false
    for number in values.values() do
      let source: String val = number.string()
      _success(source, source.size(), number)?
      let width = source.size() - (if number < 0 then USize(1) else 0 end)
      try widths(width)? = true else _Unreachable() end
      positive = positive or (number > 0)
      negative = negative or (number < 0)
      zero = zero or (number == 0)
      below_i32 = below_i32 or (number == (I32.min_value().i64() - 1))
      above_i32 = above_i32 or (number == (I32.max_value().i64() + 1))
    end
    _assert(positive, "positive coverage")?
    _assert(negative, "negative coverage")?
    _assert(zero, "zero coverage")?
    _assert(below_i32, "lower I32 neighbor coverage")?
    _assert(above_i32, "upper I32 neighbor coverage")?
    for width in Range[USize](1, 20) do
      _assert(widths(width)?, "decimal width " + width.string())?
    end

  fun _success(source: String, length: USize, expected: I64) ? =>
    var value: I64 = 0
    _assert(@conduit_pq_i64_decimal(source.cstring(), length,
      addressof value) == 1, "status for " + source)?
    _assert(value == expected, "value for " + source)?

  fun _decline(source: String, length: USize) ? =>
    var value: I64 = 0
    _assert(@conduit_pq_i64_decimal(source.cstring(), length,
      addressof value) == 0, "decline for " + source)?

  fun _assert(condition: Bool, message: String, loc: SourceLoc = __loc) ? =>
    if not condition then
      _env.err.print(loc.file() + ":" + loc.line().string() + ": " + message)
      error
    end

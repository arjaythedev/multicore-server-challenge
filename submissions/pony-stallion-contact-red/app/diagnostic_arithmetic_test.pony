use "collections"
use pg = "postgres"

class \nodoc\ _DiagArithmeticTest
  let _env: Env

  new create(env: Env) =>
    _env = env
    try
      histogram()?
      intervals()?
      env.out.print("Diagnostic arithmetic passed")
    else
      env.err.print("Diagnostic arithmetic failed")
      env.exitcode(1)
    end

  fun histogram() ? =>
    let ordinary = pg.DiagHistogram
    ordinary.add(4)
    ordinary.add(9)
    let ordinary_value = ordinary.snapshot()
    _assert(ordinary_value.count == 2)?
    _assert(ordinary_value.sum == 13)?
    _assert(ordinary_value.maximum == 9)?
    _assert(not ordinary_value.overflow)?
    let distribution = pg.DiagHistogram
    let edges: Array[U64] val =
      [as U64: 1; 1_000; 2_000; 4_000; 8_000; 16_000; 32_000
        64_000; 128_000; 256_000; 512_000; 1_024_000; 2_048_000
        4_096_000; 8_192_000; 16_384_000; 32_768_000; 65_536_000
        131_072_000; 262_144_000; 524_288_000; 1_048_576_000
        2_097_152_000; 4_194_304_000; 8_388_608_000
        16_777_216_000]
    let expected = Array[U64].init(0, 27)
    var count: U64 = 0
    var sum: U128 = 0
    var maximum: U64 = 0
    var seed: U64 = 1
    for i in Range(0, 1_024) do
      seed = (seed * 6_364_136_223_846_793_005) +
        1_442_695_040_888_963_407
      let value: U64 =
        if i == 0 then 0
        elseif i == 1 then U64.max_value()
        elseif i < 80 then
          let edge = edges((i - 2) % edges.size())?
          if (i % 3) == 0 then edge - 1
          elseif (i % 3) == 1 then edge
          else edge + 1 end
        else seed % 20_000_000_000 end
      distribution.add(value)
      var bucket: USize = 0
      for edge in edges.values() do
        if value >= edge then bucket = bucket + 1 end
      end
      expected(bucket)? = expected(bucket)? + 1
      count = count + 1
      sum = sum + value.u128()
      if value > maximum then maximum = value end
    end
    let actual = distribution.snapshot()
    _assert(actual.count == count)?
    _assert(actual.sum == sum.min(U64.max_value().u128()).u64())?
    _assert(actual.maximum == maximum)?
    _assert(actual.overflow == (sum > U64.max_value().u128()))?
    for i in Range(0, 27) do
      _assert(actual.buckets(i)? == expected(i)?)?
    end

  fun intervals() ? =>
    let state = pg.DiagState(1, 2)
    state.count(0)
    state.observe(0, 7, 7)
    state.observe(0, 7, 8)
    let empty: Array[U64] val = recover val Array[U64] end
    let before = state.snapshot(1, 3, 4, 5, 6, empty)
    state.observe(1, 8, 7)
    state.observe(1, 8, 10)
    state.count(0)
    let after = state.snapshot(1, 3, 4, 5, 6, empty)
    _assert(before.invalid_clock == 0)?
    _assert(before.counters(0)? == 1)?
    _assert(before.histograms(0)?.count == 2)?
    _assert(before.histograms(0)?.sum == 1)?
    _assert(after.invalid_clock == 1)?
    _assert(after.counters(0)? == 2)?
    _assert(after.histograms(1)?.count == 1)?
    _assert(after.histograms(1)?.sum == 2)?
    _assert(after.histograms(1)?.maximum == 2)?

  fun _assert(condition: Bool, loc: SourceLoc = __loc) ? =>
    if not condition then
      _env.err.print(loc.file() + ":" + loc.line().string() +
        ": assertion failed")
      error
    end

use pg = "postgres"

primitive \nodoc\ _DecodedValueTest
  fun apply(actual: pg.FieldData, expected: pg.FieldData, env: Env) ? =>
    match expected
    | let n: I64 =>
      _assert(match actual | let _: I64 => true else false end, env)?
      _assert((actual as I64) == n, env)?
    | let n: I32 =>
      _assert(match actual | let _: I32 => true else false end, env)?
      _assert((actual as I32) == n, env)?
    | let b: Bool =>
      _assert(match actual | let _: Bool => true else false end, env)?
      _assert((actual as Bool) == b, env)?
    | let s: String =>
      _assert(match actual | let _: String => true else false end, env)?
      _assert((actual as String) == s, env)?
    | None => _assert(actual is None, env)?
    | let t: pg.PgTimestamp =>
      _assert(match actual | let _: pg.PgTimestamp => true
        else false end, env)?
      _assert((actual as pg.PgTimestamp).microseconds == t.microseconds, env)?
    | let a: pg.PgArray =>
      _assert(match actual | let _: pg.PgArray => true else false end, env)?
      let value = actual as pg.PgArray
      _assert(value.element_oid == a.element_oid, env)?
      _assert(value.elements.size() == a.elements.size(), env)?
      for (index, element) in a.elements.pairs() do
        apply(value.elements(index)?, element, env)?
      end
    else error
    end

  fun _assert(condition: Bool, env: Env, loc: SourceLoc = __loc) ? =>
    if not condition then
      env.err.print(loc.file() + ":" + loc.line().string()
        + ": decoded value assertion failed")
      error
    end

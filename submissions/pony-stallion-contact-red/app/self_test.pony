use json = "json"
use "encode/base64"
use "time"
use "collections"

class \nodoc\ _SelfTest
  let _env: Env

  new create(env: Env) =>
    _env = env
    try
      decimal()?
      configuration()?
      fields()?
      query_params()?
      _OutputTest(env)?
      _PGDecodeTest(env)?
      _PendingJobsTest(env)?
      passwords()?
      tokens()?
      env.out.print("Self-tests passed: decimal, fields, query, output, "
        + "database decoding, bcrypt, JWT")
    else
      env.err.print("Self-test failed")
      env.exitcode(1)
    end

  fun decimal() ? =>
    _assert(_Input.decimal("0")? == 0)?
    _assert(_Input.decimal("9223372036854775807")? == I64.max_value())?
    for s in [""; "-1"; "+1"; "1x"; "9223372036854775808"].values() do
      _assert(try _Input.decimal(s)?; false else true end)?
    end

  fun configuration() ? =>
    let base: Array[String] val = [
      "DATABASE_URL=postgres://test:test@127.0.0.1/test"
      "JWT_SECRET=test"]
    for count in ["1"; "24"; "95"; ""; "invalid"; "0"; "96"].values() do
      let vars: Array[String] val = recover val
        Array[String].>append(base).>push("DB_WORKERS=" + count)
      end
      _assert(_Config(vars)?.database == "test")?
    end
    for pair in [(USize(1), USize(1)); (USize(2), USize(2))
      (USize(7), USize(7)); (USize(8), USize(8)); (USize(9), USize(8))
      (USize.max_value(), USize(8))].values() do
      let defaults = _DatabaseOptions(["conduit"], pair._1) as _DatabaseLayout
      _sizes(defaults.sizes, _DatabaseLayout.production(pair._2)?.sizes)?
    end
    for count in Range[USize](1, 96) do
      let layout = _DatabaseLayout.production(count)?
      _assert(layout.sizes.size() == count)?
      _assert(layout.total == 95)?
      var sum: USize = 0
      var smallest: USize = 95
      var largest: USize = 0
      for size in layout.sizes.values() do
        _assert(size > 0)?
        sum = sum + size
        smallest = smallest.min(size)
        largest = largest.max(size)
      end
      _assert(sum == 95)?
      _assert((largest - smallest) <= 1)?
      for index in Range[USize](1, count) do
        _assert(layout.pool_size(index - 1) >= layout.pool_size(index))?
      end
      for args in [recover val
          ["conduit"; "--db-worker-count=" + count.string()] end
        recover val ["conduit"; "--db-worker-count"; count.string()] end
      ].values() do
        let parsed = _DatabaseOptions(args, 1) as _DatabaseLayout
        _sizes(parsed.sizes, layout.sizes)?
      end
    end
    for pair in [(USize(1), recover val [as USize: 95] end)
      (USize(2), recover val [as USize: 48; 47] end)
      (USize(4), recover val [as USize: 24; 24; 24; 23] end)
      (USize(8), recover val [as USize: 12; 12; 12; 12; 12; 12; 12; 11] end)
    ].values() do
      _sizes(_DatabaseLayout.production(pair._1)?.sizes, pair._2)?
    end
    for value in [""; "0"; "96"; "-1"; "+1"; "1x"; " 1"; "1 "
      "9223372036854775808"].values() do
      _assert(_DatabaseOptions(recover val
        ["conduit"; "--db-worker-count=" + value] end, 1)
        is _WorkerCountError)?
    end
    _assert(_DatabaseOptions(["conduit"; "--db-worker-count"], 1)
      is _WorkerCountError)?
    _assert(_DatabaseOptions(["conduit"; "--db-worker-count=2"
      "--db-worker-count"; "2"], 1) is _WorkerCountError)?
    let padded = _DatabaseOptions(["conduit"; "--unrelated"
      "--db-worker-count=008"; "--ponymaxthreads=1"], 1) as _DatabaseLayout
    _sizes(padded.sizes, _DatabaseLayout.production(8)?.sizes)?
    _assert(_DatabaseLayout.production(95)?.pool_size(94) == 1)?
    for count in [as USize: 0; 96].values() do
      _assert(try _DatabaseLayout.production(count)?; false else true end)?
    end
    for pair in [(USize(0), USize(1)); (USize(96), USize(1))
      (USize(1), USize(0)); (USize(4), USize(24))
      (USize(2), USize.max_value())].values() do
      _assert(try _DatabaseLayout.fixture(pair._1, pair._2)?
        false else true end)?
    end
    _assert(_DatabaseLayout.fixture(1, 95)?.total == 95)?
    _assert(_DatabaseLayout.fixture(95, 1)?.total == 95)?
    _sizes(_DatabaseLayout.fixture(4, 5)?.sizes,
      recover val [as USize: 5; 5; 5; 5] end)?
    let fixture = _TestDatabaseLayout(base, 4)?
    _sizes(fixture.sizes, recover val [as USize: 1; 1; 1; 1] end)?
    _assert(fixture.total == 4)?

  fun _sizes(actual: Array[USize] val, expected: Array[USize] val) ? =>
    _assert(actual.size() == expected.size())?
    for index in Range(0, actual.size()) do
      _assert(actual(index)? == expected(index)?)?
    end

  fun fields() ? =>
    let obj = _Input.wrapper("""
      {"user":{"username":"name","bio":"","image":null,"password":3}}
      """, "user")?
    _assert(_Input.required(obj, "username")? == "name")?
    _assert(_Input.optional(obj, "image")? is None)?
    _assert(_Input.optional(obj, "absent")? is None)?
    _assert((_Input.optional(obj, "bio", false)? as String) == "")?
    _assert(try _Input.optional(obj, "bio")?; false else true end)?
    _assert(try _Input.optional(obj, "password")?; false else true end)?
    _assert(try _Input.required(obj, "image")?; false else true end)?

  fun passwords() ? =>
    let hash' = _Password.hash("a\x00b")?
    _assert(_Password.verify("a\x00b", hash'))?
    _assert(not _Password.verify("a\x00c", hash'))?
    _assert(not _Password.verify("a", hash'))?
    let long: String val = "p".mul(72)
    _assert(_Password.hash(long)?.size() == 60)?
    _assert(try _Password.hash(long + "p")?; false else true end)?

  fun query_params() ? =>
    _assert((_Input.query_param("limit=0&junk=%ZZ", "limit") as String)
      == "0")?
    _assert((_Input.query_param("tag=a%26b&tag=c", "tag") as String)
      == "a&b")?
    _assert((_Input.query_param("limit=&limit=1", "limit") as String)
      == "")?

  fun tokens() ? =>
    let token = _JWT.issue("secret", 42)?
    _assert(_JWT.verify("secret", token)? == 42)?
    _assert(try _JWT.verify("wrong", token)?; false else true end)?
    let now = Time.seconds()
    let good = json.JSONObject.update("sub", "42").update("exp", now + 3600)
    for claims in [good.update("exp", I64(0)); good.remove("exp")
      good.update("exp", "tomorrow"); good.update("sub", I64(42))
      good.update("sub", "0"); good.update("sub", "-1")
      good.update("sub", "9223372036854775808")].values()
    do
      let bad = signed(claims)?
      _assert(try _JWT.verify("secret", bad)?; false else true end)?
    end
    let wrong_alg = signed(good, "HS512")?
    _assert(try _JWT.verify("secret", wrong_alg)?; false else true end)?

  fun signed(claims: json.JSONObject, alg: String = "HS256"): String ? =>
    let header: String val = json.JSONObject.update("alg", alg).print()
    let body: String val = claims.print()
    let data: String val = _JWT.encode(header) + "." + _JWT.encode(body)
    data + "." + _JWT.encode(_JWT.sign("secret", data)?)

  fun _assert(condition: Bool, loc: SourceLoc = __loc) ? =>
    if not condition then
      _env.err.print(loc.file() + ":" + loc.line().string()
        + ": assertion failed")
      error
    end

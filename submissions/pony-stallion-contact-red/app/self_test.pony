use json = "json"
use "encode/base64"
use "time"

class \nodoc\ _SelfTest
  let _env: Env

  new create(env: Env) =>
    _env = env
    try
      decimal()?
      fields()?
      query_params()?
      passwords()?
      tokens()?
      env.out.print("Self-tests passed: decimal, fields, query, bcrypt, JWT")
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

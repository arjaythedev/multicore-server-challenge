use json = "json"
use stallion = "stallion"
use uri = "uri"

primitive _Input
  fun decimal(s: String): I64 ? =>
    if s.size() == 0 then error end
    var n: I64 = 0
    for c in s.values() do
      if (c < '0') or (c > '9') then error end
      n = n.mul_partial(10)?.add_partial((c - '0').i64())?
    end
    n

  fun wrapper(body: String, name: String): json.JSONObject ? =>
    let root = json.JSONParser.parse(body) as json.JSONObject
    root(name)? as json.JSONObject

  fun required(obj: json.JSONObject, name: String): String ? =>
    let s = obj(name)? as String
    if s.size() == 0 then error end
    s

  fun optional(obj: json.JSONObject, name: String,
    nonempty: Bool = true): (String | None) ?
  =>
    match obj.get_or_else(name, None)
    | None => None
    | let s: String =>
      if nonempty and (s.size() == 0) then error end
      s
    else error
    end

  fun param(request': stallion.Request, name: String): (String | None) =>
    match request'.uri.query
    | let query': String => query_param(query', name)
    else None
    end

  fun query_param(query': String, name: String): (String | None) =>
    let pairs: Array[String] val = query'.split("&")
    for pair in pairs.values() do
      match uri.ParseFormURLEncoded(pair)
      | let params: uri.FormURLEncoded val =>
        match params.get(name)
        | let value: String => return value
        end
      end
    end
    None

  fun page(request': stallion.Request): (I64, I64) ? =>
    let limit = match param(request', "limit")
      | let s: String => decimal(s)?
      else I64(20)
      end
    let offset = match param(request', "offset")
      | let s: String => decimal(s)?
      else I64(0)
      end
    if (limit < 1) or (limit > 100) then error end
    (limit, offset)

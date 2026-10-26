use json = "json"
use pg = "postgres"
use "collections"

class \nodoc\ _OutputTest
  let _env: Env

  new create(env: Env) ? =>
    _env = env
    _strings()?
    _schemas()?
    _accepted()?
    _overrides()?
    _boundaries()?
    _pre_unix_timestamp_compatibility()?
    _failures()?

  fun _strings() ? =>
    for byte in Range[U8](0, 32) do
      let s: String val = recover val String.>push(byte) end
      _roundtrip(s)?
    end
    for s in [""; "plain"; "\""; "\\"; "/"; " "; "\x7f"; "\\u0000"
      "é雪🐎"; "\",\"injected\":true,\"tail\":\""].values()
    do
      _roundtrip(s)?
    end

  fun _roundtrip(value: String) ? =>
    for s in [value; "head" + value; value + "tail"
      "head" + value + "tail"; value + value].values()
    do
      let root = json.JSONParser.parse(_Output.error_body(s))
        as json.JSONObject
      _keys(root, ["errors"])?
      let errors = root("errors")? as json.JSONObject
      _keys(errors, ["body"])?
      let body = errors("body")? as json.JSONArray
      _assert(body.size() == 1)?
      _string(body(0)?, s)?
    end

  fun _schemas() ? =>
    let special: String val = "\"\\\b\f\n\r\t\x00\x1fé雪🐎tail"
    let user = _row([as pg.FieldData:
      I64(81); "username"; "email"; None; ""; "private hash"])
    let user_keys: Array[String] val =
      ["username"; "email"; "bio"; "image"; "token"]
    let u = _object(_Output.user_body(user, "token")?, "user")?
    _keys(u, user_keys)?
    _string(u("username")?, "username")?
    _string(u("email")?, "email")?
    _assert(u("bio")? is None)?
    _string(u("image")?, "")?
    _string(u("token")?, "token")?
    for pair in [(USize(1), "username"); (USize(2), "email")
      (USize(3), "bio"); (USize(4), "image")].values()
    do
      let value = _object(_Output.user_body(
        _replace(user, pair._1, special), "token")?, "user")?
      _keys(value, user_keys)?
      _string(value(pair._2)?, special)?
      _string(value("token")?, "token")?
    end
    let token = _object(_Output.user_body(user, special)?, "user")?
    _string(token("token")?, special)?
    _string(token("email")?, "email")?

    let profile = _row([as pg.FieldData:
      I64(82); "author"; "biography"; "picture"; true])
    let p = _object(_Output.profile_body(profile, 1)?, "profile")?
    _profile(p, "author", "biography", "picture", true)?
    for pair in [(USize(1), "username"); (USize(2), "bio")
      (USize(3), "image")].values()
    do
      let value = _object(_Output.profile_body(
        _replace(profile, pair._1, special), 1)?, "profile")?
      _string(value(pair._2)?, special)?
      _assert(value("following")? as Bool)?
    end

    let tags = pg.PgArray(25, [as pg.FieldData: "tag-a"; "tag-b"])
    let article = _row([as pg.FieldData:
      I64(83); "slug"; "title"; "description"; "body"
      pg.PgTimestamp(0); pg.PgTimestamp(123456); tags; I64(0); false
      "writer"; None; ""; true])
    let a = _object(_Output.article_body(article)?, "article")?
    _keys(a, ["slug"; "title"; "description"; "body"; "createdAt"
      "updatedAt"; "tagList"; "favoritesCount"; "favorited"; "author"])?
    for pair in [("slug", "slug"); ("title", "title")
      ("description", "description"); ("body", "body")
      ("createdAt", "2000-01-01T00:00:00.000Z")
      ("updatedAt", "2000-01-01T00:00:00.123Z")].values()
    do
      _string(a(pair._1)?, pair._2)?
    end
    _integer(a("favoritesCount")?, 0)?
    _assert(not (a("favorited")? as Bool))?
    _profile(a("author")? as json.JSONObject, "writer", None, "", true)?
    let tag_list = a("tagList")? as json.JSONArray
    _assert(tag_list.size() == 2)?
    _string(tag_list(0)?, "tag-a")?
    _string(tag_list(1)?, "tag-b")?
    for pair in [(USize(1), "slug"); (USize(2), "title")
      (USize(3), "description"); (USize(4), "body")].values()
    do
      let value = _object(_Output.article_body(
        _replace(article, pair._1, special))?, "article")?
      _string(value(pair._2)?, special)?
      _integer(value("favoritesCount")?, 0)?
    end
    for pair in [(USize(10), "username"); (USize(11), "bio")
      (USize(12), "image")].values()
    do
      let value = _object(_Output.article_body(
        _replace(article, pair._1, special))?, "article")?
      let author = value("author")? as json.JSONObject
      _string(author(pair._2)?, special)?
      _string(value("body")?, "body")?
    end
    let tagged = _object(_Output.article_body(_replace(article, 7,
      pg.PgArray(25, [as pg.FieldData: special])))?, "article")?
    let escaped_tags = tagged("tagList")? as json.JSONArray
    _assert(escaped_tags.size() == 1)?
    _string(escaped_tags(0)?, special)?

    let comment = _row([as pg.FieldData:
      I64(84); "comment"; pg.PgTimestamp(1000); pg.PgTimestamp(999999)
      "commenter"; "comment bio"; None; false])
    let c = _object(_Output.comment_body(comment)?, "comment")?
    _keys(c, ["id"; "body"; "createdAt"; "updatedAt"; "author"])?
    _integer(c("id")?, 84)?
    _string(c("body")?, "comment")?
    _string(c("createdAt")?, "2000-01-01T00:00:00.001Z")?
    _string(c("updatedAt")?, "2000-01-01T00:00:00.999Z")?
    _profile(c("author")? as json.JSONObject,
      "commenter", "comment bio", None, false)?
    for pair in [(USize(1), "body"); (USize(4), "username")
      (USize(5), "bio"); (USize(6), "image")].values()
    do
      let changed = _replace(comment, pair._1, special)
      let single = _object(_Output.comment_body(changed)?, "comment")?
      let listed = _array(_Output.comments_body([changed])?, "comments")?
      _assert(listed.size() == 1)?
      let item = listed(0)? as json.JSONObject
      if pair._1 == 1 then
        _string(single("body")?, special)?
        _string(item("body")?, special)?
      else
        _string((single("author")? as json.JSONObject)(pair._2)?, special)?
        _string((item("author")? as json.JSONObject)(pair._2)?, special)?
      end
      _integer(item("id")?, 84)?
    end

  fun _accepted() ? =>
    let values: Array[(pg.FieldData, json.JSONValue)] val = [
      ("sentinel", "sentinel"); (I64(42), I64(42)); (I32(-7), I64(-7))
      (false, false); (None, None)
      (pg.PgArray(25, [as pg.FieldData: "a"; ""]),
        json.JSONArray.push("a").push(""))
      (pg.PgTimestamp(0), "2000-01-01T00:00:00.000Z")]
    for pair in values.values() do
      let row = _row([as pg.FieldData:
        I64(1); pair._1; "neighbor"; None; ""])
      let user = _object(_Output.user_body(row, "token")?, "user")?
      match pair._2
      | let s: String => _string(user("username")?, s)?
      | let n: I64 => _integer(user("username")?, n)?
      | let b: Bool => _assert((user("username")? as Bool) == b)?
      | None => _assert(user("username")? is None)?
      | let expected: json.JSONArray =>
        let actual = user("username")? as json.JSONArray
        _assert(actual.size() == expected.size())?
        for index in Range(0, expected.size()) do
          _string(actual(index)?, expected(index)? as String)?
        end
      else error
      end
      _string(user("email")?, "neighbor")?
      _string(user("token")?, "token")?
    end

  fun _overrides() ? =>
    let short_profile = _row([as pg.FieldData:
      I64(1); "profile"; "bio"; "image"])
    let short_comment = _row([as pg.FieldData:
      I64(2); "body"; pg.PgTimestamp(0); pg.PgTimestamp(0)
      "commenter"; "bio"; "image"])
    for following in [false; true].values() do
      let profile = _object(_Output.profile_body(
        short_profile, 1, following)?, "profile")?
      _profile(profile, "profile", "bio", "image", following)?
      let comment = _object(_Output.comment_body(
        short_comment, following)?, "comment")?
      _profile(comment("author")? as json.JSONObject,
        "commenter", "bio", "image", following)?
      for source in [as pg.FieldData: not following; F64(1)].values() do
        let p = _row([as pg.FieldData:
          I64(1); "profile"; "bio"; "image"; source])
        let explicit = _object(_Output.profile_body(
          p, 1, following)?, "profile")?
        _assert((explicit("following")? as Bool) == following)?
        let c = _row([as pg.FieldData:
          I64(2); "body"; pg.PgTimestamp(0); pg.PgTimestamp(0)
          "commenter"; "bio"; "image"; source])
        let overridden = _object(_Output.comment_body(
          c, following)?, "comment")?
        _assert(((overridden("author")? as json.JSONObject)("following")?
          as Bool) == following)?
      end
      let stored = _row([as pg.FieldData:
        I64(1); "profile"; None; ""; following])
      let defaulted = _object(_Output.profile_body(stored, 1)?, "profile")?
      _profile(defaulted, "profile", None, "", following)?
    end
    _assert(try _Output.profile_body(short_profile, 1)?
      false else true end)?
    _assert(try _Output.comment_body(short_comment)?; false else true end)?
    let missing_image = _row([as pg.FieldData: I64(1); "name"; "bio"])
    _assert(try _Output.profile_body(missing_image, 1, false)?
      false else true end)?

  fun _boundaries() ? =>
    let article = _row([as pg.FieldData:
      I64(1); "slug"; "title"; "description"; "body"
      pg.PgTimestamp(0); pg.PgTimestamp(0)
      pg.PgArray(25, recover val Array[pg.FieldData] end)
      I64(0); false; "author"; None; None; false])
    for names in [recover val Array[pg.FieldData] end
      recover val [as pg.FieldData: ""] end
      recover val [as pg.FieldData: "first"; "quote\""; "last"] end
    ].values() do
      let body = _object(_Output.article_body(_replace(article, 7,
        pg.PgArray(25, names)))?, "article")?
      let tags = body("tagList")? as json.JSONArray
      _assert(tags.size() == names.size())?
      for index in Range(0, names.size()) do
        _string(tags(index)?, names(index)? as String)?
      end
    end
    let comment = _row([as pg.FieldData:
      I64(1); "body"; pg.PgTimestamp(0); pg.PgTimestamp(0)
      "author"; None; None; false])
    for count in [as USize: 0; 1; 3].values() do
      let rows: pg.Rows = recover val
        let result = Array[pg.Row]
        for index in Range(0, count) do
          result.push(_replace(comment, 0, index.i64()))
        end
        result
      end
      let comments = _array(_Output.comments_body(rows)?, "comments")?
      _assert(comments.size() == count)?
      for index in Range(0, count) do
        let item = comments(index)? as json.JSONObject
        _integer(item("id")?, index.i64())?
        _string(item("body")?, "body")?
        _profile(item("author")? as json.JSONObject,
          "author", None, None, false)?
      end
    end
    for pair in [(I64.min_value(), "-9223372036854775808")
      (I64(-9007199254740993), "-9007199254740993")
      (I64(-1), "-1"); (I64(0), "0"); (I64(1), "1")
      (I64(9007199254740993), "9007199254740993")
      (I64.max_value(), "9223372036854775807")].values()
    do
      let a_body = _Output.article_body(_replace(article, 8, pair._1))?
      let c_body = _Output.comment_body(_replace(comment, 0, pair._1))?
      _decimal(a_body, "favoritesCount", pair._2)?
      _decimal(c_body, "id", pair._2)?
      let a = _object(a_body, "article")?
      let c = _object(c_body, "comment")?
      if (pair._1 != I64.min_value()) and (pair._1 != I64.max_value()) then
        _integer(a("favoritesCount")?, pair._1)?
        _integer(c("id")?, pair._1)?
      end
    end
    for n in [I32.min_value(); I32.max_value()].values() do
      let c = _object(_Output.comment_body(
        _replace(comment, 0, n))?, "comment")?
      _integer(c("id")?, n.i64())?
    end
    for pair in [(I64(-946684800000000), "1970-01-01T00:00:00.000Z")
      (I64(-1), "1999-12-31T23:59:59.999Z")
      (I64(0), "2000-01-01T00:00:00.000Z")
      (I64(1001), "2000-01-01T00:00:00.001Z")
      (I64(9999), "2000-01-01T00:00:00.009Z")
      (I64(10999), "2000-01-01T00:00:00.010Z")
      (I64(99999), "2000-01-01T00:00:00.099Z")
      (I64(100999), "2000-01-01T00:00:00.100Z")
      (I64(999999), "2000-01-01T00:00:00.999Z")].values()
    do
      for item in [(USize(5), "createdAt"); (USize(6), "updatedAt")].values()
      do
        let a = _object(_Output.article_body(_replace(article,
          item._1, pg.PgTimestamp(pair._1)))?, "article")?
        _string(a(item._2)?, pair._2)?
      end
      for item in [(USize(2), "createdAt"); (USize(3), "updatedAt")].values()
      do
        let c = _object(_Output.comment_body(_replace(comment,
          item._1, pg.PgTimestamp(pair._1)))?, "comment")?
        _string(c(item._2)?, pair._2)?
      end
    end

  fun _pre_unix_timestamp_compatibility() ? =>
    let row = _row([as pg.FieldData:
      I64(1); "body"; pg.PgTimestamp(-946684800000001); pg.PgTimestamp(0)
      "author"; None; None; false])
    let comment = _object(_Output.comment_body(row)?, "comment")?
    _string(comment("createdAt")?, "1970-01-01T00:00:00.999Z")?
    _string(comment("updatedAt")?, "2000-01-01T00:00:00.000Z")?

  fun _failures() ? =>
    let good = _row([as pg.FieldData:
      I64(1); "body"; pg.PgTimestamp(0); pg.PgTimestamp(0)
      "author"; None; None; false])
    let short = _row([as pg.FieldData:
      I64(2); "second"; pg.PgTimestamp(0); pg.PgTimestamp(0)
      "author"; None; None])
    let empty = _row(recover val Array[pg.FieldData] end)
    for bad in [empty; short; _replace(good, 7, F64(1))].values() do
      _assert(try _Output.comment_body(bad)?; false else true end)?
      _assert(try _Output.comments_body([good; bad])?
        false else true end)?
      let recovered = _object(_Output.comment_body(good)?, "comment")?
      _integer(recovered("id")?, 1)?
      _string(recovered("body")?, "body")?
      _roundtrip("after failure")?
    end
    for bad in [as pg.FieldData:
      F64(1); pg.PgArray(25, [as pg.FieldData: "first"; I32(2)])
      pg.PgArray(25, [as pg.FieldData: "first"; None])].values()
    do
      let row = _row([as pg.FieldData: I64(1); "name"; "email"; None; bad])
      _assert(try _Output.user_body(row, "token")?; false else true end)?
    end

  fun _row(values: Array[pg.FieldData] val): pg.Row =>
    pg.Row(values)

  fun _replace(row: pg.Row, index: USize, value: pg.FieldData): pg.Row =>
    let fields: Array[pg.FieldData] val = recover val
      let result = Array[pg.FieldData]
      for (i, field) in row.fields.pairs() do
        result.push(if i == index then value else field end)
      end
      result
    end
    pg.Row(fields)

  fun _object(body: String, name: String): json.JSONObject ? =>
    let root = json.JSONParser.parse(body) as json.JSONObject
    _keys(root, [name])?
    root(name)? as json.JSONObject

  fun _array(body: String, name: String): json.JSONArray ? =>
    let root = json.JSONParser.parse(body) as json.JSONObject
    _keys(root, [name])?
    root(name)? as json.JSONArray

  fun _keys(value: json.JSONObject, expected: Array[String] val) ? =>
    _assert(value.size() == expected.size())?
    for key in expected.values() do _assert(value.contains(key))? end

  fun _string(value: json.JSONValue, expected: String) ? =>
    let actual = value as String
    _assert(actual.size() == expected.size())?
    _assert(actual == expected)?

  fun _integer(value: json.JSONValue, expected: I64) ? =>
    _assert((value as I64) == expected)?

  fun _decimal(body: String, key: String, expected: String) ? =>
    let marker: String val = "\"" + key + "\":"
    let start = body.find(marker)? + marker.size().isize()
    let finish = body.find(",", start)?
    _assert(body.substring(start, finish) == expected)?

  fun _profile(value: json.JSONObject, username: String,
    bio: (String | None), image: (String | None), following: Bool) ?
  =>
    _keys(value, ["username"; "bio"; "image"; "following"])?
    _string(value("username")?, username)?
    match bio
    | let s: String => _string(value("bio")?, s)?
    else _assert(value("bio")? is None)?
    end
    match image
    | let s: String => _string(value("image")?, s)?
    else _assert(value("image")? is None)?
    end
    _assert((value("following")? as Bool) == following)?

  fun _assert(condition: Bool, loc: SourceLoc = __loc) ? =>
    if not condition then
      _env.err.print(loc.file() + ":" + loc.line().string()
        + ": assertion failed")
      error
    end

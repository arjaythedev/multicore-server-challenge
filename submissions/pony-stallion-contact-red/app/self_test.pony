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
      statement_classes()?
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
      let selection = _DatabaseOptions(["conduit"], pair._1)
        as _DatabaseSelection
      let defaults = selection.production() as _DatabaseLayout
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
        let selection = _DatabaseOptions(args, 1) as _DatabaseSelection
        let parsed = selection.production() as _DatabaseLayout
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
      "--db-worker-count=008"; "--ponymaxthreads=1"], 1) as _DatabaseSelection
    _sizes((padded.production() as _DatabaseLayout).sizes,
      _DatabaseLayout.production(8)?.sizes)?
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
    var production_cases: USize = 0
    var fixture_cases: USize = 0
    for count in Range[USize](1, 96) do
      for writes in Range[USize](0, 96) do
        let accepted = (writes == 0) or
          ((writes >= count) and ((writes + count) <= 95))
        let actual = try _DatabaseLayout.production(count, writes)?
          else None end
        _assert((actual isnt None) == accepted)?
        match actual
        | let layout: _DatabaseLayout =>
          _allocation(layout, count, 95, writes)?
        end
        production_cases = production_cases + 1
      end
      for size in Range[USize](1, (95 / count) + 1) do
        for writes in Range[USize](0, 96) do
          let total = count * size
          let accepted = (writes == 0) or
            ((writes >= count) and ((writes + count) <= total))
          let actual = try _DatabaseLayout.fixture(count, size, writes)?
            else None end
          _assert((actual isnt None) == accepted)?
          match actual
          | let layout: _DatabaseLayout =>
            _allocation(layout, count, total, writes)?
            for index in Range[USize](0, count) do
              _assert(layout.pool_size(index) == size)?
            end
          end
          fixture_cases = fixture_cases + 1
        end
      end
    end
    _assert(production_cases == 9_120)?
    _assert(fixture_cases == 42_912)?
    for value in [as USize: 0; 96; USize.max_value()].values() do
      _assert(try _SharedSessions(value)?; false else true end)?
      _assert(try _DatabaseLayout.production(value)?; false else true end)?
      _assert(try _DatabaseLayout.fixture(value, 1)?; false else true end)?
      _assert(try _DatabaseLayout.fixture(1, value)?; false else true end)?
    end
    for value in [as USize: 96; USize.max_value()].values() do
      _assert(try _DatabaseLayout.production(1, value)?
        false else true end)?
      _assert(try _DatabaseLayout.fixture(1, 95, value)?
        false else true end)?
    end
    _assert(_SharedSessions(1)?.total == 1)?
    _assert(_SharedSessions(95)?.total == 95)?
    for pair in [(USize(1), USize(1)); (USize(1), USize(94))
      (USize(94), USize(1))].values() do
      let sessions = _SplitSessions(pair._1, pair._2)?
      _assert(sessions.reads == pair._1)?
      _assert(sessions.writes == pair._2)?
      _assert(sessions.total == (pair._1 + pair._2))?
    end
    for pair in [(USize(0), USize(0)); (USize(0), USize(1))
      (USize(1), USize(0)); (USize(1), USize(95))
      (USize(95), USize(1)); (USize.max_value(), USize(1))
      (USize(1), USize.max_value())
      (USize.max_value(), USize.max_value())].values() do
      _assert(try _SplitSessions(pair._1, pair._2)?
        false else true end)?
    end
    _allocation_vector(_DatabaseLayout.production(8, 32)?,
      [as USize: 8; 8; 8; 8; 8; 8; 8; 7],
      [as USize: 4; 4; 4; 4; 4; 4; 4; 4])?
    _allocation_vector(_DatabaseLayout.production(2, 3)?,
      [as USize: 46; 46], [as USize: 2; 1])?
    _allocation_vector(_DatabaseLayout.fixture(4, 3, 5)?,
      [as USize: 1; 2; 2; 2], [as USize: 2; 1; 1; 1])?

  fun _allocation(layout: _DatabaseLayout, count: USize, total: USize,
    writes: USize) ?
  =>
    _assert(layout.sizes.size() == count)?
    _assert(layout.total == total)?
    var actual_total: USize = 0
    var actual_writes: USize = 0
    var actual_reads: USize = 0
    var previous_writes: USize = 95
    var largest_writes: USize = 0
    var smallest_writes: USize = 95
    for index in Range[USize](0, count) do
      let size = layout.pool_size(index)
      _assert(size > 0)?
      actual_total = actual_total + size
      match layout.sessions(index)
      | let shared: _SharedSessions =>
        _assert(writes == 0)?
        _assert(shared.total == size)?
      | let split: _SplitSessions =>
        _assert(writes > 0)?
        _assert(split.total == size)?
        _assert(split.reads > 0)?
        _assert(split.writes > 0)?
        _assert((split.reads + split.writes) == size)?
        _assert(split.writes <= previous_writes)?
        previous_writes = split.writes
        largest_writes = largest_writes.max(split.writes)
        smallest_writes = smallest_writes.min(split.writes)
        actual_writes = actual_writes + split.writes
        actual_reads = actual_reads + split.reads
      end
    end
    _assert(actual_total == total)?
    _assert(actual_writes == writes)?
    if writes != 0 then
      _assert(actual_reads == (total - writes))?
      _assert((largest_writes - smallest_writes) <= 1)?
    end

  fun _allocation_vector(layout: _DatabaseLayout, reads: Array[USize] val,
    writes: Array[USize] val) ?
  =>
    _assert(layout.sizes.size() == reads.size())?
    for index in Range[USize](0, reads.size()) do
      let split = layout.sessions(index) as _SplitSessions
      _assert(split.reads == reads(index)?)?
      _assert(split.writes == writes(index)?)?
    end

  fun statement_classes() ? =>
    let expected: Array[(_RequestStatement, String, _StatementClass)] val = [
      (_Tags, "tags", _ReadClass)
      (_RegisterUser, "register_user", _WriteClass)
      (_LoginUser, "login_user", _ReadClass)
      (_CurrentUser, "current_user", _ReadClass)
      (_UpdateUser, "update_user", _WriteClass)
      (_Profile, "profile", _ReadClass)
      (_FollowTarget, "follow_target", _ReadClass)
      (_FollowInsert, "follow_insert", _WriteClass)
      (_FollowDelete, "follow_delete", _WriteClass)
      (_ArticlePageAll, "article_page_all", _ReadClass)
      (_ArticlePageFeed, "article_page_feed", _ReadClass)
      (_ArticlePageTag, "article_page_tag", _ReadClass)
      (_ArticlePageAuthor, "article_page_author", _ReadClass)
      (_ArticlePageFavorited, "article_page_favorited", _ReadClass)
      (_ArticleFullBySlug, "article_full_by_slug", _ReadClass)
      (_ArticleFullById, "article_full_by_id", _ReadClass)
      (_ArticleInsert, "article_insert", _WriteClass)
      (_ArticleIdAndAuthorBySlug, "article_id_and_author_by_slug", _ReadClass)
      (_ArticleUpdateInput, "article_update_input", _ReadClass)
      (_ArticleUpdate, "article_update", _WriteClass)
      (_ArticleDelete, "article_delete", _WriteClass)
      (_ArticleIdBySlug, "article_id_by_slug", _ReadClass)
      (_FavoriteInsert, "favorite_insert", _WriteClass)
      (_FavoriteDelete, "favorite_delete", _WriteClass)
      (_CommentsBySlug, "comments_by_slug", _ReadClass)
      (_CommentInput, "comment_input", _ReadClass)
      (_CommentInsert, "comment_insert", _WriteClass)
      (_CommentOwner, "comment_owner", _ReadClass)
      (_CommentDelete, "comment_delete", _WriteClass)]
    var reads: USize = 0
    var writes: USize = 0
    for (kind, entry) in expected.pairs() do
      (let statement, let name, let role) = entry
      _assert(_Catalog.statement_class(statement) is role)?
      _assert(_Catalog.name(statement) == name)?
      _assert(_Catalog.kind(statement) == kind)?
      let selected = _PoolStatement(name)?
      _assert(selected is statement)?
      _assert(_Catalog.name(selected) == name)?
      _assert(_Catalog.kind(selected) == kind)?
      if role is _ReadClass then reads = reads + 1
      else writes = writes + 1 end
    end
    _assert(expected.size() == 29)?
    _assert(reads == 18)?
    _assert(writes == 11)?
    _assert(_Catalog.all().size() == 30)?
    _assert(_Catalog.all()(29)? is _Rollback)?

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

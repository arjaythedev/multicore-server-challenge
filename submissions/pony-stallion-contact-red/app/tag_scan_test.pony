use "collections"
use pg = "postgres"

class \nodoc\ _TagScanTest
  let _env: Env
  let _recipient: _Recipient

  new create(env: Env) ? =>
    _env = env
    _recipient = _Recipient(_PendingClient)
    _classification()?
    _case("", 31, recover val Array[USize] end)?
    _case("RR", 31, recover val Array[USize] end)?
    _case("BT", 31, recover val Array[USize] end)?
    _case("TRTRT", 31, [as USize: 0; 2; 4])?
    _case("TT", 31, [as USize: 0; 1])?
    _case("RTT", 31, [as USize: 1; 2])?
    _case("TR", 31, [as USize: 0])?
    _case("RTBT", 31, [as USize: 1])?
    _case("TT", 0, recover val Array[USize] end)?
    _case("RTT", 1, [as USize: 1])?
    let first: Array[USize] val = recover val
      let indices = Array[USize]
      for index in Range[USize](0, 31) do indices.push(index) end
      indices
    end
    _case(_repeat('T', 32), 31, first)?
    _case(_repeat('T', 32), 32, first)?
    _case(_repeat('R', 30) + "TT", 31, [as USize: 30])?
    _case(_repeat('R', 31) + "T", 31,
      recover val Array[USize] end)?
    _later_tag()?
    _env.out.print("tag scan tests passed")

  fun _repeat(byte: U8, count: USize): String val =>
    recover val String.from_array(Array[U8].init(byte, count)) end

  fun ref _job(kind: U8): _Job =>
    _Job(_recipient, 1,
      if kind == 'T' then _TagsQuery
      else pg.PreparedQuery("SELECT 1", _P.none()) end,
      0, 0, kind == 'R')

  fun ref _classification() ? =>
    let reads: Array[(_RequestStatement, Array[_Param] val)] val = [
      (_CurrentUser, _P.one(I64(1)))
      (_Profile, _P.two(I64(1), "name"))
      (_ArticlePageAll, _P.three(I64(1), I64(10), I64(0)))
      (_ArticlePageFeed, _P.three(I64(1), I64(10), I64(0)))
      (_ArticlePageTag, _P.four(I64(1), I64(10), I64(0), "tag"))
      (_ArticlePageAuthor, _P.four(I64(1), I64(10), I64(0), "name"))
      (_ArticlePageFavorited, _P.four(I64(1), I64(10), I64(0), "name"))
      (_ArticleFullBySlug, _P.two(I64(1), "slug"))
      (_ArticleFullById, _P.two(I64(1), I64(2)))
      (_CommentsBySlug, _P.two(I64(1), "slug"))]
    for (statement, params) in reads.values() do
      _assert(_Catalog.tag_scan_safe(statement, params))?
      let short: Array[_Param] val = recover val
        let values = Array[_Param].>append(params)
        try values.pop()? else _Unreachable() end
        values
      end
      _assert(not _Catalog.tag_scan_safe(statement, short))?
      _assert(not _Catalog.tag_scan_safe(statement,
        recover val Array[_Param].>append(params).>push(I64(1)) end))?
      for position in Range[USize](0, params.size()) do
        let replacements: Array[_Param] val = match params(position)?
          | let _: I64 => [as _Param: None; "1"; I32(1)]
          else [as _Param: None; I64(1)]
          end
        for replacement in replacements.values() do
          let changed: Array[_Param] val = recover val
            let values = Array[_Param].>append(params)
            try values(position)? = replacement else _Unreachable() end
            values
          end
          _assert(not _Catalog.tag_scan_safe(statement, changed))?
        end
      end
    end
    let barriers: Array[(_RequestStatement, Array[_Param] val)] val = [
      (_RegisterUser, _P.three("name", "email", "hash"))
      (_LoginUser, _P.one("email"))
      (_UpdateUser, _P.six(I64(1), "email", "name", "hash", "bio", "image"))
      (_FollowTarget, _P.one("name"))
      (_FollowInsert, _P.two(I64(1), I64(2)))
      (_FollowDelete, _P.two(I64(1), I64(2)))
      (_ArticleInsert, _P.two(I64(1), "{}"))
      (_ArticleIdAndAuthorBySlug, _P.one("slug"))
      (_ArticleUpdateInput, _P.two("slug", "{}"))
      (_ArticleUpdate, _P.four(I64(1), "title", "description", "body"))
      (_ArticleDelete, _P.one(I64(1)))
      (_ArticleIdBySlug, _P.one("slug"))
      (_FavoriteInsert, _P.two(I64(1), I64(2)))
      (_FavoriteDelete, _P.two(I64(1), I64(2)))
      (_CommentInput, _P.two("slug", "{}"))
      (_CommentInsert, _P.three(I64(1), I64(2), "body"))
      (_CommentOwner, _P.two(I64(1), "slug"))
      (_CommentDelete, _P.one(I64(1)))]
    for (statement, params) in barriers.values() do
      _assert(not _Catalog.tag_scan_safe(statement, params))?
    end
    _assert(not _Catalog.tag_scan_safe(_Tags, _P.none()))?
    _assert(not _Catalog.tag_scan_safe(_Tags, _P.one(I64(1))))?
    _assert(_job('T').is_tags())?
    let raw = _Job(_recipient, 1,
      pg.NamedPreparedQuery("tags", _P.none()), 0, 0)
    _assert(not raw.is_tags())?
    _assert(not raw.scan_read)?

  fun ref _case(pattern: String, limit: USize,
    selected: Array[USize] val) ?
  =>
    let queue: _PendingJobs ref = _PendingJobs
    let original = Array[_Job]
    for kind in pattern.values() do
      let job = _job(kind)
      queue.push(job)
      original.push(job)
    end
    let followers = queue.take_tags(limit)
    _assert((followers is None) == (selected.size() == 0))?
    match followers
    | let jobs: _TagFollowers =>
      _assert(jobs.size() == selected.size())?
      let actual = jobs.jobs()
      for index in selected.values() do
        _assert(actual.next()? is original(index)?)?
        _assert(original(index)?._pending_next() is None)?
      end
      _assert(not actual.has_next())?
    end
    let retained = Array[_Job]
    for index in Range[USize](0, original.size()) do
      if not selected.contains(index) then retained.push(original(index)?) end
    end
    _queue(queue, retained)?
    let fresh = _job('B')
    queue.push(fresh)
    retained.push(fresh)
    _queue(queue, retained)?
    for index in selected.values() do
      _assert(original(index)?._pending_next() is None)?
    end
    for expected in retained.values() do
      _assert(queue.shift()? is expected)?
      _assert(expected._pending_next() is None)?
    end
    _queue(queue, Array[_Job])?
    let refill = _job('T')
    queue.push(refill)
    let after = queue.take_tags(31) as _TagFollowers
    _assert(after.jobs().next()? is refill)?
    _queue(queue, Array[_Job])?

  fun ref _later_tag() ? =>
    let queue: _PendingJobs ref = _PendingJobs
    for index in Range[USize](0, 31) do queue.push(_job('R')) end
    let tag_job = _job('T')
    queue.push(tag_job)
    _assert(queue.take_tags(31) is None)?
    for index in Range[USize](0, 31) do queue.shift()? end
    let followers = queue.take_tags(31) as _TagFollowers
    _assert(followers.jobs().next()? is tag_job)?
    _assert(queue.size() == 0)?

  fun _queue(queue: _PendingJobs box, expected: Array[_Job] box) ? =>
    _assert(queue.size() == expected.size())?
    let actual = queue.values()
    for job in expected.values() do _assert(actual.next()? is job)? end
    _assert(not actual.has_next())?
    let endpoints = queue._test_endpoints()
    if expected.size() == 0 then
      _assert(endpoints._1 is None)?
      _assert(endpoints._2 is None)?
    else
      _assert(endpoints._1 is expected(0)?)?
      _assert(endpoints._2 is expected(expected.size() - 1)?)?
      _assert((endpoints._2 as _Job box)._pending_next() is None)?
    end

  fun _assert(condition: Bool, loc: SourceLoc = __loc) ? =>
    if not condition then
      _env.err.print(loc.file() + ":" + loc.line().string()
        + ": tag scan assertion failed")
      error
    end

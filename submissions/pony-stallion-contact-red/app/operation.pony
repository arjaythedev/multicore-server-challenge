use pg = "postgres"
use stallion = "stallion"
use uri = "uri"
use "time"

class _Operation
  let _request: _Request
  let _worker: _Worker
  var _next: (_Next | None) = None
  var _outcome: ((U16, String) | None) = None
  var _viewer: I64 = 0
  var _token: String = ""
  var _slug: String = ""
  var _name: String = ""
  var _method: String = ""

  new create(request': _Request, worker: _Worker) =>
    _request = request'
    _worker = worker

  fun ref query(statement: _RequestStatement, params: Array[_Param] val,
    next': _Next)
  =>
    _next = next'
    ifdef "conduit_diagnostic" then
      _worker.query(_request._2, _request._3, statement, params,
        Time.nanos())
    else
      _worker.query(_request._2, _request._3, statement, params)
    end

  fun ref result(result': pg.Result) =>
    try
      let next' = _next as _Next
      _next = None
      next'(this, result')?
    else
      error_reply(500, "invalid database result")
    end

  fun ref failed(failure: _DBFailure) =>
    match failure
    | let sql: _SQLFailure if sql.code == "23505" =>
      error_reply(422, "database error")
    | let _: _ConnectionLost => error_reply(500, "connection lost")
    else error_reply(500, "database error")
    end

  fun ref reply(status: U16, body: String = "") =>
    _outcome = (status, if status == 204 then "" else body end)

  fun ref reply_json(status: U16, row: pg.Row) ? =>
    _outcome = (status, row.fields(0)?.value as String)

  fun ref error_reply(status: U16, message: String) =>
    reply(status, _Output.error_body(message))

  fun ref outcome(): ((U16, String) | None) => _outcome

  fun ref start() =>
    try
      let path = _request._4.uri.path
      let parts: Array[String] val = path.split("/")
      _method = _request._4.method.string()
      let noauth = ((_method == "POST") and
        ((path == "/api/users") or (path == "/api/users/login")))
        or ((_method == "GET") and (path == "/api/tags"))
      let optional = (_method == "GET") and
        (path != "/api/user") and (path != "/api/articles/feed")
      if not noauth then
        try
          match _request._4.headers.get("Authorization")
          | let header: String =>
            if not header.at("Token ") then error end
            _token = header.substring(6)
            _viewer = _JWT.verify(_request._6, _token)?
          else
            if not optional then error end
          end
        else
          error_reply(401, "unauthorized")
          return
        end
      end
      match path
      | "/api/tags" if _method == "GET" =>
        query(_Tags, _P.none(),
          {ref(w': _Operation ref, r: pg.Result) ? =>
            w'.reply_json(200, _Output.first(r)? as pg.Row)?
          })
      | "/api/users" if _method == "POST" => register()?
      | "/api/users/login" if _method == "POST" => login()?
      | "/api/user" if _method == "GET" => current()
      | "/api/user" if _method == "PUT" => update_user()?
      | "/api/articles" if _method == "GET" => list(false)?
      | "/api/articles/feed" if _method == "GET" => list(true)?
      | "/api/articles" if _method == "POST" => create_article()
      else
        if (parts.size() >= 4) and (parts(1)? == "api") then
          if parts(2)? == "profiles" then
            _name = uri.PercentDecode(parts(3)?) as String
            if (parts.size() == 4) and (_method == "GET") then
              profile()
            elseif (parts.size() == 5) and (parts(4)? == "follow")
              and ((_method == "POST") or (_method == "DELETE"))
            then
              follow()
            else error_reply(404, "not found")
            end
          elseif parts(2)? == "articles" then
            _slug = uri.PercentDecode(parts(3)?) as String
            if parts.size() == 4 then
              match _method
              | "GET" => full_article(_ArticleFullBySlug, _slug)
              | "PUT" => update_article()
              | "DELETE" => delete_article()
              else error_reply(404, "not found")
              end
            elseif (parts.size() == 5) and (parts(4)? == "favorite")
              and ((_method == "POST") or (_method == "DELETE"))
            then
              favorite()
            elseif (parts.size() == 5) and (parts(4)? == "comments") then
              match _method
              | "GET" => comments()
              | "POST" => create_comment()
              else error_reply(404, "not found")
              end
            elseif (parts.size() == 6) and (parts(4)? == "comments")
              and (_method == "DELETE")
            then
              try delete_comment(_Input.decimal(parts(5)?)?)
              else error_reply(404, "not found") end
            else error_reply(404, "not found")
            end
          else error_reply(404, "not found")
          end
        else error_reply(404, "not found")
        end
      end
    else
      error_reply(422, "invalid request")
    end

  fun ref user_response(r: pg.Result, fresh: Bool,
    status: U16 = 200) ?
  =>
    match _Output.first(r)?
    | let row: pg.Row =>
      let token = if fresh then
        _JWT.issue(_request._6, _Output.id(row)?)?
      else _token
      end
      reply(status, _Output.user_body(row, token)?)
    else error_reply(401, "unauthorized")
    end

  fun ref register() ? =>
    let obj = _Input.wrapper(_request._5, "user")?
    let username = _Input.required(obj, "username")?
    let email = _Input.required(obj, "email")?
    let hash' = _Password.hash(_Input.required(obj, "password")?)?
    let op = this
    query(_RegisterUser, _P.three(username, email, hash'),
      {ref(w': _Operation ref, r: pg.Result) ? =>
        op.user_response(r, true, 201)? })

  fun ref login() ? =>
    let obj = _Input.wrapper(_request._5, "user")?
    let email = _Input.required(obj, "email")?
    let password = _Input.required(obj, "password")?
    let op = this
    query(_LoginUser, _P.one(email),
      {ref(w': _Operation ref, r: pg.Result) ? =>
        match _Output.first(r)?
        | let row: pg.Row =>
          if _Password.verify(password, row.fields(5)?.value as String) then
            op.user_response(r, true)?
          else w'.error_reply(401, "invalid email or password")
          end
        else w'.error_reply(401, "invalid email or password")
        end
      })

  fun ref current() =>
    let op = this
    query(_CurrentUser,
      _P.one(_viewer), {ref(w': _Operation ref, r: pg.Result) ? =>
        op.user_response(r, false)? })

  fun ref update_user() ? =>
    let obj = _Input.wrapper(_request._5, "user")?
    let email = _Input.optional(obj, "email")?
    let username = _Input.optional(obj, "username")?
    let hash': (String | None) = match _Input.optional(obj, "password")?
      | let password: String => _Password.hash(password)?
      else None
      end
    let bio = _Input.optional(obj, "bio", false)?
    let image = _Input.optional(obj, "image", false)?
    let op = this
    query(_UpdateUser,
      _P.six(_viewer, email, username, hash', bio, image),
      {ref(w': _Operation ref, r: pg.Result) ? =>
        op.user_response(r, false)? })

  fun ref profile() =>
    query(_Profile, _P.two(_viewer, _name),
      {ref(w': _Operation ref, r: pg.Result) ? =>
        match _Output.first(r)?
        | let row: pg.Row =>
          w'.reply(200, _Output.profile_body(row, 1)?)
        else w'.error_reply(404, "profile not found")
        end
      })

  fun ref follow() =>
    let viewer = _viewer
    let following = _method == "POST"
    query(_FollowTarget,
      _P.one(_name), {ref(w': _Operation ref, r: pg.Result) ? =>
        match _Output.first(r)?
        | let row: pg.Row =>
          let statement: _RequestStatement = if following then
            _FollowInsert
          else
            _FollowDelete
          end
          w'.query(statement, _P.two(viewer, _Output.id(row)?),
            {ref(w'': _Operation ref, r': pg.Result) ? =>
              w''.reply(200, _Output.profile_body(row, 1, following)?) })
        else w'.error_reply(404, "profile not found")
        end
      })

  fun ref list(feed: Bool) ? =>
    (let limit, let offset) = _Input.page(_request._4)?
    var page: _RequestStatement = _ArticlePageAll
    var args = _P.three(_viewer, limit, offset)
    if feed then
      page = _ArticlePageFeed
    else
      var filter: String = ""
      var kind: String = ""
      for name in ["tag"; "author"; "favorited"].values() do
        match _Input.param(_request._4, name)
        | let s: String if s.size() > 0 =>
          filter = s
          kind = name
          break
        end
      end
      match kind
      | "tag" => page = _ArticlePageTag
      | "author" => page = _ArticlePageAuthor
      | "favorited" => page = _ArticlePageFavorited
      end
      if kind != "" then
        args = _P.four(_viewer, limit, offset, filter)
      end
    end
    query(page, args, {ref(w': _Operation ref, r: pg.Result) ? =>
      w'.reply_json(200, _Output.first(r)? as pg.Row)?
    })

  fun ref full_article(statement: _RequestStatement,
    key: _Param, status: U16 = 200)
  =>
    query(statement, _P.two(_viewer, key),
      {ref(w': _Operation ref, r: pg.Result) ? =>
        match _Output.first(r)?
        | let row: pg.Row =>
          w'.reply(status, _Output.article_body(row)?)
        else w'.error_reply(404, "article not found")
        end
      })

  fun ref create_article() =>
    let op = this
    query(_ArticleInsert, _P.two(_viewer, _request._5),
      {ref(w': _Operation ref, r: pg.Result) ? =>
        match _Output.first(r)?
        | let row: pg.Row =>
          op.full_article(_ArticleFullById, _Output.id(row)?, 201)
        else w'.error_reply(422, "invalid request")
        end
      })

  fun ref owned_article(next': _Next) =>
    let viewer = _viewer
    query(_ArticleIdAndAuthorBySlug,
      _P.one(_slug), {ref(w': _Operation ref, r: pg.Result) ? =>
        match _Output.first(r)?
        | let row: pg.Row =>
          if _Output.id(row, 1)? != viewer then
            w'.error_reply(403, "not the author")
          else next'(w', r)?
          end
        else w'.error_reply(404, "article not found")
        end
      })

  fun ref update_article() =>
    let op = this
    let viewer = _viewer
    query(_ArticleUpdateInput, _P.two(_slug, _request._5),
      {ref(w': _Operation ref, r: pg.Result)(op, viewer) ? =>
        let row = _Output.first(r)? as pg.Row
        if not (row.fields(0)?.value as Bool) then
          w'.error_reply(422, "invalid request")
        elseif row.fields(1)?.value is None then
          w'.error_reply(404, "article not found")
        elseif _Output.id(row, 2)? != viewer then
          w'.error_reply(403, "not the author")
        else
          let id = _Output.id(row, 1)?
          w'.query(_ArticleUpdate, _P.four(id,
              row.fields(3)?.value as (String | None),
              row.fields(4)?.value as (String | None),
              row.fields(5)?.value as (String | None)),
            {ref(w'': _Operation ref, r': pg.Result) =>
              op.full_article(_ArticleFullById, id) })
        end
    })

  fun ref delete_article() =>
    owned_article({ref(w': _Operation ref, r: pg.Result) ? =>
      let id = _Output.id(_Output.first(r)? as pg.Row)?
      w'.query(_ArticleDelete, _P.one(id),
        {ref(w'': _Operation ref, r': pg.Result) => w''.reply(204) })
    })

  fun ref with_article(next': _Next) =>
    query(_ArticleIdBySlug, _P.one(_slug),
      {ref(w': _Operation ref, r: pg.Result) ? =>
        if _Output.rows(r)?.size() == 0 then
          w'.error_reply(404, "article not found")
        else next'(w', r)?
        end
      })

  fun ref favorite() =>
    let statement: _RequestStatement = if _method == "POST" then
      _FavoriteInsert
    else _FavoriteDelete
    end
    let viewer = _viewer
    let op = this
    with_article(
      {ref(w': _Operation ref, r: pg.Result)(op, viewer, statement) ? =>
      let id = _Output.id(_Output.first(r)? as pg.Row)?
      w'.query(statement, _P.two(viewer, id),
        {ref(w'': _Operation ref, r': pg.Result) =>
          op.full_article(_ArticleFullById, id) })
    })

  fun ref comments() =>
    let viewer = _viewer
    with_article({ref(w': _Operation ref, r: pg.Result) ? =>
      let id = _Output.id(_Output.first(r)? as pg.Row)?
      w'.query(_CommentsByArticle, _P.two(viewer, id),
        {ref(w'': _Operation ref, r': pg.Result) ? =>
          w''.reply(200, _Output.comments_body(_Output.rows(r')?)?)
        })
    })

  fun ref create_comment() =>
    let viewer = _viewer
    query(_CommentInput, _P.two(_slug, _request._5),
      {ref(w': _Operation ref, r: pg.Result)(viewer) ? =>
        let row = _Output.first(r)? as pg.Row
        if not (row.fields(0)?.value as Bool) then
          w'.error_reply(422, "invalid request")
        elseif row.fields(1)?.value is None then
          w'.error_reply(404, "article not found")
        else
          w'.query(_CommentInsert,
            _P.three(_Output.id(row, 1)?, viewer,
              row.fields(2)?.value as String),
            {ref(w'': _Operation ref, r': pg.Result) ? =>
              w''.reply(201,
                _Output.comment_body(_Output.first(r')? as pg.Row, false)?)
            })
        end
    })

  fun ref delete_comment(id: I64) =>
    let viewer = _viewer
    query(_CommentOwner, _P.two(id, _slug),
      {ref(w': _Operation ref, r: pg.Result) ? =>
        match _Output.first(r)?
        | let row: pg.Row =>
          if _Output.id(row)? != viewer then
            w'.error_reply(403, "not the author")
          else
            w'.query(_CommentDelete, _P.one(id),
              {ref(w'': _Operation ref, r': pg.Result) => w''.reply(204) })
          end
        else w'.error_reply(404, "comment not found")
        end
      })

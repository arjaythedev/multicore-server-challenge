## RealWorld Conduit API.
##
## This module deliberately contains no socket code.  It receives a parsed
## asynchttpserver Request, validates/authorizes it, executes live PostgreSQL
## statements, and returns a JSON response.  Each worker process owns one
## PgConn, so a request never shares a connection with another process.

import std/[asynchttpserver, asyncdispatch, httpcore, json, strutils, tables,
            times, uri]
import ./pg, ./auth, ./password

type
  ApiCtx* = ref object
    db*: PgConn
    secret*: string

const
  ArticleListFields = """
SELECT a.id, a.slug, a.title, a.description,
       to_char(a.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS created_at,
       to_char(a.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS updated_at,
       array_to_json(ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id)
                             FROM article_tags at WHERE at.article_id = a.id
                            ORDER BY 1)) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
"""

  ArticleListSelect = ArticleListFields & """
  FROM articles a
  JOIN users u ON u.id = a.author_id
"""

  ArticleFullSelect = """
SELECT a.id, a.slug, a.title, a.description, a.body,
       to_char(a.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS created_at,
       to_char(a.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS updated_at,
       array_to_json(ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id)
                             FROM article_tags at WHERE at.article_id = a.id
                            ORDER BY 1)) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
"""

  JsonHeaders = @[("Content-Type", "application/json")]

type Handled = object of CatchableError

template replyJson(req: Request; code: HttpCode; node: JsonNode) =
  await req.respond(code, $node, newHttpHeaders(JsonHeaders))
  raise newException(Handled, "")

template replyError(req: Request; code: HttpCode; message: string) =
  let e = %*{"errors": {"body": [message]}}
  await req.respond(code, $e, newHttpHeaders(JsonHeaders))
  raise newException(Handled, "")

proc bodyJson(req: Request): JsonNode =
  try: parseJson(req.body)
  except CatchableError: nil

proc textField(n: JsonNode; key: string): string =
  if n == nil or n.kind != JObject or not n.hasKey(key): return ""
  let v = n[key]
  if v.kind != JString: "" else: v.getStr

proc nonEmpty(n: JsonNode; key: string): bool =
  textField(n, key).strip.len > 0

proc parseStrictInt(s: string): int =
  ## Accept only a non-empty run of ASCII digits.  URL query integers must not
  ## accept a leading plus/minus or whitespace.
  if s.len == 0: return -1
  for c in s:
    if c notin {'0'..'9'}: return -1
  try: parseInt(s)
  except ValueError: -1

proc optionalNonEmptyString(n: JsonNode; key: string): bool =
  ## True when absent/null, or a non-empty JSON string.
  if not n.hasKey(key) or n[key].kind == JNull: return true
  n[key].kind == JString and n[key].getStr.strip.len > 0

proc optionalString(n: JsonNode; key: string): bool =
  ## True when absent/null, or any JSON string.
  if not n.hasKey(key) or n[key].kind == JNull: return true
  n[key].kind == JString

proc profileNode(username, bio, image: string;
                 bioNull, imageNull, following: bool): JsonNode =
  result = newJObject()
  result["username"] = %username
  result["bio"] = if bioNull: newJNull() else: %bio
  result["image"] = if imageNull: newJNull() else: %image
  result["following"] = %following

proc userNode(id: int64; username, email, bio, image: string;
              bioNull, imageNull: bool; token: string): JsonNode =
  result = newJObject()
  result["email"] = %email
  result["token"] = %token
  result["username"] = %username
  result["bio"] = if bioNull: newJNull() else: %bio
  result["image"] = if imageNull: newJNull() else: %image

proc articleNode(res: QueryResult; row: int; includeBody: bool): JsonNode =
  var c = 1 # column 0 is the internal article id; the API object starts at slug
  result = newJObject()
  result["slug"] = %res.get(row, c); inc c
  result["title"] = %res.get(row, c); inc c
  result["description"] = %res.get(row, c); inc c
  if includeBody:
    result["body"] = %res.get(row, c); inc c
  result["createdAt"] = %res.get(row, c); inc c
  result["updatedAt"] = %res.get(row, c); inc c
  let tagJson = res.get(row, c); inc c
  try: result["tagList"] = parseJson(tagJson)
  except CatchableError: result["tagList"] = newJArray()
  result["favoritesCount"] = %parseInt(res.get(row, c)); inc c
  result["favorited"] = %(res.get(row, c) == "t"); inc c
  let authorName = res.get(row, c); inc c
  let bio = res.get(row, c); inc c
  let image = res.get(row, c); inc c
  let following = res.get(row, c) == "t"; inc c
  result["author"] = profileNode(authorName, bio, image,
                                 res.isNull(row, c - 3),
                                 res.isNull(row, c - 2), following)

proc commentNode(res: QueryResult; row: int): JsonNode =
  var c = 0
  result = newJObject()
  result["id"] = %parseInt(res.get(row, c)); inc c
  result["createdAt"] = %res.get(row, c); inc c
  result["updatedAt"] = %res.get(row, c); inc c
  result["body"] = %res.get(row, c); inc c
  let username = res.get(row, c); inc c
  let bio = res.get(row, c); inc c
  let image = res.get(row, c); inc c
  let following = res.get(row, c) == "t"; inc c
  result["author"] = profileNode(username, bio, image,
                                 res.isNull(row, c - 3),
                                 res.isNull(row, c - 2), following)

proc authUser(req: Request; ctx: ApiCtx; required: bool):
    tuple[ok: bool, userId: int64] =
  ## `ok` means the request may proceed.  Missing auth is okay only when
  ## `required` is false; a present-but-invalid token is never okay.
  let header = req.headers.getOrDefault("Authorization")
  if header.len == 0:
    return (not required, 0)
  if not header.startsWith("Token "):
    return (false, 0)
  let (status, info) = verifyJwt(ctx.secret, header[6 .. ^1])
  if status != jsOk: (false, 0) else: (true, info.userId)

proc parsePaging(req: Request): tuple[ok: bool, limit, offset: int] =
  var limit = 20
  var offset = 0
  var seenLimit = false
  var seenOffset = false
  for k, v in decodeQuery(req.url.query):
    case k
    of "limit":
      if seenLimit: return (false, 0, 0)
      seenLimit = true
      limit = parseStrictInt(v)
      if limit < 0: return (false, 0, 0)
    of "offset":
      if seenOffset: return (false, 0, 0)
      seenOffset = true
      offset = parseStrictInt(v)
      if offset < 0: return (false, 0, 0)
    else: discard
  if limit < 1 or limit > 100 or offset < 0: (false, 0, 0)
  else: (true, limit, offset)

proc queryValue(req: Request; key: string): string =
  for k, v in decodeQuery(req.url.query):
    if k == key: return v
  ""

proc postgresArray(values: seq[string]): string =
  ## PostgreSQL text[] literal for a validated list of non-empty strings.
  result = "{"
  for i, v in values:
    if i > 0: result.add ','
    result.add '"'
    for c in v:
      if c == '"' or c == '\\': result.add '\\'
      result.add c
    result.add '"'
  result.add "}"

proc sendArticleBySlug(req: Request; ctx: ApiCtx; viewer: int64;
                       slug: string; includeBody: bool) {.async.} =
  var q = ctx.db.execParams(ArticleFullSelect & " WHERE a.slug = $2",
                            [value($viewer), value(slug)])
  defer: q.close()
  if q.rowCount == 0:
    replyError(req, Http404, "not found")
  replyJson(req, Http200, %*{"article": articleNode(q, 0, includeBody)})

proc handleImpl(req: Request; ctx: ApiCtx) {.async.} =
  # Routing is intentionally linear: the 19 Conduit endpoints are few enough
  # that a table would add indirection without improving clarity.
  let path = req.url.path
  let meth = req.reqMethod

  # Health/read endpoint first: also validates that PostgreSQL is live.
  if meth == HttpGet and path == "/api/tags":
    var q = ctx.db.exec("SELECT name FROM tags ORDER BY name")
    defer: q.close()
    var tags = newJArray()
    for r in 0 ..< q.rowCount: tags.add %q.get(r, 0)
    let body = $(%*{"tags": tags})
    await req.respond(Http200, body, newHttpHeaders(JsonHeaders))
    return

  # --- users and authentication -------------------------------------------
  if meth == HttpPost and path == "/api/users":
    let j = bodyJson(req)
    let u = if j != nil and j.kind == JObject: j{"user"} else: nil
    if u == nil or not nonEmpty(u, "username") or
       not nonEmpty(u, "email") or not nonEmpty(u, "password") or
       textField(u, "password").len > 72:
      replyError(req, Http422, "invalid user")
    var q: QueryResult
    try:
      q = ctx.db.execParams(
        "INSERT INTO users (username,email,password_hash) VALUES ($1,$2,$3) RETURNING id,username,email,bio,image",
        [value(textField(u, "username")), value(textField(u, "email")),
         value(hashPassword(textField(u, "password")))])
    except DbError:
      replyError(req, Http422, "user already exists")
    defer: q.close()
    let id = int64(parseBiggestInt(q.get(0, 0)))
    let token = encodeJwt(id, ctx.secret)
    replyJson(req, Http201, %*{"user": userNode(id, q.get(0, 1), q.get(0, 2),
      q.get(0, 3), q.get(0, 4), q.isNull(0, 3), q.isNull(0, 4), token)})

  if meth == HttpPost and path == "/api/users/login":
    let j = bodyJson(req)
    let u = if j != nil and j.kind == JObject: j{"user"} else: nil
    if u == nil or not nonEmpty(u, "email") or not nonEmpty(u, "password"):
      replyError(req, Http422, "invalid login")
    var q = ctx.db.execParams(
      "SELECT id,username,email,bio,image,password_hash FROM users WHERE email=$1",
      [value(textField(u, "email"))])
    defer: q.close()
    if q.rowCount == 0 or not verifyPassword(textField(u, "password"), q.get(0, 5)):
      replyError(req, Http401, "invalid credentials")
    let id = int64(parseBiggestInt(q.get(0, 0)))
    let token = encodeJwt(id, ctx.secret)
    replyJson(req, Http200, %*{"user": userNode(id, q.get(0, 1), q.get(0, 2),
      q.get(0, 3), q.get(0, 4), q.isNull(0, 3), q.isNull(0, 4), token)})

  if meth == HttpGet and path == "/api/user":
    let a = authUser(req, ctx, true)
    if not a.ok: replyError(req, Http401, "unauthorized")
    var q = ctx.db.execParams("SELECT id,username,email,bio,image FROM users WHERE id=$1",
                              [value($a.userId)])
    defer: q.close()
    if q.rowCount == 0: replyError(req, Http401, "unauthorized")
    let token = req.headers.getOrDefault("Authorization")[6 .. ^1]
    replyJson(req, Http200, %*{"user": userNode(a.userId, q.get(0, 1), q.get(0, 2),
      q.get(0, 3), q.get(0, 4), q.isNull(0, 3), q.isNull(0, 4), token)})

  if meth == HttpPut and path == "/api/user":
    let a = authUser(req, ctx, true)
    if not a.ok: replyError(req, Http401, "unauthorized")
    let j = bodyJson(req)
    let u = if j != nil and j.kind == JObject: j{"user"} else: nil
    if u == nil: replyError(req, Http422, "invalid user")
    if not optionalNonEmptyString(u, "email") or
       not optionalNonEmptyString(u, "username") or
       not optionalString(u, "bio") or not optionalString(u, "image"):
      replyError(req, Http422, "invalid user")
    if u.hasKey("password") and u["password"].kind != JNull:
      if u["password"].kind != JString or u["password"].getStr.len == 0 or
         u["password"].getStr.len > 72:
        replyError(req, Http422, "invalid password")
    var email = nullValue(); var username = nullValue(); var pass = nullValue()
    var bio = nullValue(); var image = nullValue()
    if u.hasKey("email") and u["email"].kind != JNull: email = value(u["email"].getStr)
    if u.hasKey("username") and u["username"].kind != JNull: username = value(u["username"].getStr)
    if u.hasKey("password") and u["password"].kind != JNull: pass = value(hashPassword(u["password"].getStr))
    if u.hasKey("bio") and u["bio"].kind != JNull: bio = value(u["bio"].getStr)
    if u.hasKey("image") and u["image"].kind != JNull: image = value(u["image"].getStr)
    var q: QueryResult
    try:
      q = ctx.db.execParams(
        "UPDATE users SET email=COALESCE($2,email),username=COALESCE($3,username),password_hash=COALESCE($4,password_hash),bio=COALESCE($5,bio),image=COALESCE($6,image) WHERE id=$1 RETURNING id,username,email,bio,image",
        [value($a.userId), email, username, pass, bio, image])
    except DbError:
      replyError(req, Http422, "user already exists")
    defer: q.close()
    let token = req.headers.getOrDefault("Authorization")[6 .. ^1]
    replyJson(req, Http200, %*{"user": userNode(a.userId, q.get(0, 1), q.get(0, 2),
      q.get(0, 3), q.get(0, 4), q.isNull(0, 3), q.isNull(0, 4), token)})

  # --- profiles and follows ------------------------------------------------
  if path.startsWith("/api/profiles/"):
    let parts = path.split('/')
    if parts.len == 4 and meth == HttpGet:
      let a = authUser(req, ctx, false)
      if not a.ok: replyError(req, Http401, "unauthorized")
      var q = ctx.db.execParams(
        "SELECT u.username,u.bio,u.image,EXISTS(SELECT 1 FROM follows fo WHERE fo.follower_id=$1 AND fo.followee_id=u.id) FROM users u WHERE u.username=$2",
        [value($a.userId), value(decodeUrl(parts[3]))])
      defer: q.close()
      if q.rowCount == 0: replyError(req, Http404, "not found")
      replyJson(req, Http200, %*{"profile": profileNode(q.get(0, 0), q.get(0, 1),
        q.get(0, 2), q.isNull(0, 1), q.isNull(0, 2), q.get(0, 3) == "t")})
    if parts.len == 5 and parts[4] == "follow" and meth in {HttpPost, HttpDelete}:
      let a = authUser(req, ctx, true)
      if not a.ok: replyError(req, Http401, "unauthorized")
      let followSql =
        if meth == HttpPost:
          """WITH target AS (SELECT id,username,bio,image FROM users WHERE username=$2),
                 ins AS (INSERT INTO follows(follower_id,followee_id)
                         SELECT $1,id FROM target ON CONFLICT DO NOTHING)
             SELECT username,bio,image FROM target"""
        else:
          """WITH target AS (SELECT id,username,bio,image FROM users WHERE username=$2),
                 del AS (DELETE FROM follows WHERE follower_id=$1
                         AND followee_id=(SELECT id FROM target))
             SELECT username,bio,image FROM target"""
      var q = ctx.db.execParams(followSql,
                                [value($a.userId), value(decodeUrl(parts[3]))])
      defer: q.close()
      if q.rowCount == 0: replyError(req, Http404, "not found")
      replyJson(req, Http200, %*{"profile": profileNode(q.get(0, 0), q.get(0, 1),
        q.get(0, 2), q.isNull(0, 1), q.isNull(0, 2), meth == HttpPost)})

  # --- article lists, feeds and CRUD --------------------------------------
  if meth == HttpGet and path == "/api/articles":
    let a = authUser(req, ctx, false)
    if not a.ok: replyError(req, Http401, "unauthorized")
    let paging = parsePaging(req)
    if not paging.ok: replyError(req, Http422, "invalid pagination")
    let tag = queryValue(req, "tag")
    let author = queryValue(req, "author")
    let favorited = queryValue(req, "favorited")
    var q: QueryResult
    if tag.len > 0:
      q = ctx.db.execParams(ArticleListSelect & """
 WHERE a.id IN (SELECT at.article_id FROM article_tags at
      WHERE at.tag_id=(SELECT t.id FROM tags t WHERE t.name=$4)
      ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC""",
        [value($a.userId), value($paging.limit), value($paging.offset), value(tag)])
    elif author.len > 0:
      q = ctx.db.execParams("""
WITH page AS MATERIALIZED (
  SELECT a.* FROM articles a
   WHERE a.author_id=(SELECT au.id FROM users au WHERE au.username=$4)
   ORDER BY a.id DESC LIMIT $2 OFFSET $3
)
""" & ArticleListFields & """
 FROM page a JOIN users u ON u.id = a.author_id ORDER BY a.id DESC""",
        [value($a.userId), value($paging.limit), value($paging.offset), value(author)])
    elif favorited.len > 0:
      q = ctx.db.execParams(ArticleListSelect & """
 WHERE a.id IN (SELECT f.article_id FROM favorites f
      WHERE f.user_id=(SELECT fu.id FROM users fu WHERE fu.username=$4)
      ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC""",
        [value($a.userId), value($paging.limit), value($paging.offset), value(favorited)])
    else:
      # Very deep offsets are outside the capped pagination range. Avoid a
      # full 500k-row index walk just to return an empty page.
      if paging.offset > 100_000:
        var totalQ = ctx.db.exec("SELECT count(*) FROM articles")
        let total = parseInt(totalQ.get(0, 0))
        totalQ.close()
        if paging.offset >= total:
          replyJson(req, Http200, %*{"articles": newJArray(),
                                     "articlesCount": min(total, 1000)})
      q = ctx.db.execParams("""
WITH page AS MATERIALIZED (
  SELECT a.* FROM articles a ORDER BY a.id DESC LIMIT $2 OFFSET $3
)
""" & ArticleListFields & """
 FROM page a JOIN users u ON u.id = a.author_id ORDER BY a.id DESC""",
        [value($a.userId), value($paging.limit), value($paging.offset)])
    defer: q.close()
    var countQ: QueryResult
    if tag.len > 0:
      countQ = ctx.db.execParams("SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id=(SELECT t.id FROM tags t WHERE t.name=$1) LIMIT 1000) s", [value(tag)])
    elif author.len > 0:
      countQ = ctx.db.execParams("SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id=(SELECT u.id FROM users u WHERE u.username=$1) LIMIT 1000) s", [value(author)])
    elif favorited.len > 0:
      countQ = ctx.db.execParams("SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id=(SELECT fu.id FROM users fu WHERE fu.username=$1) LIMIT 1000) s", [value(favorited)])
    else:
      countQ = ctx.db.exec("SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s")
    defer: countQ.close()
    var arr = newJArray()
    for r in 0 ..< q.rowCount: arr.add articleNode(q, r, false)
    replyJson(req, Http200, %*{"articles": arr, "articlesCount": parseInt(countQ.get(0, 0))})

  if meth == HttpGet and path == "/api/articles/feed":
    let a = authUser(req, ctx, true)
    if not a.ok: replyError(req, Http401, "unauthorized")
    let paging = parsePaging(req)
    if not paging.ok: replyError(req, Http422, "invalid pagination")
    var q = ctx.db.execParams(ArticleListSelect & """
 WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL
   (SELECT a2.id FROM articles a2 WHERE a2.author_id=fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int+$3::int)) x
   WHERE fo.follower_id=$1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC""",
      [value($a.userId), value($paging.limit), value($paging.offset)])
    defer: q.close()
    var countQ = ctx.db.execParams("SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id=$1) LIMIT 1000) s", [value($a.userId)])
    defer: countQ.close()
    var arr = newJArray()
    for r in 0 ..< q.rowCount: arr.add articleNode(q, r, false)
    replyJson(req, Http200, %*{"articles": arr, "articlesCount": parseInt(countQ.get(0, 0))})

  if meth == HttpGet and path.startsWith("/api/articles/") and
     not path.contains("/comments") and not path.endsWith("/favorite"):
    let rest = path["/api/articles/".len .. ^1]
    if not rest.contains('/'):
      let slug = decodeUrl(rest)
      let a = authUser(req, ctx, false)
      if not a.ok: replyError(req, Http401, "unauthorized")
      await sendArticleBySlug(req, ctx, a.userId, slug, true)

  if meth == HttpPost and path == "/api/articles":
    let a = authUser(req, ctx, true)
    if not a.ok: replyError(req, Http401, "unauthorized")
    let j = bodyJson(req)
    let art = if j != nil and j.kind == JObject: j{"article"} else: nil
    if art == nil or not nonEmpty(art, "title") or not nonEmpty(art, "description") or not nonEmpty(art, "body"):
      replyError(req, Http422, "invalid article")
    var tags: seq[string]
    if art.hasKey("tagList") and art["tagList"].kind != JNull:
      if art["tagList"].kind != JArray: replyError(req, Http422, "invalid tagList")
      for t in art["tagList"]:
        if t.kind != JString or t.getStr.strip.len == 0: replyError(req, Http422, "invalid tagList")
        tags.add t.getStr
    var id: int64
    ctx.db.beginTx()
    try:
      var q = ctx.db.execParams(
        "INSERT INTO articles(id,slug,author_id,title,description,body) SELECT n.id,trim(both '-' from lower(regexp_replace($2,'[^A-Za-z0-9]+','-','g')))||'-'||n.id,$1,$2,$3,$4 FROM (SELECT nextval(pg_get_serial_sequence('articles','id')) AS id) n RETURNING id",
        [value($a.userId), value(textField(art, "title")), value(textField(art, "description")), value(textField(art, "body"))])
      id = int64(parseBiggestInt(q.get(0, 0)))
      q.close()
      if tags.len > 0:
        let arr = postgresArray(tags)
        ctx.db.execParams("INSERT INTO tags(name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT(name) DO NOTHING", [value(arr)]).close()
        ctx.db.execParams("INSERT INTO article_tags(article_id,tag_id) SELECT $1,t.id FROM tags t WHERE t.name=ANY($2::text[])", [value($id), value(arr)]).close()
      ctx.db.commitTx()
    except CatchableError:
      ctx.db.rollbackTx()
      replyError(req, Http422, "invalid article")
    var aq = ctx.db.execParams(ArticleFullSelect & " WHERE a.id=$2",
                               [value($a.userId), value($id)])
    if aq.rowCount == 0:
      aq.close()
      replyError(req, Http500, "article commit lost")
    replyJson(req, Http201, %*{"article": articleNode(aq, 0, true)})

  if meth == HttpPut and path.startsWith("/api/articles/"):
    let a = authUser(req, ctx, true)
    if not a.ok: replyError(req, Http401, "unauthorized")
    let slug = decodeUrl(path["/api/articles/".len .. ^1])
    var q = ctx.db.execParams("SELECT id,author_id FROM articles WHERE slug=$1", [value(slug)])
    defer: q.close()
    if q.rowCount == 0: replyError(req, Http404, "not found")
    let id = int64(parseBiggestInt(q.get(0, 0)))
    if int64(parseBiggestInt(q.get(0, 1))) != a.userId: replyError(req, Http403, "forbidden")
    let j = bodyJson(req)
    let art = if j != nil and j.kind == JObject: j{"article"} else: nil
    if art == nil: replyError(req, Http422, "invalid article")
    if not optionalNonEmptyString(art, "title") or
       not optionalNonEmptyString(art, "description") or
       not optionalNonEmptyString(art, "body"):
      replyError(req, Http422, "invalid article")
    var title = nullValue(); var desc = nullValue(); var body = nullValue()
    if art.hasKey("title") and art["title"].kind != JNull: title = value(art["title"].getStr)
    if art.hasKey("description") and art["description"].kind != JNull: desc = value(art["description"].getStr)
    if art.hasKey("body") and art["body"].kind != JNull: body = value(art["body"].getStr)
    ctx.db.execParams(
      "UPDATE articles SET title=COALESCE($2,title),description=COALESCE($3,description),body=COALESCE($4,body),slug=CASE WHEN $2::text IS NULL THEN slug ELSE trim(both '-' from lower(regexp_replace($2,'[^A-Za-z0-9]+','-','g')))||'-'||id END,updated_at=now() WHERE id=$1",
      [value($id), title, desc, body]).close()
    var aq = ctx.db.execParams(ArticleFullSelect & " WHERE a.id=$2",
                               [value($a.userId), value($id)])
    if aq.rowCount == 0:
      aq.close()
      replyError(req, Http404, "not found")
    replyJson(req, Http200, %*{"article": articleNode(aq, 0, true)})

  if meth == HttpDelete and path.startsWith("/api/articles/") and
     not path.contains("/comments/") and not path.endsWith("/favorite"):
    let a = authUser(req, ctx, true)
    if not a.ok: replyError(req, Http401, "unauthorized")
    let slug = decodeUrl(path["/api/articles/".len .. ^1])
    var q = ctx.db.execParams("""
WITH target AS (SELECT id,author_id FROM articles WHERE slug=$1),
     del AS (DELETE FROM articles WHERE id=(SELECT id FROM target)
             AND author_id=$2 RETURNING 1)
SELECT (SELECT author_id FROM target) AS author_id,
       EXISTS(SELECT 1 FROM del) AS deleted""", [value(slug), value($a.userId)])
    defer: q.close()
    if q.isNull(0, 0): replyError(req, Http404, "not found")
    if int64(parseBiggestInt(q.get(0, 0))) != a.userId: replyError(req, Http403, "forbidden")
    await req.respond(Http204, "")
    return

  # --- comments -------------------------------------------------------------
  if path.startsWith("/api/articles/") and path.endsWith("/comments"):
    let slug = decodeUrl(path["/api/articles/".len .. ^(len("/comments") + 1)])
    let a = authUser(req, ctx, false)
    if not a.ok: replyError(req, Http401, "unauthorized")

    if meth == HttpPost:
      let a2 = authUser(req, ctx, true)
      if not a2.ok: replyError(req, Http401, "unauthorized")
      let j = bodyJson(req)
      let c = if j != nil and j.kind == JObject: j{"comment"} else: nil
      if c == nil or not nonEmpty(c, "body"): replyError(req, Http422, "invalid comment")
      var q = ctx.db.execParams("""
WITH target AS (SELECT id FROM articles WHERE slug=$1),
     ins AS (INSERT INTO comments(article_id,author_id,body)
             SELECT id,$2,$3 FROM target
             RETURNING id,created_at,updated_at,body,author_id)
SELECT c.id,
       to_char(c.created_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
       to_char(c.updated_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
       c.body,u.username,u.bio,u.image
  FROM ins c JOIN users u ON u.id=c.author_id""",
        [value(slug), value($a2.userId), value(textField(c, "body"))])
      defer: q.close()
      if q.rowCount == 0: replyError(req, Http404, "not found")
      var node = newJObject()
      node["id"] = %parseInt(q.get(0, 0))
      node["createdAt"] = %q.get(0, 1)
      node["updatedAt"] = %q.get(0, 2)
      node["body"] = %q.get(0, 3)
      node["author"] = profileNode(q.get(0, 4), q.get(0, 5), q.get(0, 6),
                                   q.isNull(0, 5), q.isNull(0, 6), false)
      replyJson(req, Http201, %*{"comment": node})

    if meth == HttpGet:
      var q = ctx.db.execParams("""
WITH target AS (SELECT id FROM articles WHERE slug=$1)
SELECT c.id,
       to_char(c.created_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
       to_char(c.updated_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
       c.body,u.username,u.bio,u.image,
       EXISTS(SELECT 1 FROM follows fo WHERE fo.follower_id=$2 AND fo.followee_id=c.author_id)
  FROM target t
  LEFT JOIN comments c ON c.article_id=t.id
  LEFT JOIN users u ON u.id=c.author_id
 ORDER BY c.created_at DESC,c.id DESC LIMIT 100""",
        [value(slug), value($a.userId)])
      defer: q.close()
      if q.rowCount == 0: replyError(req, Http404, "not found")
      var arr = newJArray()
      if not q.isNull(0, 0):
        for r in 0 ..< q.rowCount: arr.add commentNode(q, r)
      replyJson(req, Http200, %*{"comments": arr})

  if path.startsWith("/api/articles/") and path.contains("/comments/"):
    let a = authUser(req, ctx, true)
    if not a.ok: replyError(req, Http401, "unauthorized")
    let chunks = path.split('/')
    let slug = decodeUrl(chunks[3])
    var cid: int64
    try: cid = int64(parseBiggestInt(chunks[5]))
    except ValueError: replyError(req, Http404, "not found")
    var q = ctx.db.execParams("""
WITH target AS (SELECT c.author_id FROM comments c
                JOIN articles a ON a.id=c.article_id
                WHERE c.id=$1 AND a.slug=$2),
     del AS (DELETE FROM comments WHERE id=$1
             AND EXISTS(SELECT 1 FROM target WHERE author_id=$3) RETURNING 1)
SELECT (SELECT author_id FROM target) AS author_id,
       EXISTS(SELECT 1 FROM del) AS deleted""", [value($cid), value(slug), value($a.userId)])
    defer: q.close()
    if q.isNull(0, 0): replyError(req, Http404, "not found")
    if int64(parseBiggestInt(q.get(0, 0))) != a.userId: replyError(req, Http403, "forbidden")
    await req.respond(Http204, "")
    return

  # --- favorites ------------------------------------------------------------
  if path.startsWith("/api/articles/") and (path.endsWith("/favorite")):
    let a = authUser(req, ctx, true)
    if not a.ok: replyError(req, Http401, "unauthorized")
    let slug = decodeUrl(path["/api/articles/".len .. ^(len("/favorite") + 1)])
    # Read the article before the write, then adjust the two fields the write
    # changes. This saves one round trip compared with read/write/read.
    var q = ctx.db.execParams(ArticleFullSelect & " WHERE a.slug=$2",
                              [value($a.userId), value(slug)])
    if q.rowCount == 0:
      q.close()
      replyError(req, Http404, "not found")
    let node = articleNode(q, 0, true)
    let aid = q.get(0, 0)
    let wasFavorited = node["favorited"].getBool
    q.close()
    if meth == HttpPost:
      ctx.db.execParams("INSERT INTO favorites(user_id,article_id) VALUES($1,$2) ON CONFLICT DO NOTHING", [value($a.userId), value(aid)]).close()
      if not wasFavorited:
        node["favorited"] = %true
        node["favoritesCount"] = %(node["favoritesCount"].getInt + 1)
    elif meth == HttpDelete:
      ctx.db.execParams("DELETE FROM favorites WHERE user_id=$1 AND article_id=$2", [value($a.userId), value(aid)]).close()
      if wasFavorited:
        node["favorited"] = %false
        node["favoritesCount"] = %(node["favoritesCount"].getInt - 1)
    else: replyError(req, Http404, "not found")
    replyJson(req, Http200, %*{"article": node})

  replyError(req, Http404, "not found")


proc handle*(req: Request; ctx: ApiCtx) {.async.} =
  ## Convert the internal "response already sent" exception into normal
  ## completion.  Async procedures cannot use template return safely, so every
  ## terminal helper raises `Handled` after writing the response.
  try:
    await handleImpl(req, ctx)
  except Handled:
    discard

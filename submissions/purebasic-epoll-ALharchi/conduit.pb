; Conduit (RealWorld) API for the multicore server challenge, in PureBasic 6.41 Free (one file, under its 781-line cap).
; Every worker thread owns an epoll instance, a SO_REUSEPORT listening socket and one Postgres connection.
; Postgres builds every response body as JSON, so serving a request is: parse it, check the token, run one prepared
; statement, copy the bytes Postgres returned into the socket.
EnableExplicit

ImportC ""
  socket.l(domain.l, type.l, protocol.l)
  setsockopt.l(fd.l, level.l, name.l, *val, len.l)
  bind.l(fd.l, *addr, len.l)
  listen.l(fd.l, backlog.l)
  accept4.l(fd.l, *addr, *len, flags.l)
  recv.i(fd.l, *buf, len.i, flags.l)
  send.i(fd.l, *buf, len.i, flags.l)
  close.l(fd.l)
  epoll_create1.l(flags.l)
  epoll_ctl.l(epfd.l, op.l, fd.l, *ev)
  epoll_wait.l(epfd.l, *evs, max.l, timeout.l)
  inet_addr.l(cp.p-ascii)
  time.q(*t)
EndImport
ImportC "-lpq"
  PQconnectdb(conninfo.p-utf8)
  PQstatus.l(conn)
  PQerrorMessage(conn)
  PQexec(conn, query.p-utf8)
  PQprepare(conn, name.p-ascii, query.p-utf8, nparams.l, *types)
  PQexecPrepared(conn, name.p-ascii, nparams.l, *values, *lengths, *formats, resultformat.l)
  PQresultStatus.l(res)
  PQresultErrorField(res, code.l)
  PQntuples.l(res)
  PQgetvalue(res, row.l, col.l)
  PQgetlength.l(res, row.l, col.l)
  PQclear(res)
EndImport
ImportC "-lcrypto"
  EVP_sha256()
  HMAC(md, *key, keylen.l, *data, n.i, *out, *outlen)
EndImport

Structure EpollEvent ; packed, as on x86-64
  events.l
  fd.l
  pad.l
EndStructure
Structure SockAddrIn
  family.w
  port.w
  addr.l
  zero.q
EndStructure

#MAXFD = 262144
#RBUF = 1048576
#BAD$ = #SOH$   ; a field that is present but invalid
#NUL$ = #STX$   ; a field that is absent or null (SQL NULL)
#JWTHEAD$ = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" ; {"alg":"HS256","typ":"JWT"}

Global dburl$ = GetEnvironmentVariable("DATABASE_URL"), host$ = GetEnvironmentVariable("HOST")
Global port = Val(GetEnvironmentVariable("PORT")), threads = Val(GetEnvironmentVariable("THREADS"))
Global *key = UTF8(GetEnvironmentVariable("JWT_SECRET")), nsql
Global Dim sql$(31), Dim *pend(#MAXFD), Dim plen.l(#MAXFD)

Threaded conn, res, epfd, *rbuf, *sbuf, *pv, *mac, js
Threaded Dim prm.s(7)

; ---------- SQL: each statement returns the finished JSON body ----------

Procedure.s TS(c$)
  ProcedureReturn "to_char(" + c$ + ~" AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"')"
EndProcedure

Procedure.s Slug(x$)
  ProcedureReturn "trim(both '-' from lower(regexp_replace(" + x$ + ",'[^A-Za-z0-9]+','-','g')))"
EndProcedure

; Profile of user row u (author id column idcol$), following = viewer $1 follows them
Procedure.s Prof(idcol$, following$ = "")
  If following$ = ""
    following$ = "EXISTS(SELECT 1 FROM follows fo WHERE fo.follower_id=$1 AND fo.followee_id=" + idcol$ + ")"
  EndIf
  ProcedureReturn "json_build_object('username',u.username,'bio',u.bio,'image',u.image,'following'," + following$ + ")"
EndProcedure

; Article row a joined with author u
Procedure.s Item(body, fav$ = "", cnt$ = "", tags$ = "")
  If fav$ = "" : fav$ = "EXISTS(SELECT 1 FROM favorites f WHERE f.article_id=a.id AND f.user_id=$1)" : EndIf
  If cnt$ = "" : cnt$ = "(SELECT count(*) FROM favorites f WHERE f.article_id=a.id)" : EndIf
  If tags$ = "" ; tag names by primary key (a join here hashes all 200 tags for every article)
    tags$ = "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id=at.tag_id) FROM article_tags at WHERE at.article_id=a.id ORDER BY 1)"
  EndIf
  Protected s$ = "json_build_object('slug',a.slug,'title',a.title,'description',a.description,"
  If body : s$ + "'body',a.body," : EndIf
  ProcedureReturn s$ + "'tagList'," + tags$ + ",'createdAt'," + TS("a.created_at") + ",'updatedAt'," + TS("a.updated_at") +
                  ",'favorited'," + fav$ + ",'favoritesCount'," + cnt$ + ",'author'," + Prof("a.author_id") + ")"
EndProcedure

; $1 viewer, $2 limit, $3 offset, $4 filter. Each article is built per row of the page (LATERAL behind OFFSET 0),
; so the generic plan never depends on how many rows LIMIT $2 returns.
Procedure.s ListSQL(page$, count$)
  ProcedureReturn "SELECT json_build_object('articles',COALESCE((SELECT json_agg(x.j ORDER BY x.id DESC) FROM (" + page$ +
                  ") p(id) CROSS JOIN LATERAL (SELECT a.id," + Item(0) + " AS j FROM articles a JOIN users u ON u.id=a.author_id " +
                  "WHERE a.id=p.id OFFSET 0) x),'[]'),'articlesCount',(SELECT count(*) FROM (" + count$ + " LIMIT 1000) s))"
EndProcedure

Procedure.s Comment(following$ = "")
  ProcedureReturn "json_build_object('id',c.id,'createdAt'," + TS("c.created_at") + ",'updatedAt'," + TS("c.updated_at") +
                  ",'body',c.body,'author'," + Prof("c.author_id", following$) + ")"
EndProcedure

#UserJ$ = "json_build_object('email',email,'username',username,'bio',bio,'image',image)"

Enumeration
  #S_Tags : #S_List : #S_ListTag : #S_ListAuthor : #S_ListFav : #S_Feed : #S_Article : #S_Comments : #S_Profile
  #S_Follow : #S_Unfollow : #S_Fav : #S_Unfav : #S_Create : #S_Update : #S_Delete : #S_AddComment : #S_DelComment
  #S_Register : #S_Login : #S_User : #S_UpdateUser
EndEnumeration

Procedure BuildSQL()
  sql$(#S_Tags) = "SELECT json_build_object('tags',COALESCE(json_agg(name ORDER BY name),'[]')) FROM tags"
  sql$(#S_List) = ListSQL("SELECT id FROM articles ORDER BY id DESC LIMIT $2 OFFSET $3", "SELECT 1 FROM articles")
  sql$(#S_ListTag) = ListSQL("SELECT at.article_id FROM article_tags at WHERE at.tag_id=(SELECT id FROM tags WHERE name=$4) " +
                          "ORDER BY at.article_id DESC LIMIT $2 OFFSET $3",
                          "SELECT 1 FROM article_tags at WHERE at.tag_id=(SELECT id FROM tags WHERE name=$4)")
  sql$(#S_ListAuthor) = ListSQL("SELECT id FROM articles WHERE author_id=(SELECT id FROM users WHERE username=$4) " +
                             "ORDER BY id DESC LIMIT $2 OFFSET $3",
                             "SELECT 1 FROM articles WHERE author_id=(SELECT id FROM users WHERE username=$4)")
  sql$(#S_ListFav) = ListSQL("SELECT f.article_id FROM favorites f WHERE f.user_id=(SELECT id FROM users WHERE username=$4) " +
                          "ORDER BY f.article_id DESC LIMIT $2 OFFSET $3",
                          "SELECT 1 FROM favorites f WHERE f.user_id=(SELECT id FROM users WHERE username=$4)")
  sql$(#S_Feed) = ListSQL("SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE " +
                       "a2.author_id=fo.followee_id ORDER BY a2.id DESC LIMIT ($2::bigint+$3::bigint)) x " +
                       "WHERE fo.follower_id=$1 ORDER BY x.id DESC LIMIT $2 OFFSET $3",
                       "SELECT 1 FROM articles WHERE author_id IN (SELECT followee_id FROM follows WHERE follower_id=$1)")
  sql$(#S_Article) = "SELECT json_build_object('article'," + Item(1) + ") FROM articles a JOIN users u ON u.id=a.author_id WHERE a.slug=$2"
  sql$(#S_Comments) = "SELECT json_build_object('comments',COALESCE((SELECT json_agg(" + Comment() +
                      " ORDER BY c.created_at DESC,c.id DESC) FROM (SELECT * FROM comments WHERE article_id=a0.id " +
                      "ORDER BY created_at DESC,id DESC LIMIT 100) c JOIN users u ON u.id=c.author_id),'[]')) " +
                      "FROM articles a0 WHERE a0.slug=$2"
  sql$(#S_Profile) = "SELECT json_build_object('profile'," + Prof("u.id") + ") FROM users u WHERE u.username=$2"
  sql$(#S_Follow) = "WITH u AS (SELECT * FROM users WHERE username=$2), i AS (INSERT INTO follows (follower_id,followee_id) " +
                    "SELECT $1,id FROM u ON CONFLICT DO NOTHING) SELECT json_build_object('profile'," + Prof("", "true") + ") FROM u"
  sql$(#S_Unfollow) = "WITH u AS (SELECT * FROM users WHERE username=$2), d AS (DELETE FROM follows WHERE follower_id=$1 " +
                      "AND followee_id=(SELECT id FROM u)) SELECT json_build_object('profile'," + Prof("", "false") + ") FROM u"
  ; the write isn't visible to the statement's own snapshot, so the count adds what this statement changed
  sql$(#S_Fav) = "WITH t AS (SELECT id FROM articles WHERE slug=$2), i AS (INSERT INTO favorites (user_id,article_id) " +
                 "SELECT $1,id FROM t ON CONFLICT DO NOTHING RETURNING 1) SELECT json_build_object('article'," +
                 Item(1, "true", "(SELECT count(*) FROM favorites f WHERE f.article_id=a.id)+(SELECT count(*) FROM i)") +
                 ") FROM articles a JOIN users u ON u.id=a.author_id WHERE a.id=(SELECT id FROM t)"
  sql$(#S_Unfav) = "WITH t AS (SELECT id FROM articles WHERE slug=$2), d AS (DELETE FROM favorites WHERE user_id=$1 " +
                   "AND article_id=(SELECT id FROM t) RETURNING 1) SELECT json_build_object('article'," +
                   Item(1, "false", "(SELECT count(*) FROM favorites f WHERE f.article_id=a.id)-(SELECT count(*) FROM d)") +
                   ") FROM articles a JOIN users u ON u.id=a.author_id WHERE a.id=(SELECT id FROM t)"
  ; $1 viewer, $2 title, $3 description, $4 body, $5 tags (one statement, so one transaction)
  sql$(#S_Create) = "WITH n AS (SELECT nextval(pg_get_serial_sequence('articles','id')) AS id), " +
                    "a AS (INSERT INTO articles (id,slug,author_id,title,description,body) SELECT n.id," + Slug("$2") +
                    "||'-'||n.id,$1,$2,$3,$4 FROM n RETURNING *), " +
                    "nt AS (INSERT INTO tags (name) SELECT DISTINCT unnest($5::text[]) ON CONFLICT (name) DO NOTHING RETURNING id), " +
                    "nat AS (INSERT INTO article_tags (article_id,tag_id) SELECT a.id,x.id FROM a," +
                    "(SELECT id FROM nt UNION SELECT id FROM tags WHERE name=ANY($5::text[])) x) " +
                    "SELECT json_build_object('article'," + Item(1, "false", "0", "ARRAY(SELECT DISTINCT unnest($5::text[]) ORDER BY 1)") +
                    ") FROM a JOIN users u ON u.id=a.author_id"
  ; $1 viewer, $2 slug, $3 title, $4 description, $5 body; returns the author and, if it is the viewer, the article
  sql$(#S_Update) = "WITH t AS (SELECT id,author_id FROM articles WHERE slug=$2), a AS (UPDATE articles SET " +
                    "title=COALESCE($3,title),description=COALESCE($4,description),body=COALESCE($5,body)," +
                    "slug=CASE WHEN $3::text IS NULL THEN slug ELSE " + Slug("$3") + "||'-'||articles.id END,updated_at=now() " +
                    "WHERE id=(SELECT id FROM t) AND (SELECT author_id FROM t)=$1 RETURNING *) " +
                    "SELECT t.author_id,(SELECT json_build_object('article'," + Item(1) + ") FROM a JOIN users u ON u.id=a.author_id) FROM t"
  sql$(#S_Delete) = "WITH t AS (SELECT id,author_id FROM articles WHERE slug=$2), d AS (DELETE FROM articles " +
                    "WHERE id=(SELECT id FROM t) AND (SELECT author_id FROM t)=$1) SELECT author_id FROM t"
  sql$(#S_AddComment) = "WITH t AS (SELECT id FROM articles WHERE slug=$2), c AS (INSERT INTO comments (article_id,author_id,body) " +
                        "SELECT id,$1,$3 FROM t RETURNING *) SELECT json_build_object('comment'," + Comment("false") +
                        ") FROM c JOIN users u ON u.id=c.author_id"
  ; $1 viewer, $2 comment id, $3 slug
  sql$(#S_DelComment) = "WITH t AS (SELECT c.id,c.author_id FROM comments c JOIN articles a ON a.id=c.article_id " +
                        "WHERE c.id=$2 AND a.slug=$3), d AS (DELETE FROM comments WHERE id=(SELECT id FROM t) " +
                        "AND (SELECT author_id FROM t)=$1) SELECT author_id FROM t"
  sql$(#S_Register) = "INSERT INTO users (username,email,password_hash) VALUES ($1,$2,$3) RETURNING id," + #UserJ$
  sql$(#S_Login) = "SELECT id,password_hash," + #UserJ$ + " FROM users WHERE email=$1"
  sql$(#S_User) = "SELECT id," + #UserJ$ + " FROM users WHERE id=$1"
  sql$(#S_UpdateUser) = "UPDATE users SET email=COALESCE($2,email),username=COALESCE($3,username)," +
                        "password_hash=COALESCE($4,password_hash),bio=COALESCE($5,bio),image=COALESCE($6,image) " +
                        "WHERE id=$1 RETURNING id," + #UserJ$
  nsql = #S_UpdateUser
EndProcedure

; ---------- Postgres ----------

Procedure Connect()
  Protected i, r
  ; no TLS on loopback (libpq's OpenSSL setup also crashes next to the PureBasic runtime)
  If FindString(dburl$, "?") : conn = PQconnectdb(dburl$ + "&sslmode=disable") : Else : conn = PQconnectdb(dburl$ + "?sslmode=disable") : EndIf
  If PQstatus(conn) <> 0
    PrintN("postgres: " + PeekS(PQerrorMessage(conn), -1, #PB_UTF8)) : End 1
  EndIf
  ; generic plans: every statement is planned once per connection instead of on every execution
  PQclear(PQexec(conn, "SET jit = off; SET max_parallel_workers_per_gather = 0; SET plan_cache_mode = force_generic_plan"))
  For i = 0 To nsql
    r = PQprepare(conn, "s" + Str(i), sql$(i), 0, 0)
    If PQresultStatus(r) <> 1
      PrintN("prepare s" + Str(i) + ": " + PeekS(PQerrorMessage(conn), -1, #PB_UTF8)) : End 1
    EndIf
    PQclear(r)
  Next
EndProcedure

; Runs statement stmt with prm(0..n-1). Returns the row count, -1 on a unique violation, -2 on any other error.
Procedure Q(stmt, n)
  Protected i, st
  If res : PQclear(res) : res = 0 : EndIf
  For i = 0 To n - 1
    If prm(i) = #NUL$ : PokeI(*pv + i * 8, 0) : Else : PokeI(*pv + i * 8, UTF8(prm(i))) : EndIf
  Next
  res = PQexecPrepared(conn, "s" + Str(stmt), n, *pv, 0, 0, 0)
  For i = 0 To n - 1
    If PeekI(*pv + i * 8) : FreeMemory(PeekI(*pv + i * 8)) : EndIf
  Next
  st = PQresultStatus(res)
  If st = 1 Or st = 2 : ProcedureReturn PQntuples(res) : EndIf
  If PQresultErrorField(res, 'C') And PeekS(PQresultErrorField(res, 'C'), -1, #PB_Ascii) = "23505"
    ProcedureReturn -1
  EndIf
  PrintN("s" + Str(stmt) + ": " + PeekS(PQerrorMessage(conn), -1, #PB_UTF8))
  ProcedureReturn -2
EndProcedure

Procedure.s VS(col)
  ProcedureReturn PeekS(PQgetvalue(res, 0, col), PQgetlength(res, 0, col), #PB_UTF8 | #PB_ByteLength)
EndProcedure

; ---------- HTTP responses ----------

Procedure Respond(fd, code, *body, len)
  Protected h$, hl, sent, r
  Select code
    Case 200 : h$ = "200 OK"
    Case 201 : h$ = "201 Created"
    Case 204 : h$ = "204 No Content"
    Case 401 : h$ = "401 Unauthorized"
    Case 403 : h$ = "403 Forbidden"
    Case 404 : h$ = "404 Not Found"
    Case 422 : h$ = "422 Unprocessable Entity"
    Default : h$ = "500 Internal Server Error"
  EndSelect
  h$ = "HTTP/1.1 " + h$ + #CRLF$ + "Content-Type: application/json" + #CRLF$ + "Content-Length: " + Str(len) + #CRLF$ + #CRLF$
  If MemorySize(*sbuf) < len + 256 : *sbuf = ReAllocateMemory(*sbuf, len + 4096) : EndIf
  hl = PokeS(*sbuf, h$, -1, #PB_Ascii | #PB_String_NoZero)
  If len : CopyMemory(*body, *sbuf + hl, len) : EndIf
  While sent < hl + len
    r = send(fd, *sbuf + sent, hl + len - sent, $4000) ; MSG_NOSIGNAL
    If r <= 0 : Break : EndIf
    sent + r
  Wend
EndProcedure

Procedure RespondS(fd, code, body$)
  Protected *u = UTF8(body$)
  Respond(fd, code, *u, MemorySize(*u) - 1)
  FreeMemory(*u)
EndProcedure

Procedure Err(fd, code, msg$)
  RespondS(fd, code, ~"{\"errors\":{\"body\":[\"" + msg$ + ~"\"]}}")
EndProcedure

; Sends column col of the first row, or the error for a failed or empty result
Procedure Reply(fd, rows, code = 200, col = 0, notfound = 404)
  If rows = -1 : Err(fd, 422, "already taken") : ProcedureReturn : EndIf
  If rows < 0 : Err(fd, 500, "database error") : ProcedureReturn : EndIf
  If rows = 0 : Err(fd, notfound, "not found") : ProcedureReturn : EndIf
  Respond(fd, code, PQgetvalue(res, 0, col), PQgetlength(res, 0, col))
EndProcedure

; ---------- JSON request bodies ----------

; The object under key$ of the body's top-level object, or 0
Procedure Wrapper(body$, key$)
  Protected *o
  If js : FreeJSON(js) : js = 0 : EndIf
  js = ParseJSON(#PB_Any, body$)
  If js = 0 Or JSONType(JSONValue(js)) <> #PB_JSON_Object : ProcedureReturn 0 : EndIf
  *o = GetJSONMember(JSONValue(js), key$)
  If *o And JSONType(*o) = #PB_JSON_Object : ProcedureReturn *o : EndIf
EndProcedure

; A string field: #NUL$ when absent or null, #BAD$ when not a string (or empty and nonempty is set)
Procedure.s Field(*o, key$, nonempty = #True)
  Protected *m = GetJSONMember(*o, key$), v$
  If *m = 0 Or JSONType(*m) = #PB_JSON_Null : ProcedureReturn #NUL$ : EndIf
  If JSONType(*m) <> #PB_JSON_String : ProcedureReturn #BAD$ : EndIf
  v$ = GetJSONString(*m)
  If nonempty And v$ = "" : ProcedureReturn #BAD$ : EndIf
  ProcedureReturn v$
EndProcedure

Procedure.s Required(*o, key$)
  Protected v$ = Field(*o, key$)
  If v$ = #NUL$ : ProcedureReturn #BAD$ : EndIf
  ProcedureReturn v$
EndProcedure

; ---------- JWT (HS256) ----------

Procedure.s Mac(msg$)
  Protected *m = UTF8(msg$), outlen.l
  HMAC(EVP_sha256(), *key, MemorySize(*key) - 1, *m, MemorySize(*m) - 1, *mac, @outlen)
  FreeMemory(*m)
  ProcedureReturn Base64Encoder(*mac, 32, #PB_Cipher_URL | #PB_Cipher_NoPadding)
EndProcedure

Procedure.s B64(s$)
  Protected *m = UTF8(s$), r$ = Base64Encoder(*m, MemorySize(*m) - 1, #PB_Cipher_URL | #PB_Cipher_NoPadding)
  FreeMemory(*m)
  ProcedureReturn r$
EndProcedure

; Parses one base64url JSON object of a token into a fresh JSON handle (0 if it isn't one)
Procedure TokenPart(part$)
  Protected *a, *d = AllocateMemory(Len(part$) + 4), n, j
  part$ = ReplaceString(ReplaceString(part$, "-", "+"), "_", "/") ; the decoder takes standard base64 only
  part$ + Left("==", (4 - Len(part$) % 4) % 4)
  *a = Ascii(part$)
  n = Base64DecoderBuffer(*a, Len(part$), *d, MemorySize(*d))
  If n > 0 : j = ParseJSON(#PB_Any, PeekS(*d, n, #PB_UTF8 | #PB_ByteLength)) : EndIf
  FreeMemory(*a) : FreeMemory(*d)
  If j And JSONType(JSONValue(j)) <> #PB_JSON_Object : FreeJSON(j) : j = 0 : EndIf
  ProcedureReturn j
EndProcedure

Procedure.s Token(id$)
  Protected now.q = time(0)
  Protected p$ = #JWTHEAD$ + "." + B64(~"{\"sub\":\"" + id$ + ~"\",\"iat\":" + Str(now) + ~",\"exp\":" + Str(now + 2592000) + "}")
  ProcedureReturn p$ + "." + Mac(p$)
EndProcedure

Procedure IsDigits(s$, maxlen = 18)
  Protected i
  If s$ = "" Or Len(s$) > maxlen : ProcedureReturn #False : EndIf
  For i = 1 To Len(s$)
    If Asc(Mid(s$, i, 1)) < '0' Or Asc(Mid(s$, i, 1)) > '9' : ProcedureReturn #False : EndIf
  Next
  ProcedureReturn #True
EndProcedure

; The viewer's user id: 0 without an Authorization header, -1 for an invalid token
Procedure.q Viewer(auth$)
  Protected t$, h, p, *m, viewer.q = -1
  If auth$ = "" : ProcedureReturn 0 : EndIf
  If Left(auth$, 6) <> "Token " : ProcedureReturn -1 : EndIf
  t$ = Mid(auth$, 7)
  If CountString(t$, ".") <> 2 Or StringField(t$, 3, ".") <> Mac(StringField(t$, 1, ".") + "." + StringField(t$, 2, "."))
    ProcedureReturn -1
  EndIf
  h = TokenPart(StringField(t$, 1, "."))
  If h
    *m = GetJSONMember(JSONValue(h), "alg")
    If *m And JSONType(*m) = #PB_JSON_String And GetJSONString(*m) = "HS256"
      p = TokenPart(StringField(t$, 2, "."))
    EndIf
    FreeJSON(h)
  EndIf
  If p
    *m = GetJSONMember(JSONValue(p), "exp")
    If *m And JSONType(*m) = #PB_JSON_Number And GetJSONDouble(*m) > time(0)
      *m = GetJSONMember(JSONValue(p), "sub")
      If *m And JSONType(*m) = #PB_JSON_String And IsDigits(GetJSONString(*m))
        viewer = Val(GetJSONString(*m))
      EndIf
    EndIf
    FreeJSON(p)
  EndIf
  ProcedureReturn viewer
EndProcedure

; ---------- routes ----------

; A query parameter's URL-decoded value, or #NUL$ when absent
Procedure.s Param(query$, name$)
  Protected i, kv$
  For i = 1 To CountString(query$, "&") + 1
    kv$ = StringField(query$, i, "&")
    If StringField(kv$, 1, "=") = name$ : ProcedureReturn URLDecoder(Mid(kv$, Len(name$) + 2)) : EndIf
  Next
  ProcedureReturn #NUL$
EndProcedure

; A non-negative integer parameter, the default when absent, -1 when invalid or out of range
Procedure.q IntParam(v$, def, min, max.q)
  Protected n.q
  If v$ = #NUL$ : ProcedureReturn def : EndIf
  While Len(v$) > 1 And Left(v$, 1) = "0" : v$ = Mid(v$, 2) : Wend
  If Not IsDigits(v$) : ProcedureReturn -1 : EndIf
  n = Val(v$)
  If n < min Or n > max : ProcedureReturn -1 : EndIf
  ProcedureReturn n
EndProcedure

Procedure ListArticles(fd, v.q, query$, feed)
  Protected limit.q = IntParam(Param(query$, "limit"), 20, 1, 100), offset.q = IntParam(Param(query$, "offset"), 0, 0, 999999999999999999)
  Protected stmt = #S_List, t$ = Param(query$, "tag"), a$ = Param(query$, "author"), f$ = Param(query$, "favorited")
  If limit < 0 Or offset < 0 : Err(fd, 422, "limit and offset must be integers in range") : ProcedureReturn : EndIf
  prm(0) = Str(v) : prm(1) = Str(limit) : prm(2) = Str(offset)
  ; the first non-empty filter applies
  If feed
    stmt = #S_Feed
  ElseIf t$ <> #NUL$ And t$ <> ""
    stmt = #S_ListTag : f$ = t$
  ElseIf a$ <> #NUL$ And a$ <> ""
    stmt = #S_ListAuthor : f$ = a$
  ElseIf f$ <> #NUL$ And f$ <> ""
    stmt = #S_ListFav
  EndIf
  prm(3) = f$
  If stmt = #S_List Or stmt = #S_Feed : Reply(fd, Q(stmt, 3)) : Else : Reply(fd, Q(stmt, 4)) : EndIf
EndProcedure

Procedure.s UserBody(json$, token$)
  ProcedureReturn ~"{\"user\":{\"token\":\"" + token$ + ~"\"," + Mid(json$, 2) + "}"
EndProcedure

Procedure Register(fd, body$)
  Protected *o = Wrapper(body$, "user"), u$, e$, p$, rows
  If *o = 0 : Err(fd, 422, "user is required") : ProcedureReturn : EndIf
  u$ = Required(*o, "username") : e$ = Required(*o, "email") : p$ = Required(*o, "password")
  If u$ = #BAD$ Or e$ = #BAD$ Or p$ = #BAD$ Or StringByteLength(p$, #PB_UTF8) > 72
    Err(fd, 422, "username, email and password are required") : ProcedureReturn
  EndIf
  prm(0) = u$ : prm(1) = e$ : prm(2) = CreatePasswordHash(p$, 10)
  rows = Q(#S_Register, 3)
  If rows <= 0 : Reply(fd, rows) : ProcedureReturn : EndIf
  RespondS(fd, 201, UserBody(VS(1), Token(VS(0))))
EndProcedure

Procedure Login(fd, body$)
  Protected *o = Wrapper(body$, "user"), e$, p$, rows
  If *o = 0 : Err(fd, 422, "user is required") : ProcedureReturn : EndIf
  e$ = Required(*o, "email") : p$ = Required(*o, "password")
  If e$ = #BAD$ Or p$ = #BAD$ : Err(fd, 422, "email and password are required") : ProcedureReturn : EndIf
  prm(0) = e$
  rows = Q(#S_Login, 1)
  If rows < 0 : Reply(fd, rows) : ProcedureReturn : EndIf
  If rows = 0 Or Not VerifyPasswordHash(p$, VS(1)) : Err(fd, 401, "invalid email or password") : ProcedureReturn : EndIf
  RespondS(fd, 200, UserBody(VS(2), Token(VS(0))))
EndProcedure

Procedure UpdateUser(fd, v.q, token$, body$)
  Protected *o = Wrapper(body$, "user"), i, rows
  If *o = 0 : Err(fd, 422, "user is required") : ProcedureReturn : EndIf
  prm(0) = Str(v) : prm(1) = Field(*o, "email") : prm(2) = Field(*o, "username") : prm(3) = Field(*o, "password")
  prm(4) = Field(*o, "bio", #False) : prm(5) = Field(*o, "image", #False)
  For i = 1 To 5
    If prm(i) = #BAD$ : Err(fd, 422, "invalid field") : ProcedureReturn : EndIf
  Next
  If prm(3) <> #NUL$
    If StringByteLength(prm(3), #PB_UTF8) > 72 : Err(fd, 422, "password too long") : ProcedureReturn : EndIf
    prm(3) = CreatePasswordHash(prm(3), 10)
  EndIf
  rows = Q(#S_UpdateUser, 6)
  If rows <= 0 : Reply(fd, rows, 200, 0, 401) : ProcedureReturn : EndIf
  RespondS(fd, 200, UserBody(VS(1), token$))
EndProcedure

Procedure CreateArticle(fd, v.q, body$)
  Protected *o = Wrapper(body$, "article"), *t, *e, i, tags$ = "{"
  If *o = 0 : Err(fd, 422, "article is required") : ProcedureReturn : EndIf
  prm(0) = Str(v) : prm(1) = Required(*o, "title") : prm(2) = Required(*o, "description") : prm(3) = Required(*o, "body")
  If prm(1) = #BAD$ Or prm(2) = #BAD$ Or prm(3) = #BAD$
    Err(fd, 422, "title, description and body are required") : ProcedureReturn
  EndIf
  *t = GetJSONMember(*o, "tagList")
  If *t And JSONType(*t) <> #PB_JSON_Null
    If JSONType(*t) <> #PB_JSON_Array : Err(fd, 422, "tagList must be an array") : ProcedureReturn : EndIf
    For i = 0 To JSONArraySize(*t) - 1
      *e = GetJSONElement(*t, i)
      If JSONType(*e) <> #PB_JSON_String Or GetJSONString(*e) = ""
        Err(fd, 422, "tags must be non-empty strings") : ProcedureReturn
      EndIf
      If i : tags$ + "," : EndIf
      tags$ + #DQUOTE$ + ReplaceString(ReplaceString(GetJSONString(*e), "\", "\\"), #DQUOTE$, ~"\\\"") + #DQUOTE$
    Next
  EndIf
  prm(4) = tags$ + "}"
  Reply(fd, Q(#S_Create, 5), 201)
EndProcedure

Procedure UpdateArticle(fd, v.q, slug$, body$)
  Protected *o = Wrapper(body$, "article"), rows
  If *o = 0 : Err(fd, 422, "article is required") : ProcedureReturn : EndIf
  prm(0) = Str(v) : prm(1) = slug$ : prm(2) = Field(*o, "title") : prm(3) = Field(*o, "description") : prm(4) = Field(*o, "body")
  If prm(2) = #BAD$ Or prm(3) = #BAD$ Or prm(4) = #BAD$ : Err(fd, 422, "invalid field") : ProcedureReturn : EndIf
  rows = Q(#S_Update, 5)
  If rows > 0 And VS(0) <> Str(v) : Err(fd, 403, "not the author") : ProcedureReturn : EndIf
  Reply(fd, rows, 200, 1)
EndProcedure

; Runs a delete statement that returns the row's author: 204, 403 or 404
Procedure DeleteOwned(fd, v.q, stmt, n)
  Protected rows = Q(stmt, n)
  If rows > 0 And VS(0) <> Str(v) : Err(fd, 403, "not the author") : ProcedureReturn : EndIf
  If rows > 0 : Respond(fd, 204, 0, 0) : Else : Reply(fd, rows) : EndIf
EndProcedure

Procedure Route(fd, method$, target$, auth$, body$)
  Protected path$ = StringField(target$, 1, "?"), query$ = Mid(target$, Len(path$) + 2)
  Protected s2$ = StringField(path$, 3, "/"), s3$ = URLDecoder(StringField(path$, 4, "/"))
  Protected s4$ = StringField(path$, 5, "/"), s5$ = StringField(path$, 6, "/"), n = CountString(path$, "/"), v.q
  If StringField(path$, 2, "/") <> "api" : Err(fd, 404, "not found") : ProcedureReturn : EndIf
  If s2$ = "tags" And n = 2 And method$ = "GET" : Reply(fd, Q(#S_Tags, 0)) : ProcedureReturn : EndIf
  If s2$ = "users" And n = 2 And method$ = "POST" : Register(fd, body$) : ProcedureReturn : EndIf
  If s2$ = "users" And n = 3 And s3$ = "login" And method$ = "POST" : Login(fd, body$) : ProcedureReturn : EndIf
  v = Viewer(auth$)
  If v < 0 : Err(fd, 401, "invalid token") : ProcedureReturn : EndIf
  prm(0) = Str(v) : prm(1) = s3$
  Select s2$
    Case "user"
      If n <> 2 Or (method$ <> "GET" And method$ <> "PUT") : Err(fd, 404, "not found") : ProcedureReturn : EndIf
      If v = 0 : Err(fd, 401, "authentication required") : ProcedureReturn : EndIf
      If method$ = "PUT" : UpdateUser(fd, v, Mid(auth$, 7), body$) : ProcedureReturn : EndIf
      If Q(#S_User, 1) = 1 : RespondS(fd, 200, UserBody(VS(1), Mid(auth$, 7))) : Else : Err(fd, 401, "unknown user") : EndIf
    Case "profiles"
      If n = 3 And method$ = "GET" : Reply(fd, Q(#S_Profile, 2)) : ProcedureReturn : EndIf
      If n <> 4 Or s4$ <> "follow" Or (method$ <> "POST" And method$ <> "DELETE") : Err(fd, 404, "not found") : ProcedureReturn : EndIf
      If v = 0 : Err(fd, 401, "authentication required") : ProcedureReturn : EndIf
      If method$ = "POST" : Reply(fd, Q(#S_Follow, 2)) : Else : Reply(fd, Q(#S_Unfollow, 2)) : EndIf
    Case "articles"
      If n = 2 And method$ = "GET" : ListArticles(fd, v, query$, #False) : ProcedureReturn : EndIf
      If n = 3 And s3$ = "feed" And method$ = "GET"
        If v = 0 : Err(fd, 401, "authentication required") : Else : ListArticles(fd, v, query$, #True) : EndIf
        ProcedureReturn
      EndIf
      If n = 3 And method$ = "GET" : Reply(fd, Q(#S_Article, 2)) : ProcedureReturn : EndIf
      If n = 4 And s4$ = "comments" And method$ = "GET" : Reply(fd, Q(#S_Comments, 2)) : ProcedureReturn : EndIf
      If v = 0 : Err(fd, 401, "authentication required") : ProcedureReturn : EndIf
      If n = 2 And method$ = "POST" : CreateArticle(fd, v, body$)
      ElseIf n = 3 And method$ = "PUT" : UpdateArticle(fd, v, s3$, body$)
      ElseIf n = 3 And method$ = "DELETE" : DeleteOwned(fd, v, #S_Delete, 2)
      ElseIf n = 4 And s4$ = "favorite" And method$ = "POST" : Reply(fd, Q(#S_Fav, 2))
      ElseIf n = 4 And s4$ = "favorite" And method$ = "DELETE" : Reply(fd, Q(#S_Unfav, 2))
      ElseIf n = 4 And s4$ = "comments" And method$ = "POST"
        Protected *o = Wrapper(body$, "comment")
        If *o : prm(2) = Required(*o, "body") : EndIf
        If *o = 0 Or prm(2) = #BAD$ : Err(fd, 422, "comment body is required") : ProcedureReturn : EndIf
        prm(0) = Str(v) : prm(1) = s3$
        Reply(fd, Q(#S_AddComment, 3), 201)
      ElseIf n = 5 And s4$ = "comments" And method$ = "DELETE"
        If Not IsDigits(s5$) : Err(fd, 404, "not found") : ProcedureReturn : EndIf
        prm(1) = s5$ : prm(2) = s3$
        DeleteOwned(fd, v, #S_DelComment, 3)
      Else
        Err(fd, 404, "not found")
      EndIf
    Default
      Err(fd, 404, "not found")
  EndSelect
EndProcedure

; ---------- HTTP/1.1 server ----------

Procedure.s Header(head$, lhead$, name$)
  Protected p = FindString(lhead$, #CRLF$ + name$ + ":")
  If p = 0 : ProcedureReturn "" : EndIf
  ProcedureReturn Trim(StringField(Mid(head$, p + Len(name$) + 3), 1, #CR$))
EndProcedure

; Handles one complete request at the start of *rbuf. Returns the bytes it used, 0 if incomplete, -1 to close.
Procedure Handle(fd, have)
  Protected s$ = PeekS(*rbuf, have, #PB_Ascii), he = FindString(s$, #CRLF$ + #CRLF$), head$, lhead$, line$, clen
  If he = 0
    If have >= #RBUF : ProcedureReturn -1 : EndIf
    ProcedureReturn 0
  EndIf
  head$ = Left(s$, he + 1) : lhead$ = LCase(head$)
  clen = Val(Header(head$, lhead$, "content-length"))
  If he + 3 + clen > have
    If he + 3 + clen > #RBUF : ProcedureReturn -1 : EndIf
    ProcedureReturn 0
  EndIf
  line$ = StringField(head$, 1, #CR$)
  Route(fd, StringField(line$, 1, " "), StringField(line$, 2, " "), Header(head$, lhead$, "authorization"),
        PeekS(*rbuf + he + 3, clen, #PB_UTF8 | #PB_ByteLength))
  ProcedureReturn he + 3 + clen
EndProcedure

Procedure CloseConn(fd)
  epoll_ctl(epfd, 2, fd, 0) : close(fd) ; EPOLL_CTL_DEL
  If *pend(fd) : FreeMemory(*pend(fd)) : *pend(fd) = 0 : EndIf ; the fd number is reused by the next accept
EndProcedure

Procedure Serve(fd)
  Protected have, r, used
  If *pend(fd)
    have = plen(fd) : CopyMemory(*pend(fd), *rbuf, have) : FreeMemory(*pend(fd)) : *pend(fd) = 0
  EndIf
  r = recv(fd, *rbuf + have, #RBUF - have, 0)
  If r <= 0 : CloseConn(fd) : ProcedureReturn : EndIf
  have + r
  Repeat
    used = Handle(fd, have)
    If used <= 0 : Break : EndIf
    have - used
    If have : MoveMemory(*rbuf + used, *rbuf, have) : EndIf
  Until have = 0
  If used < 0 : CloseConn(fd) : ProcedureReturn : EndIf
  If have : *pend(fd) = AllocateMemory(have) : CopyMemory(*rbuf, *pend(fd), have) : plen(fd) = have : EndIf
EndProcedure

Procedure Worker(id)
  Protected lfd, c, i, n, one.l = 1, addr.SockAddrIn, ev.EpollEvent
  Protected Dim evs.EpollEvent(255)
  Dim prm(7) ; a Threaded array is allocated per thread
  *rbuf = AllocateMemory(#RBUF) : *sbuf = AllocateMemory(65536) : *pv = AllocateMemory(64) : *mac = AllocateMemory(64)
  Connect()
  ; non-blocking listener: a client can give up between epoll's wakeup and accept, which must not block the worker
  lfd = socket(2, 1 | $800, 0) ; AF_INET, SOCK_STREAM | SOCK_NONBLOCK
  setsockopt(lfd, 1, 2, @one, 4) : setsockopt(lfd, 1, 15, @one, 4) ; SO_REUSEADDR, SO_REUSEPORT
  addr\family = 2 : addr\port = ((port & $FF) << 8) | (port >> 8) : addr\addr = inet_addr(host$)
  If bind(lfd, @addr, SizeOf(SockAddrIn)) <> 0 Or listen(lfd, 4096) <> 0
    PrintN("cannot listen on " + host$ + ":" + Str(port)) : End 1
  EndIf
  epfd = epoll_create1(0)
  ev\events = 1 : ev\fd = lfd : epoll_ctl(epfd, 1, lfd, @ev) ; EPOLLIN, EPOLL_CTL_ADD
  Repeat
    n = epoll_wait(epfd, @evs(0), 256, -1)
    For i = 0 To n - 1
      If evs(i)\fd = lfd
        Repeat ; accepted sockets are blocking (O_NONBLOCK isn't inherited)
          c = accept4(lfd, 0, 0, 0)
          If c >= 0 And c < #MAXFD
            setsockopt(c, 6, 1, @one, 4) ; TCP_NODELAY
            ev\events = 1 : ev\fd = c : epoll_ctl(epfd, 1, c, @ev)
          ElseIf c >= 0
            close(c)
          EndIf
        Until c < 0
      Else
        Serve(evs(i)\fd)
      EndIf
    Next
  ForEver
EndProcedure

OpenConsole()
If threads <= 0 : threads = 32 : EndIf
If host$ = "" : host$ = "0.0.0.0" : EndIf
BuildSQL()
Define i, t
For i = 1 To threads
  t = CreateThread(@Worker(), i)
Next
WaitThread(t)

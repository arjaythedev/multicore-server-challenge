package conduit

import io.netty.buffer.ByteBuf
import io.netty.channel.EventLoop

import scala.util.control.NonFatal

/** An error response's message: the spec leaves the text free; these say what went wrong. */
object Messages:
  val NotFound = "not found"
  val Unauthorized = "unauthorized"
  val Forbidden = "not the author"
  val InvalidBody = "invalid body"
  val InvalidPaging = "limit must be 1-100 and offset >= 0"
  val Taken = "username or email is already taken"
  val PasswordTooLong = "password is too long"
  val InvalidLogin = "invalid email or password"
  val Unavailable = "the database is unavailable"
  val Internal = "internal server error"

/** The API on one event loop: routes each request a [[Connection]] decodes to the [[Call]] that answers it, with the
  * loop's Postgres connections, response buffers and the shared password threads. Used on its loop's thread only.
  */
final class Api(val jwt: Jwt, val pool: PgPool, val passwords: Passwords, val loop: EventLoop):
  import Api.*

  /** Response buffers for the requests in flight. */
  val outs: Out.Pool = Out.Pool()

  def handle(c: Connection, req: Request): Unit =
    val call =
      try route(req)
      catch
        case NonFatal(e) =>
          Log.error("request failed", e, "method" -> req.method, "path" -> req.path)
          Failed(Status.InternalServerError, Messages.Internal)
    call.api = this
    call.connection = c
    call.ending = if !req.keepAlive then Out.Ending.Close else if req.http10 then Out.Ending.KeepAlive10 else Out.Ending.KeepAlive
    c.enqueue(call)
    try call.start()
    catch
      case NonFatal(e) =>
        Log.error("request failed", e, "method" -> req.method, "path" -> req.path)
        call.fail(Status.InternalServerError, Messages.Internal)

  private def now: Long = System.currentTimeMillis() / 1000

  /** The viewer: the token's user, 0 without an `Authorization` header, or [[Jwt.Invalid]] for one that isn't a
    * valid token (or not RealWorld's `Token` scheme).
    */
  private def viewer(req: Request): Long =
    val h = req.authorization
    if h == null || h.isEmpty then 0
    else if !h.startsWith(TokenScheme) then Jwt.Invalid
    else jwt.verify(h, TokenScheme.length, now)

  /** The request's [[Call]], picked by method and path. */
  private def route(req: Request): Call =
    val path = req.path
    if !path.startsWith("/api/") then return NotFound
    val parts = path.substring(5).split("/", -1)
    val m = req.method
    parts.length match
      case 1 =>
        parts(0) match
          case "tags" if m == "GET" => TagsCall()
          case "users" if m == "POST" => withBody(req, "user")(RegisterCall(_))
          case "user" if m == "GET" => required(req)(v => CurrentUserCall(v, req.authorization.substring(TokenScheme.length)))
          case "user" if m == "PUT" =>
            required(req)(v => withBody(req, "user")(UpdateUserCall(v, req.authorization.substring(TokenScheme.length), _)))
          case "articles" if m == "GET" => optional(req)(v => list(req, v))
          case "articles" if m == "POST" => required(req)(v => withBody(req, "article")(CreateArticleCall(v, _)))
          case _ => NotFound
      case 2 =>
        val name = segment(parts, 1)
        (parts(0), m) match
          case ("users", "POST") if parts(1) == "login" => withBody(req, "user")(LoginCall(_))
          case ("profiles", "GET") if name != null => optional(req)(ProfileCall(Sql.Profile, _, name))
          case ("articles", "GET") if parts(1) == "feed" =>
            required(req)(v => paging(req)((limit, offset) => ListCall(Sql.Feed, v, limit, offset, null)))
          case ("articles", "GET") if name != null => optional(req)(v => ArticleCall(Seq(Sql.ArticleBySlug), v, name))
          case ("articles", "PUT") if name != null => required(req)(v => withBody(req, "article")(UpdateArticleCall(v, name, _)))
          case ("articles", "DELETE") if name != null => required(req)(DeleteCall(Sql.DeleteArticle, _, name, 0))
          case _ => NotFound
      case 3 =>
        val name = segment(parts, 1)
        if name == null then return NotFound
        (parts(0), parts(2), m) match
          case ("profiles", "follow", "POST") => required(req)(ProfileCall(Sql.Follow, _, name, following = 1))
          case ("profiles", "follow", "DELETE") => required(req)(ProfileCall(Sql.Unfollow, _, name, following = 0))
          case ("articles", "favorite", "POST") => required(req)(v => ArticleCall(Seq(Sql.Favorite, Sql.ArticleBySlug), v, name))
          case ("articles", "favorite", "DELETE") => required(req)(v => ArticleCall(Seq(Sql.Unfavorite, Sql.ArticleBySlug), v, name))
          case ("articles", "comments", "GET") => optional(req)(CommentsCall(_, name))
          case ("articles", "comments", "POST") => required(req)(v => withBody(req, "comment")(CreateCommentCall(v, name, _)))
          case _ => NotFound
      case 4 =>
        val name = segment(parts, 1)
        if name == null || parts(0) != "articles" || parts(2) != "comments" || m != "DELETE" then return NotFound
        required(req): v =>
          val digits = segment(parts, 3)
          val id = if digits == null then -1 else Input.unsigned(digits)
          if id <= 0 then NotFound else DeleteCall(Sql.DeleteComment, v, name, id)
      case _ => NotFound

  /** The decoded `i`-th path segment, null if it is empty or not valid percent-encoded UTF-8 (no such resource). */
  private def segment(parts: Array[String], i: Int): String =
    if parts(i).isEmpty then null else Input.segment(parts(i), 0, parts(i).length)

  private def required(req: Request)(call: Long => Call): Call =
    val v = viewer(req)
    if v <= 0 then Failed(Status.Unauthorized, Messages.Unauthorized) else call(v)

  private def optional(req: Request)(call: Long => Call): Call =
    val v = viewer(req)
    if v < 0 then Failed(Status.Unauthorized, Messages.Unauthorized) else call(v)

  /** The fields of the body's object under `key` (`{"user": {...}}`), or a 422 if there isn't one. */
  private def withBody(req: Request, key: String)(call: Map[String, Json] => Call): Call =
    Json.parseUtf8(req.body) match
      case Some(Json.Obj(top)) =>
        top.get(key) match
          case Some(Json.Obj(fields)) =>
            try call(fields)
            catch case Invalid => Failed(Status.Unprocessable, Messages.InvalidBody)
          case _ => Failed(Status.Unprocessable, Messages.InvalidBody)
      case _ => Failed(Status.Unprocessable, Messages.InvalidBody)

  /** `limit` (default 20, 1 to 100) and `offset` (default 0), or a 422. */
  private def paging(req: Request)(call: (Long, Long) => Call): Call =
    paging(Input.Query(req.query))(call)

  private def paging(q: Input.Query)(call: (Long, Long) => Call): Call =
    val limit = if q.limit == null then 20 else Input.unsigned(q.limit)
    val offset = if q.offset == null then 0 else Input.unsigned(q.offset)
    if limit < 1 || limit > 100 || offset < 0 then Failed(Status.Unprocessable, Messages.InvalidPaging)
    else call(limit, offset)

  /** `GET /api/articles`: the first non-empty filter of tag, author and favorited applies. */
  private def list(req: Request, viewer: Long): Call =
    val q = Input.Query(req.query)
    paging(q): (limit, offset) =>
      if q.tag != null && q.tag.nonEmpty then ListCall(Sql.ListByTag, viewer, limit, offset, q.tag)
      else if q.author != null && q.author.nonEmpty then ListCall(Sql.ListByAuthor, viewer, limit, offset, q.author)
      else if q.favorited != null && q.favorited.nonEmpty then ListCall(Sql.ListByFavorited, viewer, limit, offset, q.favorited)
      else ListCall(Sql.ListAll, viewer, limit, offset, null)

object Api:
  private val TokenScheme = "Token "

  /** A packed batch named an article it didn't send: a 500, never a page without it. */
  private val Missing = PgError("XX000", "a packed batch named an article it didn't send")

  /** A body field that isn't what the request needs: a 422. */
  private object Invalid extends Exception(null, null, false, false)

  /** A required non-empty string. */
  private def string(fields: Map[String, Json], key: String): String =
    val s = optionalString(fields, key, nonEmpty = true)
    if s == null then throw Invalid
    s

  /** A string, or null when absent or null; anything else, or an empty one if `nonEmpty`, is invalid. */
  private def optionalString(fields: Map[String, Json], key: String, nonEmpty: Boolean): String = fields.get(key) match
    case None | Some(Json.Null) => null
    case Some(Json.Str(s)) => if nonEmpty && s.isEmpty then throw Invalid else s
    case _ => throw Invalid

  /** An optional array of non-empty strings. */
  private def tagList(fields: Map[String, Json]): Vector[String] = fields.get("tagList") match
    case None | Some(Json.Null) => Vector.empty
    case Some(Json.Arr(items)) =>
      items.map:
        case Json.Str(s) if s.nonEmpty => s
        case _ => throw Invalid
    case _ => throw Invalid

  /** A password as bcrypt's input, or invalid if bcrypt can't take it whole (over 72 bytes). */
  private def password(s: String): Array[Byte] =
    val bytes = Bcrypt.utf8(s)
    if bytes.length > Bcrypt.MaxPasswordBytes then throw TooLong
    bytes

  private object TooLong extends Exception(null, null, false, false)

  /** A request answered without Postgres: an error. */
  private final class Failed(status: Status, message: String) extends Call:
    def start(): Unit = fail(status, message)
    def send(w: PgWriter): Unit = ()
    def row(statement: Int, row: PgRow): Unit = ()
    def done(error: PgError): Unit = ()

  /** A 404: a new one per request, as every [[Call]] is. */
  private def NotFound: Call = Failed(Status.NotFound, Messages.NotFound)

  // -- Articles --------------------------------------------------------------------------------------------------

  /** One article: `statements` run in one transaction, the last returning the article (none: a 404). */
  private final class ArticleCall(statements: Seq[Statement], viewer: Long, slug: String, status: Status = Status.Ok) extends Call:
    private var found = false

    override val batch: Sql.Batch = if statements.length == 1 then Sql.batchOf(statements.head) else null
    override def write: Boolean = statements.length > 1 // a favorite or an unfavorite, then the article
    override def int8Param(p: Int): Long = viewer
    override def textParam(p: Int): String = slug
    override protected def restart(): Unit = found = false

    def start(): Unit = api.pool.submit(this)

    def send(w: PgWriter): Unit =
      for s <- statements do w.bind(s).int8(viewer).text(slug).execute()

    override def row(statement: Int, row: PgRow): Unit =
      if statement == statements.length - 1 then
        found = true
        Render.articleOpen(out)
        Render.article(out, row, Columns.FullArticle, withBody = true)
        Render.close(out)

    override def done(error: PgError): Unit =
      if error != null then failed(error)
      else if found then finish(status)
      else fail(Status.NotFound, Messages.NotFound)

  private final class CreateArticleCall(viewer: Long, fields: Map[String, Json]) extends Call:
    private val title = string(fields, "title")
    private val description = string(fields, "description")
    private val body = string(fields, "body")
    private val tags = tagList(fields)
    private var found = false

    override def write: Boolean = true
    override protected def restart(): Unit = found = false

    def start(): Unit = api.pool.submit(this)

    def send(w: PgWriter): Unit =
      w.bind(Sql.InsertArticle).int8(viewer).text(title).text(description).text(body).text(Input.slugify(title)).execute()
      if tags.nonEmpty then
        w.bind(Sql.InsertTags).textArray(tags).execute()
        w.bind(Sql.TagArticle).textArray(tags).execute()
      w.bind(Sql.NewArticle).int8(viewer).execute()

    override def row(statement: Int, row: PgRow): Unit =
      found = true
      Render.articleOpen(out)
      Render.article(out, row, Columns.FullArticle, withBody = true)
      Render.close(out)

    override def done(error: PgError): Unit =
      if error != null then failed(error)
      else if found then finish(Status.Created)
      else fail(Status.InternalServerError, Messages.Internal)

  private final class UpdateArticleCall(viewer: Long, slug: String, fields: Map[String, Json]) extends Call:
    private val title = optionalString(fields, "title", nonEmpty = true)
    private val description = optionalString(fields, "description", nonEmpty = true)
    private val body = optionalString(fields, "body", nonEmpty = true)
    private var author = 0L

    override def write: Boolean = true
    override protected def restart(): Unit = author = 0

    def start(): Unit = api.pool.submit(this)

    def send(w: PgWriter): Unit =
      w.bind(Sql.UpdateArticle).int8(viewer).text(slug).textOrNull(title).textOrNull(description).textOrNull(body)
        .textOrNull(if title == null then null else Input.slugify(title)).execute()

    override def row(statement: Int, row: PgRow): Unit =
      author = row.int8(0)
      if author == viewer then
        Render.articleOpen(out)
        Render.article(out, row, Columns.UpdatedArticle, withBody = true)
        Render.close(out)

    override def done(error: PgError): Unit =
      if error != null then failed(error)
      else if author == 0 then fail(Status.NotFound, Messages.NotFound)
      else if author != viewer then fail(Status.Forbidden, Messages.Forbidden)
      else finish(Status.Ok)

  /** Deletes what `statement` deletes if `viewer` is its author: the statement returns the author (none: a 404). */
  private final class DeleteCall(statement: Statement, viewer: Long, slug: String, id: Long) extends Call:
    private var author = 0L

    override def write: Boolean = true
    override protected def restart(): Unit = author = 0

    def start(): Unit = api.pool.submit(this)

    def send(w: PgWriter): Unit =
      w.bind(statement).int8(viewer).text(slug)
      if id > 0 then w.int8(id)
      w.execute()

    override def row(statement: Int, row: PgRow): Unit = author = row.int8(0)

    override def done(error: PgError): Unit =
      if error != null then failed(error)
      else if author == 0 then fail(Status.NotFound, Messages.NotFound)
      else if author != viewer then fail(Status.Forbidden, Messages.Forbidden)
      else finish(Status.NoContent)

  /** A page of articles and the capped count, which every row carries; a row without an article for an empty page.
    * In a packed batch, one row: the count, the page's ids, and the viewer's flags for its articles.
    */
  private final class ListCall(statement: Statement, viewer: Long, limit: Long, offset: Long, filter: String) extends Call:
    private var count = 0L
    private var articles = 0
    /** A packed batch named an article it didn't send. */
    private var missing = false

    override def batch: Sql.Batch = Sql.batchOf(statement)
    override def int8Param(p: Int): Long = if p == 0 then viewer else if p == 1 then limit else offset
    override def textParam(p: Int): String = filter

    def start(): Unit = api.pool.submit(this)

    def send(w: PgWriter): Unit =
      w.bind(statement).int8(viewer).int8(limit).int8(offset)
      if filter != null then w.text(filter)
      w.execute()

    override def row(statement: Int, row: PgRow): Unit =
      count = row.int8(0)
      if !row.isNull(Columns.ListArticle) then
        if articles == 0 then Render.articlesOpen(out) else out.byte(',')
        Render.article(out, row, Columns.ListArticle, withBody = false)
        articles += 1

    override def packed(): PgPacked = PackedArticles(api.outs)

    override def row(statement: Int, row: PgRow, packed: PgPacked): Unit =
      import Columns.Packed
      count = row.int8(Packed.Count)
      val shared = packed.asInstanceOf[PackedArticles]
      val n = row.int8ArrayLength(Packed.Ids)
      var k = 0
      while k < n do
        val id = row.int8ArrayAt(Packed.Ids, k)
        val a = if shared == null then -1 else shared.find(id)
        if a < 0 then missing = true
        else
          if articles == 0 then Render.articlesOpen(out) else out.byte(',')
          val following = row.isNull(Packed.Following) || row.int8ArrayHas(Packed.Following, shared.author(a))
          shared.write(out, a, row.int8ArrayHas(Packed.Favorited, id), following)
          articles += 1
        k += 1

    override def done(error: PgError): Unit =
      if error != null then failed(error)
      else if missing then failed(Api.Missing)
      else
        if articles == 0 then Render.articlesOpen(out)
        Render.articlesClose(out, count)
        finish(Status.Ok)

  // -- Comments --------------------------------------------------------------------------------------------------

  private final class CommentsCall(viewer: Long, slug: String) extends Call:
    private var found = false
    private var comments = 0

    override def batch: Sql.Batch = Sql.batchOf(Sql.Comments)
    override def int8Param(p: Int): Long = viewer
    override def textParam(p: Int): String = slug

    def start(): Unit = api.pool.submit(this)

    def send(w: PgWriter): Unit = w.bind(Sql.Comments).int8(viewer).text(slug).execute()

    override def row(statement: Int, row: PgRow): Unit =
      found = true
      if !row.isNull(0) then
        if comments == 0 then Render.commentsOpen(out) else out.byte(',')
        Render.comment(out, row, row.bool(7))
        comments += 1

    override def done(error: PgError): Unit =
      if error != null then failed(error)
      else if !found then fail(Status.NotFound, Messages.NotFound)
      else
        if comments == 0 then Render.commentsOpen(out)
        Render.arrayClose(out)
        finish(Status.Ok)

  private final class CreateCommentCall(viewer: Long, slug: String, fields: Map[String, Json]) extends Call:
    private val body = string(fields, "body")
    private var found = false

    override def write: Boolean = true
    override protected def restart(): Unit = found = false

    def start(): Unit = api.pool.submit(this)

    def send(w: PgWriter): Unit = w.bind(Sql.CreateComment).int8(viewer).text(slug).text(body).execute()

    override def row(statement: Int, row: PgRow): Unit =
      found = true
      Render.commentOpen(out)
      Render.comment(out, row, following = false)
      Render.close(out)

    override def done(error: PgError): Unit =
      if error != null then failed(error)
      else if found then finish(Status.Created)
      else fail(Status.NotFound, Messages.NotFound)

  // -- Profiles and tags -----------------------------------------------------------------------------------------

  /** A profile; `following` is 1 or 0 after a follow or unfollow, or -1 to read it from the row. */
  private final class ProfileCall(statement: Statement, viewer: Long, username: String, following: Int = -1) extends Call:
    private var found = false

    override def batch: Sql.Batch = Sql.batchOf(statement) // only the profile's read has one, not a follow's write
    override def write: Boolean = following >= 0
    override def int8Param(p: Int): Long = viewer
    override def textParam(p: Int): String = username
    override protected def restart(): Unit = found = false

    def start(): Unit = api.pool.submit(this)

    def send(w: PgWriter): Unit = w.bind(statement).int8(viewer).text(username).execute()

    override def row(statement: Int, row: PgRow): Unit =
      found = true
      Render.profileResponse(out, row, if following < 0 then row.bool(3) else following == 1)

    override def done(error: PgError): Unit =
      if error != null then failed(error)
      else if found then finish(Status.Ok)
      else fail(Status.NotFound, Messages.NotFound)

  private final class TagsCall extends Call:
    private var tags = 0

    override def batch: Sql.Batch = Sql.batchOf(Sql.Tags)

    def start(): Unit = api.pool.submit(this)

    def send(w: PgWriter): Unit = w.bind(Sql.Tags).execute()

    override def row(statement: Int, row: PgRow): Unit =
      if tags == 0 then Render.tagsOpen(out) else out.byte(',')
      row.text(0, out)
      tags += 1

    override def done(error: PgError): Unit =
      if error != null then failed(error)
      else
        if tags == 0 then Render.tagsOpen(out)
        Render.arrayClose(out)
        finish(Status.Ok)

  // -- Users -----------------------------------------------------------------------------------------------------

  /** A user's row, answered with a token: `token`, or a new one for the row's id if null. */
  private abstract class UserCall(status: Status) extends Call:
    protected var token: String = null
    private var found = false

    override protected def restart(): Unit = found = false

    override def row(statement: Int, row: PgRow): Unit =
      found = true
      val t = if token != null then token else api.jwt.issue(row.int8(0), System.currentTimeMillis() / 1000)
      Render.user(out, row, t)

    override def done(error: PgError): Unit =
      if error != null then
        if error.isUniqueViolation then fail(Status.Unprocessable, Messages.Taken) else failed(error)
      else if found then answered()
      else fail(Status.Unauthorized, Messages.Unauthorized)

    /** The user's row has been rendered: by default, the response is ready. */
    protected def answered(): Unit = finish(status)

  private final class CurrentUserCall(viewer: Long, presented: String) extends UserCall(Status.Ok):
    token = presented

    override def batch: Sql.Batch = Sql.batchOf(Sql.CurrentUser)
    override def int8Param(p: Int): Long = viewer

    def start(): Unit = api.pool.submit(this)

    def send(w: PgWriter): Unit = w.bind(Sql.CurrentUser).int8(viewer).execute()

  private final class RegisterCall(fields: Map[String, Json]) extends UserCall(Status.Created):
    private val username = string(fields, "username")
    private val email = string(fields, "email")
    private val secret = string(fields, "password")
    private var hash: String = null

    override def write: Boolean = true

    def start(): Unit =
      val bytes =
        try password(secret)
        catch case TooLong => return fail(Status.Unprocessable, Messages.PasswordTooLong)
      api.passwords.hash(bytes, api.loop, h =>
        if h == null then fail(Status.InternalServerError, Messages.Internal)
        else
          hash = h
          api.pool.submit(this)
      )

    def send(w: PgWriter): Unit = w.bind(Sql.Register).text(username).text(email).text(hash).execute()

  private final class UpdateUserCall(viewer: Long, presented: String, fields: Map[String, Json]) extends UserCall(Status.Ok):
    token = presented
    private val email = optionalString(fields, "email", nonEmpty = true)
    private val username = optionalString(fields, "username", nonEmpty = true)
    private val secret = optionalString(fields, "password", nonEmpty = true)
    private val bio = optionalString(fields, "bio", nonEmpty = false)
    private val image = optionalString(fields, "image", nonEmpty = false)
    private var hash: String = null

    override def write: Boolean = true

    def start(): Unit =
      if secret == null then api.pool.submit(this)
      else
        val bytes =
          try password(secret)
          catch case TooLong => return fail(Status.Unprocessable, Messages.PasswordTooLong)
        api.passwords.hash(bytes, api.loop, h =>
          if h == null then fail(Status.InternalServerError, Messages.Internal)
          else
            hash = h
            api.pool.submit(this)
        )

    def send(w: PgWriter): Unit =
      w.bind(Sql.UpdateUser).int8(viewer).textOrNull(email).textOrNull(username).textOrNull(hash).textOrNull(bio)
        .textOrNull(image).execute()

  /** A login: the user's row by email, then its hash checked on the password threads. */
  private final class LoginCall(fields: Map[String, Json]) extends UserCall(Status.Ok):
    private val email = string(fields, "email")
    private val secret = string(fields, "password")
    private var stored: String = null

    def start(): Unit =
      if Bcrypt.utf8(secret).length > Bcrypt.MaxPasswordBytes then fail(Status.Unauthorized, Messages.InvalidLogin)
      else api.pool.submit(this)

    def send(w: PgWriter): Unit = w.bind(Sql.Login).text(email).execute()

    override def row(statement: Int, row: PgRow): Unit =
      stored = row.string(5)
      super.row(statement, row)

    override def done(error: PgError): Unit =
      if error == null && stored == null then fail(Status.Unauthorized, Messages.InvalidLogin)
      else super.done(error)

    override protected def answered(): Unit =
      api.passwords.check(Bcrypt.utf8(secret), stored, api.loop, ok =>
        if ok then finish(Status.Ok) else fail(Status.Unauthorized, Messages.InvalidLogin)
      )

/** A request being answered, from its decoding until its response is written. Most ask Postgres (they are its
  * [[PgQuery]]); each writes its response body into its [[Out]] as the rows arrive and [[finish]]es with a status,
  * or [[fail]]s with an error. Its [[Connection]] sends responses in the order the requests came.
  */
abstract class Call extends PgQuery:
  private[conduit] var api: Api = null
  private[conduit] var connection: Connection = null
  /** The response body, from the loop's pool when first written to: a request waiting for Postgres holds none. */
  private var buffer: Out = null
  private[conduit] var ending: Out.Ending = null
  /** The connection's next request, pipelined after this one. */
  private[conduit] var nextCall: Call = null
  /** The whole response, once there is one. */
  private[conduit] var response: ByteBuf = null

  /** Starts answering: asks Postgres, or answers at once. */
  def start(): Unit

  protected final def out: Out =
    if buffer == null then buffer = api.outs.take()
    buffer

  /** The client went away (its connection closed) before the request was sent to Postgres: don't send it. */
  override def abandoned: Boolean = !connection.open

  /** The group of writes it went out in was rolled back: drops the response written so far, and what the replies
    * set ([[restart]]).
    */
  override final def reset(): Unit =
    if buffer != null then
      api.outs.give(buffer)
      buffer = null
    restart()

  /** Forgets what the replies so far set, for [[reset]]. */
  protected def restart(): Unit = ()

  /** The response is the body written so far, with `status`. */
  final def finish(status: Status): Unit =
    val o = out
    response = o.response(connection.alloc, status, ending)
    api.outs.give(o)
    buffer = null
    connection.answered(this)

  /** The response is an error. */
  final def fail(status: Status, message: String): Unit =
    Render.error(out, message)
    finish(status)

  /** Postgres failed the request: 503 if the connection is the trouble, else a 500 (logged). */
  protected final def failed(error: PgError): Unit =
    if error eq PgError.Abandoned then fail(Status.ServiceUnavailable, Messages.Unavailable) // nobody reads it
    else if error.code.startsWith("08") then fail(Status.ServiceUnavailable, Messages.Unavailable)
    else
      Log.warn("query failed", "request" -> getClass.getSimpleName, "error" -> error.toString)
      fail(Status.InternalServerError, Messages.Internal)

/** A packed batch's articles ([[Columns.Packed]]), each written once as the JSON its requests' pages share
  * ([[Render.sharedArticle]]), and found by id; a page copies them with its viewer's flags.
  */
private[conduit] final class PackedArticles(outs: Out.Pool) extends PgPacked:
  private val text = outs.take()
  private var ids = new Array[Long](16)
  private var authors = new Array[Long](16)
  /** Where each article's text is split around `favorited`, and where it ends; it starts where the one before ends. */
  private var splits = new Array[Int](16)
  private var ends = new Array[Int](16)
  private var n = 0
  /** Open addressing by id: each slot an article's index plus 1, or 0. */
  private var slots = new Array[Int](32)

  def row(row: PgRow): Unit =
    import Columns.Packed
    if n == ids.length then
      ids = java.util.Arrays.copyOf(ids, n * 2)
      authors = java.util.Arrays.copyOf(authors, n * 2)
      splits = java.util.Arrays.copyOf(splits, n * 2)
      ends = java.util.Arrays.copyOf(ends, n * 2)
    ids(n) = row.int8(Packed.Id)
    authors(n) = row.int8(Packed.Author)
    splits(n) = Render.sharedArticle(text, row, Packed.Article)
    ends(n) = text.length
    n += 1
    if 2 * n > slots.length then
      slots = new Array[Int](slots.length * 2)
      var a = 0
      while a < n do
        place(a)
        a += 1
    else place(n - 1)

  private def slot(id: Long): Int = ((id * 0x9e3779b97f4a7c15L) >>> 40).toInt & (slots.length - 1)

  private def place(a: Int): Unit =
    var i = slot(ids(a))
    while slots(i) != 0 do i = (i + 1) & (slots.length - 1)
    slots(i) = a + 1

  /** The article with `id`'s index, or -1. */
  def find(id: Long): Int =
    var i = slot(id)
    while slots(i) != 0 && ids(slots(i) - 1) != id do i = (i + 1) & (slots.length - 1)
    slots(i) - 1

  def author(a: Int): Long = authors(a)

  /** Article `a` as [[Render.article]] writes it, with these flags. */
  def write(out: Out, a: Int, favorited: Boolean, following: Boolean): Unit =
    val start = if a == 0 then 0 else ends(a - 1)
    out.bytes(text, start, splits(a) - start).bool(favorited)
    out.bytes(text, splits(a), ends(a) - splits(a)).bool(following).byte('}').byte('}')

  def release(): Unit = outs.give(text)

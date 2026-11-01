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
  * loop's Postgres connections and the shared password threads. Used on its loop's thread only.
  */
final class Api(val jwt: Jwt, val pool: PgPool, val passwords: Passwords, val loop: EventLoop):
  import Api.*

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
          case ("articles", "GET") if name != null => optional(req)(v => ArticleCall(null, v, name))
          case ("articles", "PUT") if name != null => required(req)(v => withBody(req, "article")(UpdateArticleCall(v, name, _)))
          case ("articles", "DELETE") if name != null => required(req)(DeleteCall(Sql.DeleteArticle, _, name, 0))
          case _ => NotFound
      case 3 =>
        val name = segment(parts, 1)
        if name == null then return NotFound
        (parts(0), parts(2), m) match
          case ("profiles", "follow", "POST") => required(req)(ProfileCall(Sql.Follow, _, name, following = 1))
          case ("profiles", "follow", "DELETE") => required(req)(ProfileCall(Sql.Unfollow, _, name, following = 0))
          case ("articles", "favorite", "POST") => required(req)(v => ArticleCall(Sql.Favorite, v, name))
          case ("articles", "favorite", "DELETE") => required(req)(v => ArticleCall(Sql.Unfavorite, v, name))
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

  /** One article, by slug ([[Sql.ArticleBySlug]]; none: a 404), which a round may plan ([[RoundPlan]]). With `change`
    * (a favorite or an unfavorite), that write first, committed with its group; then the article, read as any article
    * page is, in a read round after the commit, where it shares what the round reads (in the write's transaction it
    * was a statement of its own, 30,613 a run). No article: the write changed nothing, and the read finds none.
    */
  private final class ArticleCall(change: Statement, viewer: Long, slug: String) extends Call, PlannedRead:
    private var found = false
    /** Planned: its article among the round's, or -1 if there is none with its slug. */
    private var planned = -1
    /** The write still to commit. */
    private var writing = change != null

    override def batch: Sql.Batch = if writing then null else Sql.batchOf(Sql.ArticleBySlug)
    override def write: Boolean = writing
    override def merge: Sql.Merge = if writing then Sql.mergeOf(change) else null
    override def int8Param(p: Int): Long = viewer
    override def textParam(p: Int): String = slug
    override protected def restart(): Unit =
      found = false
      planned = -1

    def start(): Unit = api.pool.submit(this)

    def send(w: PgWriter): Unit = w.bind(if writing then change else Sql.ArticleBySlug).int8(viewer).text(slug).execute()

    override def row(statement: Int, row: PgRow): Unit =
      if !writing then
        found = true
        Render.articleOpen(out)
        Render.article(out, row, Columns.FullArticle, withBody = true)
        Render.close(out)

    override def done(error: PgError): Unit =
      if error != null then failed(error)
      else if writing then
        writing = false
        api.pool.submit(this) // committed: now the article
      else if found then finish(Status.Ok)
      else fail(Status.NotFound, Messages.NotFound)

    def plannedRow(row: PgRow, articles: RoundArticles): Unit = planned = articles.article(row, withBody = true)

    def ask(articles: RoundArticles): Unit = if viewer != 0 && planned >= 0 then articles.ask(viewer, planned, following = true)

    def answer(articles: RoundArticles): Unit =
      if planned < 0 then fail(Status.NotFound, Messages.NotFound)
      else if !articles.ready(planned) then failed(Api.Missing)
      else
        Render.articleOpen(out)
        articles.writeWithBody(out, planned, articles.favorited(viewer, planned), articles.following(viewer, planned))
        Render.close(out)
        finish(Status.Ok)

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
    * In a packed batch, one row: the count, the page's ids, and the viewer's flags for its articles. Planned in a
    * round ([[RoundPlan]]), one row in the first phase: the count and the page's ids.
    */
  private final class ListCall(statement: Statement, viewer: Long, limit: Long, offset: Long, filter: String)
      extends Call, PlannedRead:
    private var count = 0L
    private var articles = 0
    /** A packed batch named an article it didn't send. */
    private var missing = false
    /** Planned: the page's ids, newest first (null until its row). */
    private var page: Array[Long] = null

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

    override def packed(): PgPacked = PackedArticles(Out.Pool.current)

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

    def plannedRow(row: PgRow, articles: RoundArticles): Unit =
      import Columns.Plan as P
      count = row.int8(P.Count)
      page = Array.tabulate(row.int8ArrayLength(P.Ids))(row.int8ArrayAt(P.Ids, _))

    /** The feed's viewer follows every author in it, in the first phase's snapshot: only `favorited` to ask. */
    def ask(articles: RoundArticles): Unit =
      if viewer != 0 && page != null then
        for id <- page do
          val a = articles.find(id)
          if a >= 0 then articles.ask(viewer, a, following = statement ne Sql.Feed)

    def answer(articles: RoundArticles): Unit =
      if page == null then return failed(Api.Missing)
      Render.articlesOpen(out)
      var k = 0
      while k < page.length do
        val a = articles.find(page(k))
        if a < 0 || !articles.ready(a) then return failed(Api.Missing)
        if k > 0 then out.byte(',')
        articles.write(out, a, articles.favorited(viewer, a), (statement eq Sql.Feed) || articles.following(viewer, a))
        k += 1
      Render.articlesClose(out, count)
      finish(Status.Ok)

  // -- A round's plan ---------------------------------------------------------------------------------------------

  /** A read a round may plan ([[RoundPlan]]). */
  private trait PlannedRead:
    /** Its row in the round's first phase. */
    def plannedRow(row: PgRow, articles: RoundArticles): Unit
    /** Asks for the flags it needs of its articles, before the second phase. */
    def ask(articles: RoundArticles): Unit
    /** Answers from the round's articles (null: the first phase read none). */
    def answer(articles: RoundArticles): Unit

  /** The kinds a round plans, and each batch's place among them by its id (-1: not planned). */
  private val Planned = Array(Sql.ListAll, Sql.ListByTag, Sql.ListByAuthor, Sql.ListByFavorited, Sql.Feed, Sql.ArticleBySlug)
    .map(Sql.batchOf)
  private val PlannedIndex =
    val a = Array.fill(Sql.batchKinds.length + 1)(-1)
    for (b, k) <- Planned.zipWithIndex do a(b.id) = k
    a

  /** A round's lists, feeds and article pages, of two kinds or more ([[PgPlan]]), in two phases. The first runs each
    * kind's plan statement ([[Sql.Batch]] `plan`) over its reads' parameters: each list's distinct pages and counts
    * and the rows of its pages' articles, each article page's article. The second reads once for the round what those
    * articles need, whatever kind showed them ([[RoundArticles]]): their tag ids and favorites counts, their authors'
    * profiles, the tags' names, and the flags the viewers asked about. Its rows are read, and its reads answered, on
    * its connection's loop.
    */
  private[conduit] final class RoundPlan extends PgPlan:
    /** Each planned kind's reads, by its place in [[Planned]]. */
    private val byKind = Array.fill(Planned.length)(new Array[PgQuery](8))
    private val counts = new Array[Int](Planned.length)
    private var total = 0
    private var kindsUsed = 0
    /** The first phase's statements: the kind each is. */
    private val sent = new Array[Int](Planned.length)
    private var second = false
    private var articles: RoundArticles = null

    def add(q: PgQuery): Unit =
      val k = PlannedIndex(q.batch.id)
      if counts(k) == 0 then kindsUsed += 1
      if counts(k) == byKind(k).length then byKind(k) = java.util.Arrays.copyOf(byKind(k), counts(k) * 2)
      byKind(k)(counts(k)) = q
      counts(k) += 1
      total += 1

    def size: Int = total
    def kinds: Int = kindsUsed

    def query(i: Int): PgQuery =
      var k = 0
      var rest = i
      while rest >= counts(k) do
        rest -= counts(k)
        k += 1
      byKind(k)(rest)

    def send(w: PgWriter): Unit =
      if !second then
        var s = 0
        var k = 0
        while k < Planned.length do
          val n = counts(k)
          if n > 0 then
            val qs = byKind(k)
            w.bind(Planned(k).plan)
            val types = Planned(k).paramTypes
            var p = 0
            while p < types.length do
              val param = p
              if types(p) == Oid.Int8 then w.int8Array(n, i => qs(i).int8Param(param))
              else w.textArray(n, i => qs(i).textParam(param))
              p += 1
            w.execute()
            sent(s) = k
            s += 1
          k += 1
      else
        val a = articles
        w.bind(Sql.PlanArticles).int8Array(a.size, a.id).execute()
        w.bind(Sql.PlanAuthors).int8Array(a.authorCount, a.authorId).execute()
        w.bind(Sql.PlanTags).execute()
        if a.asked then
          val f = a.favoritesAsked
          val o = a.followsAsked
          w.bind(Sql.PlanFlags)
            .int8Array(f.size, f.first).int8Array(f.size, f.start).int8Array(f.size, f.end).int8Array(f.count, f.second)
            .int8Array(o.size, o.first).int8Array(o.size, o.start).int8Array(o.size, o.end).int8Array(o.count, o.second)
            .execute()

    def row(statement: Int, row: PgRow): Unit =
      if articles == null then articles = RoundArticles(Out.Pool.current)
      if !second then
        val i = row.int8(Columns.Plan.Request).toInt
        if i == 0 then articles.article(row, withBody = false)
        else byKind(sent(statement))(i - 1).asInstanceOf[PlannedRead].plannedRow(row, articles)
      else statement match
        case 0 => articles.enriched(row)
        case 1 => articles.author(row)
        case 2 => articles.tag(row)
        case _ => articles.flag(row)

    def done(error: PgError): Unit =
      if error != null then fail(error)
      else if !second && articles != null && articles.size > 0 then
        each(_.ask(articles))
        second = true
        again()
      else
        if articles != null then articles.assemble()
        each(_.answer(articles))
        release()

    private def fail(error: PgError): Unit =
      var k = 0
      while k < Planned.length do
        var i = 0
        while i < counts(k) do
          try byKind(k)(i).done(error)
          catch case NonFatal(t) => Log.error("request failed", t)
          i += 1
        k += 1
      release()

    private def each(f: PlannedRead => Unit): Unit =
      var k = 0
      while k < Planned.length do
        var i = 0
        while i < counts(k) do
          try f(byKind(k)(i).asInstanceOf[PlannedRead])
          catch case NonFatal(t) => Log.error("request failed", t)
          i += 1
        k += 1

    private def release(): Unit =
      if articles != null then
        articles.release()
        articles = null

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

    override def packed(): PgPacked = PackedComments(Out.Pool.current)

    /** In a packed batch: the article's comments, from the batch's (null: none in the batch), with this viewer's
      * `following`.
      */
    override def row(statement: Int, row: PgRow, packed: PgPacked): Unit =
      import Columns.PackedComments as C
      found = true
      val shared = packed.asInstanceOf[PackedComments]
      if shared != null then
        val article = row.int8(C.Article)
        var k = shared.first(article)
        while k >= 0 && k < shared.size && shared.article(k) == article do
          if comments == 0 then Render.commentsOpen(out) else out.byte(',')
          shared.write(out, k, row.int8ArrayHas(C.Following, shared.author(k)))
          comments += 1
          k += 1

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
    override def merge: Sql.Merge = Sql.mergeOf(Sql.CreateComment)
    override def int8Param(p: Int): Long = viewer
    override def textParam(p: Int): String = if p == 1 then slug else body
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
    override def merge: Sql.Merge = if write then Sql.mergeOf(statement) else null
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

    // A batch's tag list is the same for all its requests: the first writes it, the others copy its bytes.
    override def copiesShared: Boolean = true

    override def copyShared(first: PgQuery): Unit =
      val f = first.asInstanceOf[TagsCall]
      if f.tags > 0 then out.bytes(f.out, 0, f.out.length)
      tags = f.tags

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
  * or [[fail]]s with an error. Its [[Connection]] sends responses in the order the requests came. A read may be
  * answered on another loop's Postgres connection ([[PgReads]]): its rows are read, and its response put together,
  * on that loop's thread, which then hands the response to the request's ([[Handoff]]).
  */
abstract class Call extends PgQuery:
  private[conduit] var api: Api = null
  private[conduit] var connection: Connection = null
  /** The response body, from the thread's pool when first written to: a request waiting for Postgres holds none. */
  private var buffer: Out = null
  private[conduit] var ending: Out.Ending = null
  /** The connection's next request, pipelined after this one. */
  private[conduit] var nextCall: Call = null
  /** The whole response, once there is one. */
  private[conduit] var response: ByteBuf = null

  /** Starts answering: asks Postgres, or answers at once. */
  def start(): Unit

  protected final def out: Out =
    if buffer == null then buffer = Out.Pool.current.take()
    buffer

  /** The client went away (its connection closed) before the request was sent to Postgres: don't send it. */
  override def abandoned: Boolean = !connection.open

  override def client: AnyRef = connection

  /** The group of writes it went out in was rolled back: drops the response written so far, and what the replies
    * set ([[restart]]).
    */
  override final def reset(): Unit =
    if buffer != null then
      Out.Pool.current.give(buffer)
      buffer = null
    restart()

  /** Forgets what the replies so far set, for [[reset]]. */
  protected def restart(): Unit = ()

  /** The response is the body written so far, with `status`: written by its connection's loop, this one or the one
    * it is handed to.
    */
  final def finish(status: Status): Unit =
    val o = out
    val r = o.response(connection.alloc, status, ending)
    Out.Pool.current.give(o)
    buffer = null
    if api.loop.inEventLoop then
      response = r
      connection.answered(this)
    else Handoff.current.add(this, r)

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
  private val text = outs.takeRound()
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

  def release(): Unit = outs.giveRound(text)

/** A packed comments batch's comments ([[Columns.PackedComments]]), each written once as the JSON every request for
  * its article shares ([[Render.sharedComment]]), an article's together and newest first, as they arrive; a request
  * copies its article's with its viewer's `following`.
  */
private[conduit] final class PackedComments(outs: Out.Pool) extends PgPacked:
  import Columns.PackedComments as C

  private val text = outs.takeRound()
  private var articles = new Array[Long](64)
  private var authors = new Array[Long](64)
  /** Where each comment's text ends; it starts where the one before ends. */
  private var ends = new Array[Int](64)
  private var n = 0
  /** Open addressing by article id: each slot the index of the article's first comment plus 1, or 0. */
  private var slots = new Array[Int](32)
  private var distinct = 0

  def size: Int = n
  def article(k: Int): Long = articles(k)
  def author(k: Int): Long = authors(k)

  def row(row: PgRow): Unit =
    if n == articles.length then
      articles = java.util.Arrays.copyOf(articles, n * 2)
      authors = java.util.Arrays.copyOf(authors, n * 2)
      ends = java.util.Arrays.copyOf(ends, n * 2)
    articles(n) = row.int8(C.Article)
    authors(n) = row.int8(C.Author)
    Render.sharedComment(text, row)
    ends(n) = text.length
    if n == 0 || articles(n - 1) != articles(n) then
      distinct += 1
      if 2 * distinct > slots.length then
        slots = new Array[Int](slots.length * 2)
        var k = 0
        while k < n do
          if k == 0 || articles(k - 1) != articles(k) then place(k)
          k += 1
      place(n)
    n += 1

  private def slot(article: Long): Int = ((article * 0x9e3779b97f4a7c15L) >>> 40).toInt & (slots.length - 1)

  private def place(k: Int): Unit =
    var i = slot(articles(k))
    while slots(i) != 0 do i = (i + 1) & (slots.length - 1)
    slots(i) = k + 1

  /** The index of `article`'s first comment, or -1. */
  def first(article: Long): Int =
    var i = slot(article)
    while slots(i) != 0 && articles(slots(i) - 1) != article do i = (i + 1) & (slots.length - 1)
    slots(i) - 1

  /** Comment `k` as [[Render.comment]] writes it, with this `following`. */
  def write(out: Out, k: Int, following: Boolean): Unit =
    val start = if k == 0 then 0 else ends(k - 1)
    out.bytes(text, start, ends(k) - start).bool(following).byte('}').byte('}')

  def release(): Unit = outs.giveRound(text)

/** A round's articles ([[Api.RoundPlan]]), each read once whatever kind of request showed it: its row from the first
  * phase; from the second its tag ids and favorites count, its author's profile and the tags' names; put together
  * once as the JSON every response that shows it shares ([[assemble]]), as [[Render.article]] writes it. And the
  * flags the round's viewers asked about ([[ask]]), with those that hold.
  */
private[conduit] final class RoundArticles(outs: Out.Pool):
  import Columns.Plan as P

  /** The pieces as they arrive: each article's head and dates (and an article page's body), each author's profile up
    * to `following`'s value, each tag's name.
    */
  private val pieces = outs.takeRound()
  /** Each article's JSON, put together once the second phase is answered. */
  private val text = outs.takeRound()

  private val articles = LongIndex()
  private var n = 0
  private var authorIds = new Array[Long](64)
  /** In `pieces`: each article's head (slug, title, description) from `heads` to `dates`, its dates to `datesEnd`, and
    * its body from `bodies` to `bodiesEnd` (-1: none).
    */
  private var heads = new Array[Int](64)
  private var dates = new Array[Int](64)
  private var datesEnd = new Array[Int](64)
  private var bodies = new Array[Int](64)
  private var bodiesEnd = new Array[Int](64)
  private var counts = new Array[Long](64)
  /** Its tag ids, `tagCounts` of them (-1: not read) from `tagFrom` in `tagIds`. */
  private var tagFrom = new Array[Int](64)
  private var tagCounts = new Array[Int](64)
  private var tagIds = new Array[Int](256)
  private var tagIdsLength = 0
  /** In `text`: where each article starts (-1: the second phase didn't name all it needs), where an article page's
    * body goes, where it splits around `favorited`, and where it ends.
    */
  private var starts = new Array[Int](64)
  private var headEnds = new Array[Int](64)
  private var splits = new Array[Int](64)
  private var ends = new Array[Int](64)

  /** The distinct authors, and in `pieces` each one's profile up to `following`'s value (-1: not read). */
  private val authors = LongIndex()
  private var authorStarts = new Array[Int](64)
  private var authorEnds = new Array[Int](64)

  /** By tag id: its place in name order plus 1 (0: not read), and its name in `pieces`. */
  private var tagRanks = new Array[Int](256)
  private var tagStarts = new Array[Int](256)
  private var tagEnds = new Array[Int](256)
  private var tags = 0

  /** The flags asked about, (viewer, article) and (viewer, author), and of those the ones that hold. */
  private val favoritesAskedFor = PairSet()
  private val followsAskedFor = PairSet()
  private val favorites = PairSet()
  private val follows = PairSet()

  def size: Int = n
  def id(a: Int): Long = articles.key(a)
  /** The article with `id`'s index, or -1. */
  def find(id: Long): Int = articles.find(id)

  def authorCount: Int = authors.size
  def authorId(i: Int): Long = authors.key(i)

  /** A first phase's article row: its index, the article's columns read once (an article page's with its body). */
  def article(row: PgRow, withBody: Boolean): Int =
    val a = articles.add(row.int8(P.Id))
    if a == n then
      if n == heads.length then grow()
      authorIds(a) = row.int8(P.Author)
      heads(a) = pieces.length
      Render.articleHead(pieces, row, P.Slug)
      dates(a) = pieces.length
      Render.articleDates(pieces, row, P.CreatedAt)
      datesEnd(a) = pieces.length
      bodies(a) = -1
      tagCounts(a) = -1
      val i = authors.add(authorIds(a))
      if i == authorStarts.length then
        authorStarts = java.util.Arrays.copyOf(authorStarts, i * 2)
        authorEnds = java.util.Arrays.copyOf(authorEnds, i * 2)
      if i == authors.size - 1 then authorStarts(i) = -1
      n += 1
    if withBody && bodies(a) < 0 then
      bodies(a) = pieces.length
      Render.articleBody(pieces, row, P.Ids)
      bodiesEnd(a) = pieces.length
    a

  private def grow(): Unit =
    val m = n * 2
    authorIds = java.util.Arrays.copyOf(authorIds, m)
    heads = java.util.Arrays.copyOf(heads, m)
    dates = java.util.Arrays.copyOf(dates, m)
    datesEnd = java.util.Arrays.copyOf(datesEnd, m)
    bodies = java.util.Arrays.copyOf(bodies, m)
    bodiesEnd = java.util.Arrays.copyOf(bodiesEnd, m)
    counts = java.util.Arrays.copyOf(counts, m)
    tagFrom = java.util.Arrays.copyOf(tagFrom, m)
    tagCounts = java.util.Arrays.copyOf(tagCounts, m)
    starts = java.util.Arrays.copyOf(starts, m)
    headEnds = java.util.Arrays.copyOf(headEnds, m)
    splits = java.util.Arrays.copyOf(splits, m)
    ends = java.util.Arrays.copyOf(ends, m)

  /** `viewer` (not 0) asks whether it favorited article `a`, and with `following` whether it follows its author. */
  def ask(viewer: Long, a: Int, following: Boolean): Unit =
    favoritesAskedFor.add(viewer, articles.key(a))
    if following then followsAskedFor.add(viewer, authorIds(a))

  def asked: Boolean = favoritesAskedFor.size + followsAskedFor.size > 0
  /** The (viewer, article) pairs asked about, by viewer. */
  def favoritesAsked: PairSlices = PairSlices(favoritesAskedFor)
  /** The (viewer, author) pairs asked about, by viewer. */
  def followsAsked: PairSlices = PairSlices(followsAskedFor)

  /** A row of [[Sql.PlanArticles]]: id, tag ids, favorites count. */
  def enriched(row: PgRow): Unit =
    val a = articles.find(row.int8(0))
    if a >= 0 then
      val k = row.int8ArrayLength(1)
      if tagIdsLength + k > tagIds.length then tagIds = java.util.Arrays.copyOf(tagIds, math.max(tagIds.length * 2, tagIdsLength + k))
      tagFrom(a) = tagIdsLength
      tagCounts(a) = k
      var j = 0
      while j < k do
        tagIds(tagIdsLength + j) = row.int8ArrayAt(1, j).toInt
        j += 1
      tagIdsLength += k
      counts(a) = row.int8(2)

  /** A row of [[Sql.PlanAuthors]]: id, username, bio, image. */
  def author(row: PgRow): Unit =
    val i = authors.find(row.int8(0))
    if i >= 0 then
      authorStarts(i) = pieces.length
      Render.sharedProfile(pieces, row, 1)
      authorEnds(i) = pieces.length

  /** A row of [[Sql.PlanTags]], in name order: id, name. */
  def tag(row: PgRow): Unit =
    val id = row.int4(0)
    if id >= tagRanks.length then
      val m = math.max(tagRanks.length * 2, id + 1)
      tagRanks = java.util.Arrays.copyOf(tagRanks, m)
      tagStarts = java.util.Arrays.copyOf(tagStarts, m)
      tagEnds = java.util.Arrays.copyOf(tagEnds, m)
    tags += 1
    tagRanks(id) = tags
    tagStarts(id) = pieces.length
    row.text(1, pieces)
    tagEnds(id) = pieces.length

  /** A row of [[Sql.PlanFlags]]: 0 for a favorite or 1 for a follow, the viewer, the article or author. */
  def flag(row: PgRow): Unit = (if row.int8(0) == 0 then favorites else follows).add(row.int8(1), row.int8(2))

  def favorited(viewer: Long, a: Int): Boolean = viewer != 0 && favorites.has(viewer, articles.key(a))
  def following(viewer: Long, a: Int): Boolean = viewer != 0 && follows.has(viewer, authorIds(a))

  /** Puts each article's JSON together, once the second phase is answered: its tags in name order. */
  def assemble(): Unit =
    var a = 0
    while a < n do
      val i = authors.find(authorIds(a))
      if tagCounts(a) < 0 || i < 0 || authorStarts(i) < 0 || !tagsKnown(a) then starts(a) = -1
      else
        sortTags(a)
        starts(a) = text.length
        text.bytes(pieces, heads(a), dates(a) - heads(a))
        headEnds(a) = text.length
        Render.tagListOpen(text)
        var j = 0
        while j < tagCounts(a) do
          val t = tagIds(tagFrom(a) + j)
          if j > 0 then text.byte(',')
          text.bytes(pieces, tagStarts(t), tagEnds(t) - tagStarts(t))
          j += 1
        text.byte(']')
        text.bytes(pieces, dates(a), datesEnd(a) - dates(a))
        Render.favoritedKey(text)
        splits(a) = text.length
        Render.countAndAuthor(text, counts(a))
        text.bytes(pieces, authorStarts(i), authorEnds(i) - authorStarts(i))
        ends(a) = text.length
      a += 1

  private def tagsKnown(a: Int): Boolean =
    var j = 0
    while j < tagCounts(a) do
      val t = tagIds(tagFrom(a) + j)
      if t < 0 || t >= tagRanks.length || tagRanks(t) == 0 then return false
      j += 1
    true

  /** Article `a`'s tag ids in name order (an insertion sort: an article has 1 to 4). */
  private def sortTags(a: Int): Unit =
    val from = tagFrom(a)
    var j = from + 1
    while j < from + tagCounts(a) do
      val t = tagIds(j)
      var k = j - 1
      while k >= from && tagRanks(tagIds(k)) > tagRanks(t) do
        tagIds(k + 1) = tagIds(k)
        k -= 1
      tagIds(k + 1) = t
      j += 1

  /** Whether article `a`'s JSON is whole: the second phase named all it needs. */
  def ready(a: Int): Boolean = starts(a) >= 0

  /** Article `a` as [[Render.article]] writes it without its body, with these flags. */
  def write(out: Out, a: Int, favorited: Boolean, following: Boolean): Unit =
    out.bytes(text, starts(a), splits(a) - starts(a)).bool(favorited)
    out.bytes(text, splits(a), ends(a) - splits(a)).bool(following).byte('}').byte('}')

  /** Article `a` as [[Render.article]] writes it with its body, with these flags. */
  def writeWithBody(out: Out, a: Int, favorited: Boolean, following: Boolean): Unit =
    out.bytes(text, starts(a), headEnds(a) - starts(a))
    out.bytes(pieces, bodies(a), bodiesEnd(a) - bodies(a))
    out.bytes(text, headEnds(a), splits(a) - headEnds(a)).bool(favorited)
    out.bytes(text, splits(a), ends(a) - splits(a)).bool(following).byte('}').byte('}')

  def release(): Unit =
    outs.giveRound(pieces)
    outs.giveRound(text)

/** Distinct longs, each given the next index from 0 when first added (open addressing). */
private[conduit] final class LongIndex:
  private var keys = new Array[Long](64)
  /** Each a key's index plus 1, or 0. */
  private var slots = new Array[Int](128)
  private var n = 0

  def size: Int = n
  def key(i: Int): Long = keys(i)

  /** `key`'s index, or -1. */
  def find(key: Long): Int =
    var s = slot(key)
    while slots(s) != 0 && keys(slots(s) - 1) != key do s = (s + 1) & (slots.length - 1)
    slots(s) - 1

  /** `key`'s index, the next one if it is new. */
  def add(key: Long): Int =
    var s = slot(key)
    while slots(s) != 0 do
      if keys(slots(s) - 1) == key then return slots(s) - 1
      s = (s + 1) & (slots.length - 1)
    if n == keys.length then keys = java.util.Arrays.copyOf(keys, n * 2)
    keys(n) = key
    n += 1
    if 2 * n > slots.length then rehash() else slots(s) = n
    n - 1

  private def slot(key: Long): Int = ((key * 0x9e3779b97f4a7c15L) >>> 40).toInt & (slots.length - 1)

  private def rehash(): Unit =
    slots = new Array[Int](slots.length * 2)
    var i = 0
    while i < n do
      var s = slot(keys(i))
      while slots(s) != 0 do s = (s + 1) & (slots.length - 1)
      slots(s) = i + 1
      i += 1

/** Distinct pairs of longs, in the order added (open addressing). */
private[conduit] final class PairSet:
  private var as = new Array[Long](64)
  private var bs = new Array[Long](64)
  /** Each a pair's index plus 1, or 0. */
  private var slots = new Array[Int](128)
  private var n = 0

  def size: Int = n
  def a(i: Int): Long = as(i)
  def b(i: Int): Long = bs(i)

  def has(a: Long, b: Long): Boolean =
    var s = slot(a, b)
    while slots(s) != 0 do
      val i = slots(s) - 1
      if as(i) == a && bs(i) == b then return true
      s = (s + 1) & (slots.length - 1)
    false

  /** Adds the pair if it is new. */
  def add(a: Long, b: Long): Unit =
    var s = slot(a, b)
    while slots(s) != 0 do
      val i = slots(s) - 1
      if as(i) == a && bs(i) == b then return
      s = (s + 1) & (slots.length - 1)
    if n == as.length then
      as = java.util.Arrays.copyOf(as, n * 2)
      bs = java.util.Arrays.copyOf(bs, n * 2)
    as(n) = a
    bs(n) = b
    n += 1
    if 2 * n > slots.length then rehash() else slots(s) = n

  private def slot(a: Long, b: Long): Int = (((a * 0x9e3779b97f4a7c15L) ^ (b * 0xc2b2ae3d27d4eb4fL)) >>> 40).toInt & (slots.length - 1)

  private def rehash(): Unit =
    slots = new Array[Int](slots.length * 2)
    var i = 0
    while i < n do
      var s = slot(as(i), bs(i))
      while slots(s) != 0 do s = (s + 1) & (slots.length - 1)
      slots(s) = i + 1
      i += 1

/** A [[PairSet]]'s pairs grouped by their first, as SQL's array slices take them: each distinct first once, in the
  * order first added, and its seconds, in the order added, `seconds(start - 1)` to `seconds(end - 1)` (1-based and
  * inclusive, `$n[start:end]`). A counting sort: each pair's first's index, the slices' ends, then the seconds.
  */
private[conduit] final class PairSlices(pairs: PairSet):
  private val firsts = LongIndex()
  private val firstOf = new Array[Int](pairs.size)
  private val ends = locally:
    var i = 0
    while i < pairs.size do
      firstOf(i) = firsts.add(pairs.a(i))
      i += 1
    val e = new Array[Int](firsts.size)
    i = 0
    while i < pairs.size do
      e(firstOf(i)) += 1
      i += 1
    var k = 1
    while k < e.length do
      e(k) += e(k - 1)
      k += 1
    e
  private val seconds = locally:
    val s = new Array[Long](pairs.size)
    val next = ends.clone()
    var i = pairs.size - 1
    while i >= 0 do
      next(firstOf(i)) -= 1
      s(next(firstOf(i))) = pairs.b(i)
      i -= 1
    s

  /** The distinct firsts. */
  def size: Int = ends.length
  def first(k: Int): Long = firsts.key(k)
  def start(k: Int): Long = if k == 0 then 1 else ends(k - 1) + 1
  def end(k: Int): Long = ends(k)
  /** The pairs. */
  def count: Int = seconds.length
  def second(i: Int): Long = seconds(i)

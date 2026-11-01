package conduit

import Oid.*

/** Every statement the server runs, prepared on each connection at startup. Each returns what the spec's
  * reference SQL returns (`SPEC.md`), with less work for Postgres:
  *
  *   - one statement per request where the reference has two or three, so one round trip and one transaction;
  *   - a list's page is cut from the bare index walk first, and the per-article subqueries (tags, favorites count,
  *     the viewer's flags) run for the page's rows only, not for the rows `OFFSET` skips;
  *   - the page sits under a constant `LIMIT 100` (the most a request may ask for): with generic plans a bare
  *     `LIMIT $2` makes the planner expect a tenth of the table, and plan for it;
  *   - tag names by primary key, one probe per tag, instead of a join the generic plan hashes all tags for; in a
  *     packed batch, where the probes add up, one hash of the tags for the batch's articles.
  *
  * The article columns, in every statement that returns an article: slug, title, description, [body,] created_at,
  * updated_at, tag_list, favorites_count, favorited, username, bio, image, following ([[Columns]]).
  */
object Sql:
  private val all = collection.mutable.ArrayBuffer[Statement]()

  private def statement(sql: String, params: Int*): Statement =
    val s = Statement(all.length, sql.trim.replaceAll("\\s+", " "), params.toArray)
    all += s
    s

  /** The statements, by id. */
  def statements: collection.IndexedSeq[Statement] = all

  /** The article's columns after `updated_at`, for an article row aliased `a` (with `id` and `author_id`) and a user
    * row `u`, for viewer `viewer`.
    */
  private def tail(a: String, viewer: String, following: String = "") =
    s"""${tagNames(a)},
       |${favoritesCount(a)},
       |${favorited(a, viewer)},
       |u.username, u.bio, u.image,
       |${if following.nonEmpty then following else follows(s"$a.author_id", viewer)}""".stripMargin

  private def tagNames(a: String) =
    s"ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = $a.id ORDER BY 1)"
  private def favoritesCount(a: String) = s"(SELECT count(*) FROM favorites f WHERE f.article_id = $a.id)"
  private def favorited(a: String, viewer: String) =
    s"EXISTS (SELECT 1 FROM favorites f WHERE f.user_id = $viewer AND f.article_id = $a.id)"
  private def follows(author: String, viewer: String) =
    s"EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $viewer AND fo.followee_id = $author)"

  private val Full = "a.slug, a.title, a.description, a.body, a.created_at, a.updated_at"
  private val Short = "a.slug, a.title, a.description, a.created_at, a.updated_at"
  private val PageColumns = "id, slug, title, description, created_at, updated_at, author_id"

  /** A list statement: the capped count `count` (rows of a `SELECT 1 ...`), then the page's articles, one per row
    * after the count (none: one row with nulls). `page` yields the page's `id`s, newest first, or whole article
    * rows if `rows`.
    */
  private def list(count: String, page: String, rows: Boolean, following: String = "") =
    val articles =
      if rows then s"LEFT JOIN LATERAL ($page) a ON true"
      else s"LEFT JOIN LATERAL ($page) p ON true LEFT JOIN articles a ON a.id = p.id"
    s"""SELECT c.n, $Short, ${tail("a", "$1", following)}
       |FROM (SELECT count(*) AS n FROM ($count LIMIT 1000) s) c
       |$articles
       |LEFT JOIN users u ON u.id = a.author_id
       |ORDER BY a.id DESC""".stripMargin

  /** `page`'s rows from `$3` on, at most `$2` of them (1 to 100). */
  private def paged(page: String, order: String) =
    s"SELECT * FROM ($page ORDER BY $order DESC OFFSET $$3 LIMIT 100) x ORDER BY x.$order DESC LIMIT $$2"

  // $1 viewer, $2 limit, $3 offset
  val ListAll: Statement = statement(
    list("SELECT 1 FROM articles", paged(s"SELECT $PageColumns FROM articles", "id"), rows = true),
    Int8, Int8, Int8,
  )

  /** A list's filter, `$4`, as its id. */
  private val TagId = "(SELECT t.id FROM tags t WHERE t.name = $4)"
  private val UserId = "(SELECT u.id FROM users u WHERE u.username = $4)"

  private val ByTag = s"FROM article_tags at WHERE at.tag_id = $TagId"
  private val TagCount = s"SELECT 1 $ByTag"
  private val TagPage = paged(s"SELECT at.article_id AS id $ByTag", "id")

  // $4 tag
  val ListByTag: Statement = statement(list(TagCount, TagPage, rows = false), Int8, Int8, Int8, Text)

  private val AuthorCount = s"SELECT 1 FROM articles a WHERE a.author_id = $UserId"
  private val AuthorPage = paged(s"SELECT id FROM articles WHERE author_id = $UserId", "id")

  // $4 author's username
  val ListByAuthor: Statement = statement(
    list(
      AuthorCount,
      paged(s"SELECT $PageColumns FROM articles WHERE author_id = $UserId", "id"),
      rows = true,
    ),
    Int8, Int8, Int8, Text,
  )

  private val ByFavoriter = s"FROM favorites f WHERE f.user_id = $UserId"
  private val FavoritedCount = s"SELECT 1 $ByFavoriter"
  private val FavoritedPage = paged(s"SELECT f.article_id AS id $ByFavoriter", "id")

  // $4 the username whose favorites these are
  val ListByFavorited: Statement = statement(list(FavoritedCount, FavoritedPage, rows = false), Int8, Int8, Int8, Text)

  private val FeedCount = "SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1)"
  /** The newest `$2 + $3` of each followed author's articles, merged; `floor` a condition on them (`a2`). */
  private def feedPage(floor: String) = paged(
    s"""SELECT x.id FROM follows fo CROSS JOIN LATERAL
       |  (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id$floor ORDER BY a2.id DESC LIMIT ($$2 + $$3)) x
       |WHERE fo.follower_id = $$1""".stripMargin,
    "id",
  )
  private val FeedPage = feedPage("")

  /** The viewer's feed: the newest `$2 + $3` of each followed author's articles, merged. The viewer follows every
    * author in it, in the statement's own snapshot, so `following` is true without a probe.
    */
  val Feed: Statement = statement(list(FeedCount, FeedPage, rows = false, following = "true"), Int8, Int8, Int8)

  // $1 viewer, $2 slug
  val ArticleBySlug: Statement = statement(
    s"SELECT $Full, ${tail("a", "$1")} FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = $$2",
    Int8, Text,
  )

  /** `$1` (the viewer) favorites the article with slug `$2`; once it is committed, [[ArticleBySlug]] reads the article. */
  val Favorite: Statement = statement(
    "INSERT INTO favorites (user_id, article_id) SELECT $1, a.id FROM articles a WHERE a.slug = $2 ON CONFLICT DO NOTHING",
    Int8, Text,
  )

  val Unfavorite: Statement = statement(
    "DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT a.id FROM articles a WHERE a.slug = $2)",
    Int8, Text,
  )

  /** A new article, its slug computed by [[Input.slugify]] (`$5`) and its id: `$1` author, `$2` title, `$3`
    * description, `$4` body. Then, in the same transaction, [[InsertTags]] and [[TagArticle]] if it has tags, and
    * [[NewArticle]].
    */
  val InsertArticle: Statement = statement(
    """INSERT INTO articles (id, slug, author_id, title, description, body)
      |SELECT n.id, $5 || '-' || n.id, $1, $2, $3, $4 FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n""".stripMargin,
    Int8, Text, Text, Text, Text,
  )

  /** The tags of `$1` that don't exist yet, in name order: concurrent inserts of the same new tags take their locks
    * in the same order, and tags that exist cost no insert (nor a sequence value).
    */
  val InsertTags: Statement = statement(
    """INSERT INTO tags (name)
      |SELECT DISTINCT n.name FROM unnest($1::text[]) AS n(name)
      |WHERE NOT EXISTS (SELECT 1 FROM tags t WHERE t.name = n.name) ORDER BY n.name
      |ON CONFLICT (name) DO NOTHING""".stripMargin,
    TextArray,
  )

  /** The article just inserted on this connection gets the tags `$1`. A statement of its own: in READ COMMITTED it
    * sees the tags [[InsertTags]] inserted, and those others committed meanwhile.
    */
  val TagArticle: Statement = statement(
    """INSERT INTO article_tags (article_id, tag_id)
      |SELECT (SELECT currval(pg_get_serial_sequence('articles', 'id'))), t.id FROM tags t WHERE t.name = ANY($1::text[])""".stripMargin,
    TextArray,
  )

  /** The article just inserted on this connection, for viewer `$1` (its author). */
  val NewArticle: Statement = statement(
    s"""SELECT $Full, ${tail("a", "$1")} FROM articles a JOIN users u ON u.id = a.author_id
       |WHERE a.id = (SELECT currval(pg_get_serial_sequence('articles', 'id')))""".stripMargin,
    Int8,
  )

  /** The article with slug `$2` updated by its author `$1`, as the spec's reference SQL updates it (`$3` title,
    * `$4` description, `$5` body, each null to keep it; `$6` the new title's slug, null without one), and read back:
    * `author_id`, then the article's columns, null unless it was updated. No row: no such article.
    */
  val UpdateArticle: Statement = statement(
    s"""WITH a AS (SELECT id, author_id FROM articles WHERE slug = $$2),
       |x AS (
       |  UPDATE articles SET title = COALESCE($$3, articles.title), description = COALESCE($$4, articles.description),
       |    body = COALESCE($$5, articles.body),
       |    slug = CASE WHEN $$6::text IS NULL THEN articles.slug ELSE $$6 || '-' || articles.id END, updated_at = now()
       |  FROM a WHERE articles.id = a.id AND a.author_id = $$1
       |  RETURNING articles.id, articles.slug, articles.title, articles.description, articles.body, articles.created_at,
       |    articles.updated_at, articles.author_id)
       |SELECT a.author_id, x.slug, x.title, x.description, x.body, x.created_at, x.updated_at, ${tail("x", "$1")}
       |FROM a LEFT JOIN x ON true LEFT JOIN users u ON u.id = x.author_id""".stripMargin,
    Int8, Text, Text, Text, Text, Text,
  )

  /** The article with slug `$2`, deleted if `$1` is its author: its `author_id`. No row: no such article. */
  val DeleteArticle: Statement = statement(
    """WITH a AS (SELECT id, author_id FROM articles WHERE slug = $2),
      |d AS (DELETE FROM articles x USING a WHERE x.id = a.id AND a.author_id = $1)
      |SELECT author_id FROM a""".stripMargin,
    Int8, Text,
  )

  /** The newest 100 comments on the article with slug `$2`, for viewer `$1`: id, body, created_at, updated_at,
    * username, bio, image, following. No row: no such article; one row of nulls: no comments.
    */
  val Comments: Statement = statement(
    """SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
      |  EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id)
      |FROM articles a
      |LEFT JOIN LATERAL (
      |  SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c
      |  WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true
      |LEFT JOIN users u ON u.id = c.author_id
      |WHERE a.slug = $2
      |ORDER BY c.created_at DESC, c.id DESC""".stripMargin,
    Int8, Text,
  )

  /** A comment by `$1` on the article with slug `$2`, with body `$3`: as [[Comments]] has it, without `following`.
    * No row: no such article.
    */
  val CreateComment: Statement = statement(
    """WITH c AS (
      |  INSERT INTO comments (article_id, author_id, body) SELECT a.id, $1, $3 FROM articles a WHERE a.slug = $2
      |  RETURNING id, body, created_at, updated_at, author_id)
      |SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image FROM c JOIN users u ON u.id = c.author_id""".stripMargin,
    Int8, Text, Text,
  )

  /** Comment `$3` on the article with slug `$2`, deleted if `$1` wrote it: its `author_id`. No row: no such comment
    * there.
    */
  val DeleteComment: Statement = statement(
    """WITH c AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $3 AND a.slug = $2),
      |d AS (DELETE FROM comments x USING c WHERE x.id = c.id AND c.author_id = $1)
      |SELECT author_id FROM c""".stripMargin,
    Int8, Text, Int8,
  )

  /** The profile of `$2` for viewer `$1`: username, bio, image, following. */
  val Profile: Statement = statement(
    """SELECT u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id)
      |FROM users u WHERE u.username = $2""".stripMargin,
    Int8, Text,
  )

  /** `$1` follows `$2`: their username, bio and image. No row: no such user. */
  val Follow: Statement = statement(
    """WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),
      |i AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM u ON CONFLICT DO NOTHING)
      |SELECT username, bio, image FROM u""".stripMargin,
    Int8, Text,
  )

  val Unfollow: Statement = statement(
    """WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),
      |d AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM u))
      |SELECT username, bio, image FROM u""".stripMargin,
    Int8, Text,
  )

  val Tags: Statement = statement("SELECT name FROM tags ORDER BY name")

  // Users: id, username, email, bio, image (and the hash, for a login).
  val Register: Statement = statement(
    "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image",
    Text, Text, Text,
  )

  val Login: Statement = statement(
    "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1",
    Text,
  )

  val CurrentUser: Statement = statement(
    "SELECT id, username, email, bio, image FROM users WHERE id = $1",
    Int8,
  )

  /** `$1` the user; each of `$2` email, `$3` username, `$4` password hash, `$5` bio, `$6` image null to keep it. */
  val UpdateUser: Statement = statement(
    """UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
      |  password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
      |WHERE id = $1 RETURNING id, username, email, bio, image""".stripMargin,
    Int8, Text, Text, Text, Text, Text,
  )

  // -- Batches --------------------------------------------------------------------------------------------------

  /** A read whose waiting requests share one statement ([[PgReads]] sends the requests of a kind waiting for a
    * connection together): `batched` runs `single` once per request, in a `LATERAL` subquery over the requests'
    * parameters as arrays, one element per request, and tags each request's rows with its place in the batch, from 1,
    * in an extra last column. Much of a small statement's cost is per statement (executor start and end, a
    * transaction, a snapshot, the protocol's messages), not per row.
    *
    * The requests that wait together may share what they read, within the statement (rule 5: they read it from
    * Postgres while they are served, and nothing is kept once the statement is answered). The lists' batches
    * ([[packedList]]) read each article once however many of their requests' pages have it (and the global list's
    * count once), and are `packed`: a row for each article, then a row for each request. A `shared`
    * batch, a statement without parameters, is the statement itself, run once for all the requests in it, and each of
    * its rows goes to every one of them. The sessions run without Memoize ([[PgConnection]]).
    */
  final class Batch private[Sql] (val id: Int, val single: Statement, val batched: Statement, val shared: Boolean,
      val packed: Boolean):
    def paramTypes: Array[Int] = single.paramTypes
    /** The statement its requests run in a round's first phase ([[Api.RoundPlan]]), with the batch's parameters, or
      * null: not a kind a round plans.
      */
    private[conduit] var plan: Statement = null

  private val batches = collection.mutable.ArrayBuffer[Batch]()

  private def shared(single: Statement): Batch =
    require(single.paramTypes.isEmpty, single.sql)
    val b = Batch(batches.length + 1, single, single, shared = true, packed = false)
    batches += b
    b

  private def batch(single: Statement): Batch =
    batched(single, from => s"SELECT q.*, r.i FROM $from CROSS JOIN LATERAL (${perRequest(single, single.sql)}) q")

  /** `single`'s batch, `sql(from)` over the requests' parameters as rows `from`: `r(p1, ..., pn, i)`. */
  private def batched(single: Statement, sql: String => String, packed: Boolean = false): Batch =
    val b = Batch(batches.length + 1, single, overRequests(single, sql), shared = false, packed)
    batches += b
    b

  /** A statement `sql(from)` over `single`'s requests' parameters as arrays, one element per request, as rows `from`:
    * `r(p1, ..., pn, i)`.
    */
  private def overRequests(single: Statement, sql: String => String): Statement =
    val types = single.paramTypes
    require(types.nonEmpty, single.sql)
    val arrays = types.indices.map(i => s"$$${i + 1}::${if types(i) == Int8 then "int8" else "text"}[]").mkString(", ")
    val columns = types.indices.map(i => s"p${i + 1}").mkString(", ")
    val params = types.toSeq.map(t => if t == Int8 then Int8Array else TextArray)
    statement(sql(s"unnest($arrays) WITH ORDINALITY AS r($columns, i)"), params*)

  /** `sql`, with `single`'s parameters as the request's (`r.p1` ...). */
  private def perRequest(single: Statement, sql: String) =
    (single.paramTypes.length to 1 by -1).foldLeft(sql)((sql, i) => sql.replace("$" + i, s"r.p$i"))

  /** A list's batch that reads each article once however many of its requests' pages have it (most requests for the
    * global list ask for its first page), packed ([[Columns.Packed]]): per request its count and its page's ids
    * (`count` and `page` as [[list]] takes them, `page` yielding `id`s), then each distinct article with its tags,
    * favorites count and author, as a row of its own (the tag names from one hash of the 200 tags for all of them, a
    * probe per tag costing more: a feed batch of 16 read 14% fewer buffers); then a row per request: its count, its
    * page's ids newest first,
    * those it favorited and the authors it follows among them (null for the feed, where it follows all). Each page runs
    * once per distinct limit, offset and filter in the batch, each count once per distinct filter, whatever viewer asks
    * (under the load a global batch of about 30 requests asks for 5 pages at most); the feed's depend on the viewer.
    * The articles' rows come first ([[BatchQuery]]): a `UNION ALL`, run in order.
    *
    * The feed shares what its viewers have in common: the authors the batch's viewers follow (`vf`), and of the 32
    * most followed among them (by two viewers at least, `h`) each one's `$2 + $3`-th newest article, the largest
    * depth its viewers ask for: that author alone has that many articles at least as new, so a viewer who follows it
    * gets no older article on its page, and each followed author's walk stops there (`fl`: the highest such floor of
    * each viewer). The same rows, fewer index entries (pgbench: 156 µs of Postgres per feed in batches of 16 against
    * 186, 124 in 64 against 164). The count is capped at 1,000 and most viewers follow an author with that many
    * articles, whose count is then 1,000 without walking 1,000 index entries: the four most followed are checked
    * once, and a viewer who follows one of them counts 1,000. `OFFSET 0` keeps the count once per request rather
    * than per page row.
    */
  private def packedList(
      single: Statement, count: String, page: String, feed: Boolean = false, filter: String = null, full: Boolean = false,
  ): Batch =
    val following =
      if feed then "NULL::int8[]"
      else "ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = q.p1 AND fo.followee_id = ANY(q.authors))"
    val counted = s"count(*) AS n FROM (${perRequest(single, count)} LIMIT 1000) s"
    // A count capped at 1,000. Where most reach the cap (`full`: the global list, every tag), whether a 1,000th row
    // exists, and the whole count only below it: the scan's rows go no further up than its `Limit`, where counting
    // passes each one to the aggregate (the global count 0.10 ms against 0.15).
    def capped(c: String) =
      if full then s"CASE WHEN EXISTS ($c LIMIT 1 OFFSET 999) THEN 1000::int8 ELSE (SELECT count(*) FROM ($c) s) END"
      else s"(SELECT count(*) AS n FROM ($c LIMIT 1000) s)"
    // A list's page depends on its limit, offset and filter, its count on its filter, neither on the viewer: each runs
    // once per distinct one in the batch (`kp`, `kc`), and each request joins its own (`p`). A filter (`$4`, a tag's
    // or a user's name) is resolved to its id once (`kc`, behind `OFFSET 0` so that it isn't inlined into each use),
    // its count and pages from the id: resolved in each (a username's lookup is a descent through the users' index,
    // its every comparison a collation's), an author batch spent 4% more of Postgres's CPU. The articles come from
    // the distinct pages, as the planner estimates them as it did the requests' (from `p`, the generic plan probed the
    // tags again and joined the articles by nested loops).
    def byId(sql: String) = perRequest(single, sql.replace(filter, "r.fid"))
    val counts =
      if filter == null then ""
      else
        require(count.contains(filter) && page.contains(filter), single.sql)
        s"""kc AS MATERIALIZED (
           |  SELECT r.p4, r.fid, ${capped(byId(count))} AS n
           |  FROM (SELECT d.p4, ${filter.replace("$4", "d.p4")} AS fid FROM (SELECT DISTINCT p4 FROM r) d OFFSET 0) r),
           |""".stripMargin
    // The distinct pages (`keys`), each one's page, and how a request finds its page and its count.
    val (keys, pageSql, ofRequest, countSql) =
      if filter == null then
        ("SELECT DISTINCT p2, p3 FROM r", perRequest(single, page), "kp.p2 = r.p2 AND kp.p3 = r.p3",
          capped(perRequest(single, count)))
      else
        ("SELECT DISTINCT r.p2, r.p3, r.p4, c.fid FROM r JOIN kc c ON c.p4 = r.p4", byId(page),
          "kp.p2 = r.p2 AND kp.p3 = r.p3 AND kp.p4 = r.p4 JOIN kc c ON c.p4 = r.p4", "c.n")
    val pageKeys = if filter == null then "r.p2, r.p3" else "r.p2, r.p3, r.p4"
    val pages =
      s"""${counts}kp AS MATERIALIZED (
         |  SELECT $pageKeys, x.id FROM ($keys) r LEFT JOIN LATERAL ($pageSql) x ON true),
         |p AS MATERIALIZED (
         |  SELECT r.i, r.p1, $countSql AS n, kp.id
         |  FROM r JOIN kp ON $ofRequest),""".stripMargin
    // In a round's plan each distinct page's ids are one array, newest first, that its requests share: no row per
    // request and article, nor an aggregate per request putting them back together (as rows, the global list's
    // statement took 40% more time under the load, the filtered lists' 6-8%).
    val pageArrays =
      s"""${counts}kp AS MATERIALIZED (
         |  SELECT $pageKeys, ARRAY($pageSql) AS ids FROM ($keys) r),
         |m AS MATERIALIZED (
         |  SELECT a.id, a.author_id, $Short FROM (SELECT DISTINCT unnest(ids) AS id FROM kp) d JOIN articles a ON a.id = d.id),
         |q AS (SELECT r.i, $countSql AS n, kp.ids FROM r JOIN kp ON $ofRequest)""".stripMargin
    val (shared, viewers, n) =
      if !feed then ("", "r", counted)
      else (
        """vf AS MATERIALIZED (SELECT r.i, fo.followee_id AS f, r.p2 + r.p3 AS d FROM r JOIN follows fo ON fo.follower_id = r.p1),
          |h AS MATERIALIZED (
          |  SELECT x.f,
          |    (SELECT a.id FROM articles a WHERE a.author_id = x.f ORDER BY a.id DESC OFFSET x.d - 1 LIMIT 1) AS floor,
          |    CASE WHEN x.k <= 4 THEN EXISTS (SELECT 1 FROM articles a WHERE a.author_id = x.f OFFSET 999) ELSE false END AS big
          |  FROM (SELECT vf.f, max(vf.d) AS d, row_number() OVER (ORDER BY count(*) DESC, vf.f) AS k
          |    FROM vf GROUP BY vf.f HAVING count(*) >= 2 ORDER BY count(*) DESC, vf.f LIMIT 32) x),
          |fl AS MATERIALIZED (SELECT vf.i, max(h.floor) AS floor, bool_or(h.big) AS big FROM vf JOIN h ON h.f = vf.f GROUP BY vf.i),
          |""".stripMargin,
        "r LEFT JOIN fl ON fl.i = r.i",
        s"CASE WHEN fl.big THEN 1000::int8 ELSE (SELECT $counted) END AS n OFFSET 0",
      )
    val perViewer =
      s"""${shared}p AS MATERIALIZED (
         |  SELECT r.i, r.p1, c.n, x.id FROM $viewers
         |  CROSS JOIN LATERAL (SELECT $n) c
         |  LEFT JOIN LATERAL (${perRequest(single, page)}) x ON true),""".stripMargin
    val ids = if feed then "p" else "kp"
    val b = batched(single, packed = true, sql = from =>
      s"""WITH r AS MATERIALIZED (SELECT * FROM $from),
         |${if feed then perViewer else pages}
         |m AS MATERIALIZED (
         |  SELECT a.id, a.author_id, $Short, COALESCE(tg.names, '{}') AS tag_list, ${favoritesCount("a")} AS favorites_count,
         |    u.username, u.bio, u.image
         |  FROM (SELECT DISTINCT id FROM $ids WHERE id IS NOT NULL) d JOIN articles a ON a.id = d.id JOIN users u ON u.id = a.author_id
         |  LEFT JOIN (
         |    SELECT at.article_id, array_agg(t.name ORDER BY t.name) AS names FROM article_tags at JOIN tags t ON t.id = at.tag_id
         |    WHERE at.article_id IN (SELECT id FROM $ids) GROUP BY at.article_id) tg ON tg.article_id = a.id),
         |q AS (
         |  SELECT p.i, p.p1, p.n, array_agg(m.id ORDER BY m.id DESC) FILTER (WHERE m.id IS NOT NULL) AS ids,
         |    array_agg(m.author_id) FILTER (WHERE m.id IS NOT NULL) AS authors
         |  FROM p LEFT JOIN m ON m.id = p.id GROUP BY p.i, p.p1, p.n)
         |SELECT NULL::int8, m.slug, m.title, m.description, m.created_at, m.updated_at, m.tag_list, m.favorites_count,
         |  m.username, m.bio, m.image, m.id, m.author_id, NULL::int8[], NULL::int8[], NULL::int8[], 0::int8
         |FROM m
         |UNION ALL
         |SELECT q.n, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, q.ids,
         |  ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = q.p1 AND f.article_id = ANY(q.ids)),
         |  $following, q.i
         |FROM q""".stripMargin
    )
    // The feed's pages are per viewer: in a round's plan each one's ids are one array too (as rows, 2% more).
    val feedArrays =
      s"""${shared}q AS MATERIALIZED (
         |  SELECT r.i, c.n, ARRAY(${perRequest(single, page)}) AS ids FROM $viewers
         |  CROSS JOIN LATERAL (SELECT $n) c),
         |m AS MATERIALIZED (
         |  SELECT a.id, a.author_id, $Short FROM (SELECT DISTINCT unnest(ids) AS id FROM q) d JOIN articles a ON a.id = d.id)""".stripMargin
    // In a round's first phase: the same pages and counts, and the rows of their articles; what the articles need
    // besides, the second phase reads once for the round ([[Columns.Plan]]).
    b.plan = overRequests(single, from =>
      s"""WITH r AS MATERIALIZED (SELECT * FROM $from),
         |${if feed then feedArrays else pageArrays}
         |SELECT NULL::int8, m.id, m.author_id, m.slug, m.title, m.description, m.created_at, m.updated_at, NULL::int8[], 0::int8
         |FROM m
         |UNION ALL
         |SELECT q.n, NULL, NULL, NULL, NULL, NULL, NULL, NULL, q.ids, q.i FROM q""".stripMargin
    )
    b

  /** The article pages' first phase in a round ([[Columns.Plan]]): each request's article, with its body, by slug. */
  private def plannedArticles(b: Batch): Unit =
    b.plan = overRequests(b.single, from =>
      s"""SELECT NULL::int8, a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.body, r.i
         |FROM $from JOIN articles a ON a.slug = r.p2""".stripMargin
    )

  // -- A round's second phase ([[Api.RoundPlan]]): once for the round, what its first phase's articles need --------

  /** Each article's tag ids (named from [[PlanTags]]) and favorites count. */
  val PlanArticles: Statement = statement(
    """SELECT r.id, ARRAY(SELECT at.tag_id::int8 FROM article_tags at WHERE at.article_id = r.id),
      |  (SELECT count(*) FROM favorites f WHERE f.article_id = r.id)
      |FROM unnest($1::int8[]) AS r(id)""".stripMargin,
    Int8Array,
  )

  /** Each distinct author's profile: id, username, bio, image. */
  val PlanAuthors: Statement = statement(
    "SELECT u.id, u.username, u.bio, u.image FROM unnest($1::int8[]) AS r(id) JOIN users u ON u.id = r.id",
    Int8Array,
  )

  /** Every tag in name order, the order of an article's `tagList`: after [[PlanArticles]], so that every tag it named
    * is here (an article's tags are inserted after the tags).
    */
  val PlanTags: Statement = statement("SELECT id, name FROM tags ORDER BY name")

  /** Of each viewer `$1`'s articles, those the viewer favorited, as (0, viewer, article), and of each viewer `$5`'s
    * authors, those the viewer follows, as (1, viewer, author): one scan of the primary key per viewer for its own
    * (`= ANY`), not a probe per pair. A viewer's articles are its slice of `$4`, from `$2` to `$3` (1-based, inclusive),
    * and its authors its slice of `$8`, from `$6` to `$7`: the server groups the pairs ([[PairSlices]]), where an
    * `array_agg` per viewer here cost Postgres half again as much.
    */
  val PlanFlags: Statement = statement(
    """SELECT 0::int8, x.v, f.article_id
      |FROM unnest($1::int8[], $2::int8[], $3::int8[]) AS x(v, s, e)
      |CROSS JOIN LATERAL (SELECT f.article_id FROM favorites f
      |  WHERE f.user_id = x.v AND f.article_id = ANY(($4::int8[])[x.s::int4 : x.e::int4])) f
      |UNION ALL
      |SELECT 1::int8, y.v, fo.followee_id
      |FROM unnest($5::int8[], $6::int8[], $7::int8[]) AS y(v, s, e)
      |CROSS JOIN LATERAL (SELECT fo.followee_id FROM follows fo
      |  WHERE fo.follower_id = y.v AND fo.followee_id = ANY(($8::int8[])[y.s::int4 : y.e::int4])) fo""".stripMargin,
    Int8Array, Int8Array, Int8Array, Int8Array, Int8Array, Int8Array, Int8Array, Int8Array,
  )

  /** The comments' batch, packed ([[Columns.PackedComments]]): each distinct article's comments read once, newest
    * first, as rows of their own; then a row per request whose article exists, with the article's id and, of its
    * comments' authors, those the viewer follows (one probe for them all). A request without a row has no such article.
    * Repeats are rare in a batch, but they are the hottest articles, whose threads are the longest: read per request,
    * the batches returned 18% more rows than read once per article. Each article's comment authors (`ca`) may repeat:
    * `= ANY` doesn't mind, and `DISTINCT` sorted every comment of the batch for them (2-3% of the statement).
    */
  private def packedComments(single: Statement): Batch =
    batched(single, packed = true, sql = from =>
      s"""WITH r AS MATERIALIZED (SELECT * FROM $from),
         |a AS MATERIALIZED (SELECT a.id, a.slug FROM articles a WHERE a.slug IN (SELECT p2 FROM r)),
         |c AS MATERIALIZED (
         |  SELECT a.id AS article, c.id, c.body, c.created_at, c.updated_at, c.author_id FROM a CROSS JOIN LATERAL (
         |    SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c
         |    WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c),
         |ca AS MATERIALIZED (SELECT c.article, array_agg(c.author_id) AS authors FROM c GROUP BY c.article)
         |(SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, c.article, c.author_id, NULL::int8[], 0::int8
         |  FROM c JOIN users u ON u.id = c.author_id ORDER BY c.article, c.created_at DESC, c.id DESC)
         |UNION ALL
         |SELECT NULL, NULL, NULL, NULL, NULL, NULL, NULL, a.id, NULL,
         |  ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.p1 AND fo.followee_id = ANY(ca.authors)), r.i
         |FROM r JOIN a ON a.slug = r.p2 LEFT JOIN ca ON ca.article = a.id""".stripMargin
    )

  packedList(ListAll, "SELECT 1 FROM articles", paged("SELECT id FROM articles", "id"), full = true)
  packedList(ListByTag, TagCount, TagPage, filter = TagId, full = true)
  packedList(ListByAuthor, AuthorCount, AuthorPage, filter = UserId)
  packedList(ListByFavorited, FavoritedCount, FavoritedPage, filter = UserId)
  packedList(Feed, FeedCount, feedPage(" AND a2.id >= COALESCE(fl.floor, 0)"), feed = true)
  plannedArticles(batch(ArticleBySlug))
  packedComments(Comments)
  batch(Profile)
  shared(Tags)
  batch(CurrentUser)

  /** The kinds of batch, by [[Batch.id]] from 1. */
  def batchKinds: collection.IndexedSeq[Batch] = batches

  private lazy val bySingle: Array[Batch] =
    val a = new Array[Batch](all.length)
    for b <- batches do a(b.single.id) = b
    a

  /** The batch `single`'s requests may share, or null. */
  def batchOf(single: Statement): Batch = bySingle(single.id)

  // -- Merged writes ---------------------------------------------------------------------------------------------

  /** Writes of one kind that go out in one group ([[WriteGroup]]), as one statement over arrays of their parameters,
    * one element per write, each write's rows tagged with its place among them, from 1, in an extra last column. Each
    * statement's own cost (the Bind, the executor's start and end, the protocol's messages) is paid once for the run.
    */
  final class Merge private[Sql] (val id: Int, val single: Statement, val merged: Statement):
    def paramTypes: Array[Int] = single.paramTypes

  private val merges = collection.mutable.ArrayBuffer[Merge]()

  private def merge(single: Statement, sql: String): Merge =
    val params = single.paramTypes.toSeq.map(t => if t == Int8 then Int8Array else TextArray)
    val m = Merge(merges.length + 1, single, statement(sql, params*))
    merges += m
    m

  /** A pair twice in the run inserted once. Their articles are read after the commit ([[ArticleBySlug]]). */
  merge(
    Favorite,
    """INSERT INTO favorites (user_id, article_id)
      |SELECT DISTINCT r.p1, a.id FROM unnest($1::int8[], $2::text[]) AS r(p1, p2) JOIN articles a ON a.slug = r.p2
      |ORDER BY 1, 2 ON CONFLICT DO NOTHING""".stripMargin,
  )
  merge(
    Unfavorite,
    """DELETE FROM favorites f USING unnest($1::int8[], $2::text[]) AS r(p1, p2), articles a
      |WHERE a.slug = r.p2 AND f.user_id = r.p1 AND f.article_id = a.id""".stripMargin,
  )

  /** The users followed, as [[Follow]] returns them: none for a username that doesn't exist. */
  private def followees(write: String) =
    s"""WITH x AS (SELECT r.i, r.p1, u.id, u.username, u.bio, u.image
       |  FROM unnest($$1::int8[], $$2::text[]) WITH ORDINALITY AS r(p1, p2, i) JOIN users u ON u.username = r.p2),
       |w AS ($write)
       |SELECT x.username, x.bio, x.image, x.i FROM x""".stripMargin
  merge(Follow, followees("INSERT INTO follows (follower_id, followee_id) SELECT DISTINCT p1, id FROM x ORDER BY 1, 2 ON CONFLICT DO NOTHING"))
  merge(Unfollow, followees("DELETE FROM follows fo USING x WHERE fo.follower_id = x.p1 AND fo.followee_id = x.id"))

  /** The comments, as [[CreateComment]] returns them, their ids drawn in the writes' order: comments made in one
    * transaction share `created_at`, and a list puts the newer id first.
    */
  merge(
    CreateComment,
    """WITH x AS MATERIALIZED (
      |  SELECT s.i, s.p1, s.p3, s.article, nextval(pg_get_serial_sequence('comments', 'id')) AS id
      |  FROM (SELECT r.i, r.p1, r.p3, a.id AS article
      |    FROM unnest($1::int8[], $2::text[], $3::text[]) WITH ORDINALITY AS r(p1, p2, p3, i) JOIN articles a ON a.slug = r.p2
      |    ORDER BY r.i OFFSET 0) s),
      |c AS (INSERT INTO comments (id, article_id, author_id, body) SELECT id, article, p1, p3 FROM x
      |  RETURNING id, body, created_at, updated_at, author_id)
      |SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, x.i
      |FROM c JOIN x ON x.id = c.id JOIN users u ON u.id = c.author_id""".stripMargin,
  )

  private lazy val mergeBySingle: Array[Merge] =
    val a = new Array[Merge](all.length)
    for m <- merges do a(m.single.id) = m
    a

  /** How the writes of `single`'s kind merge, or null. */
  def mergeOf(single: Statement): Merge = mergeBySingle(single.id)

/** Where the article columns start in each statement's rows. */
object Columns:
  /** The capped count, then the article without its body. */
  val ListArticle = 1
  /** The article with its body. */
  val FullArticle = 0
  /** After the author's id. */
  val UpdatedArticle = 1

  /** A packed list batch's rows ([[Sql]]'s `packedList`): an article's (the last column 0) has its columns from
    * [[Article]] on without `favorited` and `following`, then [[Id]] and [[Author]]; a request's has [[Count]],
    * [[Ids]], [[Favorited]] and [[Following]].
    */
  object Packed:
    val Count = 0
    /** slug, title, description, created_at, updated_at, tag_list, favorites_count, username, bio, image. */
    val Article = 1
    val Id = 11
    val Author = 12
    val Ids = 13
    val Favorited = 14
    val Following = 15

  /** A round's first phase's rows (`Batch.plan`): an article's, the last column 0, or an article page's, with its
    * request's place there, has [[Id]], [[Author]] and the columns from [[Slug]] (slug, title, description,
    * created_at, updated_at), and an article page's its body in [[Ids]]; a list request's has [[Count]] and [[Ids]],
    * its page's ids newest first (null for an empty page).
    */
  object Plan:
    val Count = 0
    val Id = 1
    val Author = 2
    val Slug = 3
    val CreatedAt = 6
    val Ids = 8
    val Request = 9

  /** A packed comments batch's rows (`packedComments`): a comment's (the last column 0) has its columns from
    * [[Comment]] on, then [[Article]] and [[Author]]; a request's has [[Article]] and [[Following]].
    */
  object PackedComments:
    /** id, body, created_at, updated_at, username, bio, image: what [[Render.comment]] reads. */
    val Comment = 0
    val Article = 7
    val Author = 8
    val Following = 9

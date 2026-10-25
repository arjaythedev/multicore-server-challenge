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
  *   - tag names by primary key, one probe per tag, instead of a join the generic plan hashes all tags for.
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
    s"""ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = $a.id ORDER BY 1),
       |(SELECT count(*) FROM favorites f WHERE f.article_id = $a.id),
       |EXISTS (SELECT 1 FROM favorites f WHERE f.user_id = $viewer AND f.article_id = $a.id),
       |u.username, u.bio, u.image,
       |${if following.nonEmpty then following else s"EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $viewer AND fo.followee_id = $a.author_id)"}""".stripMargin

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

  // $4 tag
  val ListByTag: Statement = statement(
    list(
      "SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4)",
      paged("SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4)", "id"),
      rows = false,
    ),
    Int8, Int8, Int8, Text,
  )

  // $4 author's username
  val ListByAuthor: Statement = statement(
    list(
      "SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $4)",
      paged(s"SELECT $PageColumns FROM articles WHERE author_id = (SELECT u.id FROM users u WHERE u.username = $$4)", "id"),
      rows = true,
    ),
    Int8, Int8, Int8, Text,
  )

  // $4 the username whose favorites these are
  val ListByFavorited: Statement = statement(
    list(
      "SELECT 1 FROM favorites f WHERE f.user_id = (SELECT u.id FROM users u WHERE u.username = $4)",
      paged("SELECT f.article_id AS id FROM favorites f WHERE f.user_id = (SELECT u.id FROM users u WHERE u.username = $4)", "id"),
      rows = false,
    ),
    Int8, Int8, Int8, Text,
  )

  /** The viewer's feed: the newest `$2 + $3` of each followed author's articles, merged. The viewer follows every
    * author in it, in the statement's own snapshot, so `following` is true without a probe.
    */
  val Feed: Statement = statement(
    list(
      "SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1)",
      paged(
        """SELECT x.id FROM follows fo CROSS JOIN LATERAL
          |  (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2 + $3)) x
          |WHERE fo.follower_id = $1""".stripMargin,
        "id",
      ),
      rows = false,
      following = "true",
    ),
    Int8, Int8, Int8,
  )

  // $1 viewer, $2 slug
  val ArticleBySlug: Statement = statement(
    s"SELECT $Full, ${tail("a", "$1")} FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = $$2",
    Int8, Text,
  )

  /** `$1` (the viewer) favorites the article with slug `$2`; with [[ArticleBySlug]] after it, in one transaction. */
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

  /** A read whose waiting requests share one statement ([[PgPool]] sends the requests of a kind waiting for a
    * connection together): `batched` runs `single` once per request, in a `LATERAL` subquery over the requests'
    * parameters as arrays, one element per request (`$1` the number of requests when there are none), and tags each
    * request's rows with its place in the batch, from 1, in an extra last column. Much of a small statement's cost is
    * per statement (executor start and end, a transaction, a snapshot, the protocol's messages), not per row.
    *
    * Each request still gets its own execution, in the statement's snapshot, and nothing is shared between requests
    * (rule 5): parts with no parameter depend on the request's place (`r.i > 0`) so that Postgres runs them once per
    * request rather than once per statement, and the session runs without Memoize ([[PgConnection]]), which would hand
    * one request rows cached for another.
    */
  final class Batch private[Sql] (val id: Int, val single: Statement, val batched: Statement):
    def paramTypes: Array[Int] = single.paramTypes

  private val batches = collection.mutable.ArrayBuffer[Batch]()

  private def batch(single: Statement, body: String = null): Batch =
    val types = single.paramTypes
    val inner = (types.length to 1 by -1).foldLeft(if body == null then single.sql else body)((sql, i) => sql.replace("$" + i, s"r.p$i"))
    val (from, params) =
      if types.isEmpty then ("generate_series(1, $1::int8) AS r(i)", Seq(Int4))
      else
        val arrays = types.indices.map(i => s"$$${i + 1}::${if types(i) == Int8 then "int8" else "text"}[]").mkString(", ")
        val columns = types.indices.map(i => s"p${i + 1}").mkString(", ")
        (s"unnest($arrays) WITH ORDINALITY AS r($columns, i)", types.toSeq.map(t => if t == Int8 then Int8Array else TextArray))
    val b = Batch(batches.length + 1, single, statement(s"SELECT q.*, r.i FROM $from CROSS JOIN LATERAL ($inner) q", params*))
    batches += b
    b

  batch(ListAll, list("SELECT 1 FROM articles WHERE r.i > 0", paged(s"SELECT $PageColumns FROM articles", "id"), rows = true))
  batch(ListByTag)
  batch(ListByAuthor)
  batch(ListByFavorited)
  batch(Feed)
  batch(ArticleBySlug)
  batch(Comments)
  batch(Profile)
  batch(Tags, "SELECT name FROM tags WHERE r.i > 0 ORDER BY name")
  batch(CurrentUser)

  /** The kinds of batch, by [[Batch.id]] from 1. */
  def batchKinds: collection.IndexedSeq[Batch] = batches

  private lazy val bySingle: Array[Batch] =
    val a = new Array[Batch](all.length)
    for b <- batches do a(b.single.id) = b
    a

  /** The batch `single`'s requests may share, or null. */
  def batchOf(single: Statement): Batch = bySingle(single.id)

/** Where the article columns start in each statement's rows. */
object Columns:
  /** The capped count, then the article without its body. */
  val ListArticle = 1
  /** The article with its body. */
  val FullArticle = 0
  /** After the author's id. */
  val UpdatedArticle = 1

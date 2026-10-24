package conduit

import cats.effect.IO
import cats.syntax.all.*
import skunk.*
import skunk.codec.all.*
import skunk.data.Arr
import skunk.implicits.*

import java.time.{Instant, ZoneOffset}

/** The reference SQL from SPEC.md as skunk queries and commands, each defined once. Skunk prepares a statement the
  * first time a session runs it and reuses it after that. `viewer` is the caller's user id, or 0.
  */
object Sql:

  final case class UserRow(id: Long, username: String, email: String, bio: Option[String], image: Option[String]):
    def toUser(token: String): User = User(email, token, username, bio, image)

  final case class ArticleRow(
      id: Long,
      slug: String,
      title: String,
      description: String,
      body: Option[String],
      createdAt: Instant,
      updatedAt: Instant,
      tagList: List[String],
      favoritesCount: Long,
      favorited: Boolean,
      username: String,
      bio: Option[String],
      image: Option[String],
      following: Boolean
  ):
    def toArticle: Article = Article(
      slug,
      title,
      description,
      body,
      tagList,
      Timestamp(createdAt),
      Timestamp(updatedAt),
      favorited,
      favoritesCount,
      Profile(username, bio, image, following)
    )

  final case class CommentRow(
      id: Long,
      body: String,
      createdAt: Instant,
      updatedAt: Instant,
      username: String,
      bio: Option[String],
      image: Option[String],
      following: Boolean
  ):
    def toComment: Comment =
      Comment(id, Timestamp(createdAt), Timestamp(updatedAt), body, Profile(username, bio, image, following))

  final case class Page(limit: Int, offset: Int)

  enum Filter:
    case All
    case Tag(name: String)
    case Author(username: String)
    case Favorited(username: String)

  // Codecs

  private val instant: Codec[Instant] = timestamptz.imap(_.toInstant)(_.atOffset(ZoneOffset.UTC))

  private val user: Decoder[UserRow] = (int8 *: text *: text *: text.opt *: text.opt).to[UserRow]

  private val profile: Decoder[Profile] = (text *: text.opt *: text.opt *: bool).to[Profile]

  private val article: Decoder[ArticleRow] =
    (int8 *: text *: text *: text *: text.opt *: instant *: instant *: _text.map(_.flattenTo(List)) *: int8 *: bool *:
      text *: text.opt *: text.opt *: bool).to[ArticleRow]

  private val comment: Decoder[CommentRow] =
    (int8 *: text *: instant *: instant *: text *: text.opt *: text.opt *: bool).to[CommentRow]

  // Fragments

  /** The columns of `ARTICLE_LIST_SELECT`, or of `ARTICLE_FULL_SELECT` with `withBody`, over a row source `a` with the
    * article's columns. Lists read `NULL` for the body they leave out.
    */
  private def articleColumns(withBody: Boolean): Fragment[Long] =
    sql"""SELECT #${articleData(withBody)},
                 EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $int8) AS favorited,
                 u.username, u.bio, u.image,
                 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $int8 AND fo.followee_id = a.author_id)
                   AS following""".contramap[Long](viewer => (viewer, viewer))

  /** The article's own columns, tags and favorite count: the part of the article columns that doesn't depend on who
    * asks.
    */
  private def articleData(withBody: Boolean): String =
    val body = if withBody then "a.body" else "NULL::text"
    s"""a.id, a.slug, a.title, a.description, $body, a.created_at, a.updated_at,
        ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
               WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
        (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count"""

  /** The list columns for the feed. Every article in the feed is by someone the viewer follows: the feed selects them
    * through `follows` in the same statement, so the same snapshot, which makes the `following` EXISTS always true.
    */
  private val feedColumns: Fragment[Long] =
    sql"""SELECT #${articleData(withBody = false)},
                 EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $int8) AS favorited,
                 u.username, u.bio, u.image,
                 true AS following"""

  private val listColumns = articleColumns(withBody = false)

  /** `ARTICLE_LIST_SELECT`. */
  private val listSelect: Fragment[Long] = sql"$listColumns FROM articles a JOIN users u ON u.id = a.author_id"

  private val slugified = "trim(both '-' from lower(regexp_replace"

  // Users and auth

  val insertUser: Query[(String, String, String), UserRow] =
    sql"""INSERT INTO users (username, email, password_hash) VALUES ($text, $text, $text)
          RETURNING id, username, email, bio, image""".query(user)

  val userByEmail: Query[String, (UserRow, String)] =
    sql"SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $text".query(user *: text)

  val userById: Query[Long, UserRow] =
    sql"SELECT id, username, email, bio, image FROM users WHERE id = $int8".query(user)

  val updateUser
      : Query[(Option[String], Option[String], Option[String], Option[String], Option[String], Long), UserRow] =
    sql"""UPDATE users SET email = COALESCE(${text.opt}, email), username = COALESCE(${text.opt}, username),
                 password_hash = COALESCE(${text.opt}, password_hash), bio = COALESCE(${text.opt}, bio),
                 image = COALESCE(${text.opt}, image)
           WHERE id = $int8
          RETURNING id, username, email, bio, image""".query(user)

  // Profiles

  val profileByUsername: Query[(Long, String), Profile] =
    sql"""SELECT u.username, u.bio, u.image,
                 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $int8 AND fo.followee_id = u.id)
            FROM users u WHERE u.username = $text""".query(profile)

  // Writes: one statement each, with data-modifying CTEs. A CTE runs once and to completion whether or not the main
  // query reads it, and the statement is atomic. The main query sees the snapshot from before the CTEs ran, so a
  // read-back adds the CTE's own change where it matters.

  private val followee: Decoder[Profile] =
    (text *: text.opt *: text.opt).map((name, bio, image) => Profile(name, bio, image, following = false))

  /** Follow and return the followee's profile (no row: no such user). Replaces the reference's user lookup + insert. */
  val follow: Query[(Long, String), Profile] =
    sql"""WITH target AS (SELECT id, username, bio, image FROM users WHERE username = $text),
               changed AS (INSERT INTO follows (follower_id, followee_id) SELECT $int8, id FROM target
                           ON CONFLICT DO NOTHING)
          SELECT username, bio, image FROM target"""
      .query(followee)
      .contramap[(Long, String)]((viewer, username) => (username, viewer))

  /** Unfollow and return the profile (no row: no such user). Replaces the reference's user lookup + delete. */
  val unfollow: Query[(Long, String), Profile] =
    sql"""WITH target AS (SELECT id, username, bio, image FROM users WHERE username = $text),
               changed AS (DELETE FROM follows WHERE follower_id = $int8 AND followee_id = (SELECT id FROM target))
          SELECT username, bio, image FROM target"""
      .query(followee)
      .contramap[(Long, String)]((viewer, username) => (username, viewer))

  // Articles

  // Lists: one statement per request. The capped count is the single outer row and the page joins it laterally, so
  // an empty page (an unknown tag, or an offset past the end) still carries the count. This replaces the reference's
  // two statements (page, then count): the same work for Postgres, one exchange less for the app.
  //
  // The global and author pages are also cut page first: the ids come from `articles` alone and only the returned
  // rows are decorated. The reference also decorates every row OFFSET skips (tags, favorite count, following): about
  // 4x the time on page 5. Their inner `LIMIT 100` is a constant on purpose (`limit` is at most 100, so the rows are
  // the same): with `LIMIT $n` the generic plan picks a 2x slower plan for the author list.

  private type Counted = (Long, Option[ArticleRow])

  private val counted: Decoder[Counted] = int8 *: article.opt

  /** The global list. Replaces `ARTICLE_LIST_SELECT ORDER_PAGE` and its count. The capped count asks whether a 1000th
    * article exists (one index probe) and counts only when there are fewer: min(count, 1000) either way.
    */
  private val listAll: Query[(Long, Int, Int), Counted] =
    sql"""SELECT c.total, p.*
            FROM (SELECT CASE WHEN EXISTS (SELECT 1 FROM articles a ORDER BY a.id OFFSET 999) THEN 1000
                              ELSE (SELECT count(*) FROM articles) END) c(total)
            LEFT JOIN LATERAL (
              $listColumns
                FROM (SELECT id, slug, title, description, created_at, updated_at, author_id
                        FROM articles ORDER BY id DESC OFFSET $int4 LIMIT 100) a
                JOIN users u ON u.id = a.author_id
               ORDER BY a.id DESC LIMIT $int4) p ON true
           ORDER BY p.id DESC"""
      .query(counted)
      .contramap[(Long, Int, Int)]((viewer, limit, offset) => (viewer, offset, limit))

  /** The `tag` list (already page first in the reference). Replaces its page and count statements. */
  private val listByTag: Query[(Long, String, Int, Int), Counted] =
    sql"""SELECT c.total, p.*
            FROM (SELECT count(*) FROM (SELECT 1 FROM article_tags at
                    WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $text) LIMIT 1000) s) c(total)
            LEFT JOIN LATERAL (
              $listSelect WHERE a.id IN (SELECT at.article_id FROM article_tags at
                                WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $text)
                                ORDER BY at.article_id DESC LIMIT $int4 OFFSET $int4)) p ON true
           ORDER BY p.id DESC"""
      .query(counted)
      .contramap[(Long, String, Int, Int)]((viewer, tag, limit, offset) => (tag, viewer, tag, limit, offset))

  /** The `author` list, page first. Replaces `ARTICLE_LIST_SELECT WHERE a.author_id = ... ORDER_PAGE` and its count. */
  private val listByAuthor: Query[(Long, String, Int, Int), Counted] =
    sql"""SELECT c.total, p.*
            FROM (SELECT count(*) FROM (SELECT 1 FROM articles a
                    WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $text) LIMIT 1000) s) c(total)
            LEFT JOIN LATERAL (
              $listColumns
                FROM (SELECT id, slug, title, description, created_at, updated_at, author_id
                        FROM articles WHERE author_id = (SELECT au.id FROM users au WHERE au.username = $text)
                       ORDER BY id DESC OFFSET $int4 LIMIT 100) a
                JOIN users u ON u.id = a.author_id
               ORDER BY a.id DESC LIMIT $int4) p ON true
           ORDER BY p.id DESC"""
      .query(counted)
      .contramap[(Long, String, Int, Int)]((viewer, author, limit, offset) => (author, viewer, author, offset, limit))

  /** The `favorited` list (already page first in the reference). Replaces its page and count statements. */
  private val listByFavorited: Query[(Long, String, Int, Int), Counted] =
    sql"""SELECT c.total, p.*
            FROM (SELECT count(*) FROM (SELECT 1 FROM favorites f
                    WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $text) LIMIT 1000) s) c(total)
            LEFT JOIN LATERAL (
              $listSelect WHERE a.id IN (SELECT f.article_id FROM favorites f
                                WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $text)
                                ORDER BY f.article_id DESC LIMIT $int4 OFFSET $int4)) p ON true
           ORDER BY p.id DESC"""
      .query(counted)
      .contramap[(Long, String, Int, Int)]((viewer, user, limit, offset) => (user, viewer, user, limit, offset))

  /** The feed (already page first in the reference). Replaces its page and count statements. The count matches
    * `author_id = ANY(ARRAY(...))` instead of `IN (...)`: the followees are read once, the same set.
    */
  private val feedPage: Query[(Long, Int, Int), Counted] =
    sql"""SELECT c.total, p.*
            FROM (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = ANY (ARRAY(
                    SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $int8)) LIMIT 1000) s) c(total)
            LEFT JOIN LATERAL (
              $feedColumns FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL
                  (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id
                    ORDER BY a2.id DESC LIMIT ($int4::int + $int4::int)) x
                 WHERE fo.follower_id = $int8 ORDER BY x.id DESC LIMIT $int4 OFFSET $int4)) p ON true
           ORDER BY p.id DESC"""
      .query(counted)
      .contramap[(Long, Int, Int)]((viewer, limit, offset) => (viewer, viewer, limit, offset, viewer, limit, offset))

  private def page(rows: List[Counted]): (List[ArticleRow], Long) =
    (rows.flatMap(_._2), rows.headOption.fold(0L)(_._1))

  /** The page and the capped count. Only the first filter given applies. */
  def articles(session: Session[IO], viewer: Long, filter: Filter, p: Page): IO[(List[ArticleRow], Long)] =
    val rows = filter match
      case Filter.All                 => session.execute(listAll)((viewer, p.limit, p.offset))
      case Filter.Tag(name)           => session.execute(listByTag)((viewer, name, p.limit, p.offset))
      case Filter.Author(username)    => session.execute(listByAuthor)((viewer, username, p.limit, p.offset))
      case Filter.Favorited(username) => session.execute(listByFavorited)((viewer, username, p.limit, p.offset))
    rows.map(page)

  def feed(session: Session[IO], viewer: Long, p: Page): IO[(List[ArticleRow], Long)] =
    session.execute(feedPage)((viewer, p.limit, p.offset)).map(page)

  /** `ARTICLE_FULL_SELECT WHERE a.slug = $2` for many (viewer, slug) pairs in one statement, for [[Batcher]]: each pair
    * keeps its position in the arrays (`ord`, from 1), so every request gets back its own row, computed for its own
    * viewer, and a slug without an article gets no row (404).
    */
  val articlesBySlug: Query[(List[Long], List[String]), (Int, ArticleRow)] =
    sql"""SELECT r.ord::int4 - 1, #${articleData(withBody = true)},
                 EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = r.viewer) AS favorited,
                 u.username, u.bio, u.image,
                 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.viewer AND fo.followee_id = a.author_id)
                   AS following
            FROM unnest(${_int8.contramap[List[Long]](Arr(_*))}, ${_text.contramap[List[String]](Arr(_*))})
                   WITH ORDINALITY AS r(viewer, slug, ord)
            JOIN articles a ON a.slug = r.slug
            JOIN users u ON u.id = a.author_id""".query(int4 *: article)

  def articlesBySlug(session: Session[IO])(keys: List[(Long, String)]): IO[Map[Int, ArticleRow]] =
    session.execute(articlesBySlug)((keys.map(_._1), keys.map(_._2))).map(_.toMap)

  /** Create an article with its tags and read it back, in one statement (so in one transaction, as the spec asks).
    * Replaces the reference's five statements (BEGIN, article, tags, article_tags, COMMIT) and the read-back after.
    * Tags are inserted sorted, so concurrent creates lock shared tag rows in the same order. `DO UPDATE` (to the same
    * name) returns the id of a tag that already exists, even one committed after this statement's snapshot, which `DO
    * NOTHING` would skip. A new article has no favorites, and its tags come straight from the insert.
    */
  val createArticle: Query[(Long, String, String, String, List[String]), ArticleRow] =
    sql"""WITH n AS (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id),
               a AS (INSERT INTO articles (id, slug, author_id, title, description, body)
                     SELECT n.id, #$slugified($text, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id, $int8, $text, $text,
                            $text
                       FROM n
                     RETURNING id, slug, title, description, body, created_at, updated_at, author_id),
               t AS (INSERT INTO tags (name) SELECT DISTINCT unnest($_text::text[]) ORDER BY 1
                     ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name
                     RETURNING id, name),
               at AS (INSERT INTO article_tags (article_id, tag_id) SELECT a.id, t.id FROM a, t)
          SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
                 ARRAY(SELECT name FROM t ORDER BY name), 0::int8, false,
                 u.username, u.bio, u.image,
                 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = a.author_id AND fo.followee_id = a.author_id)
            FROM a JOIN users u ON u.id = a.author_id"""
      .query(article)
      .contramap[(Long, String, String, String, List[String])]((author, title, description, body, tags) =>
        (title, author, title, description, body, Arr.fromFoldable(tags))
      )

  /** Update an article the caller owns and read it back. `None`: no such article; `Some((author, None))`: someone
    * else's (nothing changed). Replaces the reference's owner lookup + update + read-back. The read-back decorates the
    * updated row from `RETURNING`; tags and favorites don't change here.
    */
  val updateArticle: Query[(Option[String], Option[String], Option[String], Long, String), (Long, Option[ArticleRow])] =
    sql"""WITH target AS (SELECT id, author_id FROM articles WHERE slug = $text),
               updated AS (
                 UPDATE articles SET title = COALESCE(${text.opt}, title),
                                     description = COALESCE(${text.opt}, description),
                                     body = COALESCE(${text.opt}, body),
                                     slug = CASE WHEN ${text.opt}::text IS NULL THEN slug
                                                 ELSE #$slugified(${text.opt}, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id
                                            END,
                                     updated_at = now()
                  WHERE id = (SELECT id FROM target) AND author_id = $int8
                 RETURNING id, slug, title, description, body, created_at, updated_at, author_id)
          SELECT target.author_id, p.*
            FROM target
            LEFT JOIN LATERAL (
              ${articleColumns(withBody = true)} FROM updated a JOIN users u ON u.id = a.author_id) p ON true"""
      .query(int8 *: article.opt)
      .contramap[(Option[String], Option[String], Option[String], Long, String)](
        (title, description, body, viewer, slug) => (slug, title, description, body, title, title, viewer, viewer)
      )

  /** Delete an article the caller owns. `None`: no such article; otherwise its author (nothing deleted unless it is the
    * caller). Replaces the reference's owner lookup + delete.
    */
  val deleteArticle: Query[(Long, String), Long] =
    sql"""WITH target AS (SELECT id, author_id FROM articles WHERE slug = $text),
               gone AS (DELETE FROM articles WHERE id = (SELECT id FROM target) AND author_id = $int8)
          SELECT author_id FROM target"""
      .query(int8)
      .contramap[(Long, String)]((viewer, slug) => (slug, viewer))

  /** The read-back of a favorite toggle: `ARTICLE_FULL_SELECT` for `target`, with the toggle's own change added to the
    * count (`changed` returns one row if it changed anything) and `favorited` known.
    */
  private def toggledArticle(sign: String, favorited: Boolean): Fragment[Long] =
    sql"""SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
                 ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
                        WHERE at.article_id = a.id ORDER BY t.name),
                 (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) #$sign (SELECT count(*) FROM changed),
                 #${favorited.toString},
                 u.username, u.bio, u.image,
                 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $int8 AND fo.followee_id = a.author_id)
            FROM articles a JOIN users u ON u.id = a.author_id
           WHERE a.id = (SELECT id FROM target)"""

  /** Favorite and read the article back (no row: no such article). Replaces lookup + insert + read-back. */
  val favorite: Query[(Long, String), ArticleRow] =
    sql"""WITH target AS (SELECT id FROM articles WHERE slug = $text),
               changed AS (INSERT INTO favorites (user_id, article_id) SELECT $int8, id FROM target
                           ON CONFLICT DO NOTHING RETURNING 1)
          ${toggledArticle("+", favorited = true)}"""
      .query(article)
      .contramap[(Long, String)]((viewer, slug) => (slug, viewer, viewer))

  /** Unfavorite and read the article back (no row: no such article). Replaces lookup + delete + read-back. */
  val unfavorite: Query[(Long, String), ArticleRow] =
    sql"""WITH target AS (SELECT id FROM articles WHERE slug = $text),
               changed AS (DELETE FROM favorites WHERE user_id = $int8 AND article_id = (SELECT id FROM target)
                           RETURNING 1)
          ${toggledArticle("-", favorited = false)}"""
      .query(article)
      .contramap[(Long, String)]((viewer, slug) => (slug, viewer, viewer))

  // Comments

  /** The article's newest 100 comments for many (viewer, slug) pairs in one statement, for [[Batcher]]. Replaces the
    * reference's article-id lookup followed by the comments query: a pair whose article exists gets its comments,
    * newest first, possibly none (one row without a comment); a pair without an article gets no row at all (404).
    */
  val commentsBySlugs: Query[(List[Long], List[String]), (Int, Option[CommentRow])] =
    sql"""SELECT r.ord::int4 - 1, c.*
            FROM unnest(${_int8.contramap[List[Long]](Arr(_*))}, ${_text.contramap[List[String]](Arr(_*))})
                   WITH ORDINALITY AS r(viewer, slug, ord)
            JOIN articles a ON a.slug = r.slug
            LEFT JOIN LATERAL (
              SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
                     EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.viewer AND fo.followee_id = c.author_id)
                FROM comments c JOIN users u ON u.id = c.author_id
               WHERE c.article_id = a.id
               ORDER BY c.created_at DESC, c.id DESC
               LIMIT 100) c ON true
           ORDER BY r.ord, c.created_at DESC, c.id DESC""".query(int4 *: comment.opt)

  def commentsBySlugs(session: Session[IO])(keys: List[(Long, String)]): IO[Map[Int, List[CommentRow]]] =
    session
      .execute(commentsBySlugs)((keys.map(_._1), keys.map(_._2)))
      .map(_.groupMap(_._1)(_._2).view.mapValues(_.flatten).toMap)

  /** Comment on an article (no row: no such article). Replaces the reference's article lookup + insert. */
  val insertComment: Query[(String, Long, String), CommentRow] =
    sql"""WITH target AS (SELECT id FROM articles WHERE slug = $text),
               c AS (INSERT INTO comments (article_id, author_id, body) SELECT id, $int8, $text FROM target
                     RETURNING id, body, created_at, updated_at, author_id)
          SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, false
            FROM c JOIN users u ON u.id = c.author_id""".query(comment)

  /** Delete a comment the caller wrote. `None`: no such comment on that article; otherwise its author (nothing deleted
    * unless it is the caller). Replaces the reference's owner lookup + delete.
    */
  val deleteComment: Query[(Long, String, Long), Long] =
    sql"""WITH target AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
                           WHERE c.id = $int8 AND a.slug = $text),
               gone AS (DELETE FROM comments WHERE id = (SELECT id FROM target) AND author_id = $int8)
          SELECT author_id FROM target""".query(int8)

  // Tags

  val tags: Query[Void, String] = sql"SELECT name FROM tags ORDER BY name".query(text)

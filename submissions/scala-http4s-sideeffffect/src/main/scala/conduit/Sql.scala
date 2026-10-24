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
    val body = if withBody then "a.body" else "NULL::text"
    sql"""SELECT a.id, a.slug, a.title, a.description, #$body, a.created_at, a.updated_at,
                 ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
                        WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
                 (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
                 EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $int8) AS favorited,
                 u.username, u.bio, u.image,
                 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $int8 AND fo.followee_id = a.author_id)
                   AS following""".contramap[Long](viewer => (viewer, viewer))

  private val listColumns = articleColumns(withBody = false)

  /** `ARTICLE_LIST_SELECT` and `ARTICLE_FULL_SELECT`. */
  private val listSelect: Fragment[Long] = sql"$listColumns FROM articles a JOIN users u ON u.id = a.author_id"
  private val fullSelect: Fragment[Long] =
    sql"${articleColumns(withBody = true)} FROM articles a JOIN users u ON u.id = a.author_id"

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

  val userByUsername: Query[String, (Long, Profile)] =
    sql"SELECT id, username, bio, image FROM users WHERE username = $text"
      .query(int8 *: text *: text.opt *: text.opt)
      .map((id, name, bio, image) => (id, Profile(name, bio, image, following = false)))

  val follow: Command[(Long, Long)] =
    sql"INSERT INTO follows (follower_id, followee_id) VALUES ($int8, $int8) ON CONFLICT DO NOTHING".command

  val unfollow: Command[(Long, Long)] =
    sql"DELETE FROM follows WHERE follower_id = $int8 AND followee_id = $int8".command

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

  /** The global list. Replaces `ARTICLE_LIST_SELECT ORDER_PAGE` and its count. */
  private val listAll: Query[(Long, Int, Int), Counted] =
    sql"""SELECT c.total, p.*
            FROM (SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s) c(total)
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

  /** The feed (already page first in the reference). Replaces its page and count statements. */
  private val feedPage: Query[(Long, Int, Int), Counted] =
    sql"""SELECT c.total, p.*
            FROM (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN
                    (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $int8) LIMIT 1000) s) c(total)
            LEFT JOIN LATERAL (
              $listSelect WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL
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

  val articleBySlug: Query[(Long, String), ArticleRow] = sql"$fullSelect WHERE a.slug = $text".query(article)

  val articleById: Query[(Long, Long), ArticleRow] = sql"$fullSelect WHERE a.id = $int8".query(article)

  /** `$2` (the title) appears twice: once slugified, once as the title. */
  val insertArticle: Query[(Long, String, String, String), Long] =
    sql"""INSERT INTO articles (id, slug, author_id, title, description, body)
          SELECT n.id, #$slugified($text, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id, $int8, $text, $text, $text
            FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
          RETURNING id"""
      .query(int8)
      .contramap[(Long, String, String, String)]((author, title, description, body) =>
        (title, author, title, description, body)
      )

  private val insertTagNames: Command[Arr[String]] =
    sql"INSERT INTO tags (name) SELECT DISTINCT unnest($_text::text[]) ON CONFLICT (name) DO NOTHING".command

  private val insertArticleTags: Command[(Long, Arr[String])] =
    sql"""INSERT INTO article_tags (article_id, tag_id)
          SELECT $int8, t.id FROM tags t WHERE t.name = ANY($_text::text[])""".command

  def insertTags(session: Session[IO], articleId: Long, tags: List[String]): IO[Unit] =
    val names = Arr.fromFoldable(tags)
    session.execute(insertTagNames)(names) *> session.execute(insertArticleTags)((articleId, names)).void

  val articleOwner: Query[String, (Long, Long)] =
    sql"SELECT id, author_id FROM articles WHERE slug = $text".query(int8 *: int8)

  val updateArticle: Command[(Option[String], Option[String], Option[String], Long)] =
    sql"""UPDATE articles SET title = COALESCE(${text.opt}, title), description = COALESCE(${text.opt}, description),
                 body = COALESCE(${text.opt}, body),
                 slug = CASE WHEN ${text.opt}::text IS NULL THEN slug
                             ELSE #$slugified(${text.opt}, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END,
                 updated_at = now()
           WHERE id = $int8""".command
      .contramap[(Option[String], Option[String], Option[String], Long)]((title, description, body, id) =>
        (title, description, body, title, title, id)
      )

  val deleteArticle: Command[Long] = sql"DELETE FROM articles WHERE id = $int8".command

  val articleId: Query[String, Long] = sql"SELECT id FROM articles WHERE slug = $text".query(int8)

  val favorite: Command[(Long, Long)] =
    sql"INSERT INTO favorites (user_id, article_id) VALUES ($int8, $int8) ON CONFLICT DO NOTHING".command

  val unfavorite: Command[(Long, Long)] =
    sql"DELETE FROM favorites WHERE user_id = $int8 AND article_id = $int8".command

  // Comments

  /** The article and its newest 100 comments in one statement: no row means no such article (404), a single row without
    * a comment means no comments. Replaces the reference's article-id lookup followed by the comments query.
    */
  val commentsBySlug: Query[(Long, String), (Long, Option[CommentRow])] =
    sql"""SELECT a.id, c.*
            FROM articles a
            LEFT JOIN LATERAL (
              SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
                     EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $int8 AND fo.followee_id = c.author_id)
                FROM comments c JOIN users u ON u.id = c.author_id
               WHERE c.article_id = a.id
               ORDER BY c.created_at DESC, c.id DESC
               LIMIT 100) c ON true
           WHERE a.slug = $text
           ORDER BY c.created_at DESC, c.id DESC""".query(int8 *: comment.opt)

  val insertComment: Query[(Long, Long, String), CommentRow] =
    sql"""WITH c AS (INSERT INTO comments (article_id, author_id, body) VALUES ($int8, $int8, $text)
                     RETURNING id, body, created_at, updated_at, author_id)
          SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, false
            FROM c JOIN users u ON u.id = c.author_id""".query(comment)

  val commentAuthor: Query[(Long, String), Long] =
    sql"""SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
           WHERE c.id = $int8 AND a.slug = $text""".query(int8)

  val deleteComment: Command[Long] = sql"DELETE FROM comments WHERE id = $int8".command

  // Tags

  val tags: Query[Void, String] = sql"SELECT name FROM tags ORDER BY name".query(text)

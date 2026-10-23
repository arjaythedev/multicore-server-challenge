package conduit

import doobie.*
import doobie.implicits.*
import doobie.postgres.implicits.*

import java.time.Instant

/** The reference SQL from SPEC.md, as doobie fragments and queries. `viewer` is the caller's user id, or 0. */
object Sql:

  final case class UserRow(id: Long, username: String, email: String, bio: Option[String], image: Option[String])
      derives Read:
    def toUser(token: String): User = User(email, token, username, bio, image)

  final case class ArticleRow(
      id: Long,
      slug: String,
      title: String,
      description: String,
      body: Option[String],
      createdAt: Instant,
      updatedAt: Instant,
      tagList: Array[String],
      favoritesCount: Long,
      favorited: Boolean,
      username: String,
      bio: Option[String],
      image: Option[String],
      following: Boolean
  ) derives Read:
    def toArticle: Article = Article(
      slug,
      title,
      description,
      body,
      tagList.toList,
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
  ) derives Read:
    def toComment: Comment =
      Comment(id, Timestamp(createdAt), Timestamp(updatedAt), body, Profile(username, bio, image, following))

  final case class Page(limit: Int, offset: Int)

  /** `ARTICLE_LIST_SELECT`, or `ARTICLE_FULL_SELECT` with `withBody`. Lists read `NULL` for the body they leave out. */
  private def articleSelect(viewer: Long, withBody: Boolean): Fragment =
    val body = if withBody then fr"a.body," else fr"NULL::text,"
    fr"""SELECT a.id, a.slug, a.title, a.description,""" ++ body ++
      fr"""a.created_at, a.updated_at,
           ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
                  WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
           (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
           EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $viewer) AS favorited,
           u.username, u.bio, u.image,
           EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $viewer AND fo.followee_id = a.author_id) AS following
      FROM articles a
      JOIN users u ON u.id = a.author_id"""

  private def orderPage(page: Page): Fragment =
    fr"ORDER BY a.id DESC LIMIT ${page.limit} OFFSET ${page.offset}"

  private def slugify(title: Fragment): Fragment =
    fr"trim(both '-' from lower(regexp_replace(" ++ title ++ fr", '[^A-Za-z0-9]+', '-', 'g')))"

  // Users and auth

  def insertUser(username: String, email: String, hash: String): ConnectionIO[UserRow] =
    sql"""INSERT INTO users (username, email, password_hash) VALUES ($username, $email, $hash)
          RETURNING id, username, email, bio, image""".query[UserRow].unique

  def userByEmail(email: String): ConnectionIO[Option[(UserRow, String)]] =
    sql"SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $email"
      .query[(UserRow, String)]
      .option

  def userById(id: Long): ConnectionIO[Option[UserRow]] =
    sql"SELECT id, username, email, bio, image FROM users WHERE id = $id".query[UserRow].option

  def updateUser(
      id: Long,
      email: Option[String],
      username: Option[String],
      hash: Option[String],
      bio: Option[String],
      image: Option[String]
  ): ConnectionIO[Option[UserRow]] =
    sql"""UPDATE users SET email = COALESCE($email, email), username = COALESCE($username, username),
                 password_hash = COALESCE($hash, password_hash), bio = COALESCE($bio, bio),
                 image = COALESCE($image, image)
           WHERE id = $id
          RETURNING id, username, email, bio, image""".query[UserRow].option

  // Profiles

  def profile(viewer: Long, username: String): ConnectionIO[Option[Profile]] =
    sql"""SELECT u.username, u.bio, u.image,
                 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $viewer AND fo.followee_id = u.id) AS following
            FROM users u WHERE u.username = $username"""
      .query[(String, Option[String], Option[String], Boolean)]
      .map(Profile.apply)
      .option

  def userByUsername(username: String): ConnectionIO[Option[(Long, Profile)]] =
    sql"SELECT id, username, bio, image FROM users WHERE username = $username"
      .query[(Long, String, Option[String], Option[String])]
      .map((id, name, bio, image) => (id, Profile(name, bio, image, following = false)))
      .option

  def follow(viewer: Long, id: Long): ConnectionIO[Int] =
    sql"INSERT INTO follows (follower_id, followee_id) VALUES ($viewer, $id) ON CONFLICT DO NOTHING".update.run

  def unfollow(viewer: Long, id: Long): ConnectionIO[Int] =
    sql"DELETE FROM follows WHERE follower_id = $viewer AND followee_id = $id".update.run

  // Articles

  enum Filter:
    case All
    case Tag(name: String)
    case Author(username: String)
    case Favorited(username: String)

  def articles(viewer: Long, filter: Filter, page: Page): ConnectionIO[List[ArticleRow]] =
    val select = articleSelect(viewer, withBody = false)
    val query = filter match
      case Filter.All       => select ++ orderPage(page)
      case Filter.Tag(name) =>
        select ++ fr"""WHERE a.id IN (SELECT at.article_id FROM article_tags at
                        WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $name)
                        ORDER BY at.article_id DESC LIMIT ${page.limit} OFFSET ${page.offset})
                      ORDER BY a.id DESC"""
      case Filter.Author(username) =>
        select ++ fr"WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $username)" ++ orderPage(page)
      case Filter.Favorited(username) =>
        select ++ fr"""WHERE a.id IN (SELECT f.article_id FROM favorites f
                        WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $username)
                        ORDER BY f.article_id DESC LIMIT ${page.limit} OFFSET ${page.offset})
                      ORDER BY a.id DESC"""
    query.query[ArticleRow].to[List]

  def countArticles(filter: Filter): ConnectionIO[Long] =
    val inner = filter match
      case Filter.All       => fr"SELECT 1 FROM articles a"
      case Filter.Tag(name) =>
        fr"SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $name)"
      case Filter.Author(username) =>
        fr"SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $username)"
      case Filter.Favorited(username) =>
        fr"SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $username)"
    (fr"SELECT count(*) FROM (" ++ inner ++ fr"LIMIT 1000) s").query[Long].unique

  def feed(viewer: Long, page: Page): ConnectionIO[List[ArticleRow]] =
    (articleSelect(viewer, withBody = false) ++
      fr"""WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL
            (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id
              ORDER BY a2.id DESC LIMIT (${page.limit}::int + ${page.offset}::int)) x
           WHERE fo.follower_id = $viewer ORDER BY x.id DESC LIMIT ${page.limit} OFFSET ${page.offset})
          ORDER BY a.id DESC""").query[ArticleRow].to[List]

  def countFeed(viewer: Long): ConnectionIO[Long] =
    sql"""SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN
            (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $viewer) LIMIT 1000) s""".query[Long].unique

  def articleBySlug(viewer: Long, slug: String): ConnectionIO[Option[ArticleRow]] =
    (articleSelect(viewer, withBody = true) ++ fr"WHERE a.slug = $slug").query[ArticleRow].option

  def articleById(viewer: Long, id: Long): ConnectionIO[Option[ArticleRow]] =
    (articleSelect(viewer, withBody = true) ++ fr"WHERE a.id = $id").query[ArticleRow].option

  def insertArticle(author: Long, title: String, description: String, body: String): ConnectionIO[Long] =
    (fr"INSERT INTO articles (id, slug, author_id, title, description, body) SELECT n.id," ++
      slugify(fr"$title") ++
      fr"""|| '-' || n.id, $author, $title, $description, $body
             FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
           RETURNING id""").query[Long].unique

  def insertTags(articleId: Long, tags: List[String]): ConnectionIO[Unit] =
    val names = tags.toArray
    for
      _ <- sql"INSERT INTO tags (name) SELECT DISTINCT unnest($names::text[]) ON CONFLICT (name) DO NOTHING".update.run
      _ <- sql"""INSERT INTO article_tags (article_id, tag_id)
                 SELECT $articleId, t.id FROM tags t WHERE t.name = ANY($names::text[])""".update.run
    yield ()

  def articleOwner(slug: String): ConnectionIO[Option[(Long, Long)]] =
    sql"SELECT id, author_id FROM articles WHERE slug = $slug".query[(Long, Long)].option

  def updateArticle(
      id: Long,
      title: Option[String],
      description: Option[String],
      body: Option[String]
  ): ConnectionIO[Int] =
    (fr"""UPDATE articles SET title = COALESCE($title, title), description = COALESCE($description, description),
                 body = COALESCE($body, body),
                 slug = CASE WHEN $title::text IS NULL THEN slug ELSE""" ++ slugify(fr"$title") ++
      fr"""|| '-' || id END,
                 updated_at = now()
           WHERE id = $id""").update.run

  def deleteArticle(id: Long): ConnectionIO[Int] =
    sql"DELETE FROM articles WHERE id = $id".update.run

  def articleId(slug: String): ConnectionIO[Option[Long]] =
    sql"SELECT id FROM articles WHERE slug = $slug".query[Long].option

  def favorite(viewer: Long, id: Long): ConnectionIO[Int] =
    sql"INSERT INTO favorites (user_id, article_id) VALUES ($viewer, $id) ON CONFLICT DO NOTHING".update.run

  def unfavorite(viewer: Long, id: Long): ConnectionIO[Int] =
    sql"DELETE FROM favorites WHERE user_id = $viewer AND article_id = $id".update.run

  // Comments

  def comments(viewer: Long, articleId: Long): ConnectionIO[List[CommentRow]] =
    sql"""SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
                 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $viewer AND fo.followee_id = c.author_id)
            FROM comments c JOIN users u ON u.id = c.author_id
           WHERE c.article_id = $articleId
           ORDER BY c.created_at DESC, c.id DESC
           LIMIT 100""".query[CommentRow].to[List]

  def insertComment(articleId: Long, author: Long, body: String): ConnectionIO[CommentRow] =
    sql"""WITH c AS (INSERT INTO comments (article_id, author_id, body) VALUES ($articleId, $author, $body)
                     RETURNING id, body, created_at, updated_at, author_id)
          SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, false
            FROM c JOIN users u ON u.id = c.author_id""".query[CommentRow].unique

  def commentAuthor(id: Long, slug: String): ConnectionIO[Option[Long]] =
    sql"""SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
           WHERE c.id = $id AND a.slug = $slug""".query[Long].option

  def deleteComment(id: Long): ConnectionIO[Int] =
    sql"DELETE FROM comments WHERE id = $id".update.run

  // Tags

  val tags: ConnectionIO[List[String]] =
    sql"SELECT name FROM tags ORDER BY name".query[String].to[List]

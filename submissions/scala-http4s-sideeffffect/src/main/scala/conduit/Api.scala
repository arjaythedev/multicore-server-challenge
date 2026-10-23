package conduit

import at.favre.lib.crypto.bcrypt.BCrypt
import cats.effect.IO
import cats.syntax.all.*
import doobie.*
import doobie.implicits.*
import doobie.postgres.sqlstate
import io.circe.{Encoder, Json}
import io.circe.syntax.*
import org.http4s.*
import org.http4s.circe.CirceEntityEncoder.*
import org.http4s.dsl.io.*
import org.typelevel.ci.*

import java.nio.charset.StandardCharsets.UTF_8
import scala.concurrent.ExecutionContext

import Sql.{Filter, Page}

/** The 19 Conduit endpoints.
  *
  * @param db
  *   runs statements in autocommit mode: one round trip each, no BEGIN/COMMIT
  * @param tx
  *   runs a whole program in one transaction (only POST /api/articles needs one)
  * @param bcryptPool
  *   bcrypt runs here, a few threads, so logins can't take over the CPUs the event loop needs
  */
final class Api(db: Transactor[IO], tx: Transactor[IO], jwt: Jwt, bcryptPool: ExecutionContext):

  private val bcryptCost = 10

  // Auth

  private final case class Caller(id: Long, token: String)

  private def now: IO[Long] = IO.realTime.map(_.toSeconds)

  /** `None` when there is no (or an empty) Authorization header; a header that is present must hold a valid token. */
  private def caller(request: Request[IO]): IO[Option[Caller]] =
    request.headers.get(ci"Authorization").map(_.head.value).filter(_.nonEmpty) match
      case None         => IO.none
      case Some(header) =>
        val token = header.stripPrefix("Token ")
        if token.length == header.length then IO.raiseError(ApiError.unauthorized)
        else
          now.flatMap(t =>
            IO.fromOption(jwt.verify(token, t))(ApiError.unauthorized).map(id => Some(Caller(id, token)))
          )

  private def required(request: Request[IO]): IO[Caller] =
    caller(request).flatMap(IO.fromOption(_)(ApiError.unauthorized))

  private def viewer(request: Request[IO]): IO[Long] = caller(request).map(_.fold(0L)(_.id))

  private def sign(id: Long): IO[String] = now.map(jwt.sign(id, _))

  // bcrypt

  private def hash(password: String): IO[String] =
    IO(BCrypt.withDefaults().hashToString(bcryptCost, password.toCharArray)).evalOn(bcryptPool)

  private def verified(password: String, hash: String): IO[Boolean] =
    IO(BCrypt.verifyer().verify(password.getBytes(UTF_8), hash.getBytes(UTF_8)).verified)
      .handleError(_ => false)
      .evalOn(bcryptPool)

  // Helpers

  private def found[A](what: String)(value: Option[A]): IO[A] = IO.fromOption(value)(ApiError.notFound(what))

  private def ok[A: Encoder](key: String, value: A): IO[Response[IO]] = Ok(Json.obj(key -> value.asJson))

  private def created[A: Encoder](key: String, value: A): IO[Response[IO]] = Created(Json.obj(key -> value.asJson))

  private def uniqueViolation[A](io: IO[A]): IO[A] =
    io.exceptSomeSqlState { case sqlstate.class23.UNIQUE_VIOLATION =>
      IO.raiseError(ApiError.invalid("username or email has already been taken"))
    }

  /** `limit` (default 20, 1..100) and `offset` (default 0, >= 0): a parameter that is present, even empty, is checked.
    */
  private def page(request: Request[IO]): IO[Page] =
    def param(name: String, default: Long) =
      request.params.get(name).fold(Some(default))(Body.unsigned)
    (param("limit", 20), param("offset", 0)) match
      case (Some(limit), Some(offset)) if limit >= 1 && limit <= 100 && offset <= Int.MaxValue =>
        IO.pure(Page(limit.toInt, offset.toInt))
      case _ => IO.raiseError(ApiError.invalid("limit must be 1-100 and offset >= 0"))

  private def filter(request: Request[IO]): Filter =
    def present(name: String) = request.params.get(name).filter(_.nonEmpty)
    present("tag")
      .map(Filter.Tag(_))
      .orElse(present("author").map(Filter.Author(_)))
      .orElse(present("favorited").map(Filter.Favorited(_)))
      .getOrElse(Filter.All)

  private def articleById(viewer: Long, id: Long): IO[Article] =
    Sql.articleById(viewer, id).transact(db).flatMap(found("article")).map(_.toArticle)

  /** The article's id, if the caller wrote it: 404 if there is no such article, 403 if it is someone else's. */
  private def owned(caller: Caller, slug: String): IO[Long] =
    Sql.articleOwner(slug).transact(db).flatMap(found("article")).flatMap { (id, author) =>
      IO.raiseUnless(author == caller.id)(ApiError.forbidden).as(id)
    }

  private def setFavorite(request: Request[IO], slug: String, on: Boolean): IO[Response[IO]] =
    for
      caller <- required(request)
      article <- (for
        id <- Sql.articleId(slug).flatMap(_.liftTo[ConnectionIO](ApiError.notFound("article")))
        _ <- if on then Sql.favorite(caller.id, id) else Sql.unfavorite(caller.id, id)
        row <- Sql.articleById(caller.id, id)
      yield row).transact(db).flatMap(found("article"))
      response <- ok("article", article.toArticle)
    yield response

  private def setFollow(request: Request[IO], username: String, on: Boolean): IO[Response[IO]] =
    for
      caller <- required(request)
      profile <- (for
        target <- Sql.userByUsername(username).flatMap(_.liftTo[ConnectionIO](ApiError.notFound("profile")))
        (id, profile) = target
        _ <- if on then Sql.follow(caller.id, id) else Sql.unfollow(caller.id, id)
      yield profile.copy(following = on)).transact(db)
      response <- ok("profile", profile)
    yield response

  val routes: HttpRoutes[IO] = HttpRoutes.of[IO] {

    // Users and auth

    case request @ POST -> Root / "api" / "users" =>
      for
        user <- Body.wrapped(request, "user")
        fields <- IO.fromEither(
          (
            Body.required(user, "username"),
            Body.required(user, "email"),
            Body.required(user, "password").flatMap(Body.hashable)
          ).tupled
        )
        (username, email, password) = fields
        passwordHash <- hash(password)
        row <- uniqueViolation(Sql.insertUser(username, email, passwordHash).transact(db))
        token <- sign(row.id)
        response <- created("user", row.toUser(token))
      yield response

    case request @ POST -> Root / "api" / "users" / "login" =>
      for
        user <- Body.wrapped(request, "user")
        fields <- IO.fromEither((Body.required(user, "email"), Body.required(user, "password")).tupled)
        (email, password) = fields
        row <- Sql.userByEmail(email).transact(db)
        valid <- row.fold(IO.pure(false))((_, passwordHash) => verified(password, passwordHash))
        found <- IO.fromOption(row.filter(_ => valid))(ApiError(Status.Unauthorized, "email or password is invalid"))
        token <- sign(found._1.id)
        response <- ok("user", found._1.toUser(token))
      yield response

    case request @ GET -> Root / "api" / "user" =>
      for
        caller <- required(request)
        row <- Sql.userById(caller.id).transact(db).flatMap(IO.fromOption(_)(ApiError.unauthorized))
        response <- ok("user", row.toUser(caller.token))
      yield response

    case request @ PUT -> Root / "api" / "user" =>
      for
        caller <- required(request)
        user <- Body.wrapped(request, "user")
        fields <- IO.fromEither(
          (
            Body.optionalNonEmpty(user, "email"),
            Body.optionalNonEmpty(user, "username"),
            Body.optionalNonEmpty(user, "password").flatMap(_.traverse(Body.hashable)),
            Body.optional(user, "bio"),
            Body.optional(user, "image")
          ).tupled
        )
        (email, username, password, bio, image) = fields
        passwordHash <- password.traverse(hash)
        row <- uniqueViolation(Sql.updateUser(caller.id, email, username, passwordHash, bio, image).transact(db))
          .flatMap(IO.fromOption(_)(ApiError.unauthorized))
        response <- ok("user", row.toUser(caller.token))
      yield response

    // Profiles

    case request @ GET -> Root / "api" / "profiles" / username =>
      viewer(request)
        .flatMap(Sql.profile(_, username).transact(db))
        .flatMap(found("profile"))
        .flatMap(ok("profile", _))

    case request @ POST -> Root / "api" / "profiles" / username / "follow" => setFollow(request, username, on = true)

    case request @ DELETE -> Root / "api" / "profiles" / username / "follow" => setFollow(request, username, on = false)

    // Articles

    case request @ GET -> Root / "api" / "articles" =>
      for
        viewer <- viewer(request)
        page <- page(request)
        filter = this.filter(request)
        list <- (Sql.articles(viewer, filter, page), Sql.countArticles(filter)).tupled.transact(db)
        response <- Ok(ArticleList(list._1.map(_.toArticle), list._2))
      yield response

    case request @ GET -> Root / "api" / "articles" / "feed" =>
      for
        caller <- required(request)
        page <- page(request)
        list <- (Sql.feed(caller.id, page), Sql.countFeed(caller.id)).tupled.transact(db)
        response <- Ok(ArticleList(list._1.map(_.toArticle), list._2))
      yield response

    case request @ GET -> Root / "api" / "articles" / slug =>
      viewer(request)
        .flatMap(Sql.articleBySlug(_, slug).transact(db))
        .flatMap(found("article"))
        .flatMap(row => ok("article", row.toArticle))

    case request @ POST -> Root / "api" / "articles" =>
      for
        caller <- required(request)
        article <- Body.wrapped(request, "article")
        fields <- IO.fromEither(
          (
            Body.required(article, "title"),
            Body.required(article, "description"),
            Body.required(article, "body"),
            Body.stringList(article, "tagList")
          ).tupled
        )
        (title, description, body, tags) = fields
        id <- Sql
          .insertArticle(caller.id, title, description, body)
          .flatTap(id => Sql.insertTags(id, tags).whenA(tags.nonEmpty))
          .transact(tx)
        article <- articleById(caller.id, id)
        response <- created("article", article)
      yield response

    case request @ PUT -> Root / "api" / "articles" / slug =>
      for
        caller <- required(request)
        article <- Body.wrapped(request, "article")
        fields <- IO.fromEither(
          (
            Body.optionalNonEmpty(article, "title"),
            Body.optionalNonEmpty(article, "description"),
            Body.optionalNonEmpty(article, "body")
          ).tupled
        )
        (title, description, body) = fields
        id <- owned(caller, slug)
        _ <- Sql.updateArticle(id, title, description, body).transact(db)
        updated <- articleById(caller.id, id)
        response <- ok("article", updated)
      yield response

    case request @ DELETE -> Root / "api" / "articles" / slug =>
      for
        caller <- required(request)
        id <- owned(caller, slug)
        _ <- Sql.deleteArticle(id).transact(db)
      yield Response(Status.NoContent)

    // Favorites

    case request @ POST -> Root / "api" / "articles" / slug / "favorite" => setFavorite(request, slug, on = true)

    case request @ DELETE -> Root / "api" / "articles" / slug / "favorite" => setFavorite(request, slug, on = false)

    // Comments

    case request @ GET -> Root / "api" / "articles" / slug / "comments" =>
      for
        viewer <- viewer(request)
        comments <- (for
          id <- Sql.articleId(slug).flatMap(_.liftTo[ConnectionIO](ApiError.notFound("article")))
          rows <- Sql.comments(viewer, id)
        yield rows).transact(db)
        response <- ok("comments", comments.map(_.toComment))
      yield response

    case request @ POST -> Root / "api" / "articles" / slug / "comments" =>
      for
        caller <- required(request)
        comment <- Body.wrapped(request, "comment")
        body <- IO.fromEither(Body.required(comment, "body"))
        row <- (for
          id <- Sql.articleId(slug).flatMap(_.liftTo[ConnectionIO](ApiError.notFound("article")))
          row <- Sql.insertComment(id, caller.id, body)
        yield row).transact(db)
        response <- created("comment", row.toComment)
      yield response

    case request @ DELETE -> Root / "api" / "articles" / slug / "comments" / commentId =>
      for
        caller <- required(request)
        id <- IO.fromOption(Body.unsigned(commentId))(ApiError.notFound("comment"))
        _ <- (for
          author <- Sql.commentAuthor(id, slug).flatMap(_.liftTo[ConnectionIO](ApiError.notFound("comment")))
          _ <- ApiError.forbidden.raiseError[ConnectionIO, Unit].whenA(author != caller.id)
          _ <- Sql.deleteComment(id)
        yield ()).transact(db)
      yield Response(Status.NoContent)

    // Tags

    case GET -> Root / "api" / "tags" => Sql.tags.transact(db).flatMap(ok("tags", _))
  }

  /** Every request gets an answer: unknown paths (and known paths with another method) are 404, errors use the SPEC's
    * shape, and anything unexpected is a 500.
    */
  val app: HttpApp[IO] = HttpApp[IO] { request =>
    routes(request)
      .getOrElseF(IO.raiseError(ApiError.notFound("route")))
      .handleErrorWith {
        case ApiError(status, message) => IO.pure(Response(status).withEntity(ApiError.body(message)))
        case _                         =>
          IO.pure(Response(Status.InternalServerError).withEntity(ApiError.body("internal server error")))
      }
  }

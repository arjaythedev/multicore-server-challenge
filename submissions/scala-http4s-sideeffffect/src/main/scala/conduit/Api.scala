package conduit

import cats.effect.IO
import cats.syntax.all.*
import io.circe.{Encoder, Json}
import io.circe.syntax.*
import org.bouncycastle.crypto.generators.OpenBSDBCrypt
import org.http4s.*
import org.http4s.circe.CirceEntityEncoder.*
import org.http4s.dsl.io.*
import org.typelevel.ci.*
import skunk.SqlState

import java.security.SecureRandom
import scala.concurrent.ExecutionContext

import Sql.{Filter, Page}

/** The 19 Conduit endpoints.
  *
  * @param db
  *   lends a session for reads, or one for requests that write; statements run in autocommit mode (one round trip
  *   each), and only POST /api/articles opens a transaction
  * @param bcryptPool
  *   bcrypt runs here, a few threads, so logins can't take over the CPUs the event loop needs
  */
final class Api(
    db: Db,
    jwt: Jwt,
    bcryptPool: ExecutionContext,
    lookups: Lookups
):

  // Bouncy Castle's bcrypt: about 6% faster than at.favre's on this JVM (median 53.6 vs 56.8 ms per verify at cost
  // 10), and the hashes are the same `$2a$` format both ways.
  private val bcryptCost = 10
  private val random = SecureRandom()

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
    IO {
      val salt = new Array[Byte](16)
      random.nextBytes(salt)
      OpenBSDBCrypt.generate("2a", password.toCharArray, salt, bcryptCost)
    }.evalOn(bcryptPool)

  private def verified(password: String, hash: String): IO[Boolean] =
    IO(OpenBSDBCrypt.checkPassword(hash, password.toCharArray))
      .handleError(_ => false)
      .evalOn(bcryptPool)

  // Helpers

  private def found[A](what: String)(value: Option[A]): IO[A] = IO.fromOption(value)(ApiError.notFound(what))

  private def ok[A: Encoder](key: String, value: A): IO[Response[IO]] = Ok(Json.obj(key -> value.asJson))

  private def created[A: Encoder](key: String, value: A): IO[Response[IO]] = Created(Json.obj(key -> value.asJson))

  private def uniqueViolation[A](io: IO[A]): IO[A] =
    io.recoverWith { case SqlState.UniqueViolation(_) =>
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

  /** 404 if the owner lookup found nothing, 403 if the row belongs to someone else (the statement changed nothing). */
  private def ownedBy(caller: Caller, what: String)(author: Option[Long]): IO[Unit] =
    found(what)(author).flatMap(author => IO.raiseUnless(author == caller.id)(ApiError.forbidden))

  private def setFavorite(request: Request[IO], slug: String, on: Boolean): IO[Response[IO]] =
    for
      caller <- required(request)
      article <- db.write
        .use(_.option(if on then Sql.favorite else Sql.unfavorite)((caller.id, slug)))
        .flatMap(found("article"))
      response <- ok("article", article.toArticle)
    yield response

  private def setFollow(request: Request[IO], username: String, on: Boolean): IO[Response[IO]] =
    for
      caller <- required(request)
      profile <- db.write
        .use(_.option(if on then Sql.follow else Sql.unfollow)((caller.id, username)))
        .flatMap(found("profile"))
      response <- ok("profile", profile.copy(following = on))
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
        row <- uniqueViolation(db.write.use(_.unique(Sql.insertUser)((username, email, passwordHash))))
        token <- sign(row.id)
        response <- created("user", row.toUser(token))
      yield response

    case request @ POST -> Root / "api" / "users" / "login" =>
      for
        user <- Body.wrapped(request, "user")
        fields <- IO.fromEither((Body.required(user, "email"), Body.required(user, "password")).tupled)
        (email, password) = fields
        row <- db.read.use(_.option(Sql.userByEmail)(email))
        valid <- row.fold(IO.pure(false))((_, passwordHash) => verified(password, passwordHash))
        found <- IO.fromOption(row.filter(_ => valid))(ApiError(Status.Unauthorized, "email or password is invalid"))
        token <- sign(found._1.id)
        response <- ok("user", found._1.toUser(token))
      yield response

    case request @ GET -> Root / "api" / "user" =>
      for
        caller <- required(request)
        row <- db.read.use(_.option(Sql.userById)(caller.id)).flatMap(IO.fromOption(_)(ApiError.unauthorized))
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
        row <- uniqueViolation(
          db.write.use(_.option(Sql.updateUser)((email, username, passwordHash, bio, image, caller.id)))
        ).flatMap(IO.fromOption(_)(ApiError.unauthorized))
        response <- ok("user", row.toUser(caller.token))
      yield response

    // Profiles

    case request @ GET -> Root / "api" / "profiles" / username =>
      viewer(request)
        .flatMap(viewer => db.read.use(_.option(Sql.profileByUsername)((viewer, username))))
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
        list <- db.read.use(Sql.articles(_, viewer, filter, page))
        response <- Ok(ArticleList(list._1.map(_.toArticle), list._2))
      yield response

    case request @ GET -> Root / "api" / "articles" / "feed" =>
      for
        caller <- required(request)
        page <- page(request)
        list <- lookups.feed((caller.id, page))
        response <- Ok(ArticleList(list._1.map(_.toArticle), list._2))
      yield response

    case request @ GET -> Root / "api" / "articles" / slug =>
      viewer(request)
        .flatMap(viewer => lookups.article((viewer, slug)))
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
        article <- db.write.use(_.unique(Sql.createArticle)((caller.id, title, description, body, tags)))
        response <- created("article", article.toArticle)
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
        result <- db.write.use(_.option(Sql.updateArticle)((title, description, body, caller.id, slug)))
        _ <- ownedBy(caller, "article")(result.map(_._1))
        updated <- found("article")(result.flatMap(_._2))
        response <- ok("article", updated.toArticle)
      yield response

    case request @ DELETE -> Root / "api" / "articles" / slug =>
      for
        caller <- required(request)
        _ <- db.write.use(_.option(Sql.deleteArticle)((caller.id, slug))).flatMap(ownedBy(caller, "article"))
      yield Response(Status.NoContent)

    // Favorites

    case request @ POST -> Root / "api" / "articles" / slug / "favorite" => setFavorite(request, slug, on = true)

    case request @ DELETE -> Root / "api" / "articles" / slug / "favorite" => setFavorite(request, slug, on = false)

    // Comments

    case request @ GET -> Root / "api" / "articles" / slug / "comments" =>
      for
        viewer <- viewer(request)
        comments <- lookups.comments((viewer, slug)).flatMap(found("article"))
        response <- ok("comments", comments.map(_.toComment))
      yield response

    case request @ POST -> Root / "api" / "articles" / slug / "comments" =>
      for
        caller <- required(request)
        comment <- Body.wrapped(request, "comment")
        body <- IO.fromEither(Body.required(comment, "body"))
        row <- db.write.use(_.option(Sql.insertComment)((slug, caller.id, body))).flatMap(found("article"))
        response <- created("comment", row.toComment)
      yield response

    case request @ DELETE -> Root / "api" / "articles" / slug / "comments" / commentId =>
      for
        caller <- required(request)
        id <- IO.fromOption(Body.unsigned(commentId))(ApiError.notFound("comment"))
        _ <- db.write.use(_.option(Sql.deleteComment)((id, slug, caller.id))).flatMap(ownedBy(caller, "comment"))
      yield Response(Status.NoContent)

    // Tags

    case GET -> Root / "api" / "tags" => db.read.use(_.execute(Sql.tags)).flatMap(ok("tags", _))
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

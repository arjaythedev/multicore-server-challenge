package conduit

import io.circe.{Encoder, Json}
import org.http4s.Status

import java.time.format.DateTimeFormatter
import java.time.{Instant, ZoneOffset}
import scala.util.control.NoStackTrace

/** RFC 3339 in UTC with exactly 3 fractional digits, truncated (not rounded). */
opaque type Timestamp = Instant
object Timestamp:
  private val format = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC)
  def apply(instant: Instant): Timestamp = instant
  given Encoder[Timestamp] = Encoder.encodeString.contramap(format.format)

final case class Profile(username: String, bio: Option[String], image: Option[String], following: Boolean)
    derives Encoder.AsObject

final case class User(email: String, token: String, username: String, bio: Option[String], image: Option[String])
    derives Encoder.AsObject

/** `body` is `None` in lists, which leave the field out (as the current RealWorld spec does). */
final case class Article(
    slug: String,
    title: String,
    description: String,
    body: Option[String],
    tagList: List[String],
    createdAt: Timestamp,
    updatedAt: Timestamp,
    favorited: Boolean,
    favoritesCount: Long,
    author: Profile
)
object Article:
  given Encoder.AsObject[Article] =
    Encoder.AsObject.derived[Article].mapJsonObject(o => if o("body").contains(Json.Null) then o.remove("body") else o)

final case class Comment(id: Long, createdAt: Timestamp, updatedAt: Timestamp, body: String, author: Profile)
    derives Encoder.AsObject

final case class ArticleList(articles: List[Article], articlesCount: Long) derives Encoder.AsObject

/** A failed request, answered as `{"errors":{"body":[message]}}`. */
final case class ApiError(status: Status, message: String) extends Exception(message) with NoStackTrace
object ApiError:
  def unauthorized: ApiError = ApiError(Status.Unauthorized, "unauthorized")
  def forbidden: ApiError = ApiError(Status.Forbidden, "forbidden")
  def notFound(what: String): ApiError = ApiError(Status.NotFound, s"$what not found")
  def invalid(message: String): ApiError = ApiError(Status.UnprocessableContent, message)

  def body(message: String): Json = Json.obj("errors" -> Json.obj("body" -> Json.arr(Json.fromString(message))))

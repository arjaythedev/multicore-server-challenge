package conduit

import cats.effect.IO
import cats.syntax.all.*
import io.circe.{Json, JsonObject, jawn}
import org.http4s.Request

import java.nio.charset.StandardCharsets.UTF_8

/** Request bodies are read as a JSON tree whatever the Content-Type. Strings must be JSON strings (`{"body": 123}` is
  * not coerced to `"123"`). Anything malformed is a 422, and so is a body over 1 MiB (read no further than that).
  */
object Body:
  type Result[A] = Either[ApiError, A]

  private val maxBytes = 1024 * 1024

  /** The object under `key` in the request body: 422 unless the body is `{"key": {...}}`. */
  def wrapped(request: Request[IO], key: String): IO[JsonObject] =
    request.body.take(maxBytes + 1L).compile.to(Array).flatMap { bytes =>
      val inner = for
        _ <- Either.cond(bytes.length <= maxBytes, (), ApiError.invalid("request body is too large"))
        root <- jawn.parseByteArray(bytes).leftMap(_ => ApiError.invalid("malformed JSON body"))
        obj <- root.asObject.toRight(ApiError.invalid("body must be a JSON object"))
        in <- obj(key).flatMap(_.asObject).toRight(ApiError.invalid(s"$key must be an object"))
      yield in
      IO.fromEither(inner)
    }

  /** An optional string field: `None` when absent or `null`; 422 when it isn't a string. */
  def optional(obj: JsonObject, field: String): Result[Option[String]] =
    obj(field).filterNot(_.isNull) match
      case None       => Right(None)
      case Some(json) => json.asString.map(Some(_)).toRight(ApiError.invalid(s"$field must be a string"))

  /** An optional field that, when given, is a non-empty string. */
  def optionalNonEmpty(obj: JsonObject, field: String): Result[Option[String]] =
    optional(obj, field).flatMap {
      case Some("") => Left(ApiError.invalid(s"$field can't be blank"))
      case other    => Right(other)
    }

  /** A required non-empty string field. */
  def required(obj: JsonObject, field: String): Result[String] =
    optionalNonEmpty(obj, field).flatMap(_.toRight(ApiError.invalid(s"$field can't be blank")))

  /** An optional array of non-empty strings: empty when absent or `null`. */
  def stringList(obj: JsonObject, field: String): Result[List[String]] =
    obj(field).filterNot(_.isNull) match
      case None       => Right(Nil)
      case Some(json) =>
        json.asArray
          .toRight(ApiError.invalid(s"$field must be an array"))
          .flatMap(
            _.toList.traverse(nonEmptyString(_).toRight(ApiError.invalid(s"$field must hold non-empty strings")))
          )

  private def nonEmptyString(json: Json): Option[String] = json.asString.filter(_.nonEmpty)

  /** bcrypt uses only the first 72 bytes of a password, so a new password over 72 UTF-8 bytes is a 422: the conformance
    * suite requires it (`users.register.password-over-72-bytes`), and it wins over SPEC's "non-empty string". Logins
    * don't check this; Bouncy Castle truncates to 72 bytes the same way when hashing and verifying.
    */
  def hashable(password: String): Result[String] =
    Either.cond(password.getBytes(UTF_8).length <= 72, password, ApiError.invalid("password is too long"))

  /** ASCII digits only (no sign, no spaces) that fit in a Long. */
  def unsigned(s: String): Option[Long] =
    if s.nonEmpty && s.forall(c => c >= '0' && c <= '9') then s.toLongOption else None

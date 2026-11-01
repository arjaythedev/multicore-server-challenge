package conduit

import io.circe.jawn

import java.nio.charset.StandardCharsets.UTF_8
import java.security.MessageDigest
import java.util.Base64
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import scala.concurrent.duration.*

/** HS256 tokens `{"sub":"<user id>","iat":now,"exp":now + 30 days}`, signed and verified with the JDK's `Mac`. Every
  * request verifies its token again: there is no verification cache (rule 5).
  */
final class Jwt(secret: String):
  private val ttl = 30.days.toSeconds
  private val header = b64.encodeToString("""{"alg":"HS256","typ":"JWT"}""".getBytes(UTF_8))
  private val prototype =
    val mac = Mac.getInstance("HmacSHA256")
    mac.init(SecretKeySpec(secret.getBytes(UTF_8), "HmacSHA256"))
    mac

  private def b64 = Base64.getUrlEncoder.withoutPadding
  private def unb64(s: String): Option[Array[Byte]] =
    try Some(Base64.getUrlDecoder.decode(s))
    catch case _: IllegalArgumentException => None

  // A clone of the initialised Mac is cheap and needs no synchronisation.
  private def hmac(data: String): Array[Byte] =
    prototype.clone().asInstanceOf[Mac].doFinal(data.getBytes(UTF_8))

  def sign(userId: Long, nowSeconds: Long): String =
    val payload = s"""{"sub":"$userId","iat":$nowSeconds,"exp":${nowSeconds + ttl}}"""
    val content = s"$header.${b64.encodeToString(payload.getBytes(UTF_8))}"
    s"$content.${b64.encodeToString(hmac(content))}"

  /** The user id in a valid token: HS256 only, a good signature, `exp` present and in the future, `nbf` (if present)
    * not in the future, and `sub` a string of digits naming a positive id.
    */
  def verify(token: String, nowSeconds: Long): Option[Long] =
    // -1 keeps trailing empty parts, so "h.p.s." is four parts (and rejected), not three.
    token.split("\\.", -1) match
      case Array(h, p, s) =>
        for
          headerJson <- unb64(h).flatMap(bytes => jawn.parseByteArray(bytes).toOption)
          if headerJson.hcursor.get[String]("alg").contains("HS256")
          signature <- unb64(s)
          if MessageDigest.isEqual(signature, hmac(s"$h.$p"))
          claims <- unb64(p).flatMap(bytes => jawn.parseByteArray(bytes).toOption)
          exp <- claims.hcursor.get[Double]("exp").toOption
          if nowSeconds < exp
          if claims.hcursor.downField("nbf").focus.forall(_.asNumber.exists(_.toDouble <= nowSeconds))
          sub <- claims.hcursor.get[String]("sub").toOption
          if sub.nonEmpty && sub.length <= 18 && sub.forall(_.isDigit)
          id = sub.toLong
          if id > 0
        yield id
      case _ => None

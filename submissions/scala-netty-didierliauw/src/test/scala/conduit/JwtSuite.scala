package conduit

import java.nio.charset.StandardCharsets.UTF_8
import java.util.Base64
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

class JwtSuite extends munit.FunSuite:
  private val secret = "multicore-server-challenge"
  private val jwt = Jwt(secret.getBytes(UTF_8))
  private val now = 1_800_000_000L

  private def b64(s: String) = Base64.getUrlEncoder.withoutPadding.encodeToString(s.getBytes(UTF_8))

  private def sign(payload: String, header: String = """{"alg":"HS256","typ":"JWT"}""", key: String = secret): String =
    val input = s"${b64(header)}.${b64(payload)}"
    val mac = Mac.getInstance("HmacSHA256")
    mac.init(SecretKeySpec(key.getBytes(UTF_8), "HmacSHA256"))
    s"$input.${Base64.getUrlEncoder.withoutPadding.encodeToString(mac.doFinal(input.getBytes(UTF_8)))}"

  private def verify(token: String) = jwt.verify("Token " + token, 6, now)

  private def claims(sub: String = "\"42\"", exp: String = (now + 3600).toString) = s"""{"sub":$sub,"iat":${now - 10},"exp":$exp}"""

  test("accepts a valid token: its sub"):
    assertEquals(verify(sign(claims())), 42L)

  test("refuses the conformance suite's bad tokens"):
    for (name, token) <- Seq(
        "garbage" -> "not.a.jwt",
        "wrong secret" -> sign(claims(), key = secret + "-wrong"),
        "expired" -> sign(claims(exp = (now - 10).toString)),
        "expiring now" -> sign(claims(exp = now.toString)),
        "no exp" -> sign(s"""{"sub":"42","iat":$now}"""),
        "numeric sub" -> sign(claims(sub = "42")),
        "non-numeric sub" -> sign(claims(sub = "\"abc\"")),
        "zero sub" -> sign(claims(sub = "\"0\"")),
        "alg none" -> s"${b64("""{"alg":"none","typ":"JWT"}""")}.${b64(claims())}.",
        "alg HS512" -> sign(claims(), header = """{"alg":"HS512","typ":"JWT"}"""),
        "string exp" -> sign(claims(exp = "\"soon\"")),
        "a fourth part" -> (sign(claims()) + ".x"),
      )
    do assertEquals(verify(token), Jwt.Invalid, name)

  test("checks nbf when present"):
    assertEquals(verify(sign(s"""{"sub":"42","exp":${now + 60},"nbf":${now + 10}}""")), Jwt.Invalid)
    assertEquals(verify(sign(s"""{"sub":"42","exp":${now + 60},"nbf":${now - 10}}""")), 42L)

  test("issues tokens with exactly sub, iat and exp, valid for 30 days"):
    val token = jwt.issue(7, now)
    assertEquals(verify(token), 7L)
    val payload = String(Base64.getUrlDecoder.decode(token.split('.')(1)), UTF_8)
    assertEquals(payload, s"""{"sub":"7","iat":$now,"exp":${now + 30 * 24 * 3600}}""")
    assertEquals(token, sign(payload)) // the same signature as an independent HMAC
    assertEquals(jwt.verify("Token " + token, 6, now + 30 * 24 * 3600), Jwt.Invalid)

package conduit.auth

import conduit.platform.HmacSha256
import kotlin.io.encoding.Base64
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

private const val SECRET = "multicore-server-challenge"
private const val NOW = 1_700_000_000L

/** Vectors minted independently: golang-jwt v5.3.1 (what the conformance suite uses) and Python's hmac. */
private object Minted {
    // golang-jwt, claims serialized with sorted keys: {"exp":1702592000,"iat":1700000000,"sub":"100"}
    const val GO_VALID = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3MDI1OTIwMDAsImlhdCI6MTcwMDAwMDAwMCwic3ViIjoiMTAwIn0." +
        "PpiJjlw4qD5Np5mGEkrCB7GB9iGaUaZwLTvgWM5n-Jo"
    const val WRONG_SECRET = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3MDAwMDM2MDAsImlhdCI6MTcwMDAwMDAwMCwic3ViIjoiMTAwIn0." +
        "Cfq9LwKtz6TGu5pyjWEDsxCG5XQKjW7QCc-CRaBJaKk"
    const val EXPIRED = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE2OTkxMzYwMDAsImlhdCI6MTY5NjU0NDAwMCwic3ViIjoiMTAwIn0." +
        "OXLoL1pUTNje5JtgvAnQJoisOgKc1CQwtm9sikTV6hQ"
    const val NO_EXP = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpYXQiOjE3MDAwMDAwMDAsInN1YiI6IjEwMCJ9." +
        "2Cgg9jxMgVQEEAGg4b-VXL9zHs0AUMFZniiPAUZ8TXM"
    const val NUMERIC_SUB = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3MDAwMDM2MDAsImlhdCI6MTcwMDAwMDAwMCwic3ViIjoxMDB9." +
        "BVV0lF4W87B8IRwNUArIc7U76WmUdCgKRpGBfWWFGX0"
    const val NON_NUMERIC_SUB = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3MDAwMDM2MDAsImlhdCI6MTcwMDAwMDAwMCwic3ViIjoiYWJjIn0." +
        "4_OYTqBcePmNrKYOhLiunDvWbk9UZZCHQrbItQG0dtQ"
    const val ALG_NONE = "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJleHAiOjE3MDAwMDM2MDAsImlhdCI6MTcwMDAwMDAwMCwic3ViIjoiMTAwIn0."
    const val HS512 = "eyJhbGciOiJIUzUxMiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3MDAwMDM2MDAsImlhdCI6MTcwMDAwMDAwMCwic3ViIjoiMTAwIn0." +
        "Qb8OIx6TH_ybIxV-hz7cE7vNtzye8FcEBXGq-Ul-kNE5J8cYcnrFUWzjp2QLzKuV8v_wcPKVaZLe2srS7Zzghg"
    const val EXP_NOW = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3MDAwMDAwMDAsImlhdCI6MTcwMDAwMDAwMCwic3ViIjoiMTAwIn0." +
        "Pvfts4BHdu8eIILsi8Ktv8U1CZXYF3cXOB8ianWOKDU"
    const val EXP_NOW_PLUS_1 = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3MDAwMDAwMDEsImlhdCI6MTcwMDAwMDAwMCwic3ViIjoiMTAwIn0." +
        "Cw5AzX12yAj2_ZwJRdoYhQXd6L-yXf_Od6eJnsZGKtg"
    const val EXP_FLOAT = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3MDAwMDAwMDAuNSwic3ViIjoiMTAwIn0." +
        "SDSqowFWKDWrghSan8qvKxL2MWTqdggZvl5pA6RCOgY"
    const val SUB_ZERO = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3MDAwMDM2MDAsImlhdCI6MTcwMDAwMDAwMCwic3ViIjoiMCJ9." +
        "IMDN2FlfpvaASN-VYKWnSsvfxo5OGVeD538SctXG7Qg"
    // extra claim {"name":"Jöhn \"x\" <b>"}: escapes and non-ASCII force the JsonReader path
    const val EXTRA_UNICODE = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3MDAwMDM2MDAsImlhdCI6MTcwMDAwMDAwMCwibmFtZSI6IkrDtmhu" +
        "IFwieFwiIFx1MDAzY2JcdTAwM2UiLCJzdWIiOiIxMDAifQ.G897xsMS8fqKcmjn2xGoec7BqfUslXsug6o3ObWuWno"
    // extra claim {"aud":["a","b"]}: nesting forces the JsonReader path
    const val EXTRA_ARRAY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJhdWQiOlsiYSIsImIiXSwiZXhwIjoxNzAwMDAzNjAwLCJzdWIiOiIxMDAifQ." +
        "4j9XBV023spVUS5SLmt6v3ddPR8zyrvcf8BKX0KtsyU"

    // Python hmac: header {"typ":"JWT","alg":"HS256"}, payload {"sub":"100","exp":1700003600}
    const val REORDERED_HEADER = "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMDAiLCJleHAiOjE3MDAwMDM2MDB9." +
        "sQHqAu0FzFKTxFO6zJxLUmAru4hAqeCi8I53uHR8L5s"
    // valid HS256 MACs, but the header claims another alg
    const val HS512_HEADER_HS256_MAC = "eyJhbGciOiJIUzUxMiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMDAiLCJleHAiOjE3MDAwMDM2MDB9." +
        "sFkisSai_kARWN_rs1bE8VB-NaBXnklEidOv7jPTF0o"
    const val NONE_HEADER_HS256_MAC = "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiIxMDAiLCJleHAiOjE3MDAwMDM2MDB9." +
        "PrCsNqJmxwEIcGzl7k0ZJ9LRsoVXLzySiPEH113tSiA"
}

class JwtTest {
    @BeforeTest
    fun init() = Jwt.init(SECRET)

    /** Signs header.payload with [key]: lets a test build any token, valid MAC included. */
    private fun mint(header: String, payload: ByteArray, key: String = SECRET): String {
        val b64 = Base64.UrlSafe.withPadding(Base64.PaddingOption.ABSENT)
        val signing = b64.encode(header.encodeToByteArray()) + "." + b64.encode(payload)
        val mac = ByteArray(32)
        HmacSha256(key.encodeToByteArray()).mac(signing.encodeToByteArray(), 0, signing.length, mac, 0)
        return signing + "." + b64.encode(mac)
    }

    private fun mint(payload: String) = mint("""{"alg":"HS256","typ":"JWT"}""", payload.encodeToByteArray())

    @Test
    fun signKnownAnswer() {
        // Python: hmac.new(secret, b64url(header) + "." + b64url(payload), sha256)
        assertEquals(
            "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMDAiLCJpYXQiOjE3MDAwMDAwMDAsImV4cCI6MTcwMjU5MjAwMH0." +
                "DvUPI2-_zKseTXPqJT7IQPkQ4oRkIij1_xPRch1Xooo",
            Jwt.sign(100, NOW),
        )
        assertEquals(
            "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI5MDA3MTk5MjU0NzQwOTkzIiwiaWF0IjoxNzAwMDAwMDAwLCJleHAiOjE3MDI1OTIwMDB9." +
                "zvRxQLMZChP-Kfd5BKoAbrwWqurDi6lp7b9S9TSQ4-c",
            Jwt.sign(9_007_199_254_740_993, NOW),
        )
    }

    @Test
    fun roundTrip() {
        for (id in longArrayOf(1, 100, 4242, 999_999_999, 123_456_789_012_345_678)) {
            val t = Jwt.sign(id, NOW)
            assertEquals(id, Jwt.verify(t, NOW))
            assertEquals(id, Jwt.verify(t, NOW + 30L * 24 * 3600 - 1))
            assertEquals(0, Jwt.verify(t, NOW + 30L * 24 * 3600)) // exp is exclusive
        }
        // the payload is exactly the claims the conformance suite checks
        val payload = Base64.UrlSafe.withPadding(Base64.PaddingOption.ABSENT).decode(Jwt.sign(7, NOW).split('.')[1])
        assertEquals("""{"sub":"7","iat":1700000000,"exp":1702592000}""", payload.decodeToString())
    }

    @Test
    fun acceptsTokensFromOtherIssuers() {
        assertEquals(100, Jwt.verify(Minted.GO_VALID, NOW))
        assertEquals(100, Jwt.verify(Minted.REORDERED_HEADER, NOW))
        assertEquals(100, Jwt.verify(Minted.EXP_NOW_PLUS_1, NOW))
        assertEquals(100, Jwt.verify(Minted.EXP_FLOAT, NOW))
        assertEquals(100, Jwt.verify(Minted.EXTRA_UNICODE, NOW))
        assertEquals(100, Jwt.verify(Minted.EXTRA_ARRAY, NOW))
    }

    @Test
    fun rejectsConformanceBadTokens() {
        val bad = mapOf(
            "garbage" to "not.a.jwt",
            "wrong-secret" to Minted.WRONG_SECRET,
            "expired" to Minted.EXPIRED,
            "no-exp" to Minted.NO_EXP,
            "numeric-sub" to Minted.NUMERIC_SUB,
            "non-numeric-sub" to Minted.NON_NUMERIC_SUB,
            "alg-none" to Minted.ALG_NONE,
            "hs512" to Minted.HS512,
            "hs512-header" to Minted.HS512_HEADER_HS256_MAC,
            "none-header" to Minted.NONE_HEADER_HS256_MAC,
            "exp-now" to Minted.EXP_NOW,
            "sub-zero" to Minted.SUB_ZERO,
            "bearer-scheme" to "Bearer " + Minted.GO_VALID,
            "token-scheme" to "Token " + Minted.GO_VALID,
            "leading-space" to " " + Minted.GO_VALID,
            "trailing-space" to Minted.GO_VALID + " ",
            "empty" to "",
            "dots" to "..",
            "four-segments" to Minted.GO_VALID + ".x",
            "two-segments" to Minted.GO_VALID.substringBeforeLast('.'),
            "padded-signature" to Minted.GO_VALID + "=",
            "std-base64-chars" to Minted.GO_VALID.replace('-', '+'),
            "non-ascii" to Minted.GO_VALID.replace("Jo", "Jö"),
            "huge" to "a".repeat(5000) + "." + "b".repeat(5000) + "." + "c".repeat(43),
        )
        for ((name, t) in bad) assertEquals(0L, Jwt.verify(t, NOW), name)
    }

    @Test
    fun rejectsTampering() {
        val t = Jwt.sign(100, NOW)
        val (h, p, s) = t.split('.')
        // flip every character of the payload and signature in turn
        val alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        for (i in p.indices) {
            val c = alphabet[(alphabet.indexOf(p[i]) + 1) % 64]
            assertEquals(0L, Jwt.verify("$h.${p.substring(0, i)}$c${p.substring(i + 1)}.$s", NOW), "payload $i")
        }
        for (i in 0 until s.length - 1) {
            val c = alphabet[(alphabet.indexOf(s[i]) + 1) % 64]
            assertEquals(0L, Jwt.verify("$h.$p.${s.substring(0, i)}$c${s.substring(i + 1)}", NOW), "sig $i")
        }
        // the 43rd char carries 4 MAC bits and 2 unused bits: changing a MAC bit must fail
        val last = alphabet.indexOf(s.last())
        assertEquals(0L, Jwt.verify("$h.$p.${s.dropLast(1)}${alphabet[last xor 4]}", NOW))
        assertEquals(0L, Jwt.verify(mint("{\"sub\":\"100\",\"exp\":1800000000}").substringBeforeLast('.') + "." + s, NOW))
        // a correct MAC under another key
        assertEquals(0L, Jwt.verify(mint("""{"alg":"HS256","typ":"JWT"}""", """{"sub":"1","exp":1800000000}""".encodeToByteArray(), "x"), NOW))
    }

    @Test
    fun claimEdgeCases() {
        fun v(payload: String) = Jwt.verify(mint(payload), NOW)
        assertEquals(42, v(" { \"sub\" : \"42\" ,\n\t\"exp\" : 1700003600 } "))
        assertEquals(7, v("""{"sub":"5","exp":1700003600,"sub":"7"}""")) // last duplicate wins
        assertEquals(0, v("""{"sub":"5","exp":1700003600,"exp":1}"""))
        assertEquals(0, v("""{"sub":"5","exp":1700003600,"sub":5}"""))
        assertEquals(7, v("""{"sub":"007","exp":1700003600}"""))
        assertEquals(123_456_789_012_345_678, v("""{"sub":"123456789012345678","exp":1700003600}"""))
        assertEquals(0, v("""{"sub":"1234567890123456789","exp":1700003600}"""))
        assertEquals(0, v("""{"sub":"+7","exp":1700003600}"""))
        assertEquals(0, v("""{"sub":"-7","exp":1700003600}"""))
        assertEquals(0, v("""{"sub":" 7","exp":1700003600}"""))
        assertEquals(0, v("""{"sub":"","exp":1700003600}"""))
        assertEquals(0, v("""{"sub":null,"exp":1700003600}"""))
        assertEquals(0, v("""{"sub":true,"exp":1700003600}"""))
        assertEquals(0, v("""{"exp":1700003600}"""))
        assertEquals(0, v("""{"sub":"7","exp":"1700003600"}"""))
        assertEquals(0, v("""{"sub":"7","exp":null}"""))
        assertEquals(0, v("""{"sub":"7","exp":-1700003600}"""))
        assertEquals(0, v("""{"sub":"7","exp":1700000000}"""))
        assertEquals(7, v("""{"sub":"7","exp":1700000001}"""))
        assertEquals(7, v("""{"sub":"7","exp":1.7000036e9}"""))
        assertEquals(7, v("""{"sub":"7","exp":17000036000000000000000}"""))
        assertEquals(0, v("""{"sub":"7","exp":1e999}"""))
        assertEquals(0, v("""{"sub":"7","exp":01700003600}"""))
        assertEquals(0, v("""{"sub":"7","exp":1700003600}x"""))
        assertEquals(0, v("""{"sub":"7","exp":1700003600,}"""))
        assertEquals(0, v("""{"sub":"7" "exp":1700003600}"""))
        assertEquals(0, v("""{"sub":"7","exp":1700003600"""))
        assertEquals(0, v("""[{"sub":"7","exp":1700003600}]"""))
        assertEquals(0, v("{}"))
        assertEquals(0, v(""))
        assertEquals(7, v("""{"nbf":1800000000,"iat":1800000000,"sub":"7","exp":1700003600}""")) // not checked
        assertEquals(7, v("{\"s\\u0075b\":\"7\",\"exp\":1700003600}")) // escaped key
        assertEquals(100, v("{\"sub\":\"\\u0031\\u00300\",\"exp\":1700003600}")) // escaped value
        assertEquals(7, v("""{"sub":"7","exp":1700003600,"x":{"y":[1,{"z":null}]}}"""))
        assertEquals(0, v("{\"sub\":\"7\",\"exp\":1700003600,\"x\":\"raw\ttab\"}")) // control char in a string
        // claims that are not valid UTF-8 / not valid JSON at all
        assertEquals(0, Jwt.verify(mint("""{"alg":"HS256","typ":"JWT"}""", byteArrayOf(*"""{"sub":"7","exp":1700003600,"n":"""".encodeToByteArray(), 0xff.toByte(), '"'.code.toByte(), '}'.code.toByte())), NOW))
        assertEquals(7, Jwt.verify(mint("""{"alg":"HS256","typ":"JWT"}""", """{"sub":"7","exp":1700003600,"n":"é"}""".encodeToByteArray()), NOW))
    }

    @Test
    fun headerEdgeCases() {
        val p = """{"sub":"7","exp":1700003600}""".encodeToByteArray()
        assertEquals(7, Jwt.verify(mint("""{"alg":"HS256"}""", p), NOW))
        assertEquals(7, Jwt.verify(mint(""" { "typ" : "JWT" , "alg" : "HS256" , "kid" : "k1" } """, p), NOW))
        assertEquals(0, Jwt.verify(mint("""{"alg":"hs256"}""", p), NOW))
        assertEquals(0, Jwt.verify(mint("""{"alg":"HS384"}""", p), NOW))
        assertEquals(0, Jwt.verify(mint("""{"alg":"none"}""", p), NOW))
        assertEquals(0, Jwt.verify(mint("""{"typ":"JWT"}""", p), NOW))
        assertEquals(0, Jwt.verify(mint("""{"alg":["HS256"]}""", p), NOW))
        assertEquals(0, Jwt.verify(mint("""{"alg":"HS256","alg":"none"}""", p), NOW))
        assertEquals(0, Jwt.verify(mint("""["HS256"]""", p), NOW))
        assertEquals(0, Jwt.verify(mint("""{"alg":"HS256"""", p), NOW))
    }

    @Test
    fun reinitTakesEffectOnThisThread() {
        Jwt.init("other")
        assertEquals(0, Jwt.verify(Minted.GO_VALID, NOW))
        val t = Jwt.sign(5, NOW)
        assertEquals(5, Jwt.verify(t, NOW))
        Jwt.init(SECRET)
        assertEquals(0, Jwt.verify(t, NOW))
        assertTrue(Jwt.verify(Minted.GO_VALID, NOW) == 100L)
    }
}

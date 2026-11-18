module Tests.JwtTests

open System
open System.Buffers.Text
open System.Security.Cryptography
open System.Text
open Xunit
open global.Web

let private secret = "multicore-server-challenge"
let private signer = Jwt.Signer secret
let private now = 1_800_000_000L

let private b64 (s: string) = Base64Url.EncodeToString(Encoding.UTF8.GetBytes s)

/// A token signed with HS256 over arbitrary header/payload JSON (what a foreign minter sends).
let private forge (key: string) (header: string) (payload: string) =
    let input = b64 header + "." + b64 payload
    let mac: byte[] = HMACSHA256.HashData(Encoding.UTF8.GetBytes key, Encoding.ASCII.GetBytes input)
    input + "." + Base64Url.EncodeToString(ReadOnlySpan<byte> mac)

let private hs256 = """{"alg":"HS256","typ":"JWT"}"""

[<Fact>]
let ``a minted token verifies to its user id`` () =
    Assert.Equal(ValueSome 42L, signer.Verify(signer.Mint(42L, now), now))

[<Fact>]
let ``a minted token carries sub as a string, iat and exp thirty days on`` () =
    let payload = signer.Mint(7L, now).Split('.')[1] |> Base64Url.DecodeFromChars |> Encoding.UTF8.GetString
    Assert.Equal($"""{{"sub":"7","iat":{now},"exp":{now + 2592000L}}}""", payload)

[<Fact>]
let ``a token from another minter with the same secret verifies`` () =
    Assert.Equal(ValueSome 5L, signer.Verify(forge secret hs256 $"""{{"sub":"5","exp":{now + 60L}}}""", now))

[<Fact>]
let ``an expired token is refused`` () =
    Assert.Equal(ValueNone, signer.Verify(signer.Mint(1L, now - 31L * 86400L), now))

[<Fact>]
let ``a token without exp is refused`` () =
    Assert.Equal(ValueNone, signer.Verify(forge secret hs256 """{"sub":"5"}""", now))

[<Fact>]
let ``a numeric sub is refused`` () =
    Assert.Equal(ValueNone, signer.Verify(forge secret hs256 $"""{{"sub":5,"exp":{now + 60L}}}""", now))

[<Fact>]
let ``a non-numeric sub is refused`` () =
    Assert.Equal(ValueNone, signer.Verify(forge secret hs256 $"""{{"sub":"abc","exp":{now + 60L}}}""", now))

[<Fact>]
let ``the wrong secret is refused`` () =
    Assert.Equal(ValueNone, signer.Verify(forge (secret + "-wrong") hs256 $"""{{"sub":"5","exp":{now + 60L}}}""", now))

[<Fact>]
let ``alg none is refused even with an empty signature`` () =
    let token = b64 """{"alg":"none","typ":"JWT"}""" + "." + b64 $"""{{"sub":"5","exp":{now + 60L}}}""" + "."
    Assert.Equal(ValueNone, signer.Verify(token, now))

[<Fact>]
let ``another HMAC alg is refused even when correctly signed`` () =
    Assert.Equal(ValueNone, signer.Verify(forge secret """{"alg":"HS512"}""" $"""{{"sub":"5","exp":{now + 60L}}}""", now))

[<Theory>]
[<InlineData("")>]
[<InlineData("not.a.jwt")>]
[<InlineData("garbage")>]
[<InlineData("a.b.c.d")>]
[<InlineData("..")>]
let ``malformed tokens are refused, never thrown`` (token: string) =
    Assert.Equal(ValueNone, signer.Verify(token, now))

[<Fact>]
let ``a tampered payload is refused`` () =
    let parts = signer.Mint(1L, now).Split('.')
    let token = parts[0] + "." + b64 $"""{{"sub":"2","iat":{now},"exp":{now + 60L}}}""" + "." + parts[2]
    Assert.Equal(ValueNone, signer.Verify(token, now))

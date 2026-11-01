/// The JWT shim: HS256 mint and verify, and the only module that touches the secret.
///
/// Every request verifies its token from scratch: signature, `alg`, `sub` and `exp`. Nothing is
/// remembered between requests (rule 5/7).
module Web.Jwt

open System
open System.Buffers.Text
open System.Globalization
open System.Security.Cryptography
open System.Text
open System.Text.Json

let private headerSegment = Base64Url.EncodeToString(Encoding.UTF8.GetBytes """{"alg":"HS256","typ":"JWT"}""")

let private thirtyDays = 30L * 24L * 3600L

type Signer(secret: string) =
    let key = Encoding.UTF8.GetBytes secret

    let sign (signingInput: string) =
        HMACSHA256.HashData(key, Encoding.ASCII.GetBytes signingInput)

    /// `{"sub": "<id>", "iat": now, "exp": now + 30 days}`
    member _.Mint(userId: int64, now: int64) : string =
        let payload = $"""{{"sub":"{userId}","iat":{now},"exp":{now + thirtyDays}}}"""
        let signingInput = headerSegment + "." + Base64Url.EncodeToString(Encoding.UTF8.GetBytes payload)
        signingInput + "." + Base64Url.EncodeToString(sign signingInput)

    /// The user id, or ValueNone for anything but a well-formed, HS256-signed, unexpired token
    /// whose `sub` is a decimal string.
    member _.Verify(token: string, now: int64) : int64 voption =
        let dot1 = token.IndexOf '.'
        let dot2 = if dot1 < 0 then -1 else token.IndexOf('.', dot1 + 1)
        if dot1 <= 0 || dot2 < 0 || token.IndexOf('.', dot2 + 1) >= 0 then
            ValueNone
        else
            try
                let header = Base64Url.DecodeFromChars(token.AsSpan(0, dot1))
                let alg =
                    use doc = JsonDocument.Parse(header)
                    match doc.RootElement.TryGetProperty "alg" with
                    | true, v when v.ValueKind = JsonValueKind.String -> v.GetString()
                    | _ -> null
                if alg <> "HS256" then
                    ValueNone
                else
                    let signature = Base64Url.DecodeFromChars(token.AsSpan(dot2 + 1))
                    if not (CryptographicOperations.FixedTimeEquals(signature, sign (token.Substring(0, dot2)))) then
                        ValueNone
                    else
                        let payload = Base64Url.DecodeFromChars(token.AsSpan(dot1 + 1, dot2 - dot1 - 1))
                        use doc = JsonDocument.Parse(payload)
                        let root = doc.RootElement
                        let sub =
                            match root.TryGetProperty "sub" with
                            | true, v when v.ValueKind = JsonValueKind.String ->
                                match Int64.TryParse(v.GetString(), NumberStyles.None, CultureInfo.InvariantCulture) with
                                | true, id when id > 0L -> ValueSome id
                                | _ -> ValueNone
                            | _ -> ValueNone
                        let unexpired =
                            match root.TryGetProperty "exp" with
                            | true, v when v.ValueKind = JsonValueKind.Number -> v.GetDouble() > float now
                            | _ -> false
                        if unexpired then sub else ValueNone
            with _ ->
                ValueNone

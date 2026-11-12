/// The JWT shim: HS256 mint and verify, and the only module that touches the secret.
///
/// Every request verifies its token from scratch: signature, `alg`, `sub` and `exp`. Nothing is
/// remembered between requests (rule 5/7).
module Web.Jwt

#nowarn "9" // NativePtr.stackalloc: the verify path's stack buffers

open System
open Microsoft.FSharp.NativeInterop
open System.Buffers.Text
open System.Globalization
open System.Security.Cryptography
open System.Text
open System.Text.Json

let private headerSegment = Base64Url.EncodeToString(Encoding.UTF8.GetBytes """{"alg":"HS256","typ":"JWT"}""")

let private thirtyDays = 30L * 24L * 3600L

let private subName = "sub"B
let private expName = "exp"B

/// The user id of a payload whose `sub` is a positive decimal string and whose `exp` is a number
/// after `now`; anything else is ValueNone, and JSON that is not one well-formed object throws.
/// Reads the bytes in place. The last of two members with one name counts, as with JsonDocument.
let private claims (payload: ReadOnlySpan<byte>) (now: int64) : int64 voption =
    let mutable reader = Utf8JsonReader(payload)
    if not (reader.Read()) || reader.TokenType <> JsonTokenType.StartObject then
        ValueNone
    else
        let mutable sub = ValueNone
        let mutable unexpired = false
        while reader.Read() && reader.TokenType = JsonTokenType.PropertyName do
            if reader.ValueTextEquals(ReadOnlySpan<byte> subName) then
                reader.Read() |> ignore
                sub <-
                    if reader.TokenType <> JsonTokenType.String then
                        ValueNone
                    else
                        let mutable id = 0L
                        let parsed =
                            if reader.ValueIsEscaped then
                                Int64.TryParse(reader.GetString(), NumberStyles.None, CultureInfo.InvariantCulture, &id)
                            else
                                Int64.TryParse(reader.ValueSpan, NumberStyles.None, CultureInfo.InvariantCulture, &id)
                        if parsed && id > 0L then ValueSome id else ValueNone
            elif reader.ValueTextEquals(ReadOnlySpan<byte> expName) then
                reader.Read() |> ignore
                unexpired <- reader.TokenType = JsonTokenType.Number && reader.GetDouble() > float now
            else
                reader.Read() |> ignore
            // A value that is an object or an array: past it. (A scalar: nothing to skip.)
            reader.Skip()
        // The object's end, then nothing: one more Read throws on trailing bytes.
        if reader.TokenType <> JsonTokenType.EndObject || reader.Read() then ValueNone
        elif unexpired then sub
        else ValueNone

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
        elif token.Length <= 1024 && token.AsSpan(0, dot1).SequenceEqual(headerSegment.AsSpan()) then
            // The header every minter of this API sends (ours and the SPEC's), so `alg` is HS256
            // without decoding it. Same checks as below, on the stack: nothing is allocated.
            let input = Span<byte>(NativePtr.toVoidPtr (NativePtr.stackalloc<byte> dot2), dot2)
            let mac = Span<byte>(NativePtr.toVoidPtr (NativePtr.stackalloc<byte> 32), 32)
            let decoded = Span<byte>(NativePtr.toVoidPtr (NativePtr.stackalloc<byte> 768), 768)
            try
                Encoding.ASCII.GetBytes(token.AsSpan(0, dot2), input) |> ignore
                HMACSHA256.HashData(ReadOnlySpan<byte> key, Span.op_Implicit input, mac) |> ignore
                let mutable n = 0
                if
                    not (Base64Url.TryDecodeFromChars(token.AsSpan(dot2 + 1), decoded, &n))
                    || not (CryptographicOperations.FixedTimeEquals(Span.op_Implicit (decoded.Slice(0, n)), Span.op_Implicit mac))
                then
                    ValueNone
                elif not (Base64Url.TryDecodeFromChars(token.AsSpan(dot1 + 1, dot2 - dot1 - 1), decoded, &n)) then
                    ValueNone
                else
                    claims (Span.op_Implicit (decoded.Slice(0, n))) now
            with _ ->
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

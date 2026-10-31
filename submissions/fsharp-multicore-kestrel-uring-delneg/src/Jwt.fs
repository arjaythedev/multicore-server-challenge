/// HS256 JWTs: {"sub": "<id>", "iat": now, "exp": now + 30 d}. Every request verifies the signature, alg and exp.
/// Ported from #22 (csharp-sockets-jh-d, MIT).
module Jwt

open System
open System.Buffers
open System.Buffers.Text
open System.Globalization
open System.Security.Cryptography
open System.Text
open System.Text.Json

let mutable private key: byte[] = [||]
let private headerB64 = Encoding.ASCII.GetBytes(Base64Url.EncodeToString(Encoding.ASCII.GetBytes "{\"alg\":\"HS256\",\"typ\":\"JWT\"}"))
let private Ttl = 30L * 24L * 3600L

let init (secret: string) = key <- Encoding.UTF8.GetBytes secret

/// One keyed HMAC per thread: the key setup is reused, every call still hashes the whole signing input.
/// per-thread state (a module cannot hold [<ThreadStatic>] fields)
type private Tls =
    [<ThreadStatic; DefaultValue>]
    static val mutable private hmac: HMACSHA256
    [<ThreadStatic; DefaultValue>]
    static val mutable private scratch: byte[]
    static member Hmac
        with get () = Tls.hmac
        and set v = Tls.hmac <- v
    static member Scratch
        with get () = Tls.scratch
        and set v = Tls.scratch <- v

let private mac (data: ReadOnlySpan<byte>) (dst: Span<byte>) =
    let mutable h = Tls.Hmac
    if isNull h then
        h <- new HMACSHA256(key)
        Tls.Hmac <- h
    h.TryComputeHash(data, dst) |> ignore

let private bSub = "{\"sub\":\""B
let private bIat = "\",\"iat\":"B
let private bExp = ",\"exp\":"B

let private append (dst: Span<byte>) (n: byref<int>) (s: ReadOnlySpan<byte>) =
    s.CopyTo(dst.Slice n)
    n <- n + s.Length

/// A fresh token for the user, as ASCII bytes.
let issue (userId: int64) : byte[] =
    let now = DateTimeOffset.UtcNow.ToUnixTimeSeconds()
    let payload = Array.zeroCreate<byte> 96
    let p = Span payload
    let mutable n = 0
    append p &n (ReadOnlySpan bSub)
    let mutable w = 0
    userId.TryFormat(p.Slice n, &w, ReadOnlySpan.Empty, CultureInfo.InvariantCulture) |> ignore
    n <- n + w
    append p &n (ReadOnlySpan bIat)
    now.TryFormat(p.Slice n, &w, ReadOnlySpan.Empty, CultureInfo.InvariantCulture) |> ignore
    n <- n + w
    append p &n (ReadOnlySpan bExp)
    (now + Ttl).TryFormat(p.Slice n, &w, ReadOnlySpan.Empty, CultureInfo.InvariantCulture) |> ignore
    n <- n + w
    p.[n] <- '}'B
    n <- n + 1
    let tok = Array.zeroCreate<byte> 256
    let t = Span tok
    let mutable k = 0
    append t &k (ReadOnlySpan headerB64)
    t.[k] <- '.'B
    k <- k + 1
    k <- k + Base64Url.EncodeToUtf8(ReadOnlySpan(payload, 0, n), t.Slice k)
    let sg = Array.zeroCreate<byte> 32
    mac (ReadOnlySpan(tok, 0, k)) (Span sg)
    t.[k] <- '.'B
    k <- k + 1
    k <- k + Base64Url.EncodeToUtf8(ReadOnlySpan sg, t.Slice k)
    tok.[0 .. k - 1]

/// a positive user id written in decimal digits only (at most 18); 0 otherwise
let private decimalId (digits: ReadOnlySpan<byte>) =
    if digits.Length = 0 || digits.Length > 18 then 0L
    else
        let mutable id = 0L
        let mutable ok = true
        for c in digits do
            let d = uint32 (c - '0'B)
            if d > 9u then ok <- false else id <- id * 10L + int64 d
        if ok then id else 0L

let private bAlg = "alg"B
let private bHs256 = "HS256"B
let private bSubName = "sub"B
let private bExpName = "exp"B

/// One pass over the top-level members of a JSON object segment. Unused members are skipped; a used member
/// with the wrong type (or an alg other than HS256) makes the token invalid.
let private read (json: ReadOnlySpan<byte>) (header: bool) (algOk: byref<bool>) (sub: byref<int64>) (exp: byref<float>) (hasExp: byref<bool>) =
    let mutable reader = Utf8JsonReader(json)
    try
        if not (reader.Read()) || reader.TokenType <> JsonTokenType.StartObject then false
        else
            let mutable result = false
            let mutable go = true
            while go && reader.Read() do
                if reader.TokenType = JsonTokenType.EndObject then
                    result <- true
                    go <- false
                else
                    let memb =
                        if header then (if reader.ValueTextEquals(ReadOnlySpan bAlg) then 1 else 0)
                        elif reader.ValueTextEquals(ReadOnlySpan bSubName) then 2
                        elif reader.ValueTextEquals(ReadOnlySpan bExpName) then 3
                        else 0
                    if not (reader.Read()) then go <- false
                    else
                        match memb with
                        | 1 ->
                            if reader.TokenType <> JsonTokenType.String || not (reader.ValueTextEquals(ReadOnlySpan bHs256)) then go <- false
                            else algOk <- true
                        | 2 ->
                            if reader.TokenType <> JsonTokenType.String || reader.ValueIsEscaped then go <- false
                            else
                                sub <- decimalId reader.ValueSpan
                                if sub = 0L then go <- false
                        | 3 ->
                            let mutable e = 0.0
                            if reader.TokenType <> JsonTokenType.Number || not (reader.TryGetDouble(&e)) then go <- false
                            else
                                exp <- e
                                hasExp <- true
                        | _ -> reader.Skip()
            result
    with :? JsonException -> false

/// Per-thread scratch for verify: signature, our MAC, decoded segments.

let private segment (b64: ReadOnlySpan<byte>) (into: Span<byte>) (len: byref<int>) =
    let mutable used = 0
    Base64Url.GetMaxDecodedLength b64.Length <= into.Length
    && Base64Url.DecodeFromUtf8(b64, into, &used, &len) = OperationStatus.Done

/// The token as sent after "Token " (ASCII). Returns the user id, or 0 for any invalid token.
let verify (token: ReadOnlySpan<byte>) : int64 =
    if token.Length < 5 || token.Length > 2048 || token.IndexOfAnyExceptInRange('!'B, '~'B) >= 0 then 0L
    else
        let firstDot = token.IndexOf '.'B
        let lastDot = token.LastIndexOf '.'B
        if firstDot < 1 || lastDot <= firstDot + 1 || token.Slice(firstDot + 1, lastDot - firstDot - 1).Contains '.'B then 0L
        else
            if isNull Tls.Scratch then Tls.Scratch <- Array.zeroCreate 2048
            let buf = Tls.Scratch
            // nothing in the token is looked at before its signature checks out
            let sigBytes = Span<byte>(buf, 0, 64)
            let mutable sigCount = 0
            if not (segment (token.Slice(lastDot + 1)) sigBytes &sigCount) || sigCount <> 32 then 0L
            else
                let ours = Span<byte>(buf, 64, 32)
                mac (token.Slice(0, lastDot)) ours
                if not (CryptographicOperations.FixedTimeEquals(ours, Span<byte>(buf, 0, 32))) then 0L
                else
                    let scratch = Span<byte>(buf, 128, 1536)
                    let mutable algOk = false
                    let mutable sub = 0L
                    let mutable exp = 0.0
                    let mutable hasExp = false
                    let mutable hl = 0
                    if not (segment (token.Slice(0, firstDot)) scratch &hl)
                       || not (read (Span<byte>.op_Implicit (scratch.Slice(0, hl))) true &algOk &sub &exp &hasExp) || not algOk then 0L
                    else
                        let mutable cl = 0
                        if not (segment (token.Slice(firstDot + 1, lastDot - firstDot - 1)) scratch &cl)
                           || not (read (Span<byte>.op_Implicit (scratch.Slice(0, cl))) false &algOk &sub &exp &hasExp) || sub = 0L || not hasExp then 0L
                        elif exp > float (DateTimeOffset.UtcNow.ToUnixTimeSeconds()) then sub
                        else 0L

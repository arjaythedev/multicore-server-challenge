/// Tokens (JWT HS256) and passwords (bcrypt, cost 10).
module Auth

#nowarn "9"

open System
open System.Buffers.Text
open System.Collections.Generic
open System.Runtime.InteropServices
open System.Security.Cryptography
open System.Text
open System.Text.Json
open System.Threading

// ---------------- JWT ----------------

let mutable private secret: byte[] = [||]
let init (s: string) = secret <- Encoding.UTF8.GetBytes s

let private header = Base64Url.EncodeToString(Encoding.ASCII.GetBytes """{"alg":"HS256","typ":"JWT"}""")

let nowUnix () = DateTimeOffset.UtcNow.ToUnixTimeSeconds()

/// A fresh token for user id: sub (decimal string), iat now, exp now + 30 days.
let mint (id: int64) : string =
    let now = nowUnix ()
    let payload = sprintf """{"sub":"%d","iat":%d,"exp":%d}""" id now (now + 30L * 86400L)
    let signing = header + "." + Base64Url.EncodeToString(Encoding.ASCII.GetBytes payload)
    let mac = HMACSHA256.HashData(secret, Encoding.ASCII.GetBytes signing)
    signing + "." + Base64Url.EncodeToString mac

let private checkHeader (json: ReadOnlySpan<byte>) =
    let mutable r = Utf8JsonReader(json)
    let mutable ok = false
    let mutable bad = false
    if r.Read() && r.TokenType = JsonTokenType.StartObject then
        while not bad && r.Read() && r.TokenType = JsonTokenType.PropertyName do
            if r.ValueTextEquals "alg"B then
                if r.Read() && r.TokenType = JsonTokenType.String && r.ValueTextEquals "HS256"B then ok <- true
                else bad <- true
            else
                r.Read() |> ignore
                r.Skip()
    ok && not bad

/// sub (decimal string, > 0) if exp (a number) is in the future; else -1
let private checkPayload (json: ReadOnlySpan<byte>) : int64 =
    let mutable r = Utf8JsonReader(json)
    let mutable sub = -1L
    let mutable exp = Double.NaN
    let mutable bad = false
    if r.Read() && r.TokenType = JsonTokenType.StartObject then
        while not bad && r.Read() && r.TokenType = JsonTokenType.PropertyName do
            if r.ValueTextEquals "sub"B then
                if r.Read() && r.TokenType = JsonTokenType.String then
                    let s = r.ValueSpan
                    let mutable v = 0L
                    let mutable consumed = 0
                    if s.Length > 0 && s.Length <= 18 && s.[0] <> '-'B && s.[0] <> '+'B && Utf8Parser.TryParse(s, &v, &consumed) && consumed = s.Length && v > 0L then
                        sub <- v
                    else bad <- true
                else bad <- true
            elif r.ValueTextEquals "exp"B then
                if r.Read() && r.TokenType = JsonTokenType.Number then exp <- r.GetDouble()
                else bad <- true
            else
                r.Read() |> ignore
                r.Skip()
    else bad <- true
    if bad || sub < 0L || Double.IsNaN exp || exp <= float (nowUnix ()) then -1L else sub

/// Verifies "Token <jwt>" bytes: signature, alg = HS256, exp in the future. The user id, or -1.
let verify (token: ReadOnlySpan<byte>) : int64 =
    let d1 = token.IndexOf '.'B
    if d1 <= 0 then -1L
    else
        let rest = token.Slice(d1 + 1)
        let d2 = rest.IndexOf '.'B
        if d2 <= 0 || rest.Slice(d2 + 1).IndexOf '.'B >= 0 then -1L
        else
            let signing = token.Slice(0, d1 + 1 + d2)
            let sig64 = rest.Slice(d2 + 1)
            let mac = Span<byte>(NativeInterop.NativePtr.toVoidPtr (NativeInterop.NativePtr.stackalloc<byte> 32), 32)
            let given = Span<byte>(NativeInterop.NativePtr.toVoidPtr (NativeInterop.NativePtr.stackalloc<byte> 48), 48)
            let mutable gLen = 0
            let mutable consumed = 0
            if sig64.Length <> 43
               || Base64Url.DecodeFromUtf8(sig64, given, &consumed, &gLen) <> Buffers.OperationStatus.Done
               || gLen <> 32 then
                -1L
            else
                HMACSHA256.HashData(ReadOnlySpan secret, signing, mac) |> ignore
                if not (CryptographicOperations.FixedTimeEquals(mac, given.Slice(0, 32))) then -1L
                else
                    let h64 = token.Slice(0, d1)
                    let p64 = rest.Slice(0, d2)
                    let hb = Array.zeroCreate<byte> (Base64Url.GetMaxDecodedLength h64.Length)
                    let pb = Array.zeroCreate<byte> (Base64Url.GetMaxDecodedLength p64.Length)
                    let mutable hl = 0
                    let mutable pl = 0
                    if Base64Url.DecodeFromUtf8(h64, Span hb, &consumed, &hl) <> Buffers.OperationStatus.Done
                       || Base64Url.DecodeFromUtf8(p64, Span pb, &consumed, &pl) <> Buffers.OperationStatus.Done then
                        -1L
                    else
                        try
                            if checkHeader (ReadOnlySpan(hb, 0, hl)) then checkPayload (ReadOnlySpan(pb, 0, pl)) else -1L
                        with _ -> -1L

// ---------------- bcrypt ----------------

[<DllImport("libconduitbc.so", EntryPoint = "bc_crypt")>]
extern int private bc_crypt(int n, int cost, nativeint keys, int[] lens, nativeint salts, nativeint outs)

let private alphabet = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

/// 16 random bytes in bcrypt's base64: the 22-character salt
let newSalt () =
    let raw = RandomNumberGenerator.GetBytes 16
    let sb = StringBuilder(22)
    let mutable acc = 0
    let mutable bits = 0
    for b in raw do
        acc <- ((acc <<< 8) ||| int b) &&& 0xffff
        bits <- bits + 8
        while bits >= 6 do
            bits <- bits - 6
            sb.Append(alphabet.[(acc >>> bits) &&& 63]) |> ignore
    sb.Append(alphabet.[(acc <<< (6 - bits)) &&& 63]) |> ignore
    sb.ToString()

/// One hash to compute. Done runs on a hasher thread with the 31-character result (or null on bad input).
[<AllowNullLiteral>]
type Job(key: byte[], salt: string, cost: int, done': string -> unit) =
    member val Queued = 0L with get, set
    member _.Key = key
    member _.Salt = salt
    member _.Cost = cost
    member _.Done(h: string) = done' h

let private q = Queue<Job>()
let private gate = obj ()
let mutable private lanes = 6
let mutable private waitTicks = 0L
let mutable private fillTo = 4

/// Hashes up to `lanes` passwords in one pass of the multi-lane core. Lanes run in lockstep, so a thread takes
/// a short wait (BCRYPT_WAIT_MS) to fill at least `fillTo` lanes before it starts a sparse batch.
let private hasher (nice: int) () =
    Sys.schedThread ()
    Sys.niceThread nice
    let batch = List<Job>()
    let keys = Array.zeroCreate<nativeint> 6
    let salts = Array.zeroCreate<nativeint> 6
    let outs = Array.zeroCreate<nativeint> 6
    let lens = Array.zeroCreate<int> 6
    let outBufs = Array.init 6 (fun _ -> Marshal.AllocHGlobal 32)
    let saltBufs = Array.init 6 (fun _ -> Marshal.AllocHGlobal 32)
    let keyBufs = Array.init 6 (fun _ -> Marshal.AllocHGlobal 128)
    while true do
        batch.Clear()
        lock gate (fun () ->
            let mutable go = true
            while go do
                if q.Count = 0 then Monitor.Wait gate |> ignore
                elif q.Count >= fillTo then go <- false
                else
                    let age = Diagnostics.Stopwatch.GetTimestamp() - q.Peek().Queued
                    if age >= waitTicks then go <- false
                    else Monitor.Wait(gate, TimeSpan.FromTicks(max 1L ((waitTicks - age) * TimeSpan.TicksPerSecond / Diagnostics.Stopwatch.Frequency))) |> ignore
            let cost = q.Peek().Cost
            while q.Count > 0 && batch.Count < lanes && q.Peek().Cost = cost do
                batch.Add(q.Dequeue())
            if q.Count > 0 then Monitor.Pulse gate)
        let n = batch.Count
        for i in 0 .. n - 1 do
            let j = batch.[i]
            let k = min j.Key.Length 72
            Marshal.Copy(j.Key, 0, keyBufs.[i], k)
            lens.[i] <- k
            keys.[i] <- keyBufs.[i]
            Marshal.Copy(Encoding.ASCII.GetBytes j.Salt, 0, saltBufs.[i], 22)
            salts.[i] <- saltBufs.[i]
            outs.[i] <- outBufs.[i]
        let ok =
            use k = fixed keys
            use s = fixed salts
            use o = fixed outs
            bc_crypt (n, batch.[0].Cost, NativeInterop.NativePtr.toNativeInt k, lens, NativeInterop.NativePtr.toNativeInt s, NativeInterop.NativePtr.toNativeInt o)
        for i in 0 .. n - 1 do
            let h = if ok = 1 then Marshal.PtrToStringAnsi(outBufs.[i], 31) else null
            try batch.[i].Done h with e -> eprintfn "bcrypt callback: %O" e

let private enqueue (j: Job) =
    j.Queued <- Diagnostics.Stopwatch.GetTimestamp()
    lock gate (fun () ->
        q.Enqueue j
        Monitor.Pulse gate)

/// Hashes a new password (cost 10, fresh salt); done gets the full 60-character hash.
let hash (password: byte[]) (done': string -> unit) =
    let salt = newSalt ()
    enqueue (Job(password, salt, 10, (fun h -> done' (if isNull h then null else "$2b$10$" + salt + h))))

/// Verifies a password against a stored $2a$/$2b$/$2y$ hash; done gets the answer.
let verifyPassword (password: byte[]) (stored: string) (done': bool -> unit) =
    if isNull stored || stored.Length <> 60 || stored.[0] <> '$' || stored.[1] <> '2' || stored.[3] <> '$' || stored.[6] <> '$'
       || not (Char.IsDigit stored.[4] && Char.IsDigit stored.[5]) then
        done' false
    else
        let cost = int stored.[4] * 10 + int stored.[5] - 11 * int '0'
        let salt = stored.Substring(7, 22)
        let want = stored.Substring 29
        enqueue (
            Job(password, salt, cost, (fun h ->
                done' (not (isNull h) && CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes h, Encoding.ASCII.GetBytes want))))
        )

/// Starts the hasher threads and checks the core against known answers first.
let start (threads: int) (laneCount: int) (fill: int) (waitMs: int) (nice: int) =
    lanes <- max 1 (min 6 laneCount)
    fillTo <- max 1 (min lanes fill)
    waitTicks <- int64 waitMs * Diagnostics.Stopwatch.Frequency / 1000L
    for i in 1 .. threads do
        Thread(hasher nice, IsBackground = true, Name = sprintf "bcrypt-%d" i).Start()
    let check (pw: string) (h: string) =
        use ev = new ManualResetEventSlim()
        let mutable r = false
        verifyPassword (Encoding.UTF8.GetBytes pw) h (fun ok -> r <- ok; ev.Set())
        ev.Wait()
        if not r then failwithf "bcrypt self-test failed for %s" h
    check "U*U" "$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW"
    check "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789chars after 72 are ignored" "$2a$05$abcdefghijklmnopqrstuu5s2v8.iXieOjg/.AySBTTZIIVFJeBui"

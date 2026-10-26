/// bcrypt cost 10 on dedicated threads. The core is C (native/bcrypt.c, from c-iouring-tigokraft #10, MIT),
/// compiled from source by build.sh: up to 4 independent hashes computed interleaved in one thread (one Blowfish
/// round is a chain of dependent table loads, so one hash leaves most of a core idle). Like group commit, a worker
/// holding one job waits a short while for more before it starts (logins are rare: ~0.1% of requests; idea: #22,
/// #10, #37). A job whose client has gone by then is dropped.
module Bcrypt

#nowarn "9"

open System
open System.Collections.Concurrent
open System.Runtime.InteropServices
open System.Text
open System.Threading
open Microsoft.FSharp.NativeInterop

[<DllImport("libconduitbc.so")>]
extern int bc_batch(int n, nativeint pw, nativeint setting, nativeint out)

[<DllImport("libconduitbc.so")>]
extern bool bc_gensalt(nativeint setting)

/// One hash: the password (UTF-8, at most 72 bytes) and the setting (a fresh salt, or the stored hash to verify).
[<AbstractClass; AllowNullLiteral>]
type Job() =
    member val Pw = Array.zeroCreate<byte> 73 with get
    member val Setting = Array.zeroCreate<byte> 64 with get
    /// the 60-char hash, after the run
    member val Out = Array.zeroCreate<byte> 64 with get
    member val Ok = false with get, set
    /// the client went away: skip the work
    abstract Gone: bool
    /// called on the bcrypt thread when the hash is computed (or failed: Ok = false)
    abstract Completed: unit -> unit

    /// false if the password is longer than 72 bytes
    member j.SetPassword(pw: string) =
        let n = Encoding.UTF8.GetByteCount pw
        if n > 72 then false
        else
            Array.Clear j.Pw
            Encoding.UTF8.GetBytes(pw, 0, pw.Length, j.Pw, 0) |> ignore
            true

    /// a new random "$2b$10$" setting
    member j.NewSalt() =
        Array.Clear j.Setting
        use p = fixed j.Setting
        bc_gensalt (NativePtr.toNativeInt p) |> ignore

    /// the stored hash as the setting; false if it does not fit
    member j.SetStored(hash: ReadOnlySpan<byte>) =
        Array.Clear j.Setting
        if hash.Length > 63 then false
        else
            hash.CopyTo(Span j.Setting)
            true

    /// the computed hash as a string (register / password change)
    member j.HashString() = Encoding.ASCII.GetString(j.Out, 0, 60)

    /// the computed hash equals the stored one (login)
    member j.Matches(stored: ReadOnlySpan<byte>) =
        j.Ok && stored.Length = 60
        && System.Security.Cryptography.CryptographicOperations.FixedTimeEquals(ReadOnlySpan(j.Out, 0, 60), stored)

let private queue = new BlockingCollection<Job>(ConcurrentQueue<Job>())
let private collecting = obj ()
let mutable private waitMs = 150
/// workers hashing right now
let mutable private hashing = 0

let private compute (jobs: Job[]) (n: int) (pw: byte[]) (st: byte[]) (out: byte[]) =
    for l in 0 .. n - 1 do
        Buffer.BlockCopy(jobs.[l].Pw, 0, pw, 73 * l, 73)
        Buffer.BlockCopy(jobs.[l].Setting, 0, st, 64 * l, 64)
    use pp = fixed pw
    use sp = fixed st
    use op = fixed out
    bc_batch (n, NativePtr.toNativeInt pp, NativePtr.toNativeInt sp, NativePtr.toNativeInt op)

let private loop () =
    let batch = Array.zeroCreate<Job> 4
    let pw = Array.zeroCreate<byte> (4 * 73)
    let st = Array.zeroCreate<byte> (4 * 64)
    let out = Array.zeroCreate<byte> (4 * 64)
    let one = Array.zeroCreate<Job> 1
    let gone = System.Collections.Generic.List<Job>()
    while true do
        let mutable n = 0
        Monitor.Enter collecting
        try
            let first = queue.Take()
            if first.Gone then gone.Add first
            else
                batch.[0] <- first
                n <- 1
            // wait for company only when busy: another batch is hashing or more jobs are queued (#79)
            let busy = queue.Count > 0 || Volatile.Read &hashing > 0
            let deadline = Environment.TickCount64 + (if busy then int64 waitMs else 0L)
            let mutable go = true
            while go && n < 4 do
                let left = int (max 0L (deadline - Environment.TickCount64))
                let mutable more: Job = null
                if queue.TryTake(&more, left) then
                    if more.Gone then gone.Add more
                    else
                        batch.[n] <- more
                        n <- n + 1
                else go <- false
        finally
            Monitor.Exit collecting
        if n > 0 then
            Interlocked.Increment &hashing |> ignore
            for l in 0 .. n - 1 do batch.[l].Ok <- false
            let rc = (try compute batch n pw st out with _ -> -1)
            if rc = 0 then
                for l in 0 .. n - 1 do
                    Buffer.BlockCopy(out, 64 * l, batch.[l].Out, 0, 64)
                    batch.[l].Ok <- true
            else
                // settings of different costs or not bcrypt: one by one
                for l in 0 .. n - 1 do
                    one.[0] <- batch.[l]
                    if (try compute one 1 pw st out with _ -> -1) = 0 then
                        Buffer.BlockCopy(out, 0, batch.[l].Out, 0, 64)
                        batch.[l].Ok <- true
            Interlocked.Decrement &hashing |> ignore
            for l in 0 .. n - 1 do
                let j = batch.[l]
                batch.[l] <- null
                try j.Completed() with e -> eprintfn "%O" e
        // a job whose client is gone is not hashed, but still completes (Ok = false) so its request is freed
        for j in gone do
            j.Ok <- false
            try j.Completed() with e -> eprintfn "%O" e
        gone.Clear()

let init (threads: int) (wait: int) =
    waitMs <- wait
    for i in 0 .. max 1 threads - 1 do
        Thread(loop, IsBackground = true, Name = "bcrypt-" + string i).Start()

/// queues a job; Completed runs on a bcrypt thread
let run (j: Job) = queue.Add j

/// Startup self-test: a known hash must verify. Throws if the native core is wrong.
let selfTest () =
    let j =
        { new Job() with
            member _.Gone = false
            member _.Completed() = () }
    // user 1 of the seed: password "password123", cost 10
    let stored = "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq"B
    j.SetPassword "password123" |> ignore
    j.SetStored(ReadOnlySpan stored) |> ignore
    let pw = Array.zeroCreate<byte> 73
    let st = Array.zeroCreate<byte> 64
    let out = Array.zeroCreate<byte> 64
    if compute [| j |] 1 pw st out <> 0 then failwith "bcrypt self-test: setting rejected"
    Buffer.BlockCopy(out, 0, j.Out, 0, 64)
    j.Ok <- true
    if not (j.Matches(ReadOnlySpan stored)) then failwithf "bcrypt self-test failed: %s" (j.HashString())

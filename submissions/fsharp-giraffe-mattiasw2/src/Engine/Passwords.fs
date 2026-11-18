module Engine.Passwords

open System
open System.Collections.Concurrent
open System.Diagnostics
open System.Security.Cryptography
open System.Text
open System.Threading
open System.Threading.Tasks

// bcrypt cost 10 is ~50 ms of an idle core and ~90 ms under load: the largest single share of
// this server's CPU (README). Run on the thread pool it would park request threads and stall the cheap reads
// behind it, so it runs on a few dedicated threads with a queue in front. Each thread computes
// up to `width` hashes in lockstep (Bcrypt: independent chains overlap in the CPU), so a thread
// that picks up a login first waits up to `gather` for batch-mates. Under load the queue
// already holds them and nobody waits.

[<NoEquality; NoComparison>]
type private Job =
    /// Our bcrypt: key, salt, cost, and what to do with the 23 hash bytes.
    | Fast of key: byte[] * salt: byte[] * cost: int * reply: (byte[] -> unit) * fail: (exn -> unit)
    /// A hash Bcrypt does not compute itself (another revision or a malformed one): BCrypt.Net-Next.
    | Other of run: (unit -> unit)

let private work = new BlockingCollection<Job>()
let mutable private hashes = 0L
let mutable private verifies = 0L
let private batches = [| 0L; 0L |] // batches, hashes in them

/// (hashes, verifies) run since start: the proof that bcrypt runs once per sign-up, password
/// change or login, and never on a request that is refused anyway.
let counts () : int64 * int64 = Interlocked.Read &hashes, Interlocked.Read &verifies

/// (lockstep batches, hashes in them) since start.
let lockstep () : int64 * int64 = Volatile.Read &batches[0], Volatile.Read &batches[1]

let mutable private threads = 0
let private gate = obj ()
/// Held by the one thread that is gathering a batch, so batch-mates are not spread one per thread.
let private gathering = obj ()

/// Takes the next batch: a first job (waiting as long as it takes), then up to `width` - 1 more
/// Fast jobs of the same cost, waiting at most `gather` from the first.
let private next (width: int) (gather: TimeSpan) : Job list =
    lock gathering (fun () ->
        let first = work.Take()
        match first with
        | Other _ -> [ first ]
        | Fast(_, _, cost, _, _) ->
            let started = Stopwatch.GetTimestamp()
            let batch = ResizeArray [ first ]
            let mutable go = true
            while go && batch.Count < width do
                let left = gather - Stopwatch.GetElapsedTime started
                let wait = if left.Ticks > 0L then int (Math.Ceiling left.TotalMilliseconds) else 0
                let mutable taken = Unchecked.defaultof<Job>
                if work.TryTake(&taken, wait) then
                    match taken with
                    | Fast(_, _, c, _, _) when c = cost -> batch.Add taken
                    | job ->
                        work.Add job // another cost or a BCrypt.Net job: next batch
                        go <- false
                else
                    go <- false
            List.ofSeq batch)

let private compute (batch: Job list) =
    match batch with
    | [ Other run ] -> run ()
    | _ ->
        let fast =
            batch
            |> List.choose (function
                | Fast(key, salt, cost, reply, fail) -> Some(key, salt, cost, reply, fail)
                | Other _ -> None)
            |> Array.ofList
        let cost =
            let _, _, c, _, _ = fast[0]
            c
        try
            let hashes = Bcrypt.raw cost [| for key, salt, _, _, _ in fast -> key, salt |]
            Interlocked.Increment &batches[0] |> ignore
            Interlocked.Add(&batches[1], int64 fast.Length) |> ignore
            for i in 0 .. fast.Length - 1 do
                let _, _, _, reply, _ = fast[i]
                reply hashes[i]
        with e ->
            for _, _, _, _, fail in fast do
                fail e

/// Starts `count` bcrypt threads, each computing up to `width` hashes at once and letting the
/// first wait up to `gather` for the rest (idempotent: only the first call starts threads).
let start (count: int) (width: int) (gather: TimeSpan) : unit =
    lock gate (fun () ->
        if threads = 0 then
            threads <- max 1 count
            for i in 1..threads do
                let t =
                    Thread(
                        (fun () ->
                            while true do
                                compute (next (max 1 width) gather)),
                        IsBackground = true,
                        Name = $"bcrypt-{i}"
                    )
                t.Start())

let private ensureStarted () =
    if threads = 0 then
        start 2 4 (TimeSpan.FromMilliseconds 50.0)

/// bcrypt reads at most 72 bytes; a longer password would be silently truncated, so it is refused.
let fits (password: string) : bool = Encoding.UTF8.GetByteCount password <= 72

/// The cost of every new hash (SPEC).
[<Literal>]
let private Cost = 10

let hash (password: string) : Task<string> =
    Interlocked.Increment &hashes |> ignore
    ensureStarted ()
    let reply = TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously)
    let salt = RandomNumberGenerator.GetBytes 16
    work.Add(
        Fast(
            Bcrypt.key password,
            salt,
            Cost,
            (fun h -> reply.TrySetResult(Bcrypt.format "$2a$" Cost salt h) |> ignore),
            (fun e -> reply.TrySetException e |> ignore)
        )
    )
    reply.Task

/// A malformed stored hash verifies as false, never as an error. The comparison is constant-time.
let verify (password: string) (storedHash: string) : Task<bool> =
    Interlocked.Increment &verifies |> ignore
    ensureStarted ()
    let reply = TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously)
    match Bcrypt.parse storedHash with
    | Some stored ->
        work.Add(
            Fast(
                Bcrypt.key password,
                stored.Salt,
                stored.Cost,
                (fun h -> reply.TrySetResult(CryptographicOperations.FixedTimeEquals(h, stored.Hash)) |> ignore),
                (fun _ -> reply.TrySetResult false |> ignore)
            )
        )
    | None ->
        work.Add(
            Other(fun () ->
                let ok =
                    try
                        BCrypt.Net.BCrypt.Verify(password, storedHash)
                    with _ ->
                        false
                reply.TrySetResult ok |> ignore)
        )
    reply.Task

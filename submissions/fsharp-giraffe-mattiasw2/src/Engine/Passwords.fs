module Engine.Passwords

open System
open System.Collections.Concurrent
open System.Text
open System.Threading
open System.Threading.Tasks

// bcrypt cost 10 is ~50-80 ms of one core. Run on the thread pool it would park request threads
// and stall the cheap reads behind it, so it runs on a few dedicated threads ("lanes") with a
// queue in front: a burst of logins waits for a lane, everything else keeps its cores.

let private work = new BlockingCollection<unit -> unit>()
let mutable private hashes = 0L
let mutable private verifies = 0L

/// (hashes, verifies) run since start: the proof that bcrypt runs once per sign-up, password
/// change or login, and never on a request that is refused anyway.
let counts () : int64 * int64 = Interlocked.Read &hashes, Interlocked.Read &verifies
let mutable private lanes = 0
let private gate = obj ()

/// Starts `count` bcrypt lanes (idempotent: only the first call starts threads).
let start (count: int) : unit =
    lock gate (fun () ->
        if lanes = 0 then
            lanes <- max 1 count
            for i in 1..lanes do
                let t =
                    Thread(
                        (fun () ->
                            for job in work.GetConsumingEnumerable() do
                                job ()),
                        IsBackground = true,
                        Name = $"bcrypt-{i}"
                    )
                t.Start())

let private run (f: unit -> 'a) : Task<'a> =
    if lanes = 0 then start (max 1 (Environment.ProcessorCount / 2))
    let tcs = TaskCompletionSource<'a>(TaskCreationOptions.RunContinuationsAsynchronously)
    work.Add(fun () ->
        try
            tcs.SetResult(f ())
        with e ->
            tcs.SetException e)
    tcs.Task

/// bcrypt reads at most 72 bytes; a longer password would be silently truncated, so it is refused.
let fits (password: string) : bool = Encoding.UTF8.GetByteCount password <= 72

let hash (password: string) : Task<string> =
    Interlocked.Increment &hashes |> ignore
    run (fun () -> BCrypt.Net.BCrypt.HashPassword(password, 10))

/// A malformed stored hash verifies as false, never as an error.
let verify (password: string) (storedHash: string) : Task<bool> =
    Interlocked.Increment &verifies |> ignore
    run (fun () ->
        try
            BCrypt.Net.BCrypt.Verify(password, storedHash)
        with _ ->
            false)

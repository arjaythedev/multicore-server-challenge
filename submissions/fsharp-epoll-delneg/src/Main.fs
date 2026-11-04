module Main

open System
open System.Threading

let private env (name: string) (fallback: string) =
    match Environment.GetEnvironmentVariable name with
    | null
    | "" -> fallback
    | v -> v

let private num (name: string) (fallback: int) = int (env name (string fallback))

[<EntryPoint>]
let main _ =
    AppDomain.CurrentDomain.UnhandledException.Add(fun e -> eprintfn "fatal: %O" e.ExceptionObject)
    let url = env "DATABASE_URL" "postgres://conduit:conduit@127.0.0.1:5432/conduit"
    // session settings on our own connections only (Rule 2): generic plans (custom planning costs about as much
    // as running these statements), no JIT and no parallel workers for short OLTP statements
    let options = env "PG_OPTIONS" "-c plan_cache_mode=force_generic_plan -c jit=off -c max_parallel_workers_per_gather=0"
    Auth.init (env "JWT_SECRET" "multicore-server-challenge")
    Store.stats <- env "MC_STATS" "0" = "1"
    if Store.stats then
        AppDomain.CurrentDomain.FirstChanceException.Add(fun e -> Console.Error.WriteLine("first chance: " + e.Exception.ToString()))
    // our threads wake without preempting Postgres mid-query (THREAD_SCHED=other turns it off)
    Sys.threadPolicy <- (if env "THREAD_SCHED" "batch" = "batch" then Sys.SCHED_BATCH else Sys.SCHED_OTHER)
    Store.dumpPath <- (match env "RD_DUMP" "" with "" -> null | p -> p)
    // logins are ~0.1% of requests, so they can wait for full lanes (a 6-lane pass costs ~11 ms per hash, one lane 38 ms)
    Auth.start (num "BCRYPT_THREADS" 2) (num "BCRYPT_LANES" 6) (num "BCRYPT_FILL" 6) (num "BCRYPT_WAIT_MS" 250) (num "BCRYPT_NICE" 5)
    Sql.read <- Sql.readSql (num "HUBS" 16) (env "HUB_COUNT" "1" = "1") (env "FEED_BOUND" "1" = "1")
    // experiments: write the statements out (for EXPLAIN replays) and stop
    match env "SQL_DUMP" "" with
    | "" -> ()
    | path ->
        IO.File.WriteAllText(path, String.Join("\n\n", [ for name, sql, _ in Sql.all () -> "-- " + name + "\n" + sql ]))
        exit 0
    let reads = num "PG_READS" 5
    let sideReads = num "PG_SIDE_READS" 3
    let writes = num "PG_WRITES" 4
    let readClock = num "READ_CLOCK_US" 20000
    Store.start url options reads sideReads writes readClock (num "SIDE_CLOCK_US" readClock) (num "READ_MAX" 2000) (num "WRITE_CLOCK_US" 5000) (num "WRITE_MAX" 256)
    Io.handler <- Api.handle
    let host = env "HOST" "0.0.0.0"
    let port = num "PORT" 3000
    let loops = num "IO_THREADS" 4
    // IO_MODE=uring: io_uring loops (each falls back to epoll if the kernel refuses a ring); URING_BUFS=classic forces
    // IORING_OP_PROVIDE_BUFFERS instead of a buffer ring, the path for kernels whose buffer rings fail
    Io.uring <- env "IO_MODE" "epoll" = "uring"
    Io.uringClassic <- env "URING_BUFS" "ring" = "classic"
    Io.uringBufs <- num "URING_NBUFS" 8192
    Io.uringBufLen <- num "URING_BUFLEN" 2048
    let limit = Io.start host port loops (reads + sideReads + writes + 200) (num "IO_NICE" 0)
    eprintfn "conduit on %s:%d: %d %s I/O threads, postgres %d + %d read and %d write connections, fd limit %d" host port loops (if Io.uring then "io_uring" else "epoll") reads sideReads writes limit
    Thread.Sleep Timeout.Infinite
    0

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
    let url = env "DATABASE_URL" "postgres://conduit:conduit@127.0.0.1:5432/conduit"
    // session settings on our own connections only (Rule 2): generic plans (custom planning costs about as much
    // as running these statements), no JIT and no parallel workers for short OLTP statements
    let options = env "PG_OPTIONS" "-c plan_cache_mode=force_generic_plan -c jit=off -c max_parallel_workers_per_gather=0"
    Auth.init (env "JWT_SECRET" "multicore-server-challenge")
    Store.stats <- env "MC_STATS" "0" = "1"
    Auth.start (num "BCRYPT_THREADS" 2) (num "BCRYPT_LANES" 6) (num "BCRYPT_FILL" 4) (num "BCRYPT_WAIT_MS" 30) (num "BCRYPT_NICE" 5)
    Sql.read <- Sql.readSql (num "HUBS" 16) (env "HUB_COUNT" "1" = "1") (env "FEED_BOUND" "1" = "1")
    let reads = num "PG_READS" 8
    let writes = num "PG_WRITES" 4
    Store.start url options reads writes (num "READ_CLOCK_US" 20000) (num "READ_MAX" 2000) (num "WRITE_CLOCK_US" 5000) (num "WRITE_MAX" 256)
    Io.handler <- Api.handle
    let host = env "HOST" "0.0.0.0"
    let port = num "PORT" 3000
    let loops = num "IO_THREADS" 4
    let limit = Io.start host port loops (reads + writes + 200) (num "IO_NICE" 0)
    eprintfn "conduit on %s:%d: %d I/O threads, postgres %d read + %d write connections, fd limit %d" host port loops reads writes limit
    Thread.Sleep Timeout.Infinite
    0

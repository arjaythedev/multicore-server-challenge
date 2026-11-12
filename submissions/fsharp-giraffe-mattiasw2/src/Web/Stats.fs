module Web.Stats

// One line on stderr every STATS_SECONDS (off unless set), to tell a GC pause from a queue that
// builds: open connections, collections and pause time, allocation and promotion, the heap by
// generation, the thread pool, and the read and write queues. The line runs on a thread of its
// own, not a thread-pool timer: a timer would be late exactly when the pool is starved, and the
// line's `dt` shows how late this thread was (a GC suspends it too).

open System
open System.Diagnostics
open System.Threading
open System.Threading.Tasks
open Microsoft.AspNetCore.Connections
open Microsoft.AspNetCore.Server.Kestrel.Core

/// One line on stderr. The server's own lines use this and string interpolation without printf
/// specifiers (`{x:F1}`, `{name,-42}`), never `eprintfn`/`sprintf`: FSharp.Core's printf builds its
/// formatters by reflection (MakeGenericMethod), which Native AOT cannot compile.
let eprint (line: string) = Console.Error.WriteLine line

/// Kestrel connections, counted by connection middleware (only when the line is on: the
/// middleware's state lives as long as each connection).
[<Sealed>]
type Connections() =
    let counts = [| 0L; 0L |] // opened, closed

    member _.Opened = Volatile.Read(&counts[0])
    member _.Open = Volatile.Read(&counts[0]) - Volatile.Read(&counts[1])

    member _.Count(listen: ListenOptions) =
        listen.Use(fun (next: ConnectionDelegate) ->
            ConnectionDelegate(fun ctx ->
                Interlocked.Increment(&counts[0]) |> ignore
                task {
                    try
                        do! next.Invoke ctx
                    finally
                        Interlocked.Increment(&counts[1]) |> ignore
                }
                :> Task))
        |> ignore

/// Server time per endpoint (only while the line is on), named as the load generator names them,
/// so a client's latency minus ours is what happened outside the handlers: Kestrel, the kernel,
/// the network.
[<Sealed>]
type Endpoints() =
    let timings = Collections.Concurrent.ConcurrentDictionary<string, Engine.Db.Millis>()

    static member Name(httpMethod: string, path: string, has: string -> bool) : string =
        let s = path.Split('/', StringSplitOptions.RemoveEmptyEntries)
        let route =
            if s.Length < 2 || s[0] <> "api" then
                "other"
            else
                match s[1], s.Length with
                | "tags", 2 -> "/api/tags"
                | "user", 2 -> "/api/user"
                | "users", 2 -> "/api/users"
                | "users", 3 -> "/api/users/login"
                | "profiles", 3 -> "/api/profiles/:username"
                | "profiles", 4 -> "/api/profiles/:username/follow"
                | "articles", 2 when httpMethod = "GET" ->
                    if has "tag" then "/api/articles?tag"
                    elif has "author" then "/api/articles?author"
                    elif has "favorited" then "/api/articles?favorited"
                    else "/api/articles"
                | "articles", 2 -> "/api/articles"
                | "articles", 3 when s[2] = "feed" && httpMethod = "GET" -> "/api/articles/feed"
                | "articles", 3 -> "/api/articles/:slug"
                | "articles", 4 -> $"/api/articles/:slug/{s[3]}"
                | "articles", 5 -> "/api/articles/:slug/comments/:id"
                | _ -> "other"
        $"{httpMethod} {route}"

    member _.Record(name: string, elapsed: TimeSpan) =
        timings.GetOrAdd(name, fun _ -> Engine.Db.Millis()).Record elapsed

    /// One line per endpoint, busiest first: "name count p50/p95/p99 ms".
    member _.Lines() =
        timings
        |> Seq.map (fun kv -> kv.Key, kv.Value.Count, kv.Value.Summary())
        |> Seq.sortByDescending (fun (_, n, _) -> n)
        |> Seq.map (fun (name, n, summary) -> $"  {name,-42} {n,9}  {summary}")
        |> List.ofSeq

/// Where each request's time went, by endpoint and by log2 bucket of its server time (bucket 0:
/// under 1 ms; bucket b: 2^(b-1) to 2^b ms; the last holds the rest). Per cell: the count and the
/// summed microseconds of the server time and of each lane phase. Six interlocked adds per
/// request, so it can stay on under load. Unlike a percentile, a cell's phases add up, so the
/// slow buckets can be split into phases. `Snapshot` appends the cumulative cells as CSV; two
/// snapshots subtracted give any window.
[<Sealed>]
type Phases() =
    static let buckets = 16
    static let fields = 6 // count, server, read queued, read executed, write queued, write executed
    let names = Collections.Concurrent.ConcurrentDictionary<string, int>()
    let cells: int64[] = Array.zeroCreate (64 * buckets * fields)
    let micros (ticks: int64) = ticks * 1_000_000L / Stopwatch.Frequency

    member _.Record(name: string, server: int64, t: Engine.Db.Trace) =
        let e = names.GetOrAdd(name, fun _ -> names.Count)
        if e < 64 then
            let ms = uint64 (server * 1000L / Stopwatch.Frequency)
            let b = if ms = 0UL then 0 else min (buckets - 1) (64 - Numerics.BitOperations.LeadingZeroCount ms)
            let at = (e * buckets + b) * fields
            Interlocked.Increment &cells[at] |> ignore
            Interlocked.Add(&cells[at + 1], micros server) |> ignore
            Interlocked.Add(&cells[at + 2], micros t.ReadQueued) |> ignore
            Interlocked.Add(&cells[at + 3], micros t.ReadExecuted) |> ignore
            Interlocked.Add(&cells[at + 4], micros t.WriteQueued) |> ignore
            Interlocked.Add(&cells[at + 5], micros t.WriteExecuted) |> ignore

    /// Appends one row per non-empty cell: unix_s,endpoint,bucket,count,server_us,read_q_us,
    /// read_x_us,write_q_us,write_x_us (cumulative since start).
    member _.Snapshot(path: string, unix: int64) =
        use w = IO.File.AppendText path
        for kv in names do
            for b in 0 .. buckets - 1 do
                let at = (kv.Value * buckets + b) * fields
                let n = Volatile.Read &cells[at]
                if n > 0L then
                    let f i = Volatile.Read &cells[at + i]
                    w.WriteLine $"{unix},{kv.Key},{b},{n},{f 1},{f 2},{f 3},{f 4},{f 5}"

/// A fine timeline (BATCH_LOG): every `every` (25 ms) a row of cumulative counters, written as
/// CSV at shutdown. CPU of the app (its own clock), of Postgres (the usage_usec of the cgroup
/// file BATCH_LOG_PG_CGROUP, if given) and of the cores this process may run on (busy and total
/// jiffies from /proc/stat, which also counts the Postgres backends sharing them); the GC pause
/// so far; the read lanes busy, the read queue, the read requests answered so far, the write
/// queue. Differences between rows give each 25 ms.
[<Sealed>]
type Sampler(every: TimeSpan, reads: Engine.Reads.Gather, writes: Engine.Commit.Writer, pgCgroup: string, capacity: int) =
    static let fields = 10
    let rows: int64[] = Array.zeroCreate (capacity * fields)
    let next = [| -1 |]
    let unixAt0 = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() * 1000L
    let ticksAt0 = Stopwatch.GetTimestamp()
    // The cores in this process's affinity (the first 64).
    let ours =
        let mask = uint64 (Process.GetCurrentProcess().ProcessorAffinity.ToInt64())
        Set.ofList [ for c in 0..63 do if (mask >>> c) &&& 1UL = 1UL then c ]
    let cores () =
        let mutable busy = 0L
        let mutable total = 0L
        for line in IO.File.ReadLines "/proc/stat" do
            if line.StartsWith "cpu" && line.Length > 3 && Char.IsDigit line[3] then
                let f = line.Split(' ', StringSplitOptions.RemoveEmptyEntries)
                if ours.Contains(int (f[0].Substring 3)) then
                    let v i = if f.Length > i then int64 f[i] else 0L
                    let idle = v 4 + v 5 // idle, iowait
                    let b = v 1 + v 2 + v 3 + v 6 + v 7 + v 8 // user, nice, system, irq, softirq, steal
                    busy <- busy + b
                    total <- total + b + idle
        busy, total
    let pg () =
        if pgCgroup = "" then 0L
        else
            try
                IO.File.ReadLines pgCgroup
                |> Seq.tryFind (fun l -> l.StartsWith "usage_usec ")
                |> Option.map (fun l -> int64 (l.Substring 11))
                |> Option.defaultValue 0L
            with _ -> 0L

    member _.Start() =
        let sample () =
            try
                while true do
                    Thread.Sleep every
                    let i = Interlocked.Increment &next[0]
                    if i < capacity then
                        let busy, total = cores ()
                        let _, answered = reads.Counts
                        let at = i * fields
                        rows[at] <- unixAt0 + (Stopwatch.GetTimestamp() - ticksAt0) * 1_000_000L / Stopwatch.Frequency
                        rows[at + 1] <- int64 Environment.CpuUsage.TotalTime.TotalMicroseconds
                        rows[at + 2] <- pg ()
                        rows[at + 3] <- busy
                        rows[at + 4] <- total
                        rows[at + 5] <- int64 (GC.GetTotalPauseDuration().TotalMicroseconds)
                        rows[at + 6] <- int64 reads.Busy
                        rows[at + 7] <- int64 reads.Depth
                        rows[at + 8] <- answered
                        rows[at + 9] <- int64 writes.Depth
            with e ->
                // A diagnostic must never take the server down.
                eprint $"sampler stopped: {e.Message}"
        Thread(sample, IsBackground = true, Name = "sampler").Start()

    member _.Write(path: string) =
        let n = min capacity (Volatile.Read &next[0] + 1)
        use w = new IO.StreamWriter(path)
        w.WriteLine "unix_us,app_cpu_us,pg_cpu_us,cores_busy_jiffies,cores_total_jiffies,gc_pause_us,read_lanes_busy,read_queue,reads_answered,write_queue"
        for i in 0 .. n - 1 do
            w.WriteLine(String.Join(',', rows[i * fields .. i * fields + fields - 1]))
        n

/// Every collection (with BATCH_LOG), from the runtime's own GC events, written as CSV at
/// shutdown: when the runtime began suspending threads, its number, generation, type and reason;
/// how long the suspension took (until every thread stopped), the collection itself, and the
/// whole pause (until every thread ran again); the bytes promoted out of each generation and each
/// generation's size after; pinned objects; the mechanisms (compaction, promotion, demotion); and
/// what the marking found alive, by root: stacks, the finalize queue, handles, older generations
/// (cards). A suspension with no collection in it has generation -1.
[<Sealed>]
type GcLog(capacity: int) =
    inherit Diagnostics.Tracing.EventListener()
    static let fields = 25
    let rows: int64[] = Array.zeroCreate (capacity * fields)
    let at = [| 0; 0 |] // rows done, a row open (1)
    let mutable suspended = 0L
    let mutable started = 0L
    let unix (t: DateTime) = (t.ToUniversalTime() - DateTime.UnixEpoch).Ticks / 10L
    let value (e: Diagnostics.Tracing.EventWrittenEventArgs) (name: string) =
        let i = e.PayloadNames.IndexOf name
        if i < 0 then 0L else Convert.ToInt64 e.Payload[i]

    // Called by the base constructor, before this type's fields exist: touch none of them.
    override this.OnEventSourceCreated(source) =
        if source.Name = "Microsoft-Windows-DotNETRuntime" then
            this.EnableEvents(source, Diagnostics.Tracing.EventLevel.Informational, LanguagePrimitives.EnumOfValue<int64, Diagnostics.Tracing.EventKeywords> 1L) // GC

    override _.OnEventWritten(e) =
        lock rows (fun () ->
            let n = at[0]
            let row = n * fields
            let t = unix e.TimeStamp
            let isOpen = at[1] = 1 && n < capacity
            match e.EventId with
            | 9 when n < capacity -> // GCSuspendEEBegin
                Array.fill rows row fields 0L
                rows[row] <- t
                rows[row + 2] <- -1L
                suspended <- t
                at[1] <- 1
            | 8 when isOpen -> rows[row + 5] <- t - suspended // GCSuspendEEEnd
            | 1 when isOpen -> // GCStart
                started <- t
                rows[row + 1] <- value e "Count"
                rows[row + 2] <- value e "Depth"
                rows[row + 3] <- value e "Type"
                rows[row + 4] <- value e "Reason"
            | 2 when isOpen -> rows[row + 6] <- t - started // GCEnd
            | 4 when isOpen -> // GCHeapStats
                for g in 0..4 do
                    rows[row + 8 + g] <- value e $"TotalPromotedSize{g}"
                    rows[row + 13 + g] <- value e $"GenerationSize{g}"
                rows[row + 18] <- value e "PinnedObjectCount"
            | 205 when isOpen -> // GCGlobalHeapHistory
                rows[row + 19] <- value e "GlobalMechanisms"
                rows[row + 24] <- value e "NumHeaps"
            | 202 when isOpen -> // GCMarkWithType: stack, finalize queue, handles, older generations
                match value e "Type" with
                | k when k <= 3L -> rows[row + 20 + int k] <- rows[row + 20 + int k] + value e "Bytes"
                | _ -> ()
            | 3 when isOpen -> // GCRestartEEEnd
                rows[row + 7] <- t - suspended
                at[0] <- n + 1
                at[1] <- 0
            | _ -> ())

    /// Writes the rows; returns how many, and per generation (-1: no collection) the count, the
    /// pauses' p50 and max and mean suspension in ms, and the mean promoted MB.
    member _.Write(path: string) =
        let n, rs =
            lock rows (fun () ->
                let n = at[0]
                n, [| for i in 0 .. n - 1 -> rows[i * fields .. i * fields + fields - 1] |])
        use w = new IO.StreamWriter(path)
        w.WriteLine "unix_us,index,gen,type,reason,suspend_us,gc_us,pause_us,promoted0,promoted1,promoted2,promoted_loh,promoted_poh,size0,size1,size2,size_loh,size_poh,pinned,mechanisms,mark_stack,mark_fq,mark_handles,mark_older,heaps"
        for r in rs do
            w.WriteLine(String.Join(',', r))
        let lines =
            rs
            |> Array.groupBy (fun r -> r[2])
            |> Array.sortBy fst
            |> Array.map (fun (gen, xs) ->
                let pauses = xs |> Array.map (fun r -> r[7]) |> Array.sort
                let ms (us: int64) = float us / 1000.0
                let p50 = ms pauses[pauses.Length / 2]
                let worst = ms pauses[pauses.Length - 1]
                let suspension = xs |> Array.averageBy (fun r -> ms r[5])
                let promoted = xs |> Array.averageBy (fun r -> float (r[8] + r[9] + r[10] + r[11] + r[12]) / 1048576.0)
                $"  gen {gen,2}: {xs.Length,5}, pause p50 {p50:F1} max {worst:F1} ms, suspension mean {suspension:F2} ms, promoted mean {promoted:F1} MB")
        n, lines

let private mb (bytes: int64) = bytes / 1048576L

/// The latest GC of `kind` and, if it is not GC number `seen`, "g<gen> <promoted>MB <pause>ms".
let private latest (kind: GCKind) (seen: int64) : int64 * string =
    let info = GC.GetGCMemoryInfo kind
    if info.Index = seen then
        seen, ""
    else
        let pause = if info.PauseDurations.Length > 0 then info.PauseDurations[0] else TimeSpan.Zero
        info.Index, $"g{info.Generation} {mb info.PromotedBytes}MB {int pause.TotalMilliseconds}ms"

let start (every: TimeSpan) (connections: Connections) (reads: Engine.Reads.Gather) (readLanes: int) (writes: Engine.Commit.Writer) (writeLanes: int) (phases: (Phases * string) option) =
    let sample () =
        let mutable at = Stopwatch.GetTimestamp()
        let mutable opened = connections.Opened
        let mutable collections = [| GC.CollectionCount 0; GC.CollectionCount 1; GC.CollectionCount 2 |]
        let mutable paused = GC.GetTotalPauseDuration()
        let mutable allocated = GC.GetTotalAllocatedBytes false
        let mutable cpu = Environment.CpuUsage.TotalTime
        let mutable batches, requests = reads.Counts
        let mutable groups, written = writes.Counts
        let mutable writeBusy = writes.BusyTicks
        let mutable ephemeral = (GC.GetGCMemoryInfo GCKind.Ephemeral).Index
        let mutable full = (GC.GetGCMemoryInfo GCKind.FullBlocking).Index
        let mutable background = (GC.GetGCMemoryInfo GCKind.Background).Index
        while true do
            Thread.Sleep every
            let now = Stopwatch.GetTimestamp()
            let dt = Stopwatch.GetElapsedTime(at, now)
            let opened' = connections.Opened
            let collections' = [| GC.CollectionCount 0; GC.CollectionCount 1; GC.CollectionCount 2 |]
            // CollectionCount n also counts every collection of a higher generation.
            let d = Array.map2 (-) collections' collections
            let paused' = GC.GetTotalPauseDuration()
            let allocated' = GC.GetTotalAllocatedBytes false
            let cpu' = Environment.CpuUsage.TotalTime
            let batches', requests' = reads.Counts
            let groups', written' = writes.Counts
            let heap = GC.GetGCMemoryInfo GCKind.Any
            let generations = heap.GenerationInfo
            let ephemeral', lastEphemeral = latest GCKind.Ephemeral ephemeral
            let full', lastFull = latest GCKind.FullBlocking full
            let background', lastBackground = latest GCKind.Background background
            let wall = DateTimeOffset.UtcNow
            let perBatch = if batches' = batches then 0L else (requests' - requests) / (batches' - batches)
            let cores = (cpu' - cpu).TotalSeconds / dt.TotalSeconds
            let writeBusyPercent =
                100.0 * float (writes.BusyTicks - writeBusy) / float Stopwatch.Frequency / dt.TotalSeconds / float writeLanes
            let perGroup = if groups' = groups then 0L else (written' - written) / (groups' - groups)
            let clock = wall.ToString "HH:mm:ss.fff"
            // Interpolation without printf specifiers compiles to String.Format (no reflection, so
            // Native AOT can build it). A literal percent sign would be a specifier, hence "pct".
            eprint (
                $"stats t={wall.ToUnixTimeSeconds()} {clock} dt={int dt.TotalMilliseconds}ms"
                + $" | conn={connections.Open} new={opened' - opened}"
                + $" | gc0={d[0] - d[1]} gc1={d[1] - d[2]} gc2={d[2]} pause={int (paused' - paused).TotalMilliseconds}ms"
                + $" alloc={mb (allocated' - allocated)}MB eph=[{lastEphemeral}] full=[{lastFull}] bg=[{lastBackground}]"
                + $" | heap={mb heap.HeapSizeBytes}MB gen2={mb generations[2].SizeAfterBytes}MB"
                + $" loh={mb generations[3].SizeAfterBytes}MB poh={mb generations[4].SizeAfterBytes}MB"
                + $" | cpu={cores:F2} pool={ThreadPool.ThreadCount} pending={ThreadPool.PendingWorkItemCount}"
                + $" | reads q={reads.Depth} busy={reads.Busy}/{readLanes} batches={batches' - batches} per={perBatch}"
                + $" worst={int (reads.Worst()).TotalMilliseconds}ms"
                + $" | writes q={writes.Depth} busy={writeBusyPercent:F0}pct groups={groups' - groups} per={perGroup}"
                + $" refused={fst writes.Refusals}"
            )
            writeBusy <- writes.BusyTicks
            groups <- groups'
            written <- written'
            phases |> Option.iter (fun (p, path) -> p.Snapshot(path, wall.ToUnixTimeSeconds()))
            at <- now
            opened <- opened'
            collections <- collections'
            paused <- paused'
            allocated <- allocated'
            cpu <- cpu'
            batches <- batches'
            requests <- requests'
            ephemeral <- ephemeral'
            full <- full'
            background <- background'

    // A diagnostic must never take the server down.
    let guarded () =
        try
            sample ()
        with e ->
            eprint $"stats stopped: {e.Message}"
    Thread(guarded, IsBackground = true, Name = "stats").Start()

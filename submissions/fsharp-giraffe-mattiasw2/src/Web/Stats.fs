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

let private mb (bytes: int64) = bytes / 1048576L

/// The latest GC of `kind` and, if it is not GC number `seen`, "g<gen> <promoted>MB <pause>ms".
let private latest (kind: GCKind) (seen: int64) : int64 * string =
    let info = GC.GetGCMemoryInfo kind
    if info.Index = seen then
        seen, ""
    else
        let pause = if info.PauseDurations.Length > 0 then info.PauseDurations[0] else TimeSpan.Zero
        info.Index, $"g{info.Generation} {mb info.PromotedBytes}MB {int pause.TotalMilliseconds}ms"

let start (every: TimeSpan) (connections: Connections) (reads: Engine.Reads.Gather) (readLanes: int) (writes: Engine.Commit.Writer) =
    let sample () =
        let mutable at = Stopwatch.GetTimestamp()
        let mutable opened = connections.Opened
        let mutable collections = [| GC.CollectionCount 0; GC.CollectionCount 1; GC.CollectionCount 2 |]
        let mutable paused = GC.GetTotalPauseDuration()
        let mutable allocated = GC.GetTotalAllocatedBytes false
        let mutable cpu = Environment.CpuUsage.TotalTime
        let mutable batches, requests = reads.Counts
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
            let heap = GC.GetGCMemoryInfo GCKind.Any
            let generations = heap.GenerationInfo
            let ephemeral', lastEphemeral = latest GCKind.Ephemeral ephemeral
            let full', lastFull = latest GCKind.FullBlocking full
            let background', lastBackground = latest GCKind.Background background
            let wall = DateTimeOffset.UtcNow
            let perBatch = if batches' = batches then 0L else (requests' - requests) / (batches' - batches)
            eprintfn
                "stats t=%d %s dt=%dms | conn=%d new=%d | gc0=%d gc1=%d gc2=%d pause=%dms alloc=%dMB eph=[%s] full=[%s] bg=[%s] | heap=%dMB gen2=%dMB loh=%dMB poh=%dMB | cpu=%.2f pool=%d pending=%d | reads q=%d busy=%d/%d batches=%d per=%d worst=%dms | writes q=%d"
                (wall.ToUnixTimeSeconds())
                (wall.ToString "HH:mm:ss.fff")
                (int dt.TotalMilliseconds)
                connections.Open
                (opened' - opened)
                (d[0] - d[1])
                (d[1] - d[2])
                d[2]
                (int (paused' - paused).TotalMilliseconds)
                (mb (allocated' - allocated))
                lastEphemeral
                lastFull
                lastBackground
                (mb heap.HeapSizeBytes)
                (mb generations[2].SizeAfterBytes)
                (mb generations[3].SizeAfterBytes)
                (mb generations[4].SizeAfterBytes)
                ((cpu' - cpu).TotalSeconds / dt.TotalSeconds)
                ThreadPool.ThreadCount
                ThreadPool.PendingWorkItemCount
                reads.Depth
                reads.Busy
                readLanes
                (batches' - batches)
                perBatch
                (int (reads.Worst()).TotalMilliseconds)
                writes.Depth
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

    Thread(sample, IsBackground = true, Name = "stats").Start()

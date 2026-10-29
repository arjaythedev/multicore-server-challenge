# csharp-epoll-aot-gichamba

Front: direct

C# on .NET 10, compiled ahead of time with Native AOT. No web framework and no database driver: the HTTP server and the
Postgres client are our own, written for this workload.

| | |
|---|---|
| Language | C# 14, .NET 10 (SDK 10.0.303, pinned by `global.json`), Native AOT |
| HTTP | our own HTTP/1.1 server on edge-triggered epoll, keep-alive and pipelining |
| Postgres | our own client for protocol 3.0: extended query, binary results, pipelined, SCRAM-SHA-256 |
| bcrypt | Openwall crypt_blowfish 1.3, built from source, with our interleaved multi-password loop |
| Packages | none; restore fetches only the Native AOT compiler packs that the pinned SDK names |

The same code built for the .NET JIT is a separate entry, `csharp-epoll-jit-gichamba`.

## How a request flows

1. **HTTP.** Two event loops, each on its own thread with its own `SO_REUSEPORT` listener, so the kernel spreads new
   connections across them. A connection has one request at the handler at a time; pipelined requests are answered in
   order.
2. **Reads wait to share.** Reads wait in five queues (the planner's, below, and one each for tags, profiles, the
   current user and login) until 2,048 requests are waiting or the oldest has waited 20 ms. Then up to 2,048 of them
   go to Postgres as one batch, on one of 8 read connections.
3. **One planner for the article reads.** The four article lists, the feed, single articles and comments all join the
   same batch, which runs in two round trips:
   - Phase A runs one statement per kind of read in the batch, over distinct keys only. Ten readers of the same tag page
     cost one page read and one count.
   - Phase B looks up every distinct article phase A found once (tags, favorites count, author), and reads the
     favorited and following flags for every (viewer, article) and (viewer, author) pair, all in one round trip.

   Every response is then built from those rows. Tags, profiles, the current user and login have small batched
   statements of their own.
4. **Writes commit in groups.** A free write connection (there are two) takes up to 128 waiting writes as one
   transaction, and each write is answered only after its COMMIT. If the group fails, its writes run again one at a
   time, so a bad write fails alone. Each write is one statement that reports "not found" or "not yours" as a row, never
   as an error, so a normal outcome never aborts the group.
5. **bcrypt in lanes.** Two threads hash passwords four at a time. The four Blowfish key expansions are interleaved, so
   one core keeps several independent chains in flight. A batch starts when four passwords wait or the oldest has
   waited 150 ms.

## How it keeps the rules

- **No caching across requests.** Every request is answered from rows Postgres returned while it waited. Requests in
  the same batch share those rows; nothing is kept once the batch is answered. Each thread keeps only the HMAC state
  keyed with the JWT secret.
- **Writes are committed before the response**, as group commit (rule 6).
- **bcrypt cost 10** for every new password, and every login verifies against the stored hash. A failed hash is never
  stored: the request gets a 500.
- **HS256 signature and `exp`** are checked on every request.
- **Postgres stays as configured.** 10 connections (8 read, 2 write). The only settings are session-level, sent at
  connect: `plan_cache_mode = force_generic_plan`, `jit = off`, `max_parallel_workers_per_gather = 0`, and
  `enable_memoize = off` on the read connections.

## Latency trade-offs

Three waits trade a little latency for much less work per request:

- a read waits up to 20 ms for others to share its batch;
- a password waits up to 150 ms for others to share a bcrypt call;
- a lone write on an idle system waits up to 1 ms for company.

Under load a read still waits about 20 ms, because a window rarely collects 2,048 requests, but it shares the batch
with hundreds of others. Password batches fill before their timer, and a write skips the 1 ms wait whenever a
transaction is already running.

## SQL worth reading

The statements are in `src/Api/PlanSql.cs` (reads), `src/Api/WriteOps.cs` (writes) and `src/Api/ArticleSql.cs`
(shared parts).

- Pages are cut from an ordered list of ids (`OFFSET`, then a constant `LIMIT 100`) before anything is joined, so the
  planner never expects a large row count.
- Capped counts prove 1,000 rows with `EXISTS (... OFFSET 999)` and count only smaller sets.
- The global count walks the primary key from the oldest end, where pages stay all-visible as articles are added.
- A feed that follows an author with 1,000 or more articles counts 1,000 at once. The batch checks the followees its
  viewers share most, once each.
- Tag names come from one read of the tags table per batch, as one row of two arrays in the database's own order.
- Favorite, unfavorite, follow and unfollow change the row and return the response's data in the same statement.

## Measured

On our own rig (an 8-vCPU Hyper-V VM with Postgres on tmpfs, and load from four VMs on the same host), 5-minute holds
at 136,000 users, one run each:

| | p95 | p99 |
|---|---:|---:|
| this entry (Native AOT) | 253 ms | 395 ms |
| `csharp-epoll-jit-gichamba` | 316 ms | 452 ms |
| `rust-epoll-WorriedArrow` | 293 ms | 398 ms |

All three passed. At 145,000 the load VMs fell behind, so the rig could not find the ceiling. Only comparisons within
the same round mean anything; these are not challenge scores. The holds ran on an earlier build. The SQL changes since
then cut Postgres execution time at 80,000 users, and six interleaved pairs at a lower load showed the final cleanup
did not move latency beyond run-to-run noise.

## Under overload

- Clients never get the last 256 descriptors, so the runtime, Postgres reconnects and logging always have some. A
  connection past that line is closed at once, accepting stops for 100 ms, the open connections keep being served,
  and the stats line counts it (`emfile=`). `start.sh` raises the soft descriptor limit to the hard one; on the box
  that leaves 199,744 for clients.
- The server writes to the console once at startup, because .NET opens the console streams on the first write and that
  needs free descriptors.
- Checked three times on each build, with descriptors capped at 1,500 and 3,000 users arriving: that probe failed,
  and the same process then passed 1,000 users with no errors. With 13,600 idle connections open, the process grew by
  9 MB, under 1 KB each.

## Settings

The box's `DATABASE_URL`, `JWT_SECRET`, `HOST` and `PORT` are all the server needs. The rest default to the measured
configuration and are read from the environment only to experiment:

| Variable | Default | Meaning |
|---|---|---|
| `HTTP_LOOPS` | 2 | event loops, each with its own listener |
| `PG_READ` / `PG_WRITE` | 8 / 2 | read and write connections (together at most 95) |
| `PG_DEPTH` | 1 | read batches in flight per connection |
| `BATCH_MAX` | 2048 | most requests in one read batch |
| `GATHER_MS` | 20 | longest a read waits for its batch to fill |
| `BCRYPT_LANES` / `BCRYPT_THREADS` | 4 / 2 | passwords per bcrypt call, and bcrypt threads |
| `BCRYPT_WAIT_MS` | 150 | longest a password waits for a full set of lanes |
| `STATS_SECONDS` | 10 | interval of the counters line on stderr |

A bad value stops the server at startup with one line naming the variable.

## Build

- `install.sh` (root, once): gcc, clang, ICU and OpenSSL from apt, and the .NET SDK 10.0.303 from Microsoft's tarball,
  checked against its published SHA-512, into `/usr/local/lib/dotnet-sdk-10.0.303`. It waits for the apt lock, retries
  downloads, and is quick and safe to run again.
- `build.sh` (normal user): builds `libconduit_bcrypt.so` with gcc, then publishes the native server to `out/`. All
  caches stay inside the folder.
- `start.sh`: raises the soft descriptor limit to the hard one and runs `out/conduit` in the foreground.

## Credits

Ideas from other entries; the code is ours, except crypt_blowfish:

- `rust-epoll-WorriedArrow`: the two-phase batch planner, the gather window, `EXISTS ... OFFSET 999` capped counts and
  counting the global list from the oldest end.
- `go-epoll-MegaPanchamZ` and `zig-iouring-harshitkhandelwal208` (PR #100): proving a heavy author once per batch in
  the feed count.
- `zig-fourneau-y2kbugger`: the tags table as one row of arrays, and `enable_memoize = off` (also in
  `c-epoll-umitaltintas`, PR #91).
- `rust-tokio-Scooter1337`: sharing work inside a batch, and few Postgres connections.
- `csharp-sockets-jh-d`: the batched statement shape (`unnest` plus `LATERAL`, rows routed by request position),
  oldest-first dispatch, and headroom in the response buffer for the headers.
- `c-iouring-tigokraft`: a constant inner `LIMIT`, so Postgres never plans for a large page.
- Openwall crypt_blowfish by Solar Designer, public domain (`native/SOURCE.md`).

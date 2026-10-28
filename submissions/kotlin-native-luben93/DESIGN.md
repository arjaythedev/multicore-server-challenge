# Design: zero-dependency Kotlin Multiplatform Conduit server (JVM + Kotlin/Native)

One source tree, two binaries: `build/jvm/conduit.jar` (HotSpot, JDK 27) and
`build/bin/linuxX64/releaseExecutable/conduit.kexe` (Kotlin/Native). No third-party libraries at all: our own
HTTP/1.1 server, Postgres wire-protocol client, JSON, JWT, bcrypt. The one exception is bcrypt's inner loop: the
public-domain Openwall C core, vendored as source in `native/` and compiled on the box. The pure-Kotlin bcrypt is
the fallback. Coroutines are the Kotlin **language** feature
(`suspend` + `kotlin.coroutines` intrinsics from the stdlib), with no kotlinx.coroutines and no dispatcher: a
continuation is resumed directly on the thread that completed its I/O.

## Why this shape (measured in the local lab, 2 cores for app + Postgres)

| Server | max req/s (2 cores) | CPU µs/req (app + PG) | Box score |
|---|---:|---:|---:|
| kotlin-ktor-canleon (Ktor + Vert.x pg client) | ~7k | 431 at 3k req/s | 44k |
| kotlin-vertx-canleon (Vert.x Web) | ~8k | 250 at 7.8k req/s | 46k |
| rust-tokio-Scooter1337 (#1) | ~13k | 143 at 13k req/s | 100k |

The box is CPU-bound with Postgres taking ~70% of the CPU at the top, so the levers are:
1. **Postgres cost per request**: batch queued reads of the same kind into ONE statement (LATERAL over unnest),
   cheap SQL (pages cut before decoration, tag names by PK, capped counts), group commit for writes, few backends.
2. **App cost per request** (#1 spends ~50 µs): no framework, no per-request object graphs, JSON written straight
   from Postgres's binary rows into the response buffer, one write syscall per response.
3. **Few runnable threads**: 2 HTTP loops on 8 cores, 8 read + 4 write Postgres connections, 1 bcrypt thread.
4. **OS limits at 64k-120k connections** (the scorer probes 32k, 64k, then 120k = the cap): listen backlog 65535,
   SO_REUSEPORT per loop, no thread or >=128 KiB buffer per connection (`vm.max_map_count` is 65530 on the box),
   no buffers held by idle connections, RLIMIT_NOFILE raised to the hard limit (200000 under systemd), EMFILE
   backs off instead of spinning, no idle timeout (think time is up to 70 s).

## Threads and request flow

```
HTTP loop thread (x HTTP_THREADS, default ceil(cpus/4)=2)       PG read thread (x DB_READ_CONNS, default 8)
  epoll/NIO: accept, read into loop scratch                       loop:
  HttpEngine.onData: parse request                                  take a batch (oldest kind first, <= 64 reqs;
  Jwt.verify (HMAC, every request)                                    tags: every queued one, see "broadcast")
  start handler coroutine ──► Db.read(kind, ...) suspends ───────►  send one Bind/Execute/Sync, read to 'Z',
                                                                     route rows by r.i to each request's Result
                                                                     (send next batch first, then:)
                               handler resumes HERE  ◄────────────  resume each request's continuation:
                               writes JSON into Exchange.out          handler builds JSON, Exchange.send()
                               Exchange.send(): header+body,          -> HttpConn.tryWrite (non-blocking, any
                               one non-blocking write                    thread; leftovers via the owning loop)

PG write thread (x DB_WRITE_CONNS, default 2): group commit. Takes all queued writes (<= 64), sends
  BEGIN; w1; w2; ...; COMMIT; Sync in ONE round trip; resumes callers only after COMMIT's ReadyForQuery.
  On any error: ROLLBACK, then each job alone (autocommit). `isolated` writes (register, user update: unique
  violations expected) always run alone.
bcrypt thread (x BCRYPT_THREADS, default 1, nice 10): collects up to 8 jobs within BCRYPT_BATCH_MS (400 ms; at
  ~28 logins/s 93% of batches are full), computes them as interleaved lanes in one call to the C kernel (FFM on the
  JVM, cinterop on Native; 12.6-13 ms CPU/hash at 8 lanes vs 23.4 / 18.7 ms for the Kotlin 4 lanes), resumes
  each caller on the bcrypt thread. If the kernel is missing or fails its startup checks: Kotlin lanes, up to 4.
```

Every statement is prepared once per connection at startup (named `s<id>`, explicit parameter OIDs, no Describe);
every Bind asks for binary results. Startup packet `options`:
`-c plan_cache_mode=force_generic_plan -c jit=off -c max_parallel_workers_per_gather=0 -c enable_memoize=off`.

## JVM specifics (jvmMain)

- **HTTP loops** run on raw epoll through FFM (`EpollHttp.kt`, a port of the Native loop): recv/send/accept4/
  epoll_ctl are *critical* downcalls that hand heap arrays straight to the kernel (no NIO channel lock, no copy
  through a temporary direct buffer, no fd -> key `HashMap` lookup with a boxed fd per event); only epoll_wait (it
  blocks) is a normal downcall. `HTTP_IO=nio` (or no FFM, or a non-IPv4 bind address) uses the java.nio selector
  loops (`NioHttp.kt`). Both pass the same end-to-end tests (`NioHttpTest`, `EpollHttpTest`, `EmfileTest`).
- **Postgres sockets** are blocking `SocketChannel`s (connected with a timeout through a selector, then switched to
  blocking). A `java.net.Socket` stays non-blocking for good after a timed connect, which turns every waiting read
  into read -> EAGAIN, poll, read.
- **Our threads** are `ConduitThread`s: `threadScratch()` (JWT HMAC, scratch buffers) and the FFM errno capture
  segment are plain fields, not `ThreadLocal` lookups.
- **Per request**, the Authorization header is verified in place in the input buffer (`Exchange.authBuf`: no
  String, no copy); the token String exists only for `/api/user`, which echoes it.
- **JVM flags** (start.sh): `-XX:+UseTransparentHugePages -XX:+UseSystemMemoryBarrier -XX:-UsePerfData` on G1 with
  a fixed, pre-touched heap (1 GB when these were measured; 3 GB since, `JAVA_HEAP` overrides: 1 GB filled up under
  the 120k-user overload, see "Overload"). In the lab at saturation (13000 users, think-scale 0.2; 5 runs without, 2 with)
  they took the app from 50.3 to 48.0 us/req, total CPU from 138.7 to 134.5 us/req and req/s from 14266 to 14735.
  ParallelGC failed p95 in one of two runs there (642 ms): its pauses.
  GC itself is negligible (two ~10 ms young collections per 45 s at 8k req/s).

## Overload

The scorer's 120k-user probe is past the box's capacity and is never followed by a restart: the server has to come
out of it working.
- **Threads survive any Throwable.** Every catch on an HTTP loop, a Postgres worker and the bcrypt threads changes
  state or closes first, then logs through `logSafe` (never throws; an OutOfMemoryError gets a constant line), and the
  thread carries on. A Postgres worker always goes back to a guarded `reconnect()`; `run()` returns only once stopping.
- **A waiting request holds no response buffer.** `Out` is taken when the response is rendered, not when the request
  is parsed (~0.5 KB per queued request instead of ~8.8 KB).
- **Abandoned work is dropped.** `Ex` is its handler coroutine's context element (`RequestKey`), so `ReadPool` and
  `Passwords` know whose request a queued read or bcrypt job is. If that connection is closed, or the request is older
  than 10 s (the client's timeout), the job is dropped unrun and its handler is never resumed. Writes always run.
- **Queue caps.** At `READ_QUEUE_MAX` (65536) queued reads, `WRITE_QUEUE_MAX` (8192) writes or `BCRYPT_QUEUE_MAX`
  (2048) jobs a flag is set (cleared at 75%) and `App.handle` answers 503 "server busy" on the kept-alive connection.
  `Db.read`/`Db.write` still always suspend.
- `OVERLOAD_GUARD=0` turns off the last two. The heap is 3 GB (`JAVA_HEAP`).

## Postgres-side savings

Two Postgres-side savings beyond batching (measured in the lab, see the commit messages):
- **Broadcast for GET /api/tags** (`ReadKind.broadcast`): the tag list does not depend on the request, so all tags
  requests queued when a read connection frees are answered by ONE execution of
  `SELECT ARRAY(SELECT name FROM tags ORDER BY name)`, whose single row is handed to each of them (the #1 entry does
  the same). Every recipient was waiting before the statement was sent and nothing is kept after the batch, so each
  request still reads Postgres while being served. At saturation a tags batch holds 60-150 requests.
- **Tag lists sorted by the app** when the database collation is byte order (startup probe of `pg_database`:
  libc `C`/`POSIX`/`C.*`, builtin `C`/`C.UTF-8`): the per-article `ARRAY(... ORDER BY 1)` drops its Sort node
  (-3 to -7% on article/list statements) and `JsonWriter.textArray(sortBytes = true)` insertion-sorts the 1-4 names
  by bytes. With any other collation SQL keeps sorting (the reference's order). `APP_SORT_TAGS=0` turns it off.

## Shared reads (`READ_SHARE`, default on) and the gather window (`READ_GATHER_MS`, default 20)

Postgres CPU per request was the gap to the top entries (box at the 88k hold: ours 253 us/req, #1 159 us/req, apps
equal). #1 (rust-epoll-WorriedArrow) gathers reads for 20 ms and answers each distinct key once per batch. Ours now
does the same inside each kind's batched statement (`ReadShare` in app/Sql.kt), with the same columns and JSON:
- the requests are a MATERIALIZED CTE; each list's capped count runs once per distinct key (the global count once per
  execution), each page once per distinct (key, limit, offset), and each distinct article is decorated once (`art`:
  tags, favorites count, author), then joined back to every request row.
- favorited/following in the shared lists (`READ_VIEWER_FLAGS`, default on): one favorites_pkey and one follows_pkey
  scan per signed-in viewer (`= ANY` of the viewer's page articles / authors) instead of two probes per row
  (60 workload-shaped requests: global list 6.3 -> 3.2 ms, author list 7.6 -> 3.8, tag list 12.9 -> 10.7).
- article, article read-back, comments (each distinct slug's newest 100 with authors, each distinct viewer's
  followees once) and profile share by key. Feed and the favorited list stay per request (nothing repeats; the
  shared shape cost more there).
- Every keyed LATERAL ends in `OFFSET 0`: pulled up into a plain join, the generic plan (which takes a LIMIT parameter
  for 10% of the table) hashed all of articles and users per execution (278 ms per 60 requests).
- `ReadPool` sends a kind once its oldest request has waited `READ_GATHER_MS` or its batch is full
  (`READ_MAX_BATCH`, 256); a `db-gather` clock thread hands kinds whose window passed to idle connections.

Connections: 8 read + 4 write on the box (one per CPU, one per two). With 6 + 2, the write connections were ~100%
busy at 120k users waiting on the WAL flush, and the writes' backlog (5% of requests) broke p99; the read connections
queued while Postgres had idle cores. With 8 + 4 the scorer's search held its 144k cap here (p99 489 ms at the hold).

Lab (2026-10-27, box simulation on 8 of 20 laptop CPUs, lab/reports/omarchy-20261027.md): at 120k users Postgres
went from 170 to 127 us/req (statement execution 5.4 -> 4.1 cores; the global list 127 -> 44 s per 2 minutes), the
app from 46 to 40 us/req; the scorer's search held 130k (here) instead of 120k. Per execution, 60 workload-shaped
requests: global list 15.8 -> 4.8 ms, author list 5.3 -> 3.3, article 0.85 -> 0.50, tag list 11.7 -> 9.3.

## Kotlin/Native specifics (linuxX64Main, build.gradle.kts)

This folder is the Native build of the same tree: `start.sh` execs `build/bin/linuxX64/releaseExecutable/conduit.kexe`.
- **Codegen for the build machine**: build.sh asks Kotlin/Native's clang (`-march=native -###`) for the CPU name and full
  +/- feature list and passes them as `-Pconduit.targetCpu/targetCpuFeatures`; build.gradle.kts turns them into
  `-Xoverride-konan-properties=targetCpu.linux_x64=..;targetCpuFeatures.linux_x64=..` (the box builds what it runs).
- **Binary options** (Kotlin/Native 2.4.21, `-Xbinary=`): `gc` = `pmcs` (parallel mark, concurrent sweep; the compiler's own
  default is `cms`), `preCodegenInlineThreshold=40`; `-Xallocator` `custom` (default) | `std`. Others worth a lab run:
  `gcMarkSingleThreaded`, `auxGCThreads`, `gcMutatorsCooperate`, `concurrentWeakSweep`, `gcSchedulerType`
  (`adaptive` default, `aggressive`, `manual`), `pagedAllocator`, `fixedBlockPageSize`, `latin1Strings`. Selected with
  `CONDUIT_*` environment variables (README.md).
- **Runtime**: the GC heap target defaults to 10 MiB, so `platformInit` raises its floor to `GC_HEAP_MB` (512).
- The HTTP loop (`NativeHttp.kt`) has the same overload hardening as the JVM's `EpollHttp.kt` (guarded turn, close before
  `logSafe`, idempotent finishClose, no fd leak when accept runs out of memory), and stays level-triggered.

## Contracts (read the KDoc in these files; they are the source of truth)

| File | What |
|---|---|
| `platform/Platform.kt` | the only platform surface: time, random, env, threads, `Monitor`, `BlockingSocket`, `HmacSha256`, `threadScratch`, `loadLongLE`, `startHttpServer` |
| `util/ByteBuf.kt` | growable write buffer + big-endian helpers (done) |
| `crypto/Sha256.kt` | pure-Kotlin SHA-256 + HMAC (done; Native's HMAC; SCRAM uses `HmacSha256`/`sha256`) |
| `pg/Types.kt` | `Row` (binary column views), `Result`, `Params` (binary encoder), `PgError`, `Oid` (done) |
| `db/Db.kt` | `ReadKind` (batched read statement, uniform 5-array layout, or a parameterless broadcast), `WriteStmt`, `Db.start/read/write/query` |
| `http/Http.kt` | `HttpConn` (platform I/O), `HttpEngine` (common engine), `Exchange` (handler API) |
| `json/Json.kt` | `JsonWriter` (streaming, pre-encoded `JsonName`s), `JsonReader` (request bodies) |
| `auth/Auth.kt` | `Jwt` (HS256 sign/verify), `Passwords` (bcrypt pool, suspend hash/verify) |
| `crypto/BcryptKernel.kt` | `BcryptKernel` (C or Kotlin lanes, chosen at startup), `BcryptC` (expect; FFM in jvmMain, cinterop in linuxX64Main; C in `native/`, see its README) |
| `app/App.kt` | routes + handlers + SQL catalog (`reads`, `writes`) |
| `Main.kt` | wiring + env knobs (done) |

Concurrency rules everybody relies on:
- `Db.read`/`Db.write`/`Passwords.*` ALWAYS suspend (never complete inline) and resume exactly once, on the
  worker thread that did the work (except a read or bcrypt job whose client is gone: see Overload). Publication to
  that thread goes through a lock/queue (happens-before).
  Implement with `suspendCoroutineUninterceptedOrReturn { c -> enqueue(c); COROUTINE_SUSPENDED }`.
- A `Result`/`Row` is valid until the resumed code suspends again or returns: copy what must survive.
- An `Exchange` is answered exactly once; `send` may be called from any thread.
- `HttpConn.tryWrite/requestWritable/execute/close` are callable from any thread; reads and engine callbacks
  only happen on the owning loop.
- No `ThreadLocal`s except via `threadScratch()`; no blocking on HTTP loop threads.

## Rules of the challenge we must keep (README.md "Rules")
No caching across requests of any kind (no result caches, no remembered JWT or bcrypt results); every request
reads Postgres while being served. A batched statement may share its reads among the requests it serves, all of
which were already waiting when it was sent; nothing outlives the statement (the #1 entry's reading of rule 5, and
our tags broadcast above). With `READ_SHARE=0` per-request subqueries are tied to the request row so they run once
per request (the stricter reading this submission started with).
bcrypt cost 10 for every hash, every login verifies.
Every request verifies the HS256 signature and `exp`. Writes are committed before responding. No schema or
server-config changes; session settings only. <= 95 Postgres connections total.

## Code conventions
- Kotlin 2.4, common code first. Platform code only in `jvmMain` / `linuxX64Main` behind `platform/Platform.kt`.
- Hot paths avoid allocation where it is easy (reuse buffers, `@JvmField`, `IntArray` over boxed collections), but
  correctness and clarity first; we optimize with measurements.
- KDoc on public declarations: say *why*, briefly. Match the existing style.
- Tests in `src/commonTest/kotlin` (kotlin-test). Run: `gradle --no-daemon -q jvmTest` (fast) and
  `linuxX64Test`.

## Lab (this machine)
- `source /etc/profile.d/challenge-env.sh; export JAVA_HOME=/opt/jdk` before building (Go 1.27, PG 18, JDK 27,
  kotlinc on PATH; Gradle uses the local Kotlin/Native at /opt/kotlin-native via ~/.gradle/gradle.properties).
- Postgres 18.4 at 127.0.0.1:5432 (superuser `postgres`, trust); seeds `conduit_dev` (2%) and `conduit_seed`
  (full); role `conduit`/`conduit`. Postgres is pinned to CPUs 0-1.
- Conformance: `bash test/run.sh submissions/kotlin-raw-luben93` from the repo root (builds, starts, runs 197
  checks). Binary also at `/opt/tools/conformance -base http://127.0.0.1:3000 -secret multicore-server-challenge`.
- Load: `SRV_CPUS=0-1 LG_CPUS=2-3 TAG=x /opt/tools/bench.sh submissions/kotlin-raw-luben93 <users> <think-scale>`
  prints req/s, p95/p99, CPU µs per request for app and Postgres. Only ONE load test may run at a time.
  `DB_STATS_S=20` makes the server log batching statistics (requests per batch per kind, round trips) every 20 s.
  Compare Postgres µs/req at a fixed load with care: faster code means fewer queued requests, smaller batches and
  so more executions per request; the ceiling runs (13000 users at think-scale 0.2 and up) are the real test.
- Local fd limit is 20000 per process (cannot be raised); the box gives 200000.
- Research notes (verbatim SQL of the top entries, conformance checklist, bcrypt details):
  `/tmp/claude-0/-home-user-multicore-server-challenge/99796a5c-b120-524c-822d-dc73b94b523b/scratchpad/research/`

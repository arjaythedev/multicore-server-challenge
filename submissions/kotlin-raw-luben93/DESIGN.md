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
3. **Few runnable threads**: 2 HTTP loops on 8 cores, 6 read + 2 write Postgres connections, 1 bcrypt thread.
4. **OS limits at 64k-120k connections** (the scorer probes 32k, 64k, then 120k = the cap): listen backlog 65535,
   SO_REUSEPORT per loop, no thread or >=128 KiB buffer per connection (`vm.max_map_count` is 65530 on the box),
   no buffers held by idle connections, RLIMIT_NOFILE raised to the hard limit (200000 under systemd), EMFILE
   backs off instead of spinning, no idle timeout (think time is up to 70 s).

## Threads and request flow

```
HTTP loop thread (x HTTP_THREADS, default ceil(cpus/4)=2)       PG read thread (x DB_READ_CONNS, default 6)
  epoll/NIO: accept, read into loop scratch                       loop:
  HttpEngine.onData: parse request                                  take a batch (oldest kind first, <= 64 reqs)
  Jwt.verify (HMAC, every request)                                  send one Bind/Execute/Sync, read to 'Z'
  start handler coroutine ──► Db.read(kind, ...) suspends ───────►  route rows by r.i to each request's Result
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

## Contracts (read the KDoc in these files; they are the source of truth)

| File | What |
|---|---|
| `platform/Platform.kt` | the only platform surface: time, random, env, threads, `Monitor`, `BlockingSocket`, `HmacSha256`, `threadScratch`, `startHttpServer` |
| `util/ByteBuf.kt` | growable write buffer + big-endian helpers (done) |
| `crypto/Sha256.kt` | pure-Kotlin SHA-256 + HMAC (done; Native's HMAC; SCRAM uses `HmacSha256`/`sha256`) |
| `pg/Types.kt` | `Row` (binary column views), `Result`, `Params` (binary encoder), `PgError`, `Oid` (done) |
| `db/Db.kt` | `ReadKind` (batched read statement, uniform 5-array layout), `WriteStmt`, `Db.start/read/write` |
| `http/Http.kt` | `HttpConn` (platform I/O), `HttpEngine` (common engine), `Exchange` (handler API) |
| `json/Json.kt` | `JsonWriter` (streaming, pre-encoded `JsonName`s), `JsonReader` (request bodies) |
| `auth/Auth.kt` | `Jwt` (HS256 sign/verify), `Passwords` (bcrypt pool, suspend hash/verify) |
| `crypto/BcryptKernel.kt` | `BcryptKernel` (C or Kotlin lanes, chosen at startup), `BcryptC` (expect; FFM in jvmMain, cinterop in linuxX64Main; C in `native/`, see its README) |
| `app/App.kt` | routes + handlers + SQL catalog (`reads`, `writes`) |
| `Main.kt` | wiring + env knobs (done) |

Concurrency rules everybody relies on:
- `Db.read`/`Db.write`/`Passwords.*` ALWAYS suspend (never complete inline) and resume exactly once, on the
  worker thread that did the work. Publication to that thread goes through a lock/queue (happens-before).
  Implement with `suspendCoroutineUninterceptedOrReturn { c -> enqueue(c); COROUTINE_SUSPENDED }`.
- A `Result`/`Row` is valid until the resumed code suspends again or returns: copy what must survive.
- An `Exchange` is answered exactly once; `send` may be called from any thread.
- `HttpConn.tryWrite/requestWritable/execute/close` are callable from any thread; reads and engine callbacks
  only happen on the owning loop.
- No `ThreadLocal`s except via `threadScratch()`; no blocking on HTTP loop threads.

## Rules of the challenge we must keep (README.md "Rules")
No caching across requests of any kind (no result caches, no remembered JWT or bcrypt results); every request
reads Postgres while being served. Batching shares a STATEMENT, never a result: per-request subqueries must be
tied to the request row so they run once per request. bcrypt cost 10 for every hash, every login verifies.
Every request verifies the HS256 signature and `exp`. Writes are committed before responding. No schema or
server-config changes; session settings only. <= 95 Postgres connections total.

## Code conventions
- Kotlin 2.4, common code first. Platform code only in `jvmMain` / `linuxX64Main` behind `platform/Platform.kt`.
- Hot paths avoid allocation where it is easy (reuse buffers, `@JvmField`, `IntArray` over boxed collections), but
  correctness and clarity first; we optimize with measurements.
- KDoc on public declarations: say *why*, briefly. Match the existing style.
- Tests in `src/commonTest/kotlin` (kotlin-test). Run: `./gradlew --no-daemon -q jvmTest` (fast) and
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
- Local fd limit is 20000 per process (cannot be raised); the box gives 200000.
- Research notes (verbatim SQL of the top entries, conformance checklist, bcrypt details):
  `/tmp/claude-0/-home-user-multicore-server-challenge/99796a5c-b120-524c-822d-dc73b94b523b/scratchpad/research/`

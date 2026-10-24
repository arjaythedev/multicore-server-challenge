# Research: techniques in the other submissions

A survey of the merged submissions, the examples and the open pull requests (as of 2026-10-24), made before tuning this one. It is the input to [FINDINGS.md](FINDINGS.md), which records what was actually adopted and measured. Gains quoted here are the other entries' own claims, not our measurements.


Date: 2026-10-24. Source: `upstream/main` of https://github.com/arjaythedev/multicore-server-challenge, all PRs (open + closed), LEADERBOARD.md, skunk `v2.0.0-RC3` source.
Our current (doobie) entry: https://github.com/sideeffffect/multicore-server-challenge/tree/scala-http4s-sideeffffect/submissions/scala-http4s-sideeffffect

## 0. The one fact that drives everything

**Postgres is the bottleneck.** Every top entry spends 70-80% of the 8-core box in Postgres and only 17-27% in the app.
The score is decided by **Postgres CPU per request**, then app CPU, then tail latency under queueing.
Calibration from PR #36 (https://github.com/arjaythedev/multicore-server-challenge/pull/36): `users ≈ 7.6 cores / (0.25 req/s × µs per request)`.
100k users needs <= ~304 µs of total CPU per request (app + PG).

| # | Users | Entry | App / PG CPU | Key ideas |
|--:|--:|---|---|---|
| 1 | 100,000 | rust-tokio-Scooter1337 https://github.com/arjaythedev/multicore-server-challenge/pull/7 | 20% / 70% | read coalescing (unnest+LATERAL), group commit, separate R/W conns, 6+2 conns, 2 app threads, 4-lane bcrypt |
| 2 | 95,000 | csharp-sockets-jh-d https://github.com/arjaythedev/multicore-server-challenge/pull/22 | 21% / 75% | own PG client, batched reads per kind (unnest+LATERAL), 12 R + 16 W conns, generic plans, Memoize off |
| 3 | 84,000 | c-iouring-tigokraft https://github.com/arjaythedev/multicore-server-challenge/pull/10 | 18% / 80% | 1 round trip/request, pipelining with depth cap 16 + FIFO, 32 conns, SQL rewrites, generic plans |
| 4 | 84,000 | cobol-gnucobol-benmandrew https://github.com/arjaythedev/multicore-server-challenge/pull/15 | 20% / 75% | pipelined driver, shared Sync for reads, jit/generic/memoize off, 4-lane bcrypt with 500 ms window |
| 5 | 84,000 | csharp-kestrel-xeonfx (open) https://github.com/arjaythedev/multicore-server-challenge/pull/8 | 25% / 74% | Kestrel + Npgsql; NpgsqlBatch read groups (32/Sync), group commit 128, 5-lane bcrypt |
| 6 | 80,000 | rust-mio-foovoo https://github.com/arjaythedev/multicore-server-challenge/pull/11 | 18% / 75% | 8 backends total, least-work routing, shared Syncs, group commit, binary results |
| 7 | 68,000 | cpp-asio-c-hatton https://github.com/arjaythedev/multicore-server-challenge/pull/4 | 27% / 71% | libpq pipeline, 16 conns, group commit, best documented SQL rewrites |
| 8 | 65,000 | goose-native-tbsvttr (open) https://github.com/arjaythedev/multicore-server-challenge/pull/32 | 18% / 71% | bounded reader credits, read batching |
| 9 | 62,000 | goose-epoll-xeonfx https://github.com/arjaythedev/multicore-server-challenge/pull/31 | 17% / 71% | batched list reads, p99 842 ms (250 ms bcrypt window hurts tail) |
| 10 | 61,000 | go-epoll-o7livetype https://github.com/arjaythedev/multicore-server-challenge/pull/28 | 20% / 73% | 20 R + 2 W conns, group commit |
| 11 | 58,000 | rust-hyper-cknutson12 https://github.com/arjaythedev/multicore-server-challenge/pull/1 | 29% / 69% | **closest to "idiomatic"**: hyper+tokio-postgres, 16 conns, 1 statement/request, generic plans. No batching. |
| 12 | 46,000 | kotlin-vertx-canleon https://github.com/arjaythedev/multicore-server-challenge/pull/30 | 37% / 51% | **best JVM**: Vert.x pg client (pipelined), 16 conns, 1 stmt/request, generic plans, 2 GB heap |
| 15 | 44,000 | kotlin-ktor-canleon https://github.com/arjaythedev/multicore-server-challenge/pull/29 | 45% / 49% | same SQL as vertx; Ktor costs +35% app CPU vs Vert.x |
| 23 | 21,000 | examples/java (Spring+Hikari, reference SQL, nginx) https://github.com/arjaythedev/multicore-server-challenge/tree/main/examples/java | 30% / 46% (+nginx 11%) | baseline |

Observation: JVM entries have PG at ~50% CPU and app at 37-45%: **the JVM entries are app-bound, not PG-bound**. For us the
app side (Ember + CE + circe) matters more than for the native entries. The ~470 µs/request we measured locally (incl. bcrypt)
is ~3-4x vertx's ~0.1 ms app cost. Two levers: fewer PG statements (also lowers app work per request) and cheaper app path.

Not scored: c-iouring-27bhd https://github.com/arjaythedev/multicore-server-challenge/pull/5 (POST /api/articles 2 s), d-vibe https://github.com/arjaythedev/multicore-server-challenge/pull/18 (SIGILL crash).
Open, unscored, advertising tricks: julia-raw https://github.com/arjaythedev/multicore-server-challenge/pull/43, go-raw https://github.com/arjaythedev/multicore-server-challenge/pull/37, c-iouring-ssmurf https://github.com/arjaythedev/multicore-server-challenge/pull/35, c-libco https://github.com/arjaythedev/multicore-server-challenge/pull/36, elixir-gentcp https://github.com/arjaythedev/multicore-server-challenge/pull/42, python-rawsocket https://github.com/arjaythedev/multicore-server-challenge/pull/40, purebasic https://github.com/arjaythedev/multicore-server-challenge/pull/41, nim https://github.com/arjaythedev/multicore-server-challenge/pull/38, python-uvloop (46k, scored) https://github.com/arjaythedev/multicore-server-challenge/pull/13.

Maintainer (arjaythedev) merged #7 and #22 with read coalescing, group commit and interleaved bcrypt without objections.
No maintainer comment rejects any of the techniques below. Only rule notes on the leaderboard: prebuilt NuGet (#8), worker restarts (#13).

---

## 1. Postgres access

| Technique | Who | Evidence | Verdict for us |
|---|---|---|---|
| **Session settings: `plan_cache_mode=force_generic_plan`, `jit=off`, `max_parallel_workers_per_gather=0`** | all of top 12: tigokraft (+41% list, +12% article in pgbench), cpp-asio (-30% PG CPU), vertx (-17% PG CPU), rust-mio, cobol, jh-d, rust-hyper | biggest single PG lever after SQL shape | **ADOPT.** Pass as skunk `withConnectionParameters(DefaultConnectionParameters ++ Map("plan_cache_mode"->"force_generic_plan","jit"->"off","max_parallel_workers_per_gather"->"0"))`. Startup-packet values survive `RESET ALL` (they are the session's reset values). Note: generic plans need `jit=off` (LIMIT $n cost > jit_above_cost, rust-mio). |
| **Fewer backends than allowed** (8-32 total) | rust-mio 8 (68k→72k going 16→4 per 4 cores), Scooter 6R+2W, cpp-asio 16, vertx 16 (8 too few, 24/32 no better), jh-d 28, tigokraft 32 (12-32 equal, 48+ worse p99), go-epoll 95 raised p99 17x | robust across all entries | **ADOPT.** skunk has no cross-fiber pipelining (one exchange per session behind a `Mutex`), so each session = 1 statement in flight. Start at **12-16 sessions** (1.5-2x cores) for reads + 2-4 for writes; sweep 8/12/16/24. Our current 32 is likely too many. |
| **One statement / one round trip per request** (fold page+count, slug lookup+comments, lookup+write CTEs) | every top entry; rust-hyper and vertx are the idiomatic examples | vertx: page+count in one statement was part of -25% PG CPU vs JDBC/32 conns | **ADOPT.** Pure SQL change; works with skunk `Query`. Removes a PG statement start/snapshot/xact per request and halves our app-side round-trip work. |
| **Page-first list query** (cut ids with LIMIT/OFFSET in a subquery, decorate only returned rows) | tigokraft (1.7x pgbench), cpp-asio (global 182→91 µs), rust-mio (1.68→0.36 ms at offset 40), vertx, rust-hyper | huge, identical results | **ADOPT.** Example: cpp-asio SQL https://github.com/arjaythedev/multicore-server-challenge/blob/main/submissions/cpp-asio-c-hatton/src/sql.hpp |
| **Tag names by PK** `ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id=at.tag_id) FROM article_tags at WHERE at.article_id=a.id ORDER BY 1)` | tigokraft (1.33x list), cpp-asio (8.8→2.9 µs/article), rust-mio, vertx | generic plan otherwise hash-joins all 200 tags per article | **ADOPT.** |
| **Capped count rewrites**: global `CASE WHEN EXISTS (SELECT 1 FROM articles ORDER BY id OFFSET 999) THEN 1000 ELSE (SELECT count(*) FROM articles) END`; others `count(*) FROM (... LIMIT 1000)`; feed `author_id = ANY(ARRAY(SELECT followee_id ...))` | cpp-asio (-10% global, -9% feed), rust-hyper (count from oldest, all-visible end: no heap fetches), rust-mio | moderate | **ADOPT** (check SPEC count semantics: min(count,1000)). |
| **Constant inner limit** `(SELECT ... ORDER BY id DESC OFFSET $3 LIMIT 100) a LIMIT $2` | tigokraft | +14.7% on global list: stops generic plan from assuming 50k rows and adding a Memoize that `memset`s a hash table each execution | **ADOPT** (limit validated 1-100, so identical rows). |
| **Feed `following` = constant true** | rust-mio (2-4%), go-epoll (-3%), vertx, jh-d | small | **ADOPT** (same snapshot proves it). |
| **Comments: followee set once per query** | jh-d, Scooter, goose | small | **ADOPT** if comments query shows up in profile. |
| **Separate read / write connections** | Scooter, jh-d, rust-mio, cpp-asio, go-epoll, goose | commit waits for WAL flush; on a shared conn reads queue behind it. tigokraft measured *no* difference at saturation | **ADOPT** (cheap: two session pools). |
| **Pipelining many requests on one connection** | tigokraft (depth 16), cpp-asio, rust-mio, cobol, vertx, rust-hyper (tokio-postgres) | vertx vs JDBC: -25% PG CPU, but bundled with 1 stmt/request and fewer conns | **NOT AVAILABLE in skunk** (Mutex per session, issue https://github.com/typelevel/skunk/issues/912 open). Emulate with more sessions (12-16). Do not hand-write a PG client (not idiomatic). |
| **Shared Sync for several reads** (one implicit xact for N requests' statements) | cobol, rust-mio (avg 2.6 req/Sync), kestrel #8 (32/Sync) | tigokraft tried it: no CPU saved, worse p99 | **MAYBE / skip.** skunk has no public multi-statement extended-protocol batch API. |
| **Read coalescing: N same-kind requests → one `unnest(...) WITH ORDINALITY CROSS JOIN LATERAL (per-request query)` statement** | Scooter #1 (+7-10% req/s at 100k locally), jh-d #2, goose (34k→41k req/s on GCP), julia #43, go-raw #37, elixir #42 | the top-2 trick; rust-mio tried it and saw no gain ("batched statements cost more per element") | **MAYBE (second phase).** Rule-5 safe only if each request gets its own execution: tie request-independent subqueries to the request row (`WHERE r.i >= 0`), count in `OFFSET 0` subquery, `SET enable_memoize = off` on *those* sessions only (tigokraft: memoize off is -55% for non-batched plans!). Scooter's "shared article enrichment" across requests is grey: **avoid that part**. Sketch in §8. |
| **Binary result format** | jh-d, rust-mio, cpp-asio, goose | saves PG text formatting (timestamps) | **NOT AVAILABLE in skunk** (text only, issue https://github.com/typelevel/skunk/issues/837). Minor. |
| **JSON built by Postgres** (`json_agg`, `json_build_object`) | cobol (tags only), python-rawsocket #40, purebasic #41, goose (tags) | moves CPU into the bottleneck | **AVOID** for hot paths. Fine for nothing in our case. |
| **Literal fast-path statements per (limit, offset)** | c-iouring-27bhd #5 | unscored | **AVOID** (benchmark-shaped, rule 8 smell). |
| **Deep-offset index-only path** | cpp-asio (offset 1e8: 20 s→1.2 s) | robustness only | MAYBE (only for safety). |
| **Tags inserted only when missing, sorted** | jh-d, rust-mio, goose | avoids deadlocks / sequence burn; `ON CONFLICT DO UPDATE` CTE in rust-hyper | **ADOPT** sorted insert. |

## 2. Write path

| Technique | Who | Evidence | Verdict |
|---|---|---|---|
| **Data-modifying CTEs** (follow, favorite read-back adds `RETURNING 1` count, delete with owner check) | rust-hyper, rust-mio, cpp-asio, tigokraft | 1 round trip instead of 2-3 | **ADOPT.** |
| **Create article in one statement/one implicit xact** (`INSERT tags ON CONFLICT DO UPDATE ... RETURNING id` CTE) | rust-hyper; vertx splits it (not spec-strict) | correctness + 1 round trip | **ADOPT** (rust-hyper form; keeps SPEC "one transaction"). |
| **Group commit** (N writes, one xact, one WAL flush; each response waits for commit; failed group retried per request) | Scooter (1 ms / 128), jh-d (16 W conns rely on PG's own group commit), kestrel #8 (128), cpp-asio (p99 write 70→15 ms), rust-mio, go-epoll | writes are 5%; helps latency more than throughput | **MAYBE.** Simplest idiomatic version: just 4-8 write sessions (Postgres groups concurrent commits itself, like jh-d). Full version: `Queue[IO, (Write, Deferred)]` + `fs2.Stream.fromQueueUnterminated(q).groupWithin(128, 1.ms)` → one `session.transaction` per chunk, `SAVEPOINT` per item or retry individually on failure; complete Deferreds after commit. Rule 6 OK. |

## 3. bcrypt

| Technique | Who | Evidence | Verdict |
|---|---|---|---|
| **Dedicated, bounded pool** | everyone (half the cores typical; Scooter 1 thread, rust-mio 2 at nice 10) | protects PG and event loops | **ADOPT** (have it). Consider 2 threads, not cores/2: at 100k users bcrypt load ≈ N/3600 hashes/s ≈ 28/s × ~55 ms ≈ 1.5 cores. Sizing above need only steals CPU in bursts. `Semaphore` + `IO.evalOn(bcryptEC)`. |
| **Faster library: Bouncy Castle** | vertx/ktor: 51 ms vs 61 ms (at.favre) | -16% bcrypt CPU | **ADOPT** (`org.bouncycastle:bcprov-jdk18on` `OpenBSDBCrypt`). |
| **Interleaved/multi-lane bcrypt** (4-5 hashes in lockstep) | Scooter, tigokraft (46→24 ms), cpp-asio (2.75x), rust-mio (3x), cobol, goose (5 lanes), go-epoll, kestrel, julia, go-raw | bcrypt was ~20% of CPU before (cpp-asio); rule 7 OK (full cost-10 bcrypt) | **TOO GAMED / not idiomatic** for us: custom crypto in Scala; JIT unlikely to give the ILP win without careful manual unrolling. |
| **Batch window (wait up to 150-500 ms to fill lanes)** | cobol 500, goose 250 (hurt p99: 842 ms), tigokraft 150, Scooter 160, jh-d 300 | only useful with multi-lane | **AVOID** (no lanes). |
| **Low priority bcrypt threads** (`SCHED_BATCH`, nice) | rust-mio, goose, 27bhd | small | MAYBE: Java can't nice a thread portably; skip. |

## 4. JWT
All entries: HS256 per request, key schedule once (`Mac` per thread / pre-absorbed pads). Fast-path for standard header (rust-mio).
**ADOPT**: keep our hand-written `Jwt.scala`; reuse a `Mac` per thread (`ThreadLocal`) instead of `Mac.getInstance` per request; compare signatures with `MessageDigest.isEqual`. Do not cache verifications (rule 5/7).

## 5. JSON
Native entries write JSON bytes by hand from PG rows. vertx/ktor: "writing JSON as raw bytes: no measurable gain" on JVM.
**ADOPT (cheap)**: circe encoders with `Printer.noSpaces.copy(dropNullValues=false)` + `printToByteBuffer`, or `jsoniter-scala` only if profiling shows circe hot. **AVOID** PG-side JSON.

## 6. HTTP layer
| Technique | Who | Verdict |
|---|---|---|
| Direct, no nginx | every top entry; vertx: +29% req/s; nginx = 11-19% of box | **ADOPT** (have it). |
| Per-connection memory near zero (shared read buffer, buffer only while request incomplete) | tigokraft 200 B/conn, rust-mio 100 B, goose 60 MB @130k, vertx 190 MB @40k | Ember: ~35 KB/conn → 100k users ≈ 3.5 GB heap. Keep 8 KB buffer; **ADOPT `-XX:+UseCompactObjectHeaders`** (JDK 25 product flag, JEP 519) to cut fiber/scope overhead ~10-20%. |
| Listen backlog | rust-mio 65535, java example accept-count 1024 | **ADOPT** (have FFM `listen()` raise). |
| Infinite keep-alive idle | rust-hyper, ours | **ADOPT** (have it). |
| `SO_REUSEPORT` per-loop listeners, few event loops (2 on 8 cores) | tigokraft (+5% with 1 loop/4 CPUs), Scooter 2 Tokio workers, rust-mio | **MAYBE**: CE analogue = cap WSTP compute threads (e.g. 4-6) so app threads don't contend with PG backends. `override def runtimeConfig`/`IORuntime` builder `computeWorkerThreadCount`? measure 4/6/8. |
| Ktor vs Vert.x: framework overhead matters on JVM (-35% app CPU) | canleon | Ember is closer to Ktor than Vert.x in cost; keep `HttpApp` thin: route match on `req.method`/`req.pathInfo` segments, avoid middleware stacks, `Logger` off. |

## 7. Threads, cores, admission
- **Bounded admission + FIFO** (tigokraft cap 16/conn + FIFO: p95/p50 28%→18%; goose-native reader credits): our analogue is the session pool's waiting queue. **ADOPT**: fair FIFO checkout (CE `Queue`/`Semaphore` are FIFO).
- **Backpressure, not 503** (go-epoll, kestrel 503 at limit): errors count against 1%. Prefer waiting (latency) over 503; set a generous upper bound only.
- **JVM**: fixed heap (vertx: 2 GB, GC 73→21/min), G1 vs ZGC/Parallel: no gain (vertx). `-Dcats.effect.tracing.mode=none` (have). Starvation checker off (have). Heap: size for connections (100k × 35 KB ≈ 3.5 GB) → keep 4 GB, but try compact headers first.

## 8. skunk facts (researched from source `v2.0.0-RC3`)

**Versions** (Maven Central `org.tpolecat:skunk-core_3`): stable **1.0.0** (2026-04-15), **1.1.0-RC1**, **2.0.0-RC3** (2026-09-06, latest).
Use **2.0.0-RC3** if pre-release is acceptable: PR https://github.com/typelevel/skunk/pull/1356 "Optimize protocol round trips"
cuts exchanges: `execute(query)(args)` 4→**1**, `unique`/`option` 3→**1**, parameterized command 3→**1** (inside explicit xact: 2).
On loopback the latency win is small, but every exchange is a PG wakeup + socket write/read + fiber hop: fewer exchanges = less app and kernel CPU.
RC3 also fixes "don't hand out errored/closed sessions from pool" (https://github.com/typelevel/skunk/pull/1354). Pin it in build.sbt (rule 11).
Deps: fs2 3.14.0, otel4s 1.1.0 (matches our fs2).

**Architecture limits**
- One exchange at a time per session (`Exchange` = `Mutex.lock.surround(...).uncancelable`). No cross-fiber pipelining (issue #912 open). → throughput = number of sessions.
- Text format for all params/results (issue #837). Arrays: `_int8`, `_text`, `_int4` codecs exist (needed for unnest batching).
- Prepared statements: `session.prepare(q)` is cached per session (Parse cache, LRU, `parseCacheSize` default 2048); Describe cache shared across the pool (`queryCacheSize`/`commandCacheSize` 2048). `session.execute(q)(args)` = `prepare(q).flatMap(_.fetchAll(args))` → after first use per session: one Bind/Execute/Sync exchange. Prepare at startup by warming each session (run each statement once) to avoid first-request Parse latency.
- `TypingStrategy.BuiltinsOnly` (default) avoids extra type lookups: keep.

**Pool trap (important)**: `Session.Builder#pooled(max)` hard-codes `checkin = Recyclers.full` = `UNLISTEN *` + `RESET ALL` **two extra simple-query exchanges on every checkout/return** (issue https://github.com/typelevel/skunk/issues/877 "Cannot configure Recycler", open). With one statement per request that **triples** PG statements per request. Workaround (idiomatic): open N sessions once with `builder.single` (each its own `Resource`), put them in a CE `Queue[IO, Session[IO]]`, and borrow with `Resource.make(q.take)(q.offer)`; on error, check `session.transactionStatus`/health and replace the session. Session SETs then never get reset; still put them in `connectionParameters` so a replacement session has them.

**Tracing/metrics off**
```scala
given TracerProvider[IO] = TracerProvider.noop[IO]   // org.typelevel.otel4s.trace
given MeterProvider[IO]  = MeterProvider.noop[IO]    // org.typelevel.otel4s.metrics
Session.Builder[IO]
  .withTelemetryConfig(TelemetryConfig.default
     .withCaptureQuery(QueryCaptureConfig.disabled)
     .withProtocolSpans(TelemetryConfig.ProtocolSpans.Disabled)
     .withPoolSpans(TelemetryConfig.PoolSpans.Disabled))
```
otel4s noop still allocates a little per span; disabling protocol spans removes most calls. Also `withDebug(false)` (default), `withRedactionStrategy(RedactionStrategy.All)` is irrelevant for speed.

**Builder sketch**
```scala
val builder = Session.Builder[IO]
  .withHost(host).withPort(port).withUserAndPassword(u, p).withDatabase(db)
  .withConnectionParameters(Session.DefaultConnectionParameters ++ Map(
    "plan_cache_mode" -> "force_generic_plan", "jit" -> "off",
    "max_parallel_workers_per_gather" -> "0", "application_name" -> "conduit-skunk"))
  .withTelemetryConfig(noTelemetry)
// readPool: 12-16 sessions, writePool: 4 sessions, each a Queue-backed fixed pool (see "pool trap")
```

**Read coalescing sketch (phase 2, optional)**
```scala
// one Batcher per query kind (article-by-slug, list-global, list-tag, ...):
final case class Req[A, B](args: A, out: Deferred[IO, Either[Throwable, List[B]]])
Stream.fromQueueUnterminated(q)
  .chunks                                  // no timer: take what queued while sessions were busy (jh-d style)
  .map(_.take(64))
  .parEvalMapUnordered(maxInFlightPerKind) { reqs =>
     readPool.use(s => s.execute(batchedQuery)((ids, viewers, slugs)))   // _int4/_int8/_text arrays
       .flatMap(rows => reqs.traverse_(r => r.out.complete(Right(rows.filter(_.ord == r.ord)))))
  }
```
Only dispatch when a session is free (so batches grow only under load). Must keep per-request executions (no shared subresults), `enable_memoize=off` on batch sessions. Expect +5-20% at saturation (Scooter +7-10%, goose +20%); rust-mio saw 0%. Do it after phase 1.

## 9. Rule risks
- **Rule 5**: shared enrichment across requests in one statement (Scooter "shared article metadata", goose "every distinct article is read once") and shared `GET /api/tags` execution for waiting requests: grey; avoid. Per-request LATERAL execution is what jh-d documents as compliant.
- **Rule 6**: group commit fine only if the response waits for COMMIT; never `synchronous_commit=off`.
- **Rule 7**: multi-lane bcrypt is compliant (full cost 10), just not idiomatic. Never cache verify results; never lower cost.
- **Rule 8**: literal (limit, offset) fast paths (#5), tuning bcrypt windows to the known login rate (cobol's analysis uses the workload model) are benchmark-shaped; avoid.
- **Rule 2**: only session SETs (startup params are session-level). No `ALTER ROLE/DATABASE`.
- **Rule 3**: no indexes; all rewrites must use existing indexes.
- **Rule 9**: no worker restarts (#13 flagged).
- **Rule 11**: pin skunk RC version exactly.

## 10. Ranked plan for the skunk port

| Rank | Idea | Expected impact | Confidence |
|--:|---|---|---|
| 1 | One statement per request (page+count, CTE writes, comments with slug lookup) | large: fewer PG statements and fewer app round trips | 0.9 |
| 2 | Avoid `Session.pooled` checkin recycler (`UNLISTEN *` + `RESET ALL` per checkout): fixed Queue-backed session pool | large: removes 2 statements per request | 0.85 (verified in source; not measured) |
| 3 | Startup params: `force_generic_plan`, `jit=off`, `max_parallel_workers_per_gather=0` | large: -17% to -30% PG CPU in other entries | 0.9 |
| 4 | Page-first lists + tag names by PK + constant inner LIMIT 100 | large on lists (1.3-1.7x per statement) | 0.9 |
| 5 | skunk 2.0.0-RC3 (1 exchange per execute) + telemetry off | medium: app CPU and wakeups | 0.75 |
| 6 | 12-16 read sessions + 4 write sessions (down from 32) | medium | 0.75, needs sweep |
| 7 | Capped-count rewrites, feed `following=true` | small-medium | 0.85 |
| 8 | Bouncy Castle bcrypt on 2 bounded threads; compact object headers; cap CE compute threads | small-medium | 0.65 |
| later | Read coalescing (unnest+LATERAL) via fs2 batcher; group commit via `groupWithin` | +5-20% at saturation, more code | 0.55 |

Avoid: hand-written PG wire client / multi-lane custom bcrypt (not idiomatic), cross-request shared enrichment or shared tag execution (rule 5 grey), PG-built JSON or literal per-offset statements (moves load to the bottleneck / rule 8).

Caveat: "startup-packet params survive `RESET ALL`" is from Postgres GUC semantics (client source is the reset value); confidence 0.85, verify with `SHOW plan_cache_mode` after a `RESET ALL` on a dev DB.

## The challenge owner's videos

Arjay McCandless ([YouTube](https://www.youtube.com/channel/UCdSsl5RM4Tne4MhDRz2HjWw)) runs both challenges. His
videos on them, transcribed and read for this submission (one transcript from YouTube's captions, the rest from the
audio with Whisper `small.en`):

| Date | Video | What it is |
|---|---|---|
| 2026-09-25 | [How Many Users Can a $12 Server Handle?](https://www.youtube.com/watch?v=GFtFIxrAjIs) | Node + Postgres + Nginx on the $12 box; the limit is CPU; caching took it from 2,500 to 5,200 users |
| 2026-10-02 | [Which Programming Language Can Handle the Most Users on a $12 Server?](https://www.youtube.com/watch?v=sQXFhh_PiG4) | 8 stacks, one query per endpoint, no caching; Spring Boot 5,100 users on Postgres, 10,250 on SQLite; the $12 challenge's origin |
| 2026-10-09 | [I Ran 4 Databases on the Same $12 Server](https://www.youtube.com/watch?v=_M2-Dw4DpsE) | Postgres, MySQL, MariaDB, SQLite; durability: SQLite `synchronous=FULL` collapses on writes without group commit |
| 2026-10-13 | [I Asked Expert Programmers to Max Out a $12 Server](https://www.youtube.com/watch?v=QGWKCaglSBI) | Batch 1 results, the common tricks, and the trade-offs he wouldn't ship |
| 2026-10-16 | [More CPUs = Better? I tested 4 Programming Languages](https://www.youtube.com/watch?v=pG3xXuNdL34) | 1/2/4/8 vCPUs, Postgres; the multicore challenge's origin |
| 2026-10-23 | [I Asked Developers to Max Out a $12 Server (again)](https://www.youtube.com/watch?v=-BFt49ula08) | Batch 2 results, entry by entry, including the Scala/Netty one |

### What he measures and values

- **The limit is CPU** for this workload (his first video: 80% CPU at 2,500 users, 99% at 4,000; disk, RAM and network
  were fine; CPU steal 0-2% even on a shared droplet). Under a write-heavy load it moves to **disk**.
- **vCPUs are hyper-threads**, and per-core speed differs between machines sold under the same label (up to 20% in
  his tests); batch 2 moved to a different provider and scores doubled with the same code.
- His **load generators** became the limit twice (k6 memory, then source ports at ~240,000 connections per target IP);
  batch 2 used mload, replaying the k6 user model (one request per ~10 s per user).
- **The tricks the fastest entries shared** (batch 1): no Nginx, statements prepared once on one connection, JSON built
  by SQLite, group commit, frameworks replaced by hand-written servers. Batch 2 added io_uring with registered file
  tables (to get past the 65,535-descriptor limit), evicting idle connections near the limit, range-scan feeds, PGO.
- **What stopped entries** in batch 2: CPU, memory (Go net/http and Haskell were OOM-killed, the winner at 360k), the
  descriptor limit (four entries tied at 71,000), storage waits (Quarkus at `synchronous=FULL` with per-request commits:
  20-39% iowait; F#'s checkpointing), and a crash in an error handler (C#).
- **What he would not ship**: "I probably wouldn't ship most of these implementations or approve these PRs" (1,300-line
  single-file servers, unsafe Rust, partial HTTP), coupling to SQLite internals, and **durability**: "many of the
  fastest entries use SQLite's write-ahead log with synchronous set to normal ... a write could still be lost if the
  machine loses power ... a trade-off I would not use in production". His database video shows the alternative: the
  server databases fsync every commit and use group commit to share the flush; SQLite at `FULL` without it fell from
  6,800 to 1,550 users on a write-heavy load.
- **Design details he called out as good**: a busy SQLite call must not put an event loop to sleep (Kotlin's
  zero-busy-timeout writer), idle timeouts too short turn keep-alive into reconnect churn (Node), reads on a pool and
  writes through one serial writer (Swift, Go), statements prepared once, constant error responses built ahead (Swift),
  a background checkpointer must be able to finish or the WAL grows (assembly, F#).
- **The Scala entry** (Netty, one event loop, FFM SQLite, idle eviction): 90,000 users on the batch-2 machine, p95 484 ms.

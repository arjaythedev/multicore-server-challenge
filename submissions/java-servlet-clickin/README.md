# Java / Servlet 6.1 async on our own epoll loops

Front: direct

| | |
|---|---|
| Language / runtime | Java 25, Eclipse Temurin JDK `25.0.5+8` (official tarball, sha256-pinned per arch in `install.sh`), used to build and run |
| Web API | Jakarta Servlet 6.1 (`jakarta.servlet-api` 6.1.0 from Maven Central, sha256-pinned in `build.sh`): the app is one `HttpServlet` per resource (tags, users, profiles, articles), mapped by URL pattern, using the **async** API (`startAsync` / `AsyncContext.complete`) |
| Servlet container / HTTP | Our own: HTTP/1.1 on Linux `epoll` through FFM (`java.lang.foreign`), one event loop per thread, with servlet mapping (exact, `/prefix/*`, default), `HttpServlet` method dispatch (405, HEAD, OPTIONS) and an error servlet for `sendError` |
| Postgres driver | Our own v3 wire client: SCRAM-SHA-256, prepared statements, binary rows, pipelining, cross-request batching, group commit |
| JSON, JWT, bcrypt | Our own: JSON written straight from Postgres's binary rows, allocation-free HS256 verify, bcrypt cost 10 with interleaved lanes |
| Dependencies | `jakarta.servlet-api` (interfaces only). Build with `javac` only, no Maven/Gradle |

```bash
sudo bash install.sh     # Temurin 25 -> /opt/jdk
bash build.sh            # servlet API jar (pinned) + javac -> build/server.jar
DATABASE_URL=postgres://... JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

Linux only (it calls `epoll`, `eventfd` and `setpriority` directly).

## Idea

Postgres takes most of the box's CPU, so the server's job is (1) to make every request cheaper **for Postgres**
and (2) to cost as little CPU itself as it can, leaving the rest to Postgres. The application is still written
against the Servlet API: standard `HttpServlet`s, in async mode, on a container built for this workload.

## The container

- **Event loops, not threads per request.** `LOOPS` (default cores/2) platform threads, each with its own epoll set and
  its own `SO_REUSEPORT` listener (`TCP_DEFER_ACCEPT`, `TCP_NODELAY`). The loop parses the request and calls
  the container on its own thread, which maps the path to a servlet and calls its `service(req, res)`. A handler that needs the database calls `req.startAsync()`, submits
  the query and returns; the result comes back to the same loop (lock-free queue + `eventfd`), the callback writes the
  JSON and calls `complete()`, and the response goes out in one `write`. Nothing ever blocks a loop, so no virtual
  threads, no `ThreadLocal`s and no hand-offs to worker threads are needed.
- **No allocation in the steady state.** Request, response, `AsyncContext` and the app's per-request state are pooled
  per loop and recycled. Header fields, path and query are offsets into the read buffer; the standard getters
  (`getHeader`, `getParameter`, ...) still work but allocate only if called, and the hot paths don't call them.
  Instead they use `Direct`, the one interface the container adds to the Servlet API (`Direct.of(request)`): the read
  buffer with path, query, body, `Authorization` and path-segment offsets, the response body buffer, an object slot
  pooled with the request, and per-loop values (`Direct.Local`, used for the not-thread-safe `Jwt`). Everything else
  the app does goes through the standard API, including `AsyncContext.start` to come back to the loop from the
  database and bcrypt threads. An idle
  connection is an fd and a small object: the read buffer is shared per loop, and a connection gets its own only
  while it holds a partial request or unsent output. Measured with JFR under load: a few hundred bytes per request at
  most; at ~25k req/s on the Hetzner box that is a short young GC every 6-8 s with a 2 GB heap (ParallelGC,
  pre-touched).
- **Servlet mapping without a scan.** `Container.addServlet` takes exact, `/prefix/*` and default (`/`) patterns. A
  lookup hashes the path's first N segments once per registered depth, deepest first, into a table whose multiplier
  is searched at registration so patterns never collide, then checks the bytes: the cost does not grow with the number
  of servlets. Inside a servlet, `HttpServlet.service` picks `doGet`/`doPost`/... (a method the servlet does not
  override is its standard 405), and the method routes the rest of the path itself: the segment count and at most one
  keyword compare pick the handler, which binds the query and submits it with the step to run on the result.
  `sendError` renders through the error servlet, which writes the API's `{"errors":...}` JSON.
- **The rest of the Servlet API, lazily.** Readers and writers (with the request/response character encodings),
  cookies, locales, remote and local addresses (`getpeername`/`getsockname` on first call), `Host`-based server name
  and URL, `HttpServletMapping`, dispatcher types (ERROR inside the error servlet, ASYNC after `AsyncContext.dispatch()`),
  `AsyncContext.start` (a pooled task on the request's own loop, so the runnable must not block) and async listeners.
  None of it runs unless called. Not provided: sessions, login, multipart, request dispatching to other paths,
  protocol upgrade and trailers; those throw or answer as the spec says for a container without them. The async
  timeout is stored but not enforced, and a response is sent whole on completion (`flushBuffer` cannot commit early).
- **Backpressure.** At most `MAX_INFLIGHT_PER_LOOP` (2048) requests in flight per loop; past that a loop stops reading
  new requests until one completes, so overload raises latency instead of memory. A request holds its slot through
  every read round, gather waits included, so the cap is also a throughput limit (slots / time held): at 1024 a 20 ms
  gather capped Hetzner at 31.5k req/s with the box at 72%; at 4096 an overloaded run filled the 2 GB heap.

## Postgres work per request

- **One statement per request**, prepared once per connection, binary results, generic plans that stay sane: every
  list's page is cut first (`LIMIT/OFFSET` on the bare index walk) and decorated afterwards, and the page sits under a
  constant `LIMIT 100` so a parameter `LIMIT` can't make the planner expect 10% of the table (it once picked a hash
  join over all 500k articles for every request in a batch: 8 s per batch, 13 ms after). Every connection sets
  `plan_cache_mode = force_generic_plan` (a session `SET`): in `auto` mode Postgres kept re-planning the batch
  statements, whose array parameters make each custom plan look different, on almost every execution (~0.3 ms each).
- **Reads are batched across requests.** A single dispatcher thread owns all read connections (8) and the write
  connection (1). Each read connection has one round in flight; reads that arrive meanwhile wait (and wait up to
  `READ_GATHER_US` = 20 ms for company, up to `READ_ROUND_MAX` = 4096 per round), then go out together: requests of a kind become **one** statement over arrays
  of their parameters (`unnest(...) WITH ORDINALITY` + `LATERAL`), each row tagged with its request. Within a
  statement, each distinct article is decorated (tags, favorites count, author) **once**, however many requests in
  the batch show it; only `favorited` / `following` are per viewer. Nothing outlives the statement (rule 5).
- **No repeated lookups inside a batch.** Tag names come from one join + `array_agg` grouped by article (the
  per-article subquery's generic plan scanned and hashed all 200 tags for every article). The article and comments
  batches look each slug up once in a `MATERIALIZED` CTE and reuse that row (they used to look it up twice). A keyed
  list (`?tag=`, `?author=`, `?favorited=`) resolves and counts each distinct name once, however many requests in
  the batch ask for it. The feed knows `following` is true for every author it walks and skips that probe.
- **The feed's count, proven instead of counted.** Most viewers follow an author with 1,000+ articles (82.6% of users),
  so their capped count is 1,000. A batch picks the 4 authors most followed by its viewers, proves ≥ 1,000 articles
  for each with one bounded index walk, and only the other viewers count.
- **Group commit.** The write connection has one group in flight; writes that arrive meanwhile go out together, each
  request's statements back to back and one `Sync` at the end: one transaction, one WAL flush. Responses are sent
  only after the group commits (rule 6). If any statement fails, the group is rolled back by Postgres and its
  requests are retried one by one, so only the faulty one gets its error (e.g. 422 on a duplicate email). With
  four write connections each group held one or two writes, i.e. about one fsync per write; one connection gathers
  every write that arrives during a WAL flush.

Measured locally on the full seed (Postgres, server and load generator in one 8-CPU container, fixed load of
18k req/s; `pg_stat_statements`, local only):

| Step | Postgres CPU |
|---|---|
| per-request statements, pipelined | ~1.9 cores |
| + batching with 5 ms gather | ~1.3 |
| + every read kind batched, feed count shortcut, decoration once per article | ~1.0 – 1.4 (noisy) |

## bcrypt

Every login and sign-up verifies or hashes with cost 10 (rule 7). That is about 28 hashes/s at 100k users and, at
~65 ms per hash on EPYC, ~1.7 cores: a fifth of the box. Blowfish is one long dependency chain, so a single hash
leaves most of the core idle: `BCrypt` runs up to 6 independent hashes interleaved in one straight-line kernel per
width, each lane in its own locals (`BCryptLanes`, written by `dev/gen-bcrypt-lanes.py`). Per hash on Hetzner's EPYC
Milan: 1 lane 60 ms, 2 lanes 33, 3 lanes 25.8, 4 lanes 23.4, 5 lanes 23.0, 6 lanes 24.5 (the earlier hand-written
2/4-lane loop: 38 / 29). The best width depends on the core's registers and load ports, so the pool times every width
at startup (~2-5 s of one core, logged as `bcrypt: N lanes`) and takes the fastest, preferring fewer lanes within 3%. Hashes run on their own `BCRYPT_THREADS` (4) threads at `nice` 5 (`setpriority`
per thread through FFM; `Thread.setPriority` is a no-op on Linux). One thread at a time gathers a set, waiting up to
400 ms to fill its lanes, while the others hash: when every thread gathered on its own for 40 ms, ~20-30 logins/s
came out one per thread and the 4-lane loop mostly ran a lone hash (locally 70 ms of CPU per hash, 32 ms after; bcrypt
threads 1.39 -> 0.63 cores at 18k req/s). Logins wait longer for their set (p50 ~0.2 s), but they are 0.1% of requests.

## Results

### Query work (this branch vs. the previous build, `a3d49a1`)

Hetzner ccx33 target, two cpx42 load boxes (`dev/hcloud/fixed.sh`): fresh switch, a 60 s warm-up, then a fixed user
count, measured 120 s (80k) or 60 s (120k), two runs per build, alternated. CPU is the share of the whole box (app / Postgres, from systemd cgroups).

| Users | Build | req/s | p50 | p95 | p99 | Box CPU (app / Postgres) |
|--:|---|--:|--:|--:|--:|---|
| 80,000 | previous | 21,054-21,068 | 26-27 ms | 48-54 ms | 68-104 ms | 72.3% (31.1% / 39.3%) |
| 80,000 | this | 21,073-21,099 | 20-21 ms | 35-36 ms | 43-49 ms | 60.5% (29.2% / 29.2%) |
| 120,000 | previous | 30,657-30,800 | 94-98 ms | 352-371 ms | 474-667 ms | 98.6% (42.7% / 54.5%) |
| 120,000 | this | 31,297-31,325 | 40-45 ms | 167-178 ms | 251-262 ms | 90.7% (45.0% / 44.1%) |

At the same throughput Postgres uses about a quarter less CPU (39.3% -> 29.2% of the box at 80k). At 120k the
previous build is out of CPU and queueing, while this one still has ~9% of the box free and half the tail latency.
Past ~130k users these two load boxes fall behind themselves, so the rig cannot find this build's limit. Local
`pg_stat_statements` (same load, total execution time): 78 s -> 55 s.

### bcrypt kernels and longer read gathers (2026-11-01)

Same rig and script, three load boxes (two cpx42, one ccx23), 60 s warm-up, 120 s measured. This target ran faster than
the one above (base at 120k: 78% of the box, not 90.7%), so compare within this table only. "lanes" is the generated
bcrypt kernels on the old defaults; "+ gather" adds `READ_GATHER_US` 20000, `READ_ROUND_MAX` 4096 and
`MAX_INFLIGHT_PER_LOOP` 2048 (now the defaults).

| Users | Build | req/s | p95 | p99 | Box CPU (app / Postgres) |
|--:|---|--:|--:|--:|---|
| 120,000 | previous | 31,543-31,604 | 53 ms | 67 ms | 78.1-78.6% (33.3-33.8% / 41.9%) |
| 120,000 | lanes | 31,521-31,542 | 51-53 ms | 63-65 ms | 77.1-77.4% (32.2-32.4% / 42.0-42.2%) |
| 140,000 | previous | 36,550 | 124 ms | 191 ms | 94.0% (41.8% / 50.2%) |
| 140,000 | lanes | 36,636-36,673 | 92-95 ms | 126-137 ms | 91.6-92.0% (39.2-39.4% / 50.1-50.2%) |
| 140,000 | + gather | 36,127 | 200 ms | 249 ms | 84.4% (39.8% / 41.4%) |
| 150,000 | lanes | 37,956 | 498 ms | 593 ms | 97.9% (44.0% / 52.0%) — at the p95 limit |
| 150,000 | + gather | 38,447 | 254 ms | 326 ms | 90.6% (43.2% / 44.4%) |
| 160,000 | lanes | 37,313 | 786 ms | 1,090 ms | 99.1% (46.6% / 50.7%) — fail |
| 160,000 | + gather | 40,072 | 557 ms | 790 ms | 94.1% (45.2% / 46.0%) — fail (p95) |

The 20 ms gather takes ~16% off Postgres for a little more app CPU and ~100 ms more p50. With the old in-flight cap
(1024 per loop) the same gather collapsed at 140k: 31.2k req/s, p99 6.6 s, box only 72% (40 ms gathers: 21.5k).
At 160k the + gather run misses on latency with 6% of the box still free.

### Earlier search (before this branch)

On Hetzner **ccx33** (8 dedicated AMD EPYC-Milan vCPU, Postgres 18; configured by `box/pg-conf.sh` as for 16 GB),
full seed, the repo's `loadgen search` from two separate load boxes (one cx43 and one cpx42, 8 shared vCPU each, the
account's limit) over a private network. Each user count is a fresh run: switch, 3-minute warmup, 2-minute probe, and the
5-minute hold if the probe passed.

| Phase | Users | req/s | p50 | p95 | p99 | Errors | Box CPU (app / Postgres) |
|---|--:|--:|--:|--:|--:|--:|---|
| probe | 70,000 | 18,401 | 27 ms | 49 ms | 60 ms | 0% | 74% (29% / 42%) |
| probe | 90,000 | 23,511 | 50 ms | 119 ms | 153 ms | 0% | 94% (37% / 55%) |
| 5-minute hold | 90,000 | 23,456 | 58 ms | 133 ms | 178 ms | 0% | 96% (38% / 57%) |
| probe | 95,000 | 24,726 | 68 ms | 167 ms | 400 ms | 0% | 97% (39% / 57%) |
| **5-minute hold** | **95,000** | **24,627** | **80 ms** | **182 ms** | **243 ms** | **0%** | **98% (39% / 58%)** |
| probe | 100,000 | 25,164 | 134 ms | 381 ms | 1,038 ms | 0% | 99% (40% / 57%) — fail (p99) |
| probe | 105,000 | 25,742 | 230 ms | 465 ms | 1,354 ms | 0.02% | 98% (42% / 55%) — fail |

The score is the **95,000-user hold**: 0 errors, and the load boxes were not the limit (CPU ~25%, no sampler lag).
From there the box itself is out of CPU, Postgres taking about 60% of it; throughput stops growing at ~25k req/s
and queueing pushes p99 past 1 s by 100,000 users. The loadgen also flagged the 100k and 105k probes "LG-limited"
(one load box's sampler tick was ~3 s late), so those two are not clean server failures, but the box CPU says the
same thing. The commit before the servlet restructure (`0fd83b2`), run on the same boxes at 105,000, gave 25,499
req/s and p95 530 ms, i.e. no regression from it. An earlier run with two cx43 load boxes held 105,000 with
load-box warnings; this run could not reproduce that, so the numbers above replace it. This is not the official box,
so compare with the leaderboard loosely.

## Correctness checks beyond the suite

- `test/run.sh`: 197/197.
- `dev/diffcheck.py`: 3,000 concurrent reads against a batching server and one with `COALESCE=0` on the same
  database: byte-identical responses.
- `test/sql/batch_equiv.sql` and `test/sql/feed_check.sql`: the batched statements return exactly the rows of the
  per-request ones, and the feed shortcut the counts of the reference SQL (2,000 viewers).
- `test/run-unit.sh`: wire-protocol parsing (fragmented messages, errors, group retry), JWT edge cases, bcrypt
  vectors across lanes, JSON escaping, timestamp formatting, slugify, servlet mapping and method dispatch, the
  standard request/response API, each servlet's routing (through the container, keyword-like slugs included).
- `test/http-smoke.sh`: pipelining, chunked bodies, HEAD without a body, 405, `AsyncContext.start` and `dispatch()`,
  peer address.

## Tuning knobs (all optional; defaults are what was measured)

`LOOPS`, `READ_CONNS` (8), `WRITE_CONNS` (1), `READ_GATHER_US` (20000), `READ_ROUND_MAX` (4096), `READ_SPREAD` (1: how many idle read connections one round's kinds are spread over), `WRITE_GROUP_MAX` (256),
`COALESCE` (1), `MAX_INFLIGHT_PER_LOOP` (2048), `BCRYPT_THREADS` (4), `BCRYPT_LANES` (0 = timed at startup, 1-6), `BCRYPT_GATHER_MS` (400),
`BCRYPT_NICE` (5), `JAVA_OPTS`.

`dev/` holds the local Linux box (`Dockerfile`, `conformance.sh`, `load.sh`, `alloc.sh`) and the Hetzner scripts
(`dev/hcloud/`). They aren't used by the benchmark.

## Credits

The FFM epoll/socket bindings and the Postgres wire-protocol basics started from
[java-epoll-stohirov](https://github.com/arjaythedev/million-users-challenge/tree/main/submissions/java-epoll-stohirov)
(MIT) in the million-users challenge. Ideas borrowed from this repo's leaders: array-parameter batching and the feed count shortcut from [zig-iouring-nick-potts](../zig-iouring-nick-potts)
([#79](https://github.com/arjaythedev/multicore-server-challenge/pull/79),
[#117](https://github.com/arjaythedev/multicore-server-challenge/pull/117)); gathering reads and one round per
connection from [scala-netty-didierliauw](../scala-netty-didierliauw)
([#75](https://github.com/arjaythedev/multicore-server-challenge/pull/75),
[#125](https://github.com/arjaythedev/multicore-server-challenge/pull/125)).

MIT, under the repo's [license](../../LICENSE).

Built with Claude Code (Anthropic). Changes were checked against the unit tests (`test/run-unit.sh`), the
conformance suite (`dev/conformance.sh`) and alternating local load runs against the previous build (`dev/load.sh`).

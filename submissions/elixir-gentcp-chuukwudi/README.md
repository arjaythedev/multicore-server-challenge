# Elixir: own HTTP server, own Postgres client, batched reads in pipelined rounds

Front: direct

| | |
|---|---|
| Language / runtime | Elixir 1.19.6 on Erlang/OTP 28.5.0.8 (official builds, sha256-pinned in `install.sh`) |
| HTTP | own HTTP/1.1 server on `gen_tcp` (keep-alive, Content-Length bodies, pipelining-safe): no Phoenix, Plug, Cowboy or Bandit |
| Postgres | own client for the wire protocol 3.0 (SCRAM-SHA-256, extended query protocol, binary results, pipelining): no Postgrex |
| JSON | output written as iodata straight from Postgres's binary rows; OTP's `:json` for request bodies |
| bcrypt | a small NIF: the Openwall core plus 2-4 lane interleaving (`c_src/`), cost 10 |
| JWT | HS256 with `:crypto.mac`, constant-time compare |
| Dependencies | **none** (`mix.exs` has `deps: []`); `build.sh` compiles the NIF with `cc` and runs `mix release` |

## Why it is built this way

On the benchmark box Postgres is the bottleneck: the leaders spend 70-80% of the 8 cores in Postgres. So the design
goal is to make every request cost Postgres as little as possible, and then to make the BEAM's share small.

### Postgres side

* **Batched reads.** Requests of the same kind (an article by slug, a global-list page, a feed page, the tag list,
  ...) are sent together as one statement: the per-request query is the inner side of a `LATERAL` join over the
  unnested parameters of every waiting request, and each row comes back tagged with its request's index
  (`lib/conduit/sql.ex`). Each request's data is still read by its own execution of its query while it is being
  served.
* **Pipelined rounds.** A read connection sends everything queued (one statement per kind) as one round under a
  single Sync: one backend wake-up, one network exchange and one implicit transaction for the whole round, and one
  executor start per kind instead of per request. Each request gets its rows as soon as its own statement's
  CommandComplete arrives. There is no timer: at low load a round holds one request and nothing waits; under load
  requests pile up while the round is in flight, so batches grow exactly when the per-statement overhead matters.
  Measured with `pg_stat_statements`, about 60% of Postgres's CPU at moderate load was per-statement overhead rather
  than executor time; that is what batching removes.
* **No coordinator process.** Each read connection batches its own queue. Requests go to the less loaded of two
  neighbouring connections (power of two choices on a shared `:atomics` counter), so there is no dispatcher hop.
* **Six read connections** (`READ_CONNS`). Fewer connections means bigger batches: going from 12 to 6 cut Postgres
  CPU by 17% at the same throughput in local tests.
* **Generic plans, prepared once.** Session settings in the startup packet: `plan_cache_mode=force_generic_plan`,
  `jit=off`, `max_parallel_workers_per_gather=0`, `enable_memoize=off`. Every statement was checked with
  `EXPLAIN (ANALYZE, BUFFERS)` under generic plans on the full seed (index scans throughout).
* **Binary results.** Integers, booleans and timestamps arrive in binary format; timestamps are formatted by hand.
  The one exception is the tag list, which is requested in *text* format: Postgres's array literal `{a,b,c}`
  becomes `["a","b","c"]` with a single C-level `:binary.replace` when no name needs quoting (a correct slow path
  handles quoting and escapes).
* **Cheaper SQL than the reference, same answers:**
  * The page is cut (`LIMIT/OFFSET`) before anything is joined or computed, so skipped rows cost an index step.
  * The global `articlesCount` asks whether a 1000th row exists, walking the primary key from the oldest end (frozen,
    all-visible pages: an index-only scan with no heap fetches). `OFFSET 999 + 0 * r.i` ties it to the request
    without the per-row filter node that `WHERE r.i >= 0` adds.
  * Popular tags use the same "1000th row exists?" test; author/tag/favorited filter keys are resolved once per
    request and shared by the count and the page.
  * Feed rows return `following = true`: every row's author was reached through the viewer's follows row in the same
    snapshot. The feed count walks `articles_author_idx` in index order for the followee array.
  * Comments read the viewer's ~20 followees once per request instead of probing follows per comment.
  * Tag names are fetched by primary key per `article_tags` row; when the database collates in byte order
    (`C`/`C.UTF-8`, checked at start-up) the app sorts the 1-4 names itself and Postgres skips a sort per article.
  * Writes are single statements (data-modifying CTEs that also tell 404 from 403). Article creation with tags is
    one statement: existing tags are only read (no update, no lock, no sequence burn), missing ones are inserted in
    name order (no deadlock between concurrent creates). Favorite/unfavorite pipeline the write and the read-back in
    one Sync, so the response comes from the same committed transaction.
* **Writes on their own connections** (`WRITE_CONNS`, 6), round-robin and pipelined, so a commit's WAL flush never
  delays a read round.

### BEAM side

Every change below was profiled with `perf` (with BEAM JIT perf maps) on Linux, and kept only if it measured better.

* **One small process per connection, one short-lived worker per request.** The connection process only frames the
  request, spawns a worker with a preallocated heap (`WORKER_HEAP`, 4096 words), then hibernates. The worker does
  JWT, the Postgres round trip, the JSON and the write, and never garbage-collects: its heap is freed in one go
  when it exits. Compared with handling the request in the connection process and hibernating it afterwards, this
  cut app CPU by ~30%. Hibernating the (now tiny) connection process cut memory from ~30 KB to ~12 KB per active
  connection.
* **Raw writes to the inet driver.** `gen_tcp.send/2` looks up the socket module, creates a monitor and waits for the
  driver's reply. The worker writes with `port_command` and a constant reply tag instead, and doesn't wait (it is
  about to exit); the Postgres connection processes simply drop the replies. A busy port still applies
  back-pressure. (OTP's `:socket` NIF was also tried for the HTTP side and cost *more* CPU than the inet driver.)
* **No response caching, no shared results**: but no wasted work either. JWT payloads in the two exact shapes
  that occur in practice (`{"sub","iat","exp"}` and Go's sorted `{"exp","iat","sub"}`) are parsed by binary
  matching after the signature check; anything else goes through the full JSON decoder. JSON strings take a
  one-scan fast path (Aho-Corasick in C) when nothing needs escaping; slugs (always `[a-z0-9-]`) skip the scan.
* **Schedulers sized for a shared box**: `+S` = half the cores (4 on 8), `+sbwt none` so idle schedulers sleep
  instead of spinning on cores Postgres needs. Local sweeps: 7 → 4 schedulers cut app CPU 16% and halved p99.
* **Postgres connection processes run at high priority** with off-heap message queues, so a round's replies are
  never stuck behind HTTP work.

### bcrypt

A Blowfish round is a chain of dependent table loads, so one hash leaves most of a core idle. The NIF runs up to
four independent hashes interleaved round by round (same work for each, each with its own salt and full cost 10):
measured on Linux, **15 ms per hash four at a time against 52 ms alone**. A coordinator collects hashes for up to
200 ms (`BCRYPT_WINDOW_MS`): logins are ~0.1% of requests, so the wait does not move the percentiles, while at the
benchmark's ~28 logins/s it fills four-lane batches and saves about a core. Full batches go out at once. Hashing runs
on two dirty CPU schedulers, which also caps how many cores it can take from Postgres. A start-up self-test compares
every lane count against the reference path and a known vector.

## Rules

* **No caching across requests.** Every request reads Postgres while it is served. Batching shares statements and
  round trips, never results: each request's rows come from its own execution of its query, subqueries that don't
  use a request parameter are tied to the request row so Postgres evaluates them per request, Memoize is off, and no
  row read for one request is ever given to another. Nothing is kept after a reply (connections and prepared
  statements aside).
* **Writes are committed before responding**: write responses come from the committing statement or its Sync group,
  sent after ReadyForQuery. `synchronous_commit` untouched.
* **Security**: bcrypt cost 10 on every register and password change with a fresh random salt; every login verifies
  against the stored hash. Every request verifies the token's HS256 signature (constant time), `alg`, `exp` (and
  `nbf` if present).
* No DDL, no server-wide settings (session settings only), 13 Postgres connections in total. No CPU pinning.

## Configuration (all optional)

`READ_CONNS` (6), `WRITE_CONNS` (6), `BATCH_MAX` (64 requests per statement), `SCHEDULERS` (cores/2), `DIRTY_CPU`
(cores/4, at least 2), `BCRYPT_WORKERS` (= dirty CPU schedulers), `BCRYPT_WINDOW_MS` (200), `WORKER_HEAP` (4096),
`ACCEPTORS` (64).

## Tests

`mix test`: JWT (both fast paths against the general decoder, and every rejection the conformance suite tries),
JSON escaping, Postgres array literals, timestamp formatting, SLUGIFY equivalence, and HTTP framing. The
conformance suite passes 197/197 on both the dev and the full seed.

## Local measurements (not official scores)

On an Apple M-series laptop: Postgres 18 in Docker configured with the box's `pg-conf.sh` values, the full seed,
and this server plus the load generator in an Ubuntu 24.04 container sharing Postgres's network namespace.
Everything shares the Docker VM's 6 CPUs, so the absolute numbers are not the box's. For comparison, the current
#1 (`rust-tokio-Scooter1337`) was built and run in the same setup, at the same loads:

| Load (users × think-scale) | Server | req/s | p95 | p99 | Postgres CPU | App CPU | Errors |
|---|---|--:|--:|--:|--:|--:|--:|
| 6,000 × 0.1 | this | 15,835 | 4.3 ms | 13.3 ms | 182% | 138% | 0 |
| 6,000 × 0.1 | rust-tokio-Scooter1337 | 15,468 | 42.0 ms | 278.8 ms | 163% | 78% | 0 |
| 10,000 × 0.05 (VM saturated) | this | 39,678 | 113 ms | 146 ms | 279% | 203% | 0 |
| 10,000 × 0.05 (VM saturated) | rust-tokio-Scooter1337 | 40,238 | 136 ms | 204 ms | 297% | 135% | 0 |

Both saturated runs were flagged LG-limited (the load generator shares the VM). The BEAM costs more CPU per request
than Rust; the batching and the SQL make Postgres's share lower at saturation, which is where the box's limit is.
Memory: ~250 MB RSS with 20,000 connected users.

## Credits

`c_src/crypt-bcrypt.c` is Solar Designer's public-domain Openwall bcrypt, unchanged from libxcrypt 4.4.36.
`c_src/bcrypt-batch-impl.h` and the two small portability headers come from the MIT-licensed
`rust-tokio-Scooter1337` submission in this repository; `c_src/bcrypt_nif.c` is the NIF wrapper.
The batched-read SQL pattern follows `csharp-sockets-jh-d`; several query shapes follow `rust-tokio-Scooter1337`.

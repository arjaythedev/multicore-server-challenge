# Conduit: C++20 / Boost.Asio / libpq pipeline mode

**Front: direct** (serves `0.0.0.0:80` itself and holds every user's keep-alive connection; no Nginx CPU).

| Piece | Version |
|---|---|
| Compiler | g++ 13 (Ubuntu 24.04), `-std=c++20 -O3 -march=native -flto` (built on the box) |
| Networking | Boost.Asio 1.83 (header-only), own HTTP/1.1 parser and writer |
| JSON | Boost.JSON 1.83 to parse request bodies and JWTs; responses written by hand |
| Postgres | libpq (Ubuntu 16 or PGDG 18; anything ≥ 14) in **pipeline mode**, binary results |
| JWT | HS256 over OpenSSL 3 SHA-256 (key pads hashed once) |
| bcrypt | own 4-way interleaved EksBlowfish (bit-identical to libxcrypt, which is the fallback), cost 10 |

`install.sh` installs `g++-13 libboost1.83-dev libpq-dev libssl-dev libcrypt-dev`; `build.sh` is a single
compiler call; `start.sh` runs `bin/conduit`.

## How it works

- **Thread per core.** `THREADS` (default: cores) worker threads, each with its own `io_context`, its own
  `SO_REUSEPORT` listener (the kernel spreads connections over them) and its own Postgres connections. A
  connection never leaves its thread, so nothing on the request path takes a lock.
- **Postgres pipelining.** Each worker has one read connection and one write connection (16 in total on 8
  cores). Requests don't check out a connection. They append their prepared statements plus a Sync to the
  connection's pipeline and continue when that Sync comes back. All requests started in one event-loop turn
  go out in a single `send()`. Fewer, busier connections measured ~9% less Postgres CPU per request than two
  per thread, because each backend wakeup processes more work.
- **One round trip per request**, mostly one statement:
  - each list's capped count rides along as an uncorrelated scalar subquery (an InitPlan, run once);
  - an article's comments and the article lookup are one `LEFT JOIN LATERAL` statement;
  - follow/unfollow and comment creation do the lookup and the write in one CTE statement;
  - favorite/unfavorite send the write and the read-back together in one transaction.
- **Group commit.** While a write transaction is committing, new writes on that connection queue up. They then
  go out together as one transaction (one Sync, one WAL flush), and every response waits for that commit
  (rule 6). If a batched transaction fails, each request in it is retried in a transaction of its own, so one
  request's unique violation never fails another. Locally this halved write latency (p50 7 → 3.5 ms, p99
  ~70 → 15 ms).
- **bcrypt off the event loop**, on `max(2, cores/2)` threads. Jobs are batched up to 4 at a time (the oldest
  waits at most `BCRYPT_BATCH_MS`, default 40 ms) and run **interleaved in lockstep**. A single bcrypt is a
  chain of dependent S-box loads that leaves most of the core idle. Four at once take 48.7 ms instead of
  4 × 33.4 ms, so each hash costs **2.75× less CPU**. It is still standard bcrypt at cost 10, verified against
  every stored hash on every login. Logins are ~0.1% of requests but were ~20% of all CPU before this.
- **Direct mode:** idle connections hold no read buffer. The server waits for readability and then `recv()`s
  into a per-thread buffer. Responses go out with one `sendmsg()` (header + body iovecs).

## SQL optimizations (same results as SPEC.md's reference SQL)

Measured with pgbench (`-M prepared`, Postgres CPU per execution) and pg_stat_statements on the full seed:

| Change | Effect |
|---|---|
| `plan_cache_mode = force_generic_plan` (session `SET`) | The global and tag lists were re-planned on every call (180–270 µs of planning, more than they take to execute). Generic plans for every statement were checked with EXPLAIN. **−30% Postgres CPU** |
| Lists pick their page first, in a subquery, then join `users` and compute tags/counts/flags | With `LIMIT/OFFSET` on the decorated query, Postgres decorates the skipped OFFSET rows too. Global list **182 → 91 µs** with the load generator's offsets |
| Large offsets (> 200) skip rows in an index-only scan of ids | Cold `?offset=100000000`: 20 s → 1.2 s |
| `tag_list` looks each tag up by primary key instead of `JOIN tags` | The join's plan hash-joins a scan of all 200 tags for every article: 8.8 → 2.9 µs per article |
| Global count: `EXISTS (... ORDER BY id OFFSET 999)`, else `count(*)` | Index-only scan of the oldest, all-visible pages; −10% |
| Feed count: `author_id = ANY(ARRAY(followees))` | One index scan instead of a nested loop of rescans; −9% |
| Binary result format | No timestamp/int text formatting in Postgres; the app formats RFC 3339 itself |
| `jit = off` (session) | No surprise JIT compilations on costlier plans |

`tools/difftest.py` runs every list/article/comment statement against the reference SQL from SPEC.md with
random viewers, filters, limits and offsets, inside Postgres. On the full seed: **0 mismatches in ~5,000 checks**.

## Results (local, not the benchmark box)

Ryzen 7700X with the server **and** Postgres 18 pinned to 4 cores / 8 threads (the full seed, pgtune
settings), and the load generator on the other 8 threads:

| At 7.9k req/s (same load) | App CPU | Postgres CPU | p99 |
|---|---|---|---|
| Go example (net/http + pgx, 80 connections) | 61.7 s | 104.6 s | 34.5 ms |
| **This server** | **21.5 s** | **54.5 s** | 24.9 ms |

Max passing throughput in the same setup: the Go example peaks around 13k req/s, and this server does
**~35k req/s at p99 ≈ 20 ms**. At 0.25 req/s per user that is ~140k users on these (fast, desktop) cores. The
benchmark box's vCPUs will be slower; the ratio is what carries over.

## Rules

- No caching: every request reads Postgres. Only connections and prepared statements are reused.
- Every password is hashed with bcrypt cost 10, every login runs bcrypt against the stored hash, and every
  token's HS256 signature and `exp` are checked on every request (alg must be HS256; `nbf` honoured).
- Writes are committed before responding. Group commit batches requests' writes into one transaction, and each
  response waits for its commit.
- Session-level `SET` only (`jit`, `plan_cache_mode`); no schema changes; 16 connections (≤ 95).

## Tuning knobs (env, all optional)

`THREADS` (cores), `PG_READ_CONNS` (1 per thread), `PG_WRITE_CONNS` (1 per thread), `GROUP_COMMIT` (1),
`BCRYPT_THREADS` (max(2, cores/2)), `BCRYPT_BATCH_MS` (40), `PLAN_CACHE_MODE` (force_generic_plan).

## Files

- `src/main.cpp`: HTTP, routing, handlers, bcrypt pool, startup. `src/pg.hpp`: the pipelined Postgres client
  with group commit. `src/sql.hpp`: every statement. `src/jwt.hpp`, `src/util.hpp` (JSON/timestamps/base64).
  `src/bcrypt.hpp` and `src/bcrypt_tables.cpp`: interleaved bcrypt.
- `tools/difftest.py` and `tools/print_sql.cpp`: the differential SQL test. `tools/bcrypt_test.cpp`: checks
  the bcrypt against libxcrypt (random ASCII passwords, `$2a$`/`$2b$`/`$2y$`, costs 4/5/10) and times it.

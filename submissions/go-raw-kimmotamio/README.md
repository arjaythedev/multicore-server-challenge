# Go: own HTTP/1.1 server + pgconn, batched reads, group-committed writes, interleaved bcrypt

**Front: direct**

| Piece | Version |
|---|---|
| Go | 1.27.2 (`install.sh` fetches the official tarball, sha256-checked; `go.mod`: `go 1.27`) |
| HTTP | own HTTP/1.1 server on `net` (one goroutine per connection on the runtime's epoll netpoller) |
| Postgres driver | `github.com/jackc/pgx/v5` v5.11.0, `pgconn` only (prepared statements, binary results, `ExecBatch`) |
| JSON | own encoder straight from binary rows; stdlib `encoding/json` for request bodies |
| JWT | own HS256 issue/verify (`crypto/hmac`); claims exactly `sub`, `iat`, `exp` |
| bcrypt | own implementation (cost 10, `$2a$`), Blowfish key schedule interleaved over up to 4 hashes; `golang.org/x/crypto` v0.58.0 is a test-only dependency used to cross-check it |

Dependencies are pinned in `go.mod`/`go.sum`. Build output goes to `bin/` (ignored).

## Design

The box is shared with Postgres, and in every top submission Postgres takes ~70% of it. So the design
spends its effort on making each request cheap *for Postgres* first, and for Go second.

**Batched reads.** Most of a small statement's cost in Postgres is per-statement overhead (protocol
round trip, parse/bind, snapshot, executor start and stop), not row work. Read requests of the same
kind (an article by slug, the comments of a slug, a profile, a page of the global / tag / author /
favorited list, a feed page, `GET /api/user`, a login lookup, the tag list) that arrive while every read
connection is busy are sent together as **one statement**: the per-request query becomes the inner
side of a `LATERAL` join over `unnest()` of the waiting requests' parameters, and every row comes back
tagged with its request's ordinal:

```sql
SELECT r.i, <article columns>
  FROM unnest($1::int4[], $2::int8[], $3::text[]) AS r(i, v, s)   -- ordinal, viewer, slug
  JOIN articles a ON a.slug = r.s JOIN users u ON u.id = a.author_id
```

Each request's rows are produced by its own execution of its own query, inside the request. A
subquery that depends on no request parameter (the tag list, the global article count) is what
Postgres calls an InitPlan: it is evaluated once per statement, in that statement's snapshot, for the
requests in it, and nothing is kept after the statement. Counts sit behind `OFFSET 0` so the planner
cannot pull them up and run them once per article row, and `enable_memoize` is off for the session so
no request is handed a row another request's lookup fetched.

A read waits up to 4 ms (`READ_BATCH_US`) for others of its kind before a free connection takes the
batch (at most 64), sooner if the batch fills. At 26,000 req/s that makes 20-30 article, comment and
tag requests per statement and 10-15 list pages, which cuts Postgres's CPU per request by about 40%
in exchange for a few milliseconds of latency (p99 goes from 2 ms to 12 ms locally). A free connection
takes the kind whose oldest request has waited longest; a kind may hold at most half the read
connections.

**Group-committed writes.** Writes go to their own connections (a commit's WAL flush would otherwise
stall every read queued behind it on a pipelined connection). Writes that arrive within 2 ms of each
other (`WRITE_BATCH_US`) go out as one extended-protocol batch with a single `Sync`: one implicit
transaction, one WAL flush, and every response waits for that commit. If any statement fails, Postgres rolls the group back
and each request is retried alone; a unique violation then maps to 422. A connection failure is never
retried (the commit is uncertain) and fails its requests. Every mutation is one statement with CTEs that
fold the lookup, the ownership check and the response read together (a duplicate registration inserts
nothing and returns no row instead of aborting the group).

**SQL.** The reference SQL from `SPEC.md`, with the page of ids cut *before* the per-article work
(tags, favorites, author) so `OFFSET` rows cost an index step only; tag names read by primary key per
tag instead of hash-joining the tags table per article; `favorited`/`following` skipped for anonymous
viewers; the capped counts for sources that usually exceed 1,000 rows proven by the existence of a
1,000th row instead of aggregating. In the feed, `following` is constant `true` (every feed author is
followed by the viewer in the same snapshot). Session settings only: `plan_cache_mode =
force_generic_plan`, `enable_memoize = off`, `jit = off`, `max_parallel_workers_per_gather = 0`.
12 read + 4 write connections.

**HTTP.** Each connection has one goroutine and a 2 KB read buffer; response buffers come from a pool
only while a request is in flight and the header is written into slack in front of the JSON body so a
response is one `write`. Keep-alive connections are never closed by the server (direct front: every
virtual user holds its own).

**bcrypt.** A Blowfish round is a chain of dependent S-box loads, so one hash leaves most of a core
idle. Up to four hashes run interleaved in lockstep (`bcrypt_lanes.go`, generated by
`gen_bcrypt.py`): every hash still does all 1,024 expansions of its cost-10 key schedule, the lanes
only hide each other's load latency. A collector groups queued hashes into runs of up to four,
waiting at most 100 ms for a run to fill (hashes are ~0.1% of requests, so this wait touches p99.9,
not p99); half as many worker goroutines as cores execute the runs. The lane count is calibrated at
startup (1-4 lanes timed at a low cost: whether 4 beats 2 depends on the CPU's registers). `go test`
checks the implementation against `golang.org/x/crypto/bcrypt` in both directions (our hashes verify
there, theirs verify here) at several costs and lane counts, and that concurrent hashes share a run.
Hashes are `$2a$10$` with 16 random salt bytes; `$2a$`/`$2b$`/`$2y$` are accepted when verifying.

**JWT.** HS256 verified on every request (signature over the presented bytes, `alg` must be HS256,
`exp` required and in the future, `sub` a decimal user id); nothing is remembered between requests.

## Rules

No caching of any kind across requests: every request reads Postgres while it is served, only
connections and prepared statements are reused. Batching shares a statement among requests that are
all waiting when it starts; the only values shared inside a statement are those that depend on no
request (the tag list, the global count), evaluated in that statement's snapshot and discarded with
it. Every
login verifies bcrypt cost 10 against the stored hash and every registration or password change hashes
with cost 10. Writes are committed (synchronous commit) before the response. Nothing in the database is
created or altered; only session-level `SET`s are used. 16 Postgres connections in total.

## Local results

Measured on an Apple M-series laptop (16 cores, 128 GB) with Postgres 17 on the same machine, the full
seed, one `loadgen run` on the same machine with `-think-scale 0.05` (6,000 virtual users producing the
request rate of ~115,000 real ones; macOS cannot hold more sockets cleanly), 15 s ramp + 40 s measured.
Not comparable to the challenge box; what matters here is the CPU split and that latency stays flat.

| users (think x0.05) | req/s | p50 | p95 | p99 | errors | app CPU | Postgres CPU | app RSS |
|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| 6,000 | 31,138 | 4.2 ms | 8.5 ms | 12 ms | 0 | ~2.1 cores | ~2.4 cores | 165 MB |

Login (bcrypt) p50 143 ms, p95 194 ms. Of the app's CPU about 45% is bcrypt (4 lanes: 17 ms of CPU
per hash against 52 ms for `x/crypto` when run as amd64 under Rosetta, 26 vs 47 ms natively on
arm64), most of the rest is syscalls and goroutine wake-ups; parsing, JSON and the pgconn path are
under 10%. The same run with no batching window (`READ_BATCH_US=0`) needs ~3.8 Postgres cores and
~2.6 app cores: batches of 1.2 requests instead of 15-29.

## Build and run

```bash
sudo bash install.sh                     # Go 1.27.2 -> /usr/local/go
bash build.sh                            # -> bin/conduit
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

Optional tuning (env, nothing needs to be set): `DB_READ_CONNS` (12), `DB_WRITE_CONNS` (4),
`READ_BATCH` (64), `READ_BATCH_US` (4000), `READ_KIND_INFLIGHT` (6), `WRITE_BATCH` (128),
`WRITE_BATCH_US` (2000), `BCRYPT_THREADS` (cores/2), `BCRYPT_LANES` (calibrated), `BCRYPT_BATCH_MS`
(100), `GOGC` (200), `PPROF_ADDR` (off; also serves `/debug/batches`). `DUMP_SQL=1` prints every
prepared statement. Passes `test/run.sh` (197/197).

`bcrypt_pi.go` carries Blowfish's initial P-array and S-boxes from `golang.org/x/crypto/blowfish`
(BSD-3-Clause, see `LICENSE-x-crypto`).

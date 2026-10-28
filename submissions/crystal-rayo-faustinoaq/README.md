# Crystal + Rayo

Front: direct

| Component | Version / implementation |
|---|---|
| Crystal | 1.22.1, `--release --mcpu x86-64-v3 -Dwithout_mt` |
| Framework | [Rayo](https://github.com/faustinoaq/rayo), commit `c9553d94583fe2a56ab299e3788fe40dcd0e72b2` |
| PostgreSQL driver | Rayo::PG, prepared statements, pipelining and application read batches |
| Network I/O | Rayo io_uring, `SO_REUSEPORT`; Linux 6.1+ with io_uring allowed |
| JWT | Rayo::JWT, HS256 through OpenSSL libcrypto |
| Password hashing | Rayo::Bcrypt::Pool, cost 10, interleaved lanes and libcrypt fallback |
| Compression | Rayo gzip, libdeflate |

The manifest and lockfile pin Rayo. `install.sh` pins Crystal and checks the
SHA-256 digest of its official archive. System libraries use Ubuntu packages.

```bash
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit \
JWT_SECRET=multicore-server-challenge HOST=0.0.0.0 PORT=80 bash start.sh
```

## Design

Routes use `ctx.db.query`, `ctx.json`, streaming JSON arrays, borrowed JSON body
readers and `Rayo::JWT`. Rayo owns HTTP parsing, routing, io_uring, database
pipelining and worker supervision. `App#run` starts one worker per available CPU.
`app.on_worker_start` creates each worker's bcrypt pool and read coordinator;
`app.gzip` enables response compression. Custom tag serialization uses Rayo's
shared JSON writer directly.

Read batches port the hand-rolled entry's SQL and shared enrichment approach,
scheduled by Rayo's `PG::Coalescer`:

- Up to 128 waiting article requests share page selection and capped counts.
  Identical page/count keys are deduplicated within that round.
- The distinct article union is enriched once, including sorted tags and favorite
  counts. Bodies are fetched only for full-article requests.
- Viewer/article pairs share indexed favorite and follow lookups. Application
  fan-out applies the correct flags to each request using borrowed PG rows.
- Comment reads share slug lookups and comment enrichment, with follow flags
  grouped by viewer. Empty threads and missing articles remain distinct.
- Waiting tag requests share one database read. Results are discarded after
  answering the round. There are no caches across requests.

Two dedicated Rayo::PG connections per worker serve these rounds through eight
reusable round slots; ordinary `ctx.db.query` connections handle auth and writes.
User and profile reads use ordinal array queries like the epoll entry. The
coalescer dispatches idle arrivals in the same loop turn and otherwise collects
for 17.5 ms per in-flight group, capped at 35 ms. Read sessions use the epoll entry's session-local planner settings:
`jit=off`, `plan_cache_mode=force_generic_plan`,
`max_parallel_workers_per_gather=0` and `enable_seqscan=off`.
No schema or global database settings change.

Writes use the original indexed queries and CTEs. Article creation, tag upserts
and article/tag links commit together; follow-up reads happen after ReadyForQuery.
Responses wait for committed writes. Write group commit is not implemented.

Every authenticated request verifies HS256 and expiry. Every login reads its
hash from Postgres and performs bcrypt verification. Rayo's bounded password
pool runs helper threads after fork and composes password/database callbacks
without touching framework completion counters. No password or token result is
cached. Gzip is negotiated by Rayo for responses of at least 1,024 bytes.

The build keeps the garbage collector enabled: malformed input uses exceptions,
and retained connection state and batch collections can grow. This application
does not claim zero allocation per request. `-Dwithout_mt` satisfies Rayo's
multiworker fork guard; bcrypt still runs its explicitly managed native threads.

## Settings

`DATABASE_URL`, `JWT_SECRET`, `HOST` and `PORT` follow the runtime contract.

| Variable | Default | Purpose |
|---|---|---|
| `WORKERS` | Available CPU count | Rayo workers, valid 1–31 |
| `PG_CONNS` | `(95 // WORKERS - 2).clamp(1, 2)` | Ordinary connections per worker, plus two read connections |
| `BCRYPT_THREADS` | 1 | Bcrypt helpers per worker |
| `BCRYPT_WINDOW_MS` | 200 | Rayo lane collection wait, clamped to 0–400 ms |
| `GZIP` | 1 | Set to 0 to disable Rayo gzip |

Startup enforces `WORKERS * (PG_CONNS + 2) <= 95`. Each worker's bcrypt queue
has capacity 1,024 and uses cost 10. `BCRYPT_LANES` was removed with the local
bcrypt engine; Rayo chooses its fast lanes or compatibility fallback.

## Validation

Inside `crdev`, Crystal 1.22.1, three workers, port 3391:

- Challenge harness: **197/197 checks passed** after the migration and after read batching.
- `bash test/integration.sh`: bcrypt compatibility, 24 concurrent logins,
  pending-job disconnects, ordered HTTP pipelining, 800 concurrent article
  requests and gzip negotiation passed. Another **540 mixed reads** matched
  isolated reads across anonymous and authenticated viewers, including follow
  and favorite flags, empty pages, missing articles and disconnected readers.
- `crystal build --release --mcpu x86-64-v3 -Dwithout_mt test/bcrypt.cr -o bin/test-bcrypt && bin/test-bcrypt`:
  **1,000 cost-10 hashes match libcrypt**, exercising Rayo's 1/2/3/4/5/6/8 lanes.

The test scripts use isolated databases and drop them afterward. Captured output
is in [results/](results/).

## Rayo integration notes

The previous local bcrypt engine/adapter, gzip middleware and completion-counter
workaround were deleted. Rayo's shared writer also removes the need to copy
individual decoded tags into a separate list before serialization. Production
`src/*.cr` decreased from **1,305 to 1,105 lines**, including SQL and blank lines.

No new framework bug was found. Two application pieces remain:

- Conduit requires UTC timestamps with exactly three fractional digits; Rayo's
  `JSON::Timestamp` emits six. The small millisecond formatter remains. Optional
  timestamp precision would be a useful generic API addition.
- Cross-request read scheduling now lives in Rayo (`PG::Coalescer`); the Conduit
  SQL, enrichment and response shapes stay in `src/reads.cr`.

SQLite, multiple ports and affected-row hooks are not needed by this API.
Remaining differences from epoll include optional write group commit and allocation-free data
structures. This entry prioritizes ordinary framework routes and serialization.

## Final comparison (Rayo c9553d9)

Three alternating rounds, 2026-10-28, on the local mc1 box (3 CPUs, Postgres
sharing them), 3,000 users, `mcbox.sh` defaults, against
`crystal-epoll-faustinoaq`. All six runs passed with zero errors.

| Round | epoll req/s | epoll p95 / p99 | Rayo req/s | Rayo p95 / p99 |
|---|---:|---:|---:|---:|
| 1 | 7,078 | 78.2 / 83.7 ms | 7,065 | 61.2 / 76.2 ms |
| 2 | 7,102 | 75.0 / 79.6 ms | 7,319 | 52.5 / 56.7 ms |
| 3 | 7,079 | 76.7 / 81.2 ms | 7,093 | 63.5 / 80.9 ms |

CPU-seconds (Postgres / app, including ramp and tail): epoll 84/58, 77/58, 76/60;
Rayo 88/65, 91/66, 90/66, about 15% more in total. Before the coalescer Rayo used
171/83. Earlier measurements below describe older revisions.

## Local mc2 sanity comparison

Pending results. The final clean comparison will be run separately.

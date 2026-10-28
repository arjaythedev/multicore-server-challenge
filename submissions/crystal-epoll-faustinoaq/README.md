# Crystal + io_uring

Front: direct

| Component | Version / implementation |
|---|---|
| Crystal | 1.22.1, release build, `-Dgc_none`, x86-64-v3 CPU target |
| HTTP framework | None; custom HTTP/1.1 parser and JSON reader/writer |
| Network I/O | Raw Linux io_uring, `SO_REUSEPORT`; Linux 6.1+ required |
| PostgreSQL driver | Custom v3 wire client with SCRAM-SHA-256, prepared statements and pipelining |
| JWT | Custom HS256 validation using OpenSSL HMAC |
| Password hashing | Crystal EksBlowfish with interleaved lanes, cost 10; libcrypt salts and compatibility fallback |
| Compression | Ubuntu 24.04 libdeflate, gzip level 1 |

There are no shard dependencies. System libraries come from Ubuntu's packages;
`install.sh` pins Crystal and verifies the official archive's SHA-256 digest.

```bash
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit \
JWT_SECRET=multicore-server-challenge HOST=0.0.0.0 PORT=80 bash start.sh
```

The parent starts independent worker processes, each with a `SO_REUSEPORT` listener,
an io_uring event loop, PostgreSQL connections and bcrypt pthreads. A worker failure
stops the server. Despite the submission directory's name, network I/O uses io_uring.

The garbage collector is compiled out. Request buffers are managed explicitly with
`malloc`/`realloc`/`free`, and response arenas are reused after outstanding sends
complete. Idle keep-alive connections do not reserve full request buffers. Bcrypt
runs off the event loop; gzip is negotiated for JSON bodies of at least 1,024 bytes.

## Design

Read requests accumulate on a 50 ms clock. Lists of every filter, feeds and
article lookups share one queue in each process, with at most 1,024 requests per
batch. Two phases keep both database work and database result traffic small:

1. Resolve distinct page/lookup keys and capped count keys, returning each
   request's article IDs and count. Empty pages retain their counts.
2. Enrich the union of article IDs once: tags, favorite count and author profile.
   Bodies are fetched only for individual-article requests. Separate primary-key
   range scans (`= ANY`) return favorited/following pairs for distinct viewers.
   Crystal assembles each request's rows using a sorted article lookup and
   temporary sets of viewer flags, then the existing JSON serializer.

This avoids asking PostgreSQL to serialize an article repeatedly for overlapping
pages. Generic plans underestimate array sizes; lateral `OFFSET 0` keeps base-table
lookups as lookups, and a full join between two equivalent request-key sets avoids
repeated scans of the materialized capped counts. Tags, comments, profiles and
current-user reads also batch within their endpoint. The clock continues while
Postgres is idle so faster queries do not fragment subsequent batches.

With `GROUP_COMMIT=1`, writes use a 20 ms collection window on the write connection and share one implicit
PostgreSQL transaction, up to 48 requests. Their Bind/Execute messages
end with one Sync; responses stay buffered until ReadyForQuery confirms commit.
A SQL error rolls back the whole group, then each request retries independently.
Connection loss fails the affected requests without retrying an unknown commit.
Article creation and tag insertion remain atomic. A single-connection setting
closes any write group before appending a read.
Once a group closes, the next flush sends it together with any trailing partial
group. A newer group's collection window cannot postpone already closed groups.

Bcrypt pthreads collect up to six jobs, waiting at most 200 ms to fill a set.
Collection is serialized within each process so waiting threads do not split a
sparse queue. Independent EksBlowfish states run in lockstep, interleaving S-box
loads; every hash still performs all 1,024 cost-10 key-setup rounds. Underfilled sets
use their actual width (one through six), without computing dummy hashes.
libcrypt supplies random salts and handles unusual formats, noncanonical salts
and high-bit `$2a$` compatibility cases. Login comparisons examine every hash byte.

All data belongs to requests already waiting when their batch forms and is freed
after that batch. There is no data, bcrypt-result or token-verification cache.
Every authenticated request verifies HS256, algorithm and expiry. Each login
verifies the stored password hash, and writes commit before responses.

Own PostgreSQL sessions set `jit=off`, `plan_cache_mode=force_generic_plan`,
`max_parallel_workers_per_gather=0` and `enable_seqscan=off`. The last preference
avoids scanning the small tags table for every tag of every enriched article;
plans still use sequential scans when there is no alternative. No schema or
global settings change.

## Settings

`DATABASE_URL`, `JWT_SECRET`, `HOST` and `PORT` follow the runtime contract.
Optional tuning variables and their defaults:

| Variable | Default | Purpose |
|---|---|---|
| `WORKERS` | `min(CPU count, 2)` | Independent event-loop processes |
| `PG_CONNS` | `(95 // WORKERS).clamp(1, 4)` | PostgreSQL connections per worker |
| `PG_DEPTH` | 2 | Maximum outstanding jobs per connection |
| `BATCH_WINDOW_US` | 50000 | Read batch clock in microseconds |
| `READ_CLOCK` | 1 | Set to 0 for the previous in-flight-only window |
| `SHARED_READS` | 1 | Set to 0 for separate article endpoint batches |
| `PG_INDEX_LOOKUPS` | 1 | Set to 0 to restore ordinary scan selection |
| `GROUP_COMMIT` | 0 | Set to 1 to group writes into shared transactions (experimental) |
| `WRITE_WINDOW_US` | 20000 | Write collection window in microseconds (0–50000) |
| `BCRYPT_THREADS` | 2 | Bcrypt pthreads per worker |
| `BCRYPT_WINDOW_MS` | 200 | Maximum wait to fill bcrypt lanes (0–400) |
| `BCRYPT_LANES` | 6 | Set to 1 to use libcrypt for comparison |
| `GZIP` | 1 | Set to 0 to disable compression |

On the eight-core box the defaults use two workers and eight PostgreSQL connections
(one write connection and three read connections per process).
Fewer workers and small pools keep batches large and leave CPU time for PostgreSQL.
Keep `WORKERS * PG_CONNS <= 95`. `BATCH_DEBUG=1` enables batch diagnostics;
normal operation does not log individual batches.

## Validation

- `bash test/run.sh submissions/crystal-epoll-faustinoaq`: 197/197 conformance checks.
- A local script comparing the same GETs sent concurrently (batched) and one by one: three rounds, 0 differences.
- `crystal build --release --mcpu x86-64-v3 test/bcrypt.cr -o bin/test-bcrypt && bin/test-bcrypt`:
  1,000 cost-10 hashes checked against libcrypt, with random salts and 0–72 byte
  passwords: ASCII `$2a$`, arbitrary non-NUL bytes for `$2b$`, 1/2/3/4/5/6/8 lanes
  and the seed hash. The production fast path sends high-bit `$2a$` to libcrypt.
- `DATABASE_URL=... python3 test/bcrypt_fallback.py http://HOST:PORT`: HTTP login
  checks for high-bit `$2a$`, `$2y$`, UTF-8 `$2b$` and 72-byte passwords; matching
  passwords succeed and wrong passwords fail.
- `python3 test/group_commit.py http://HOST:PORT`: concurrent conflicting and
  successful registrations; successful writes must be visible after the response.
- `GROUP_COMMIT=1 crystal run test/group_flush.cr`: a full group followed by a
  partial group flushes immediately; a fresh partial group still waits for its window.

Local measurements (development seed, 3,500 users, think scale 0.05, the repo's loadgen with a 10 s ramp, 30 s
measurement and 5 s tail, app limited to four CPUs, loadgen and Postgres on the same machine; not official
full-seed scores). CPU seconds cover the whole run:

| Build | req/s | p95 | Postgres CPU-s | App CPU-s |
|---|--:|--:|--:|--:|
| Per-request statements, no batching | 7,900 | 675 ms | saturated | saturated |
| Read batching, libcrypt bcrypt | 14,500 | 126 ms | 194 | 118 |
| + shared enrichment, group commit, 6-lane bcrypt | 14,650 | 88 ms | 100 | 84 |

The load generator tops out near 15k req/s on that machine, so the gain shows up as CPU per request rather than
throughput.

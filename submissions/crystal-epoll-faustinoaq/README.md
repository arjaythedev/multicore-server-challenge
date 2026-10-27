# Crystal + io_uring

Front: direct

| Component | Version / implementation |
|---|---|
| Crystal | 1.22.1, release build, `-Dgc_none`, native CPU target |
| HTTP framework | None; custom HTTP/1.1 parser and JSON reader/writer |
| Network I/O | Raw Linux io_uring, `SO_REUSEPORT`; Linux 6.1+ required |
| PostgreSQL driver | Custom v3 wire client with SCRAM-SHA-256, prepared statements and pipelining |
| JWT | Custom HS256 validation using OpenSSL HMAC |
| Password hashing | Ubuntu 24.04 libcrypt (`crypt_rn`), bcrypt cost 10 |
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

Read requests queue by endpoint and are dispatched in batches of up to 256.
Array parameters and `unnest ... WITH ORDINALITY` preserve each request's identity.
SQL deduplicates page and lookup keys and enriches shared articles once per batch;
per-viewer flags remain specific to each request. Lateral lookups with `OFFSET 0`
keep the planner from replacing key lookups with whole-table joins. The batch
window allows requests to accumulate while an earlier batch is in flight; when
no reads are in flight, dispatch is immediate.

All shared data is read while the participating requests are waiting and discarded
after their batch; there is no cache across requests. SQL preserves `SPEC.md`'s
ordering, capped counts, errors and write semantics. Writes finish before responses
are released, and article creation is transactional. Each authenticated request
validates its token's algorithm, HS256 signature and expiry; each login verifies
the stored bcrypt hash.

Own PostgreSQL sessions set `jit=off`, `plan_cache_mode=force_generic_plan` and
`max_parallel_workers_per_gather=0` to avoid repeated planning/JIT and parallel
worker overhead for small batched queries. No database schema or global settings
are changed.

## Settings

`DATABASE_URL`, `JWT_SECRET`, `HOST` and `PORT` follow the runtime contract.
Optional tuning variables and their defaults:

| Variable | Default | Purpose |
|---|---|---|
| `WORKERS` | `min(CPU count, 2)` | Independent event-loop processes |
| `PG_CONNS` | `(95 // WORKERS).clamp(1, 4)` | PostgreSQL connections per worker |
| `PG_DEPTH` | 2 | Maximum outstanding jobs per connection |
| `BATCH_WINDOW_US` | 20000 | Read batching window in microseconds |
| `BCRYPT_THREADS` | 2 | Bcrypt pthreads per worker |
| `GZIP` | 1 | Set to 0 to disable compression |

On the eight-core box the defaults use two workers and eight PostgreSQL connections.
Fewer workers and small pools keep batches large and leave CPU time for PostgreSQL.
Keep `WORKERS * PG_CONNS <= 95`. `BATCH_DEBUG=1` enables batch diagnostics;
normal operation does not log individual batches.

## Validation

- `bash test/run.sh submissions/crystal-epoll-faustinoaq`: 197/197 conformance checks.
- Concurrent batched reads compared with sequential reads: three rounds, 0 differences.

A local development-seed run with 3,500 users, think scale 0.05, two workers, four
connections per worker and a 20 ms window passed at 14,543 requests/s with p95
94.5 ms and 0% errors. CPU time over the run was 132 seconds for PostgreSQL and
96 seconds for the app. The app was restricted to four CPUs and the load generator
ran on the same machine; this is not an official full-dataset benchmark score.

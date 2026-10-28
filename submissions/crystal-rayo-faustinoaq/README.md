# Crystal + Rayo

Front: direct

| Component | Version / implementation |
|---|---|
| Crystal | 1.22.1, release build, x86-64-v3 CPU target |
| Framework | [Rayo](https://github.com/faustinoaq/rayo), commit `e0006c8b773dae7b75d78eedab314419fb08c0e9` |
| PostgreSQL driver | Rayo::PG, prepared statements and pipelining |
| Network I/O | Rayo io_uring, `SO_REUSEPORT`; Linux 6.1+ with io_uring allowed |
| JWT | Rayo::JWT, HS256 through OpenSSL libcrypto |
| Password hashing | Interleaved Crystal EksBlowfish, cost 10; libcrypt salts and compatibility fallback |
| Compression | Application middleware, libdeflate gzip level 1 |

The shard manifest and lockfile pin Rayo. `install.sh` pins Crystal and checks the
SHA-256 digest of its official archive. System libraries use Ubuntu packages.

```bash
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit \
JWT_SECRET=multicore-server-challenge HOST=0.0.0.0 PORT=80 bash start.sh
```

## Design

This is a Rayo application: routes use `ctx.db.query`, `ctx.json`, streaming JSON
arrays, borrowed request-body readers and `Rayo::JWT`. Rayo owns HTTP parsing,
routing, io_uring, prepared statements, database pipelining and worker supervision.
`App#run` starts one worker per available CPU by default. Each worker owns its
listener, database connections, reusable buffers and bcrypt thread.

The SQL comes from the hand-rolled Crystal entry: indexed tag lookups, bounded
feed queries, capped counts and CTEs for dependent writes. Article creation,
tag upserts and article/tag links commit in one statement; responses wait for
Postgres ReadyForQuery. Follow-up article reads see the committed write.
Rayo pipelines independent queries within each event-loop turn. This entry
uses per-request SQL, without the hand-rolled entry's shared article enrichment,
cross-request read batches or optional group commit.

Each authenticated request verifies HS256 and expiry. Every login reads its hash
from Postgres and verifies it with cost-10 bcrypt. There is no result, response,
password or token-verification cache. Request arenas and serialization scratch
are reused, but their contents are read only for the current request.

Bcrypt runs in pthreads outside the event loop. Each thread gathers up to six
jobs for at most 200 ms, interleaves independent EksBlowfish states, and returns
results through a socket watched by Rayo. Underfilled groups compute only their
actual lane count. libcrypt handles unusual formats, noncanonical salts and
high-bit `$2a$` compatibility cases. Completed jobs return to a retained pool;
deferred handles protect disconnected or reused HTTP slots.

Gzip is response middleware using `app.after`. JSON of at least 1,024 bytes is
compressed only when accepted and smaller; explicit gzip `q=0` is respected.
No compressed response is cached across requests.

The normal garbage collector remains enabled. Validation deliberately raises
exceptions for malformed JSON, invalid tokens and invalid fields; those paths
allocate. Connection state and bcrypt job pools also grow on first use. Building
this application with `-Dgc_none` would retain exception allocations on repeated
invalid requests. Reused byte arenas avoid string building on warmed successful
requests without making a zero-allocation claim.

## Settings

`DATABASE_URL`, `JWT_SECRET`, `HOST` and `PORT` follow the runtime contract.

| Variable | Default | Purpose |
|---|---|---|
| `WORKERS` | Available CPU count | Rayo worker processes |
| `PG_CONNS` | `(95 // WORKERS).clamp(1, 4)` | Connections per worker |
| `BCRYPT_THREADS` | 1 | Bcrypt pthreads per worker |
| `BCRYPT_WINDOW_MS` | 200 | Maximum lane collection wait, clamped to 0–400 ms |
| `BCRYPT_LANES` | 6 | Set to 1 for libcrypt instead of the lane implementation |
| `GZIP` | 1 | Set to 0 to disable gzip middleware |

Startup rejects worker/pool settings that exceed 95 total database connections.
No schema or global Postgres settings change.

## Validation

Built and tested inside `crdev`, with Crystal 1.22.1:

- `bash test/run.sh submissions/crystal-rayo-faustinoaq`: **197/197 checks passed** on a fresh development-seed copy, three workers, port 3291.
- `crystal build --release --mcpu x86-64-v3 test/bcrypt.cr -o bin/test-bcrypt && bin/test-bcrypt`: **1,000 cost-10 hashes match libcrypt**, including 1/2/3/4/5/6/8 lanes, random salts, 0–72 byte passwords and the seed hash.
- `DATABASE_URL=... python3 test/bcrypt_fallback.py http://HOST:PORT`: high-bit `$2a$`, UTF-8 `$2b$`, `$2y$` and 72-byte passwords; matching passwords accepted and wrong passwords rejected.
- `python3 test/concurrency.py http://HOST:PORT`: 24 concurrent logins, disconnects with pending password jobs, ordered HTTP pipelining, gzip/identity equivalence and explicit gzip `q=0`.

The HTTP tests use isolated scratch databases. Drop those databases after testing.

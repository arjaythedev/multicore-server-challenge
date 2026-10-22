# Goose / native primitives / PostgreSQL

Front: direct

Goose implements the Conduit API, routing, PostgreSQL wire protocol and SQL,
HS256 claim validation, response construction, asynchronous epoll scheduling,
and cost-10 bcrypt. Small C helpers provide our SIMD JSON string writer,
per-thread OpenSSL HMAC operations, and platform-correct Linux syscall bindings.

This adapts our [single-core Goose implementation](https://github.com/arjaythedev/twelve-dollar-server-challenge/pull/143)
and the MIT-licensed asynchronous Conduit/Postgres core from
[XeonFX's PR #31](https://github.com/arjaythedev/multicore-server-challenge/pull/31).
Compatible read batching originates in [Scooter1337's Rust PR #7](https://github.com/arjaythedev/multicore-server-challenge/pull/7).
See [NOTICE.md](NOTICE.md) for pinned source attribution.

## Build and run

```sh
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit \
  JWT_SECRET=multicore-server-challenge HOST=0.0.0.0 PORT=80 bash start.sh
```

The compiler is built from Goose commit
`f605b5a07dd2aa3a5cb3f4c9b14002bd3c9d3d1a`; its source archive is SHA-256
verified. The generated C and native helpers are compiled together using GCC
with optimization and LTO. Dependencies are installed from Ubuntu 24.04's
packages; no application binary is downloaded. `GOOSE_BIN` can select an
already-installed matching compiler for local development; a normal clean
build creates the compiler from source.

## Design and conditions

- Four independent epoll loops, each with three read connections and one write
  connection: 16 PostgreSQL connections by default, below the limit of 95.
- Pipelined prepared statements and compatible concurrent read batching;
  shared enrichment exists only within one SQL execution. Quiet reads start
  immediately. No responses or query results survive for later requests.
- Cost-10 bcrypt runs on two dedicated hashing threads, with up to five jobs
  interleaved. Passwords are checked against the stored hash on every login.
- Each authenticated request computes a fresh HS256 MAC, checks the header and
  expiry, and validates its subject. Only the HMAC key setup is reused, with
  separate OpenSSL state for every thread; no verification result is cached.
- Response strings use our SSE2/NEON JSON escaping helper. Goose continues to
  own the response structure and all application-level validation.
- The app uses the supplied PostgreSQL 18 database, fixed schema and cluster
  settings. It does not set CPU affinity, change host settings or restart
  crashed workers. Successful writes wait for PostgreSQL commit completion.
- Idle connections remain open, and sockets use the challenge's descriptor
  budget. No external service or result cache is required.

`DATABASE_URL`, `JWT_SECRET`, `HOST` and `PORT` follow SPEC.md. Optional process
settings include `WORKERS`, `PG_READERS`, `HASHERS`, `BCRYPT_BATCH_MS`,
`READ_BATCH` and `READ_HOLD`, inherited from the credited base implementation.
`ARTICLE_BATCH=1` enables bounded overlapping article reads: one SQL execution
reads each distinct slug's common article data once while retaining per-viewer
favorite/follow flags. It defaults to 0 until comparative measurements justify
enabling it. No data is retained for a later batch.

## Validation status

The unchanged conformance suite passes **197/197 steps on both dev and full
seeds**, including a full-seed run with `ARTICLE_BATCH=1`. The original seed
fingerprints were checked. Additional black-box tests pass 39 JWT cases and
1,024 concurrent article comparisons against unbatched responses, including
viewer differences, Unicode, missing articles and committed changes.

A deterministic concurrent-write test reproduced an inherited favorite-count
race (response 1 while committed PostgreSQL and an immediate GET reported 2).
The response now reads the article after commit; the same test returns 2.
The bcrypt reply path also waits through nonblocking-pipe backpressure and
interrupts instead of losing completed jobs. Configuration is rejected when
its total PostgreSQL connections would exceed 95.

`bash tests/native.sh` passes 293,966 native assertions plus 4,000 Goose JWT
assertions across eight workers. It covers HMAC key changes and failure
recovery, JSON SIMD boundaries, real Linux syscall ABI, full reply-pipe
backpressure and signal interruptions. It uses no database.

A clean compiler-and-application source bootstrap as a normal user passed
in 86.25 seconds, inside the combined eight-CPU / 16-GiB / no-swap target.
These validation runs use Ubuntu 24.04 ARM64 in Docker on a Mac. The target
contains both the application and PostgreSQL 18 with the published eight-core
cluster configuration; CPU affinity is unused. They do not establish an
official x86-64 score. Comparative load measurements are in progress; no
first-place result is claimed.

# Rust / Tokio: request-cohort SQL optimization

Front: direct

**100% AI-coded experiment, submitted solely to see how far AI can go at this
challenge.** The human supplied the goal, prompts and operating constraints;
AI performed this contribution's coding, optimization, documentation and review.
All submission-specific code changes were written by AI. The inherited code and
dependencies retain their original authorship and licenses, as detailed below.
See [AI_DISCLOSURE.md](AI_DISCLOSURE.md) for the full disclosure and
[RULES_AUDIT.md](RULES_AUDIT.md) for the rule-by-rule audit and validation limits.

An attributed derivative of `rust-tokio-Scooter1337`, built from challenge commit
`c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e`. The upstream API and initial SQL in turn
build on `rust-hyper-cknutson12`. Their MIT attribution is retained in LICENSE;
vendored PostgreSQL driver and native bcrypt licenses remain with their source.

Rust 1.99.0, Tokio 1.53.2, tokio-postgres 0.7.18, PostgreSQL 18 and mimalloc 0.1.52.
All Rust dependencies are pinned in Cargo.toml/Cargo.lock. The local compiler used
for measurements is recorded in BENCHMARKS.md. No prebuilt application binaries.

The latest changes reduce batch-selection overhead and pack queued writes into
one PostgreSQL protocol group. Current-source checks pass 14 unit tests, a focused
PostgreSQL integration test and all 197 official API checks. These checks ran
under enforced development resource limits. The current revision's guarded
load tests are recorded in [results/laptop-load.md](results/laptop-load.md),
separately from the preceding revision's unrestricted measurements.

## Approach

The starting implementation already has direct HTTP/1.1, small idle connections,
prepared generic plans, a PostgreSQL binary protocol, separate read/write pools,
durable group commit, SIMD JSON escaping, and bounded four-way interleaved bcrypt.
Those mechanisms and their original authors' work are retained.

This version reduces duplicate database work among requests that are already
waiting for execution:

- Filtered list batches resolve each distinct tag/user once, calculate each capped
  count once per filter, fetch each distinct page once, and enrich each article
  once. Requests with different offsets can still share the count. Viewer flags
  and response ordinals are applied independently afterward.
- Comment batches read each request's followee set once. If at least half of the
  requests address duplicate slugs, the query fetches and enriches each distinct
  thread once, then evaluates each viewer's following flags separately.
- The simpler upstream global-feed query is retained after SQL measurements found
  that distinct page-key joins usually added overhead for that family. Its capped
  count checks for the 1,000th row first, avoiding an aggregate when that row proves
  the cap. Smaller databases use an exact-count fallback in the same snapshot.
- Two bounded bcrypt workers on eight CPUs prevent the single-worker login queue
  from growing under sustained arrivals. Each worker still interleaves up to four
  complete cost-10 hashes; salts and password verification remain independent.
- Batch selection decodes each key at most once and stops when too many distinct
  keys make sharing impossible. The default cohort uses stack storage for keys.
  Integer parameter arrays reserve their known maximum encoded size, and database
  actors reuse an empty job vector after releasing every request in a cohort.
- Writes are encoded once into owned Bind/Execute frames, avoiding per-parameter
  allocations and re-encoding. A group submits all frames with one protocol Sync
  inside its explicit transaction. Statement errors drain the protocol, roll back
  the group and retry jobs individually; commit failures never release tentative
  successes or trigger replay. Success replies still wait for COMMIT.

Every execution reads PostgreSQL using a fresh snapshot. The application keeps no
response/query-result, token-verification or password cache. A batch includes only
requests queued before its execution. bcrypt remains cost 10; every token checks
its HS256 signature, algorithm and expiry. Writes finish durable commit before
responses are sent. No schema, server configuration, CPU affinity or host changes
are made by the server.

## Build and run

```sh
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit \
  JWT_SECRET=your-secret HOST=0.0.0.0 PORT=80 bash start.sh
```

`install.sh` installs a pinned Rust toolchain and a C build toolchain on Ubuntu
24.04. `build.sh` uses a locked release build with fat LTO. `start.sh` runs the
server in the foreground. The challenge supplies the file-descriptor limit and
permission to bind port 80.

On eight CPUs the process defaults are two Tokio workers, six read
connections, two write connections and two bcrypt workers. The total connection
count is checked against the 95-connection limit. Available optional settings:
`APP_THREADS`, `DB_CONNS`, `DB_WRITE_CONNS`, `BCRYPT_THREADS`, `BCRYPT_BATCH_MS`,
`WRITE_BATCH_US`, `READ_BATCH_SIZE`, `READ_BATCH_US`, `READ_SQL_BATCH`,
`READ_ROUTE_SLACK`, `READ_TAG_BATCH`, `READ_TAG_ROUTE`, `READ_COMMENT_SET`, and
`READ_COMMENTS_BATCH` (0 disables the new comment batching).

## Validation and measurement

The optimization plan is in PLAN.md. Reproduction tools are in tools/:

- `setup-local.sh`: dedicated PostgreSQL 18 container and official seed databases.
- `bench.py`: fresh database clone per run, unchanged upstream load generator,
  raw histograms, process monitoring and cleanup.
- `sql_list_bench.py`: paired SQL timing and result equivalence against a baseline.
- `sql_count_bench.py`: global-count timing and exactness around the 1,000-row cap.
- `regression.py`: concurrent viewer isolation, fresh writes, rollback isolation,
  pagination, comments and HTTP framing checks on a disposable database.
- `bounded-check.sh`: resource-limited builds and tests, refusing to run without
  memory headroom or effective cgroup limits.
- `laptop-load.py`: capped full-seed load probes and five-minute measurements,
  with an independent temperature/resource watchdog and retained raw results.
- `check-writes.sh` / `check-conformance.sh`: small, separately capped PostgreSQL
  fixtures for transaction behavior and the official API checks.

The unchanged upstream conformance suite is the acceptance gate. Local performance
measurements and their limitations are recorded in BENCHMARKS.md. This derivative
has no official challenge score; the upstream submission's score is not ours.

The 197 conformance checks also pass after the latest changes. The preceding
revision's last five-minute local run reached
37,379 req/s, p95 174.8 ms, p99 244.6 ms and 0.0322% errors, with no generator
limitation reported. It used a shared workstation and accelerated think times;
see the report before comparing these numbers with another server or score.

# Bun / Bun.serve + Bun.SQL, compiled ahead of time, batched reads and group commit

Front: direct

| | |
|---|---|
| Runtime | Bun 1.4.4 canary `1.4.4-canary.20261031.1` (revision da867c60b), from npm (`@oven/bun-linux-x64`), version and SHA-256 pinned in `install.sh` |
| HTTP | `Bun.serve` with `routes`, one process per worker on the shared port (`reusePort`) |
| Postgres | `Bun.SQL` (built in), tagged templates with `prepare: true`; one read and one write connection per worker |
| bcrypt | Openwall's bcrypt core with a lane-interleaved driver (`native/`, through `bun:ffi`), cost 10, run by the supervisor for all workers |
| JWT | HS256 with `Bun.CryptoHasher` |
| Language | TypeScript (strict), compiled ahead of time by `bun compile` into one executable on the box; `bun check --aot` and `bunx tsc --noEmit` find no type errors |
| npm dependencies | none at run time; `typescript` and `@types/bun` for type-checking only (devDependencies) |

```bash
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

## Results on a local arm64 rig

| Run | Users | req/s | p95 ms | p99 ms | errors |
|---|--:|--:|--:|--:|--:|
| the challenge's full search (score: the 5-minute hold) | **140,000** | 35,881 | 396.5 | 524.8 | 0% |
| best: one 2-minute run on a fresh database | **230,000** | 57,946 | 416.5 | 547.3 | 0% |

Not the official box (details and the JIT comparison under [Measurements](#measurements)); at 230,000 users the
rig's own CPU, shared with the load generators, runs out first.

## Layout

```
src/server.ts         startup (supervisor and workers), the routes, request helpers, JWT
src/db.ts             the two connections, batching, every statement, group commit
src/bcrypt.ts         bcrypt pool in the supervisor; hash() / verify() in the workers
src/bcrypt-thread.ts  one bcrypt thread: interleaved hashes in native code (bun:ffi), compiled into the executable
native/               the bcrypt C code (Openwall core + lane-interleaved driver)
```

## Design

The other Bun entry runs one process (one JavaScript thread for the whole box) with `Bun.password`. This one uses
the cores and spends far less CPU per request; most of what follows came from CPU profiles (`bun --cpu-prof`) and
Postgres's per-index counters, measured before and after each change.

- **One process per worker** (`WORKERS`, default half the cores: Postgres needs the rest, and fewer workers make
  bigger batches), each with its own `Bun.serve` on the shared port (`reusePort`: the kernel spreads connections).
- **Batched reads (the DataLoader pattern).** `batch()` gathers the calls made within `BATCH_MS` (40 ms) into one
  execution: argument c of every call makes column c, an array parameter, and the statement's input is
  `unnest(...) WITH ORDINALITY`; rows come back tagged with their call. Identical calls in a window are one call.
  Nothing outlives its batch: every response is read from Postgres while its request waits (rule 5).
- **One statement per kind of read.** An article by slug or by id, the five kinds of list and the five kinds of count
  are one statement each: the variant is an argument, and `CASE` runs only the subquery its branch picks. Each worker
  sends its reads down one connection (one Postgres backend), so under load every execution's fixed cost queues the
  reads behind it; one statement per variant was 58% more executions per request, and its 5-minute holds failed
  where these pass.
- **Work once per batch.** Author, favorite count and tags are read once per distinct article in the batch (tag
  names in one join for the batch: a per-article tag subquery got a generic plan that hashed all of `tags` for every
  article, 61% of the tuples Postgres read). A viewer's `favorited` / `following` flags are one primary-key range scan
  per signed-in viewer (`= ANY` of that viewer's articles or authors in the batch, in `MATERIALIZED` CTEs; a probe per
  row read twice the index entries). Anonymous viewers skip them.
- **Group commit.** Favorites, unfavorites, follows, unfollows and new comments that arrive within `WRITE_MS` (3 ms)
  run as one statement, one data-modifying `WITH` per kind over arrays of the calls' arguments: one transaction and
  one WAL flush, and each request is answered after it commits (rule 6). If Postgres rejects the group, each write is
  retried on its own, so one bad write fails only its own request; if the outcome is unknown (a lost connection),
  nothing is retried.
- **Two connections per worker.** Bun.SQL pipelines concurrent queries on one connection; writes have their own, so
  reads never wait behind a commit. 8 connections in all, far from `max_connections`.
- **Interleaved bcrypt in the supervisor.** About 1.1 logins happen per 1,000 requests, and `Bun.password` spends
  44 ms of CPU on each: two thirds of the app's CPU in the profile. bcrypt's key schedule is one long chain of
  dependent loads, so `native/bcrypt.c` runs up to six hashes round by round in one call: 11.5 ms of CPU each
  (calibrated at startup). One worker sees too few logins to fill a set, so workers send their hashes to the
  supervisor over Bun's IPC, which gathers them from all workers. Every hash and verify still does all 2^10 rounds.
- **Prepared, generic plans.** With `prepare: true` every statement is a named prepared statement on its connection
  (connections are never recycled). Session settings: `jit = off`, `plan_cache_mode = force_generic_plan`,
  `max_parallel_workers_per_gather = 0`. With generic plans, values the planner needs (a `LIMIT`) are SQL text.
- **Rows shaped in SQL.** Aliases give the response's field names; a small typed mapper nests the article and comment
  authors. `GET /api/tags` is built by Postgres as the finished body (200 one-column rows cost more to decode than to
  build). Ids come back as `float8` (exact to 2^53), decoded as numbers.
- **Create article** is one atomic statement (the article, any new tags, the article's tags) instead of a transaction.
- **Compiled ahead of time.** `build.sh` runs `bun check --aot` (the compiler's own type check: it needs full types
  to emit typed code) and `bun compile` into one executable, `server`, with the bcrypt thread inside it. Everything
  above kept the code fully typed (typed batch arguments, a typed row mapper, classes instead of open objects), and
  `bun compile --explain` reports what still falls back to untyped code; what remains is at Bun's own APIs
  (oven-sh/bun#47599, #47600). 8–11% less app CPU per request than the JIT on the rig.

## Measurements

On a local Linux rig, not the official box: a Colima VM (10 vCPU, arm64) where Postgres and the app share a cgroup
capped at 8 CPUs and 16 GB, and 8 load-generator containers on the same VM drive it over a bridge.

The challenge's search (`test/search.sh` sequence: probes doubling from 500 users, then bisection, then 5-minute
holds stepping down), `WORKERS=4`, on a fresh database:

| Phase | Users | Passed | req/s | p50 ms | p95 ms | p99 ms | errors |
|---|--:|:-:|--:|--:|--:|--:|--:|
| probe | 64,000 | yes | 16,836 | 31.4 | 49.7 | 71.0 | 0% |
| probe | 128,000 | yes | 33,723 | 41.2 | 77.9 | 99.6 | 0% |
| probe | 140,000 | yes | 36,420 | 76.2 | 212.2 | 348.4 | 0% |
| probe | 150,000 | no | 37,167 | 243.5 | 559.1 | 720.9 | 0% |
| **hold** | **140,000** | **yes** | **35,881** | **107.4** | **396.5** | **524.8** | **0%** |

**Score on this rig: 140,000 users**, the first hold. App CPU in that hold was 56 µs per request, Postgres 89 µs.
The same code run by Bun 1.4.4's JIT (`bun src/server.ts`) scored 110,000 on the same rig: its probes passed up to
160,000, its holds failed from 160,000 to 120,000, and by the hold at 110,000 the database had grown through every
earlier phase (app 64 µs, Postgres 110 µs per request). On a fresh database, 2-minute probes of the AOT build pass up
to 230,000 users (57,946 req/s, p99 547 ms), where the rig's own CPU runs out.

Also checked on x86_64 (a Rosetta VM: 4 CPUs, Ubuntu 24.04): `install.sh` and `build.sh` as above, the conformance
suite 197/197 on the dev seed, and 2 minutes at 2,000 users (`-think-scale 0.1`, ~4,900 req/s) with 0 errors.

CPU per request (µs of CPU per request; app includes bcrypt), local Mac, 4,000 users at `-think-scale 0.1`
(~9,700 req/s), one worker, measured on the same design while it was built over Drizzle ORM:

| Version | app | Postgres | total |
|---|--:|--:|--:|
| `Bun.password` instead of interleaved bcrypt | 76 | 45 | 121 |
| interleaved bcrypt | 53 | 43 | 96 |
| + one tags join per batch, one statement per kind | 53 | 42 | 95 |
| + group commit, per-viewer flag scans | 52 | 36 | 88 |

Tried and not kept:

| Idea | Result |
|---|---|
| one statement for all article, list and count reads | about −2 µs/req of Postgres at most; single-article reads wait for list work (+8 ms p50) |
| 2 workers instead of 4 (bigger batches) | −13% CPU per request, but each worker's thread is ~73% busy at 120,000 users: too close to saturating |
| one database thread for all HTTP threads | −28% Postgres CPU per request, but one JS thread for every row, message and JSON saturated at ~24,000 req/s |
| 2 read connections per worker | no difference at 160,000 users |
| Postgres building each article's JSON | about the same app CPU, +3.6–5.7 µs/req of Postgres, the scarcer of the two |
| Bun 1.4.4's JIT instead of `bun compile` | 8–11% more app CPU per request (arm64); scored 110,000 on the rig against 140,000 |
| Drizzle ORM 1.0.0-rc.5 over the same Bun.SQL connections | same statements and design; 6–9% more app CPU per request |

## Rules

- No caches: every response is read from Postgres while its request waits. Writes are committed before the
  response. bcrypt cost 10 on every hash and verify; HS256 signature, `alg` and `exp` checked on every request.
- Session settings only; no schema, index, function or extension touched.
- Built on the box by `build.sh`: the bcrypt library from `native/`, and the server executable from `src/` (`bun compile`).
  Only the Bun toolchain is downloaded, pinned by version and SHA-256.

## Settings

| Variable | Default | |
|---|---|---|
| `WORKERS` | cores / 2 | processes, each with its own `Bun.serve` and two Postgres connections |
| `BATCH_MS` | 40 | read batch window |
| `WRITE_MS` | 3 | group-commit window |
| `BCRYPT_THREADS` | 2 | bcrypt threads in the supervisor |
| `BCRYPT_WAIT_MS` | 100 | how long a partial bcrypt set waits for company |

## Tests

The conformance suite that `test/run.sh` runs: 197/197 on the dev seed, built with `build.sh` on arm64 (macOS) and
x86_64 (Ubuntu 24.04).

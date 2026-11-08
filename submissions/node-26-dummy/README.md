# Node.js 26 Conduit API

`node-26-dummy` implements all 19 Conduit API operations with direct `node:http`,
strict TypeScript 7, Node.js 26, PostgreSQL 18, `pg`, `bcrypt`, and `jose`. It
has no ORM and no HTTP framework.

This is the canonical project reference. Update it with every change to API
behavior, SQL, scripts, configuration, diagnostics, or performance claims.

## Project layout

| Path | Purpose |
|---|---|
| `src/cluster.ts` | Cluster primary, worker budget, fail-fast supervision. |
| `src/server.ts` | HTTP server, route matching, lifecycle and shutdown. |
| `src/handlers.ts` | API handlers, SQL and response mapping. |
| `src/utils.ts` | Pool, transactions, JWT, bcrypt, parsing and validation. |
| `src/pool-diagnostics.ts` | Optional pool instrumentation and bounded JSONL output. |
| `src/http-diagnostics.ts` | Optional HTTP/event-loop instrumentation and bounded JSONL output. |
| `build.sh` / `start.sh` / `install.sh` | Clean build / compiled launch / Ubuntu-Debian bootstrap. |
| `observability/` | LGTM stack, tracing, CPU profiling, SQL snapshots and diagnostics. |

## Requirements and installation

Pinned runtime dependencies: Node.js 26, TypeScript 7.0.2, PostgreSQL 18,
`pg` 8.23.1, `bcrypt` 6.0.0, and `jose` 6.2.14. PostgreSQL schema and Conduit
seed data are prepared by the challenge repository, not this submission.

```bash
cd submissions/node-26-dummy
sudo bash install.sh
node --version
npm --version
```

`install.sh` supports Ubuntu/Debian x64 and arm64. It installs build prerequisites,
downloads Node 26.13.0, verifies its SHA-256 checksum, and links `node`, `npm`,
and `npx` into `/usr/local/bin`. It does not manage PostgreSQL.

## Build and run

```bash
cd submissions/node-26-dummy
bash build.sh
npm run typecheck

DATABASE_URL='postgres://conduit:conduit@127.0.0.1:5432/conduit_lg' \
JWT_SECRET='local-development-secret-change-me' \
HOST=0.0.0.0 PORT=3110 WORKERS=6 \
bash start.sh
```

`build.sh` verifies Node 26, runs `npm ci --include=dev`, rebuilds `bcrypt` from
source, deletes only this submission's `dist/`, and compiles with strict
TypeScript and `noEmitOnError`. `start.sh` runs only `node dist/cluster.js`;
there is no runtime compilation. `npm run typecheck` emits no JavaScript.

| Variable | Required | Default | Description |
|---|---|---|---|
| `DATABASE_URL` | yes | — | PostgreSQL connection URL. |
| `JWT_SECRET` | yes | — | HS256 signing/verification key. |
| `HOST` | no | `0.0.0.0` | Listening address. |
| `PORT` | no | `3110` | Listening port. |
| `WORKERS` | no | available CPUs, max 90 | Cluster workers, 1–90. |
| `NODE_ENV` | no | `production` | Set by `start.sh`; does not change API semantics. |
| `BENCH_DIAGNOSTICS` | no | disabled | Pool metrics when exactly `1`. |
| `BENCH_HTTP_DIAGNOSTICS` | no | disabled | HTTP/event-loop metrics when exactly `1`. |
| `BENCH_RUN_ID` | no | none | Safe identifier in diagnostic records. |
| `BENCH_DIAGNOSTICS_DIR` | no | none | Diagnostic JSONL output directory. |
| `BENCH_DIAGNOSTICS_MAX_BYTES` | no | `10485760` | Per-file cap, 4096–67108864. |

Never commit a real JWT secret or database password.

## Runtime architecture

The primary process computes the worker count once and never connects to
PostgreSQL. Every worker has one `pg.Pool`:

- `WORKERS` defaults to `min(availableParallelism(), 90)`.
- Pool size is `min(10, floor(90 / WORKERS))`.
- The application uses at most 90 PostgreSQL connections, reserving 10 of a
  100-connection server. Six workers therefore have 60 total connections.
- `PG_POOL_SIZE` is an internal primary-to-worker setting, not a public tuning
  setting.
- Any unexpected worker exit, including code 0, stops the cluster non-zero;
  there is no restart loop.
- SIGINT/SIGTERM stop new work, drain handlers, close pools and flush enabled
  diagnostics. Worker timeout is nine seconds; primary force-kills after ten.

HTTP keep-alive is 75 seconds and headers timeout is 80 seconds. `GET /api/tags`
is the database-backed health endpoint; there is no `/health` route.

## HTTP API and SQL

All SQL uses positional parameters. “Auth lookup” below means JWT validation plus
`SELECT id FROM users WHERE id=$1` when a token is supplied. Optional auth permits
no header, but rejects an invalid supplied header. Article projections include
author, ordered tags, favorite count, and viewer-specific following/favorited
flags. List projections omit article body; detail projections include it.

### Users and profiles

| Endpoint | Auth | SQL operations |
|---|---|---|
| `POST /api/users` | none | bcrypt hash; `INSERT users ... RETURNING` user fields; issue JWT. |
| `POST /api/users/login` | none | `SELECT` user/password hash by email; bcrypt compare; issue JWT. |
| `GET /api/user` | required | JWT verify; one `SELECT` user fields by id. |
| `PUT /api/user` | required | Auth lookup; optional bcrypt; `UPDATE users` with `COALESCE`, `RETURNING` fields. |
| `GET /api/profiles/:username` | optional | Auth lookup; `SELECT users` by username plus `EXISTS follows` viewer flag. |
| `POST /api/profiles/:username/follow` | required | Auth lookup; target-user lookup; `INSERT follows ... ON CONFLICT DO NOTHING`. |
| `DELETE /api/profiles/:username/follow` | required | Auth lookup; target-user lookup; `DELETE follows`. |

### Articles

| Endpoint | Auth | SQL operations |
|---|---|---|
| `GET /api/articles` | optional | Auth lookup; paged list and capped count described below. |
| `GET /api/articles/feed` | required | Auth lookup; LATERAL feed page, capped count, article enrichment. |
| `GET /api/articles/:slug` | optional | Auth lookup; full article projection filtered by slug. |
| `POST /api/articles` | required | Auth lookup; transaction: allocate ID, insert article and SQL slug; insert missing tags; insert article-tag links; commit; project result. |
| `PUT /api/articles/:slug` | required | Auth lookup; article identity/owner lookup; `UPDATE articles`; recalculate slug when title changes; project result. |
| `DELETE /api/articles/:slug` | required | Auth lookup; identity/owner lookup; `DELETE articles`; 204. |
| `POST /api/articles/:slug/favorite` | required | Auth lookup; article lookup; idempotent `INSERT favorites`; project result. |
| `DELETE /api/articles/:slug/favorite` | required | Auth lookup; article lookup; `DELETE favorites`; project result. |

### Comments and tags

| Endpoint | Auth | SQL operations |
|---|---|---|
| `GET /api/articles/:slug/comments` | optional | Auth lookup; article identity lookup; newest 100 comments joined to authors, `EXISTS follows`, ordered by `created_at DESC, id DESC`. |
| `POST /api/articles/:slug/comments` | required | Auth lookup; article lookup; transaction with `INSERT comments ... RETURNING` joined to author. |
| `DELETE /api/articles/:slug/comments/:id` | required | Auth lookup; validate id; owner lookup joined to article slug; `DELETE comments`; 204. |
| `GET /api/tags` | ignored | `SELECT name FROM tags ORDER BY name`; ignores `Authorization`. |

### List query shapes

Lists sort by article ID descending. Counts are capped at 1000 independently of
the page. The first non-empty list filter wins: `tag`, then `author`, then
`favorited`; unknown values return an empty list.

| Form | Page selection before enrichment | Capped count |
|---|---|---|
| Global | Derived `articles` relation, ordered and `LIMIT/OFFSET` before projection. | `articles`, first 1000 rows. |
| Tag | Ordered IDs from `article_tags`, then enriched `articles WHERE id IN (page)`. | `article_tags` only. |
| Author | Direct filtered `articles`, ordered and paged before projection. | `articles` only. |
| Favorited | Ordered IDs from `favorites`, then enriched `articles WHERE id IN (page)`. | `favorites` only. |
| Feed | `follows CROSS JOIN LATERAL` gets at most `limit + offset` IDs per followed author; sorts globally, pages, enriches. | Followed-author `articles`, first 1000 rows. |

The feed addition is cast to PostgreSQL `bigint` to preserve maximum-offset
behavior.

## Correctness rules

`SPEC.md` and conformance are the external contract. Current implementation:

- Accepts only `Authorization: Token <jwt>`, HS256, valid `exp`, and a positive
  decimal PostgreSQL-bigint `sub`.
- Authenticates protected routes before body validation; `/api/tags` ignores auth.
- Uses async bcrypt cost 10 and rejects new passwords over 72 UTF-8 bytes.
- Parses bodies as `unknown`, limits them to 1 MiB, rejects malformed JSON and
  invalid wrappers/types with 422, and ignores unknown fields.
- Accepts decimal-only `limit` 1–100 and `offset` 0–2147483647; leading zeroes
  are valid, signs/whitespace/fractions/overflow are not.
- Retains bigint IDs as strings internally and checks every numeric API output
  with `Number.isSafeInteger`; it never rounds silently.
- Builds slugs in PostgreSQL: non-alphanumeric runs become `-`, lowercased and
  trimmed, then `-<id>` is appended.
- Uses a transaction for article/tag/link creation and comment creation.
- Returns UTC ISO timestamps, 201 for creation, 204 with no body for deletion,
  and errors as `{ "errors": { "body": ["..."] } }`.

## Query-shape optimizations

No schema, index, PostgreSQL configuration, pool-size, or worker-count changes
are made by this submission. Current optimizations preserve response semantics:

1. Tag and favorited lists page link-table IDs before article enrichment. Their
   capped counts read their link table instead of joining `articles`.
2. The global list pages articles before author/tag/favorite/viewer enrichment;
   skipped rows do not receive that work.
3. Tag names use `tags.id = article_tags.tag_id`, allowing `tags_pkey` lookup on
   the tuned large database instead of repeated full tag scans.
4. Feed keeps the tested LATERAL form rather than a slower join alternative.
5. `GET /api/user` returns user data in the same query that confirms it exists.

`favorites_count` remains one subquery per returned article. It is a future
candidate, not an implemented optimization. Do not claim a speedup without the
same seed, workload, network path, database state, and instrumentation mode.

Read-only SQL equivalence and selected plan checks:

```bash
cd submissions/node-26-dummy
npm run build
TEST_SQL_DATABASE_URL='postgres://conduit:conduit@127.0.0.1:5432/conduit_lg' \
TEST_SQL_ALLOW_MISSING_FIXTURE=1 TEST_SQL_EXPECT_TAG_INDEX=1 node test-sql.mjs
```

This uses one read-only transaction and statement timeout; it compares query
shapes across filters, viewers, offsets and capped counts, and runs selected
`EXPLAIN ANALYZE` checks. It does not alter its database.

## Testing

From repository root, conformance creates and removes a fresh clone of
`conduit_dev`; do not direct it at a working benchmark database:

```bash
cd /home/padlo/projects/multicore-server-challenge
PORT=3111 WORKERS=1 bash test/run.sh submissions/node-26-dummy
PORT=3111 WORKERS=6 bash test/run.sh submissions/node-26-dummy
```

Set `PGHOST`, `PGPORT`, `PGUSER`, and optionally `PGPASSWORD` for a non-default
PostgreSQL server. Correctness has passed conformance 197/197 with one and six
workers on isolated PostgreSQL 18.6 seed clones.

Integration tests require an isolated PostgreSQL admin URL; they create/remove
their own `node26_*` clone:

```bash
cd submissions/node-26-dummy
TEST_DATABASE_URL='postgres://postgres@127.0.0.1:55432/postgres' npm test
TEST_DATABASE_URL='postgres://postgres@127.0.0.1:55432/postgres' node test-pool.mjs
node observability/test-http.mjs
node observability/test-output.mjs
node observability/test-ctl.mjs
```

`test.mjs` covers lifecycle, rollback, bigint, pagination, fail-fast and shutdown.
`test-pool.mjs` covers callback/Promise compatibility, reuse, saturation, errors,
transactions and release. Focused observability tests cover backpressure,
rotation, HTTP phases/sizes, premature close and controller behavior.

OTel and local diagnostic-overhead verification need an isolated seeded clone:

```bash
TEST_DATABASE_URL='postgres://conduit:conduit@127.0.0.1:55432/node26_diag_checks' \
node observability/verify.mjs otel
TEST_DATABASE_URL='postgres://conduit:conduit@127.0.0.1:55432/node26_diag_checks' \
OVERHEAD_PAIRS=2 node observability/verify.mjs overhead
```

The overhead verifier is local, six-worker, read-only 100 RPS with 30-second
warmup and 60-second measured periods; it is not an official high-VU benchmark.

## Observability

Run these commands from `submissions/node-26-dummy` after `bash build.sh`.
`observability/runtime.env` provides `DATABASE_URL` and `JWT_SECRET` to the
controller. `observability/modes.env` provides `PORT`, `HOST`, and `TRACE_RATIO`.
Treat both as local secret/configuration files.

### LGTM stack

`compose.yaml` runs Grafana LGTM locally: Grafana `127.0.0.1:3300`, OTLP HTTP
`127.0.0.1:4318`. Set `GRAFANA_ADMIN_PASSWORD` in `observability/.env` first.

```bash
export GRAFANA_ADMIN_PASSWORD='choose-a-local-password'
bash observability/ctl.sh stack start
bash observability/ctl.sh stack status
bash observability/ctl.sh stack logs
bash observability/ctl.sh status
bash observability/ctl.sh stack stop
```

### Controller modes

`ctl.sh run` launches Node in the foreground. Press Ctrl+C for graceful shutdown.
`RUN_ID` must be unique and match `[A-Za-z0-9_-]+`; output goes to
`observability/runs/<RUN_ID>/manifest.txt`.

| Command | Global SQL profile change | Trace | CPU profile |
|---|---|---|---|
| `bash observability/ctl.sh run baseline RUN_ID` | off | off | off |
| `bash observability/ctl.sh run pool RUN_ID` | preserve | off | off |
| `bash observability/ctl.sh run sql RUN_ID` | on | off | off |
| `bash observability/ctl.sh run trace5 RUN_ID` | on | 5% | off |
| `ALLOW_FULL_TRACE=1 bash observability/ctl.sh run trace100 RUN_ID` | on | 100% | off |
| `bash observability/ctl.sh run cpu RUN_ID` | on | off | on |
| `bash observability/ctl.sh run deep RUN_ID` | on | 5% | on |

Append `--pool`, `--http`, or both:

```bash
# Pool plus HTTP/event-loop metrics; preserves PostgreSQL settings.
bash observability/ctl.sh run pool diag-001 --http

# Sampled traces with both diagnostic families.
bash observability/ctl.sh run trace5 trace-001 --pool --http
```

`pool` only reads `SHOW pg_stat_statements.track`. Other modes marked `on/off`
call `sql-profile.sh`, which uses `ALTER SYSTEM` and `pg_reload_conf()` to change
global `pg_stat_statements.track`, `track_io_timing`, and planning tracking. Do
not run those global modes on shared PostgreSQL without authorization.

Direct SQL-profile controller commands are:

```bash
bash observability/ctl.sh sql status
bash observability/ctl.sh sql off
bash observability/ctl.sh sql on
bash observability/ctl.sh sql detailed
```

`off` sets statement tracking to `none`; `on` sets top-level tracking without I/O
or planning timing; `detailed` enables both I/O timing and planning tracking.

`observability/run-node.sh off|sampled|full` is a lower-level compiled-node OTel
launcher. It requires `DATABASE_URL`, `JWT_SECRET`, and `modes.env`; `full`
requires `ALLOW_FULL_TRACE=1`. Prefer `ctl.sh run` because it writes a manifest.

### SQL snapshots

Use snapshots for a real `pg_stat_statements` delta around a manually run load:

```bash
bash observability/ctl.sh begin run-001
# Run the load generator manually.
bash observability/ctl.sh end run-001
bash observability/ctl.sh report run-001
```

`sql-snapshot.sh` saves begin/end CSV plus reset/deallocation metadata.
`sql-diff.py` refuses a delta if that metadata changed, then reports calls, total
execution time, mean execution time and truncated normalized SQL. It reports SQL
execution, not complete HTTP latency, and does not reset statistics.

### Pool diagnostics

`BENCH_DIAGNOSTICS=1` instruments the existing worker pool. It preserves pool
callbacks, promises, release and transaction ownership and does not make another
pool. Every 10 seconds each worker emits `pool_diagnostics` containing current
and observed peak `totalCount`/`idleCount`/`waitingCount`, acquisition outcomes
and fixed histograms, new/reused client counts, connection create/remove counts,
and removed-client lifetime.

Acquisition duration includes queueing, physical creation and scheduling; it is
not pure queue wait. New clients are identified from physical pool `connect`
events and client identity. Gauge maxima are observed at events and 1-second
samples, not continuous perfect peaks.

### HTTP/event-loop diagnostics

`BENCH_HTTP_DIAGNOSTICS=1` is imported only when enabled. Every 10 seconds each
worker emits `http_diagnostics` records with fixed route labels, never URLs/slugs.

- Worker records: UTC interval, PID, worker id, ELU, process CPU delta, and
  event-loop delay p50/p95/p99/max.
- Endpoint records: starts, `finish`, premature close, HTTP errors, in-flight,
  callback-to-`response.end()` (`handler_ms`) and `response.end()`-to-finish
  (`flush_ms`) histograms.
- Response groups: prepared JSON bodies `<=4 KiB`, `>4–64 KiB`, `>64 KiB`, each
  with handler/flush histograms.
- Random 5% sample: JSON preparation duration; comments also reports auth,
  article lookup, comments query and mapping durations.

`handler_ms` includes asynchronous waits, not only JavaScript CPU. `flush_ms`
means Node handed data to its lower layer; it does not prove the remote client
received it. Event-loop delay has a 20-ms sampling resolution. Histograms are
fixed and non-cumulative; never subtract independent percentiles.

### Output and retention

Enabled diagnostics write JSONL to stdout and, through `ctl.sh`, to:

```text
observability/runs/<RUN_ID>/pool/worker-<worker>-<pid>.jsonl
observability/runs/<RUN_ID>/pool/http-worker-<worker>-<pid>.jsonl
```

Each stream retains a current file and one `.1` backup. Default cap is 10 MiB per
file, files are mode 0600, and pool plus HTTP output can retain 240 MiB for six
workers. Each stream has independent 64-KiB stdout/file queues, honors stdout
backpressure, and gets 1500 ms to flush on shutdown. Counters expose dropped and
failed output; SIGKILL or a sink failure can lose records. This is bounded
diagnostic logging, not durable auditing: no `fsync`, per-request records, SQL,
parameters, JWTs, credentials, or personal data.

## Performance context

Historical pre-current-SQL baseline: 10,000 VUs for 300 seconds, 2,625.9 RPS,
p95 69.2 ms, p99 117.9 ms, 0% errors. It is not comparable to a current build
unless seed, workload, route, PostgreSQL state and instrumentation mode match.

See [observability/VALIDATION.md](observability/VALIDATION.md) for actual local
diagnostic verification and ON/OFF overhead measurements. Diagnostics have
measurable overhead; enable them to explain a controlled run, then disable them
for clean benchmarks. Known candidates for future measured work include
`favorites_count`, CPU/event-loop contention, response serialization/output, and
network delivery. Change one variable at a time and preserve conformance.

Front: direct

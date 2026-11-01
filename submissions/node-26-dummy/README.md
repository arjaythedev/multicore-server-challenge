# Node.js 26 + TypeScript 7 + PostgreSQL 18

Front: direct

All 19 Conduit API operations implemented with `node:http`, parameterized SQL,
and strict TypeScript. Four application source files: all handlers and queries
in `src/handlers.ts`, shared helpers in `src/utils.ts`, routing/lifecycle in
`src/server.ts`, and worker supervision in `src/cluster.ts`.

Runtime: Node 26; compiler: TypeScript 7.0.2. Dependencies are pinned:
`pg` 8.23.1, `bcrypt` 6.0.0, and `jose` 6.2.14. No ORM or HTTP framework.

## Run

Node.js 26, npm, Python 3, and a C++ build toolchain are required.
`sudo bash install.sh` installs these prerequisites on Ubuntu/Debian.
PostgreSQL 18 and the repository's seed database must be prepared separately.

```bash
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit_lg \
JWT_SECRET=dev-secret HOST=127.0.0.1 PORT=3110 bash start.sh
```

`build.sh` checks Node 26, installs locked dependencies including development
tools, builds bcrypt from source, removes only this submission's `dist/`, then
compiles TypeScript with `noEmitOnError`. `start.sh` runs the emitted JavaScript.
`npm run typecheck` checks types without emitting files.

`DATABASE_URL` and `JWT_SECRET` are required. The start script defaults to
`HOST=0.0.0.0`, `PORT=3110`, and `NODE_ENV=production`. `GET /api/tags` is the
database-backed health endpoint. There is no separate `/health` route.

## Workers and database budget

`WORKERS` defaults to the available CPU count, capped at 90; valid values are
1–90. Each worker owns one pool with `min(10, floor(90 / WORKERS))` connections.
The application can never allocate more than 90 connections, leaving 10 of
PostgreSQL's 100 for administration and other clients. On six CPUs the maximum
is 60. Primary computes and logs the budget and never connects to PostgreSQL.
`PG_POOL_SIZE` is an internal value supplied by primary, not a tuning option.

An unexpected worker exit (even exit code 0) stops the entire cluster with exit
code 1; workers are never restarted. SIGINT/SIGTERM drain HTTP requests and close
database pools. Workers have a nine-second shutdown deadline; primary kills
remaining workers after ten seconds and exits unsuccessfully if forced cleanup
was needed. HTTP keep-alive is 75 seconds.

## API behavior

The implementation follows `SPEC.md` and the conformance suite. Authentication
uses HS256 with mandatory expiration and decimal-string subjects; credentials
and tokens are never cached. Password hashing/verification is asynchronous
bcrypt (cost 10 for new hashes), with a 72-byte UTF-8 password limit.

Article creation, tags, and links commit together. Failures roll back and release
the connection. IDs remain strings internally; numeric response fields are
checked for safe JSON integer conversion. An unrepresentable comment ID causes
an error rather than rounding; comment creation rolls back in that case.
Pagination is validated strictly, slugs are generated using the reference SQL,
and every data response reads PostgreSQL. No schema changes or result caches.

## Validation

From the repository root, with PostgreSQL administrator access configured via
the usual `PGHOST`, `PGPORT`, `PGUSER`, and optional `PGPASSWORD` variables:

```bash
PORT=3111 WORKERS=1 bash test/run.sh submissions/node-26-dummy
PORT=3111 bash test/run.sh submissions/node-26-dummy
```

The harness builds and starts the app on a temporary clone of `conduit_dev`,
runs conformance, and removes that clone. It never tests against your working
application database.

Supplemental integration tests, from this submission directory:

```bash
TEST_DATABASE_URL=postgres://postgres@127.0.0.1:5432/postgres npm test
```

The supplied URL must have permission to create/drop databases and change grants
in its own test clone. `test.mjs` creates a uniquely named clone of `conduit_dev`
and removes it in cleanup. It checks transaction rollback, bigint conversion,
pagination boundaries, a saturated connection budget, draining active requests,
pool closure, fail-fast on worker crashes and unexpected exit 0, and forced
termination of an unresponsive worker. `TEST_PORT` defaults to 33112.

Verified on Node 26.13.0 and PostgreSQL 18.6, using an isolated PostgreSQL instance
and the fingerprint-verified dev seed: conformance **197/197** with one worker
and **197/197** with the default six workers. Strict compilation and supplemental
integration checks pass. These are correctness checks, not performance scores.

## First SQL optimizations (2026-10-31)

Changes are limited to query shape and eliminating a redundant user lookup:

- Tag/favorited pages select ordered IDs with LIMIT/OFFSET from the indexed link
  table before fetching articles, authors, tags and favorite counts.
- Their capped counts read only the link table. Its foreign keys and composite
  primary key guarantee the same count without joining `articles`.
- Feed uses the reference LATERAL query: at most `limit + offset` IDs per followed
  author, then the global page, then enrichment. The sum uses bigint to avoid
  overflow at the maximum allowed offset.
- `/api/user` verifies the JWT and fetches the user in one SQL statement instead
  of two. Missing/deleted users still return 401; no verification cache is added.
- Global/author page queries retain their direct index paths: an experimental
  ID-first variant added PK lookups and increased estimated cost, so was omitted.

Read-only checks on the existing full-size `conduit_lg` used a single repeatable
read snapshot, sequential queries, and EXPLAIN **without ANALYZE**. For one fixture
per filter, viewer 100, limit 20, offset 0, planner total costs were:

| SQL | Before | After |
|---|---:|---:|
| Tag page | 817.25 | 130.80 |
| Tag capped count | 692.13 | 38.42 |
| Favorited page | 384.89 | 368.75 |
| Favorited capped count | 30.82 | 6.81 |
| Feed page | 482.53 | 477.82 |
| Global / author page | 309.01 / 332.66 | unchanged |

These are **planner cost units, not milliseconds or measured speedups**. The tag
page now uses `article_tags_tag_idx`; its count no longer probes `articles_pkey`.
This verifies removal of unnecessary work, not its share of CPU during the 10k
VU run. Feed improvement is workload-dependent: many follows or deep offsets
can still require many candidates. No indexes, schema, PostgreSQL configuration,
pool budgets, or production data were changed. No load benchmark was run.

Reproduce the read-only equivalence/plan checks from this submission directory:

```bash
npm run build
TEST_SQL_DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit_lg node test-sql.mjs
```

The check compares actual handler SQL against the previous query shapes: 30
page/count pairs covering all filters, anonymous/authenticated viewers, offsets,
missing filters and filter precedence. It also checks the maximum feed offset,
single-query current-user lookup, and unknown-user 401. It uses one connection,
a read-only transaction, and a 10-second per-statement timeout. The database must
contain the standard seed fixtures. Results and SQL parameters are not logged.

Remaining hypothesis: excess scanning/index probes contribute to PostgreSQL CPU
saturation. Their contribution and the resulting RPS/p95 change still need an
identical-workload before/after benchmark or SQL profiling under load. A larger
pool is not justified by the available measurements. Rebuild and restart the
application to use these changes; an already running server is not updated.

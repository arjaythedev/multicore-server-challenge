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

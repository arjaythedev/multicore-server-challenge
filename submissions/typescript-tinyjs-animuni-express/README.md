# TinyJS Conduit on Bun

Front: direct

TypeScript, TinyJS (`tinyjs-fullstack` **0.1.2**), Bun **1.4.4**, and PostgreSQL **18**.
`transport.ts` passes each native `Request` directly from `Bun.serve()` to TinyJS's generated
`createApplication()` handler. TinyJS discovers and dispatches the file-based `app/api/**/route.ts`
modules for all 19 Conduit endpoints. There is no proxy or second HTTP framework.

## Runtime and HTTP

`install.sh` installs the pinned Bun release on Ubuntu 24.04. `build.sh` installs lockfile-pinned
dependencies, runs focused unit checks, and builds the API with the published TinyJS CLI.
`start.sh` runs a single Bun process in the foreground. The server uses `HOST` and `PORT`, defaulting
to `0.0.0.0:80`, with HTTP/1.1 keep-alive and a **120-second idle timeout**. The challenge supplies
the port-binding capability and file-descriptor limit. `GET /api/tags` is the health endpoint.

`DATABASE_URL` and `JWT_SECRET` are required; there are no credential defaults. Startup checks the
PostgreSQL major version. SIGINT/SIGTERM stop accepting connections, drain in-flight HTTP requests,
and then close the database pool. No worker processes or `reusePort` experiments are included.

## Database and security

Bun's built-in `SQL` PostgreSQL driver uses one reusable pool with a **16-connection maximum**,
five-second connection and acquisition timeouts, and prepared statements enabled. This is an
initial baseline, not a measured optimum; the application's maximum stays below the 95-connection
budget. The transport and TinyJS server bundle share that one pool. Idle database connections are
retained for statement reuse. Acquiring a reserved connection uses an abort signal so a timed-out
wait cannot acquire and leak a connection later.

Queries start from `SPEC.md`'s reference SQL. Lists omit article bodies, sort by descending article
id, and cap counts at 1,000. Only the first nonempty tag/author/favorited filter applies. Comments
return the newest 100. SQL computes slugs using the reference expression. All user values are bound
parameters, including the values passed to `SQL.unsafe()`; concatenated fragments are fixed SQL.
No schema, indexes, database configuration, or persistent-data caches are added or changed.

Multi-statement writes use transactions on one reserved connection. Article creation commits the
article and its deduplicated tags together; tag names are inserted in sorted order to avoid opposing
lock orders. Ownership checks and writes lock the affected rows. Every response awaits commit, and
article mutation responses read the full article after commit. PostgreSQL's synchronous-commit
setting is preserved. Password hashing and verification happen outside database reservations.

JWTs use HS256 with the environment secret and exactly `sub`, `iat`, and `exp` on issuance, expiring
after 30 days. Every authenticated request checks the signature, algorithm, and expiration anew;
optional-auth endpoints reject invalid headers. Passwords use asynchronous native bcrypt with
cost 10, including replacements; passwords over 72 UTF-8 bytes are rejected. No authentication
results or query results are cached across requests.

## Remote validation only

The development laptop is an editor and Git client only. **Do not install, build, start, seed,
type-check, test, or benchmark this submission on the laptop.**

The existing challenge GitHub Actions workflow can run the following on its remote Ubuntu runner
with PostgreSQL 18 and a fresh 2% seed:

```bash
sudo bash submissions/typescript-tinyjs-animuni-express/install.sh
bash test/run.sh submissions/typescript-tinyjs-animuni-express
```

This invokes the unit checks and TinyJS build before the official 197-step conformance suite.
In GitHub Actions, the build also runs `integration.test.ts` against the harness's disposable
database, checking concurrent idempotent favorites/follows, concurrent comments and article/tag
creation, the shared connection limit, graceful shutdown, and persistence across a server restart.
It removes its own fixture rows before the official suite starts.

On **15 November 2026**, the [initial remote CI run](https://github.com/arjaythedev/multicore-server-challenge/actions/runs/43724105336)
for commit `5dd67e8` passed **197/197 official checks**, **5/5 focused unit tests**, dependency
installation, and the TinyJS production build on Ubuntu 24.04 with PostgreSQL 18.7 and Bun 1.4.4.
The [PR checks](https://github.com/arjaythedev/multicore-server-challenge/pull/234/checks) show results
for subsequent commits, including the added integration check. No local executable validation
has been performed for this submission.

## Performance and limitations

No capacity, latency, throughput, memory, or CPU measurements are claimed for this submission.
Pool-size tuning, eight-core utilization profiling, sustained high-concurrency stress,
and full-seed five-minute holds require suitable authorized remote infrastructure and are pending.
No paid infrastructure is provisioned. The challenge is closed to automatic benchmarking, so a PR
does not promise an official run or leaderboard inclusion.

The earlier [TinyJS transport PR #410](https://github.com/arjaythedev/twelve-dollar-server-challenge/pull/410)
informed the direct-handler integration. Its SQLite workload and historical results do not establish
performance or correctness for this PostgreSQL Conduit implementation.

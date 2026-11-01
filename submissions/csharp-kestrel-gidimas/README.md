# csharp-kestrel-gidimas

Front: direct

A conventional ASP.NET Core service: minimal APIs, Dapper over Npgsql with SQL in one place, request and response
records, and framework features for auth and rate limiting. The goal is to stay as close to production-ready .NET code
as possible, not to build a benchmark special: no hand-written HTTP server or Postgres client, no cross-request
batching, no unsafe code. Everything used is a stock, documented library or framework feature, and every tuning knob is
a normal setting with a default that was measured.

## Stack

| Part | Version |
|---|---|
| Runtime | .NET 10 (SDK 10.0.300, pinned in `global.json` with `rollForward: disable`), JIT, server GC (Web SDK default) |
| Web | ASP.NET Core minimal APIs on Kestrel, HTTP/1.1 |
| Data access | Dapper 2.1.66 on Npgsql 10.0.3, one pooled `NpgsqlDataSource` |
| JSON | `System.Text.Json`, source-generated (`AppJsonContext`) |
| Passwords | BCrypt.Net-Next 4.0.3, cost 10 |

Restore uses `packages.lock.json` (`--locked-mode`), so the package set is fixed.

## Layout

- `src/Program.cs`: services, middleware and endpoint registration.
- `src/Data/`:
  - `Sql.cs`: every statement, based on SPEC.md's reference SQL.
  - `Rows.cs`: the row classes Dapper maps results to (snake_case columns to properties).
  - The `DATABASE_URL` parser and the unique-violation check.
- `src/Endpoints/`:
  - One file per area: users, profiles, articles, comments, tags.
  - Helpers for errors and paging.
- `src/Auth/`:
  - The `Token` authentication handler and the token service.
  - The bcrypt wrapper.
- `src/Json/`: request and response records, the timestamp converter and the serializer context.
- `src/appsettings.json`: logging at warning level.

## Build and run

- `install.sh`: installs the pinned SDK (root, once).
- `build.sh`: `dotnet restore --locked-mode` and `dotnet publish` to `publish/`.
- `start.sh`: runs `Conduit.dll` from `publish/` (the content root, where `appsettings.json` is read) in the foreground.

## Design notes

- **No caching.** Every request reads its data from Postgres. Tokens and bcrypt results are never remembered.
- **Auth.** A standard ASP.NET Core authentication handler for RealWorld's `Authorization: Token <jwt>` scheme.
  - Required endpoints use `RequireAuthorization()`.
  - Optional endpoints use a filter that turns a present-but-invalid token into 401. ASP.NET Core caches the
    authentication result per request, so the token is verified once.
  - Token signing and verification are hand-written HS256. `Microsoft.IdentityModel` refuses HMAC keys under 256 bits, and the challenge secret is 208 bits.
  - Every request checks the signature, `alg` and `exp`.
- **Queries.** SPEC.md's reference SQL, with three changes that return the same rows:
  - Lists pick their page of articles first and compute tags, counts and flags only for those rows. Computing them
    in the outer query also ran them for every row skipped by `OFFSET` (offset 400: 20 ms instead of 1.6 ms).
  - Tag names are looked up by primary key per tag rather than by joining `tags`, which made Postgres hash the whole
    tags table for each article (about 3x slower per page).
  - A list's page and its capped count are sent together and come back in one round trip (`QueryMultiple`).
- **Npgsql multiplexing.** Commands from concurrent requests share the pooled connections and are written to Postgres
  together, instead of each request holding a connection for its whole round trip. It is a documented Npgsql
  connection-string option, and the code does not change for it. The one place that holds a connection to itself is the
  article-create transaction, which is under 1% of requests. Measured: about 50% more throughput at the same
  latency (see Results).
- **Prepared statements.** Npgsql's automatic preparation (`MaxAutoPrepare`) prepares statements a connection runs
  repeatedly, so Postgres parses and plans them once; it also avoids `DISCARD ALL` on every pool return.
- **Writes are committed before the response.**
  - Article creation runs in one transaction, computing the slug in SQL as SPEC.md does.
  - Follows and favorites use `INSERT ... ON CONFLICT DO NOTHING`, so repeats and concurrent requests succeed.
- **Errors.**
  - Malformed or missing JSON bodies surface as `BadHttpRequestException` and are answered with 422.
  - Every error uses the RealWorld `{"errors": {"body": [...]}}` shape.
- **Overload.** Register and login run bcrypt, so they sit behind ASP.NET Core's concurrency rate limiter. Past its
  queue they get `503` with `Retry-After`.
- **Postgres session setting.** `jit=off` on the connection, which is common OLTP tuning. No server-wide changes.

## Results (not the official box)

These were measured on an 8 vCPU VPS running Postgres 18 with the full seed. The repo's `loadgen` ran on a separate
box with `-think-scale 0.1` (each virtual user is about 10 times as busy as the default). Each step had a 20 s ramp
and 40 s of measurement; they are not 5-minute holds.

| Build | Users | req/s | p95 | p99 | Errors | Verdict |
|---|--:|--:|--:|--:|--:|---|
| One connection per request (`DB_MULTIPLEXING=false`) | 6,000 | 8,852 | 323 ms | 344 ms | 0.01% | PASS |
| One connection per request | 8,000 | 9,077 | 532 ms | 546 ms | 0.13% | FAIL (p95) |
| Multiplexing (default) | 8,000 | 13,768 | 377 ms | 572 ms | 0.05% | PASS |
| Multiplexing | 10,000 | 14,057 | 568 ms | 934 ms | 0.11% | FAIL (p95) |

- At 8,000 users with multiplexing, the box is about 90% busy: Postgres takes about 44% and the app about 42%.
- 13.8k req/s is roughly what 55k users generate at the default think time (about 0.25 req/s each). That is inferred,
  not measured.
- Login is where the load shows first. At 8,000 users bcrypt competes with everything else for the CPU, about 30% of
  logins get `503` from the limiter, and the rest wait about 4.5 s. Logins are a small share of requests, so the total
  error rate stays at 0.05%.
- Conformance (`test/run.sh`): 197/197 with multiplexing on and off.

## Configuration (environment)

- `DATABASE_URL`, `JWT_SECRET`, `HOST`, `PORT`: the runtime contract from SPEC.md.
- `DB_POOL_SIZE`: Npgsql max pool size (default 32; measured better than 20 or 80 on 8 cores shared with Postgres).
- `DB_MULTIPLEXING`: Npgsql multiplexing (default `true`; `false` gives one connection per request).
- `PASSWORD_HASH_CONCURRENCY`: concurrent register/login requests (default: three quarters of the CPU count).
- `PASSWORD_HASH_QUEUE`: register/login requests allowed to wait before `503` (default 64).

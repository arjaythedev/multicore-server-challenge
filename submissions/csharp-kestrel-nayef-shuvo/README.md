# C#: Kestrel + Npgsql (Native AOT)

**Front: nginx**

A plain, unoptimized baseline: a hand-written router on Kestrel's request delegate (no MVC, no minimal-API routing),
Npgsql with the reference SQL from `SPEC.md` verbatim, no caching. Optimizations come later.

| Piece | Version |
|---|---|
| .NET | 10, compiled with Native AOT to one native executable (`install.sh` installs SDK 10.0.402, clang and zlib1g-dev) |
| HTTP | ASP.NET Core Kestrel, one `app.Run` request delegate, manual routing |
| JSON | `System.Text.Json` (`Utf8JsonWriter` out, `JsonDocument` in) |
| Postgres | `Npgsql` 10.0.3, one `NpgsqlDataSource`, `MaxPoolSize = DB_POOL_SIZE` |
| JWT | `Microsoft.IdentityModel.JsonWebTokens` 8.23.0 (HS256 only, `exp` required) |
| bcrypt | our own EksBlowfish (`BcryptCore.cs`), cost 10, several hashes at once per thread, run on dedicated worker threads (`BcryptPool.cs`) |

Environment: `DATABASE_URL`, `JWT_SECRET` (required), `DB_POOL_SIZE` (10 per core, max 90),
`HOST` (127.0.0.1), `PORT` (3000).

## bcrypt

A login costs one bcrypt hash at cost 10, and that is the largest CPU cost of any request (about 50 to 65 ms with a standard
library). Blowfish is a long chain of dependent steps, so one hash leaves most of a core's execution units idle. `BcryptCore.cs`
is our own implementation of bcrypt's EksBlowfish that runs 1 to 4 independent hashes in lockstep, round by round, so the
processor overlaps them (`BcryptLanes.g.cs` is written by `Tools/gen_bcrypt.py`; the Blowfish constants in
`BlowfishConstants.g.cs` are the digits of pi, computed by the same script). Measured per hash on the dev box (BenchmarkDotNet,
cost 10): BCrypt.Net-Next 65 ms, libcrypt 50 ms, ours 63 ms alone, 35 ms with 2 at once, 27 ms with 3, **23 ms with 4**.

`BcryptPool.cs` runs the hashes on dedicated threads (not the thread pool, which a burst of logins would starve) and gathers
hashes that are waiting at the same time into one run. The first waiting hash waits up to `BCRYPT_BATCH_MS` (default 100) for
others, so a login takes about 100 ms longer; the pool never uses more than `BCRYPT_THREADS` threads (default half the cores).
Measured with logins arriving at random (open loop, Native AOT) against one hash per request thread with libcrypt:

| logins per second (about users) | CPU, before | CPU, now | login p50 / p99, before | login p50 / p99, now |
|---|---|---|---|---|
| 5.6 (20,000) | 0.30 cores | 0.27 cores | 55 / 60 ms | 168 / 190 ms |
| 14 (50,000) | 0.80 cores | 0.47 cores | 55 / 64 ms | 167 / 199 ms |
| 28 (100,000) | 1.55 cores | 0.80 cores | 56 / 74 ms | 139 / 214 ms |

Nothing is cached: every login still runs a full bcrypt hash. The hashes are the standard `$2a$10$...` format, the same as any
other bcrypt library makes and verifies. Checked against libcrypt, BCrypt.Net-Next and Go's bcrypt
(`bash Benchmarks/run.sh --check`), and the server runs known answers through every lane count at start-up and refuses to
start if one is wrong.

- A password over bcrypt's 72 bytes, or with a NUL character, is refused (422 on register and on a password change; a login with one is a 401).
- A stored hash that is not `$2a$`, `$2b$` or `$2y$` at cost 10 never verifies (and never costs CPU).

## Build and run

`build.sh` publishes with Native AOT (about 40 s) into `bin/conduit`; `start.sh` runs it. Where clang is missing it falls back to gcc.

```bash
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=conduit-dev-secret PORT=3000 bash start.sh
```

# C#: Kestrel + Npgsql (Native AOT)

**Front: nginx**

A hand-written router on Kestrel's request delegate (no MVC, no minimal-API routing), Npgsql with the reference SQL from
`SPEC.md` verbatim, and our own bcrypt that hashes several passwords at once. Compiled with Native AOT to one native
executable. It passes `bench/cmd/conformance` (197/197), also on Ubuntu 24.04 with the SDK that `install.sh` installs.

| Piece | Version |
|---|---|
| .NET | SDK 10.0.402 (official tarball, sha512-checked), Native AOT; `install.sh` also installs clang and zlib1g-dev, which the AOT linker needs |
| HTTP | ASP.NET Core 10 Kestrel, HTTP/1.1 only, one `app.Run` request delegate, manual routing |
| JSON | `System.Text.Json`: `Utf8JsonWriter` out, `JsonDocument` in (no reflection serializer) |
| Postgres | `Npgsql` 10.0.3, one `NpgsqlDataSource`, `MaxPoolSize = DB_POOL_SIZE` |
| JWT | `Microsoft.IdentityModel.JsonWebTokens` 8.23.0 (HS256 only, `exp` required, checked on every request) |
| bcrypt | our own EksBlowfish (`BcryptCore.cs`), cost 10, run on worker threads (`BcryptPool.cs`) |

NuGet packages are pinned by `packages.lock.json`, restored with `--locked-mode` under the pinned SDK.

## Setup and run

On a clean Ubuntu 24.04, from this folder:

```bash
sudo bash install.sh     # once, as root: .NET SDK 10.0.402, clang, zlib1g-dev
bash build.sh            # as a normal user: Native AOT build into bin/conduit, about 40 seconds
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=multicore-server-challenge bash start.sh
```

`start.sh` runs the server in the foreground and `GET /api/tags` answers within about a second. To test it, from the
repo root (needs Go, Postgres and psql, see the main README):

```bash
bash seed/make-seed.sh --dev
bash test/run.sh submissions/csharp-kestrel-nayef-shuvo
```

| Environment variable | Default | |
|---|---|---|
| `DATABASE_URL` | required | `postgres://user:password@host:port/database` |
| `JWT_SECRET` | required | any length (a key under 32 bytes is zero-padded, which HMAC treats as the same key) |
| `HOST`, `PORT` | `127.0.0.1`, `3000` | what the Nginx config expects |
| `DB_POOL_SIZE` | 10 per core, at most 90 | Postgres allows 100 connections and the rules say 95 |
| `DB_MAX_AUTO_PREPARE` | 64 | statements Npgsql keeps prepared per connection; 0 turns it off |
| `DB_AUTO_PREPARE_MIN_USAGES` | 5 | runs of a statement on a connection before it is prepared there |
| `BCRYPT_THREADS` | half the cores, at least 1 | worker threads for bcrypt |
| `BCRYPT_BATCH_MS` | 100 | how long the first waiting hash waits for others to share its run |

Idle keep-alive connections stay open for Kestrel's default 130 s, longer than the 65 s that Nginx needs.
`build.sh` checks the lock file strictly only with SDK 10.0.402; any other SDK (for example a distro's source-built one,
which has other hashes for the AOT packages) restores into a throwaway lock file under `obj/` instead of failing.

A Debug build (`dotnet run` in this folder) adds Swagger UI at `/swagger`, one log line per request with its error message,
and `LOG_SQL=1` for every SQL statement. All of it is compiled out of Release builds.

## Optimizations, and why

- **Native AOT** with `OptimizationPreference=Speed` and `IlcInstructionSet=native`. The server is built on the box that runs it
  (rule 11), so the compiler may use that CPU's whole instruction set. No JIT warm-up, no tiering, and about 40 to 100 MB of
  memory under load, which leaves the cores and RAM to Postgres.
- **Runtime settings** in `Conduit.csproj`: server GC without the background GC thread; thread-pool workers that sleep
  instead of spinning (`UnfairSemaphoreSpinLimit=0`: the spinning burns CPU that Postgres needs); Npgsql's SQL rewriting off
  (every statement uses positional `$n` parameters); invariant globalization; no event sources, metrics or debugger support.
- **No framework between Kestrel and the handlers.** One request delegate splits the path once and dispatches on the number of
  segments and the HTTP method. HTTP/1.1 only, no `Server` header.
- **JSON without reflection.** Responses are written with `Utf8JsonWriter` into one reused buffer per thread (so there is a
  `Content-Length`) and copied into Kestrel's output pipe. Request bodies are parsed with `JsonDocument`, which the handler owns
  and disposes instead of cloning the element, and keys are looked up as UTF-8 literals. The query string is read in one pass.
- **The reference SQL, unchanged, with automatic prepared statements.** The server sends 34 distinct statements. Once a statement has
  run 5 times on a connection, Npgsql prepares it there (`DB_MAX_AUTO_PREPARE`, default 64, keeps all of them), so Postgres plans
  each statement once per connection instead of on every call. It is a plan cache, never data. The saving is the planning time of the
  queries with subqueries: one connection, per query, 28 to 42% lower latency on the lists by tag, author or favorited, the feed and
  the article read. Interleaved load runs against the same build with it off (64 connections, 3 rounds each, laptop):

  | | requests per second | p99 | Postgres CPU per request |
  |---|---|---|---|
  | list-heavy mix, off | 1,704 to 1,782 | 88 to 96 ms | 4.2 ms |
  | list-heavy mix, on | 2,125 to 2,224 (+24%) | 68 to 75 ms | 3.1 ms |
  | feed, off | 2,112 to 2,303 | 63 to 76 ms | 3.2 ms |
  | feed, on | 3,900 to 4,221 (+79%) | 30 to 32 ms | 1.5 ms |
- **bcrypt (the largest CPU cost of any request).** One login is one hash at cost 10, about 50 to 65 ms with a standard library.
  Blowfish is a long chain of dependent steps, so one hash leaves most of a core's execution units idle. `BcryptCore.cs` runs 1 to
  4 independent hashes in lockstep, round by round, so the processor overlaps them (`BcryptLanes.g.cs` is written by
  `Tools/gen_bcrypt.py`; the constants in `BlowfishConstants.g.cs` are the digits of pi, computed by the same script). Per hash on
  the dev box (cost 10): BCrypt.Net-Next 65 ms, libcrypt 50 ms, ours 63 ms alone, 35 ms with 2 at once, 27 ms with 3, **23 ms with 4**.
  `BcryptPool.cs` runs them on dedicated threads (a burst of logins must not starve the thread pool) and gathers hashes that wait at
  the same time. The price is about 100 ms more per login. Logins arriving at random, Native AOT, against one libcrypt hash per request thread:

  | logins per second (about users) | CPU before | CPU now | login p50 / p99 before | login p50 / p99 now |
  |---|---|---|---|---|
  | 5.6 (20,000) | 0.30 cores | 0.27 cores | 55 / 60 ms | 168 / 190 ms |
  | 14 (50,000) | 0.80 cores | 0.47 cores | 55 / 64 ms | 167 / 199 ms |
  | 28 (100,000) | 1.55 cores | 0.80 cores | 56 / 74 ms | 139 / 214 ms |

  Running several hashes per thread with a short batching window is also described in `csharp-kestrel-xeonfx`'s README; the code
  here was written from the bcrypt algorithm. The hashes are the standard `$2a$10$...` format, and `bash Benchmarks/run.sh --check`
  verifies ours against libcrypt, BCrypt.Net-Next and itself in every grouping. The server also runs known answers through every lane
  count at start-up and refuses to start if one is wrong.

On a laptop (4 cores, 8 threads, Postgres in Docker on the same machine) the server handles about 2,100 to 2,600 requests per
second of the list-heavy mix at 16 to 256 connections, p99 80 to 180 ms, using about 1.2 cores and under 100 MB, while Postgres
uses about 6 cores. Postgres, running the reference SQL, is the bottleneck there, not this code.

## The rules, for reviewers

- **No caching of data.** Every response reads Postgres while it is being served. The one static table is the serialized bodies
  of our fixed error messages (`{"errors":{"body":["unauthorized"]}}` and the like), which contain no data. The per-thread JSON
  buffers and pooled connections and prepared statements (query plans) hold no data either. No JWT verification and no bcrypt result is remembered.
- **Security stays real.** Every password is hashed with bcrypt cost 10 and every login runs a full hash against the stored one;
  every token's HS256 signature and `exp` are checked on every request, and any other `alg` is refused. A password over bcrypt's
  72 bytes or with a NUL character is refused (422 on register and on a password change; a login with one is a 401). A stored
  hash that is not `$2a$`, `$2b$` or `$2y$` at cost 10 never verifies.
- **Writes are committed before the response**, with the default `synchronous_commit` and no unlogged tables.

## Layout

| | |
|---|---|
| `Program.cs` | configuration, start-up checks, Kestrel |
| `Api.cs`, `Api.Users.cs`, `Api.Articles.cs`, `Api.Comments.cs` | the router, auth wrappers and the 19 endpoints |
| `Http.cs`, `Auth.cs`, `Db.cs`, `Sql.cs` | JSON in and out, JWT, the Npgsql pool, the reference SQL |
| `Bcrypt.cs`, `BcryptCore.cs`, `BcryptPool.cs`, `*.g.cs`, `Tools/gen_bcrypt.py` | bcrypt, as described above |
| `OpenApi.cs` | Swagger for Debug builds only |
| `Benchmarks/` | BenchmarkDotNet micro-benchmarks and the bcrypt cross-check; a separate project that `build.sh` never builds |

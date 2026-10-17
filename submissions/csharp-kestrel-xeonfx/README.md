# C#: Kestrel + Npgsql

**Front: direct.** Kestrel listens on `HOST:PORT` itself. Behind nginx it works unchanged on 127.0.0.1:3000,
but a proxy hop costs CPU on the same cores, and Kestrel already holds tens of thousands of keep-alive
connections.

Implements [`SPEC.md`](../../SPEC.md). Passes `test/run.sh`: 197/197 on the dev seed and on the full seed.

| Piece | Version |
|---|---|
| .NET | SDK 10.0.402, runtime 10.0.13 (pinned in `global.json` and `install.sh`, sha512 checked) |
| HTTP | ASP.NET Core Kestrel (shared framework), `CreateEmptyBuilder` + `UseKestrelCore`, own router |
| JSON | `System.Text.Json`: `JsonDocument` to read, `Utf8JsonWriter` to write |
| Postgres | Npgsql 10.0.3 (the only package; `packages.lock.json`, restored with `--locked-mode`) |
| JWT | own HS256 (`HMACSHA256`, `Base64Url`) |
| bcrypt | own, cost 10, `$2a$` (verifies `$2a$`, `$2b$`, `$2y$`) |

## Run

```bash
sudo bash install.sh     # .NET SDK into /usr/local/dotnet
bash build.sh            # -> bin/conduit.dll
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=dev-secret PORT=3000 bash start.sh
```

Environment: `DATABASE_URL`, `JWT_SECRET` (required), `HOST` (127.0.0.1), `PORT` (3000), `DB_POOL_SIZE`
(4 per core), `DB_MULTIPLEXING` (1), `BCRYPT_THREADS` (one per two cores, at least 1),
`DOTNET_GCgen0size` (64 MB, set in `start.sh`).

## Results

The most users each server held while staying under the bar (p95 < 500 ms, p99 < 1 s, errors < 1%), stepping
the user count up on the full seed. The server and Postgres ran together on N CPUs and the load generator on
the others. Go and Rust are [`examples/go`](../../examples/go) and [`examples/rust`](../../examples/rust)
unchanged, on the same Postgres 18 with the same config.

| CPUs | C# | Go | Rust | C# req/s at its limit |
|---|---|---|---|---|
| 1 (x86-64 VPS) | **1,250** | 700 | 500 | 2,160 |
| 2 (arm64) | **5,500** | 2,500 | 2,500 | 11,150 |
| 4 (arm64) | **13,000** | 5,000 | 5,000 | 20,730 |
| 6 (arm64) | **12,000** | 6,000 | 6,000 | 22,460 |

Users think for a tenth of the workload's 7 s (`-think-scale 0.1`), so these counts are not the scoring box's;
they rank the servers under the same load. Every login and sign-up succeeded in every C# run up to its limit.
The 1-CPU box is a 2-vCPU OVH VPS; 2 to 6 CPUs are a Mac mini M1 in a Linux VM. 8 CPUs needs a separate
load generator machine, which I didn't have. On the mini, CPUs 5 and 6 are efficiency cores and the load
generator had two cores left, so the 6-CPU row understates every server.

Where it comes from, at 3,500 users on 4 CPUs (CPU time per request):

| | Server | Postgres | Total |
|---|---|---|---|
| C# | 0.15 ms | 0.14 ms | 0.29 ms |
| Go | 0.17 ms | 0.26 ms | 0.43 ms |
| Rust | 0.18 ms | 0.29 ms | 0.47 ms |

Postgres is the larger half of every request, so most of the work went into the SQL and the connections, then
into bcrypt, the most expensive single request by far.

### SQL

Every response is byte-identical to the reference (the conformance transcript); the statements are different:

- **One statement per request.** Follow, unfollow, favorite, unfavorite, update and delete check, write and
  read back in one statement with CTEs. Article lists send the page and its count as one `NpgsqlBatch`
  (one round trip, one implicit transaction). Create sends insert, tags, links and read-back as one batch.
- **Page first, then decorate.** Lists pick the page's ids with an index-only scan, then join and compute
  tags, favorite counts and flags for those rows only, not for the `OFFSET` rows before them.
- **The feed** takes the newest `limit + offset` articles per followee (a `LATERAL` index scan each) instead
  of joining every article of every followee.
- **Tag names by primary key** instead of a hash join over all tags for each article.
- **An anonymous viewer** (`$1 = 0`) skips the favorited and following probes.
- **Generic plans.** `plan_cache_mode=force_generic_plan` and `jit=off` per session. With `LIMIT $2 OFFSET $3`
  as parameters Postgres keeps re-planning every execution; these statements are written so the generic plan
  is the right one, so each connection plans each statement once (Npgsql auto-prepares after 2 uses).

### Connections

- **Multiplexing.** Npgsql pipelines commands from concurrent requests onto few connections, so Postgres runs
  a few busy backends instead of many mostly idle ones. On 1 CPU at 800 users: 17% more requests per second
  and 15% less CPU per request than one connection per request (median of 3 rounds each).
- **No reset on close, no enlistment, no TLS** on the loopback connection.

### bcrypt

A login or sign-up is about one request in a thousand, but a cost 10 hash is tens of milliseconds of CPU, as
much as a hundred or more other requests.

- **Dedicated threads.** Hashes run on their own threads, never on the thread pool, so a burst of logins
  queues behind them while every other request keeps its latency.
- **Up to four hashes interleaved.** Blowfish is a chain of dependent table lookups: each round waits for the
  load before it. A worker that finds more jobs waiting runs up to four hashes in one loop, so the CPU overlaps
  their chains. Per hash on the x86-64 VPS:

  | | ms per hash |
  |---|---|
  | BCrypt.Net-Next | 91.9 |
  | ours, one at a time | 76.0 |
  | ours, 2 interleaved | 43.1 |
  | ours, 3 interleaved | 31.6 |
  | ours, 4 interleaved | 31.0 |

  On arm64 four interleaved are 23.6 ms against 74.2 ms one at a time. Go's `x/crypto/bcrypt` is about 75 ms.
- **One thread per two cores.** Fewer threads mean jobs queue and get interleaved; but when every core is
  busy each thread only gets its share of the CPU, while logins grow with the cores. On 4 CPUs one thread let
  two thirds of the logins fail at 11,000 users; two kept every login working up to the limit. On 6 CPUs two
  threads lost 46% of the logins just past the limit, three kept them all.
- **Unknown emails cost the same** as a wrong password: the login checks against a hash of a random password,
  so response times don't tell which emails have accounts.

The implementation follows OpenBSD's and Go's. The tests check it against BCrypt.Net-Next with the same salt
for random passwords (property tests, every lane count), and against hashes made by Go. Passwords over
72 bytes are refused (422) instead of silently truncated; a malformed stored hash fails to verify instead of
throwing.

### Runtime

- **No spinning thread pool.** `System.Threading.ThreadPool.UnfairSemaphoreSpinLimit=0`: an idle pool thread
  sleeps at once instead of spinning for work, which burned CPU that Postgres, on the same cores, needed. The
  server's CPU per request fell from 0.258 ms to 0.194 ms at the same load (4 CPUs, median of 3 rounds).
- Server GC, non-concurrent; dynamic PGO; invariant globalization; no EventSource.
- `DOTNET_GCgen0size=64MB`: a request allocates a few KB, and with the default gen0 budget server GC ran
  several gen0 collections a second.
- No middleware, no routing tables, no DI: `app.Run(Router.Handle)` and a `switch` on the path segments.
- Responses are written by `Utf8JsonWriter` into a pooled buffer and sent with one `Content-Length` write.
- JWT verification allocates nothing: it checks the token's alphabet, decodes into stack buffers, signs with a
  keyed HMAC kept per thread, compares in constant time, and accepts only HS256 tokens with a numeric `sub`
  and an unexpired `exp`.

## Micro-benchmarks

BenchmarkDotNet 0.15.8 (`Benchmarks/`), arm64 Linux:

| Benchmark | Time | Allocated |
|---|---|---|
| JWT verify | 1.29 µs | 0 B |
| JWT issue | 1.14 µs | 944 B |
| Query `?limit=20&offset=40` | 111 ns | 168 B |
| Query escaped filter | 75 ns | 80 B |
| Article JSON | 482 ns | 0 B |
| Timestamp | 61 ns | 0 B |

## Tests

```bash
dotnet test --project Tests/Tests.csproj          # bcrypt, JWT, password queue, query parsing (xUnit v3 + FsCheck)
dotnet run -c Release --project Benchmarks -- --filter '*'
bash ../../test/run.sh submissions/csharp-kestrel-xeonfx
```

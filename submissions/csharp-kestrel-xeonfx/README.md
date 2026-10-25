# C#: Kestrel + Npgsql

**Front: direct.** Kestrel serves `HOST:PORT` itself. It also works behind nginx on 127.0.0.1:3000, but the
extra hop costs CPU on the same cores.

Implements [`SPEC.md`](../../SPEC.md) and passes all 197 checks of `test/run.sh` on the dev and full seeds.

Built on .NET 10 (SDK 10.0.402, pinned and checksummed), ASP.NET Core Kestrel with its own router,
`System.Text.Json` and Npgsql 10.0.3. JWT (HS256) is written here, and bcrypt (cost 10) is my CodeFusion.Security.Bcrypt
1.1.0, copied into `Security/Bcrypt/` from codefusion-dotnet and cut to what the server uses.

## Run

```bash
sudo bash install.sh     # .NET SDK into /usr/local/dotnet
bash build.sh            # -> bin/conduit.dll
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=dev-secret PORT=3000 bash start.sh
```

| Variable | Default | |
|---|---|---|
| `DATABASE_URL`, `JWT_SECRET` | required | |
| `HOST`, `PORT` | 127.0.0.1, 3000 | |
| `DB_POOL_SIZE` | 2 per core | read loops, one connection each |
| `DB_WRITERS` | 2 | writer loops, one connection each |
| `BCRYPT_THREADS` | 1 per 2 cores | |
| `BCRYPT_BATCH_MS` | 200 | how long a hash waits for others to share its run |
| `STATS_SECONDS` | 10 | seconds between stats lines, 0 for none |

## Code

| Folder | |
|---|---|
| `Program.cs`, `Router.cs` | settings, Kestrel, routing |
| `Http/` | request bodies, query strings, JSON responses |
| `Endpoints/` | users, profiles, articles, comments, tags |
| `Data/` | the SQL, the read groups and the group commit |
| `Security/` | JWT, the `Authorization` header, passwords; `Security/Bcrypt/` is the bcrypt library |
| `Tests/`, `Benchmarks/` | xUnit tests and BenchmarkDotNet |

## Results

An 8-vCPU Google Cloud `c4-highcpu-8` (Xeon Platinum 8581C, 16 GB) running the server and Postgres 18, set up
with `box/setup-box.sh`. The load came from two more `c4-highcpu-8` machines, on the full seed with the real 7 s
think time. Every run started from a fresh database, warmed up for 3 minutes, ramped for 60 s and was measured
for 60 s.

| Users | p95 / p99 | Requests/s | CPU | Memory |
|---|---|---|---|---|
| 100,000 | 9 / 60 ms | 26,500 | 89% | 4.2 GB |
| 110,000 | 33 / 94 ms | 29,100 | 92% | 4.4 GB |
| 120,000 | 150 / 242 ms | 31,500 | 97% | 4.6 GB |
| **125,000** | 192 / 231 ms | 32,400 | 98% | 4.8 GB |

125,000 is the most two load machines can drive: each opens about 64k connections to the server. No run had
errors. At 125,000 Postgres used 70 of the 98% CPU and the server 28, so the limit is CPU, not memory. The
version before the bcrypt change below (205e743) passed the same steps and used the same CPU per request. These runs
used the bcrypt then written in this folder; the library that replaced it hasn't run on the rig yet.

Earlier, with one load machine and a server with two addresses, 100,000 was the most that rig could drive:

| Version | Most users passed | p95 / p99 | CPU | Memory |
|---|---|---|---|---|
| 205e743 | **100,000** | 273 / 313 ms | 98% | 4.1 GB |
| First version of this PR (b2a554c) | 80,000 | 59 / 149 ms | 96% | 4.2 GB |
| Go example | 30,000 (not tried higher) | 8 / 15 ms | 84% | 2.7 GB |

The first version failed at 100,000 users (p95 1,198 ms). The same commit passes more users on the newer rig,
so compare rows only within a table. The Rust example didn't build on this machine, so it's only in the older table below.

Earlier runs on smaller machines, with users thinking a tenth as long. These rank the servers but don't predict
the scoring box:

| CPUs | C# | Go | Rust |
|---|---|---|---|
| 1 (x86 VPS) | **1,250** | 700 | 500 |
| 2 (arm64) | **5,500** | 2,500 | 2,500 |
| 4 (arm64) | **13,000** | 5,000 | 5,000 |
| 6 (arm64) | **12,000** | 6,000 | 6,000 |

Measured at 3,500 users on 4 CPUs, a C# request cost 0.29 ms of CPU: 0.15 in the server and 0.14 in Postgres. Go
used 0.43 ms and Rust 0.47 ms, most of it in Postgres. So most of the work went into the SQL and the
connections.

## How it's fast

### SQL

- One statement per request. Toggles, updates and deletes check, write and read back in one statement. A list
  sends its page and its count together.
- Lists pick the page's ids first with an index-only scan, then fill in authors, tags and counts for those rows
  only.
- The feed takes the newest `limit + offset` articles per followed author instead of all of them.
- Postgres returns tag lists as JSON, which go into the response as they are.
- Plans are generic and made once per connection (`plan_cache_mode=force_generic_plan`, no JIT, no parallel
  workers). The statements are written so the generic plan is the right one.
- Favorite counts stay right when two people toggle the same article at once. The tests replay those races.

### Reads and writes

- **Reads in groups.** Reads wait in a queue. Each read loop sends up to 32 of them as one batch with a single
  Sync, so Postgres opens and closes one transaction for the group instead of one per read. Each statement still
  sees fresh data. A read that fails fails alone, and the ones after it run again. On the earlier rig this took
  100,000 users from failing (p95 763 ms with Npgsql's multiplexing) to passing (273 ms).
- **Writes in groups.** Two writer loops commit up to 128 writes in one transaction, so one disk flush covers all
  of them. A response goes out only after its commit. If one write fails, the others still commit and only that
  one gets the error.
- **Limits instead of pile-ups.** At most 65,536 reads, 4,096 writes and 256 logins per bcrypt thread can wait.
  Past that, and when a row lock is held for over 2 s, the request gets a 503 with `Retry-After` at once.
- Requests whose client has gone are dropped before they reach the database.

### bcrypt

A login is about one request in a thousand, but one hash costs as much CPU as a hundred other requests.

- Hashes run on the library's own threads, so a burst of logins doesn't slow anything else.
- A thread that finds several hashes waiting runs up to five at once, interleaved. On the 8581C that takes 12 ms
  per hash instead of 47 ms (BCrypt.Net-Next takes 60 ms), by the library's measurements.
- Each round XORs its round key into one half before the S-box result arrives, not after. That keeps a step off
  the chain every round waits on: 7% less per hash.
- The first hash waits up to 200 ms for others to join it. At the real login rate, almost every hash would
  otherwise run alone.
- A login for an unknown email still checks a hash, so response times don't reveal which emails exist.
- Passwords over 72 bytes are refused instead of silently cut.

### Runtime

- Idle thread-pool threads sleep instead of spinning. Spinning took CPU that Postgres needed, and turning it off
  cut the server's CPU per request by a quarter.
- Server GC with a 64 MB gen0 budget, dynamic PGO, invariant globalization.
- No middleware or DI: one `switch` routes every request.
- Responses are written into pooled buffers. Text columns go from Postgres into the JSON as UTF-8 bytes without
  becoming strings, which halved the GC collections.
- Checking a JWT allocates nothing.
- A stats line every 10 s shows queue lengths, group sizes, commit times, bcrypt batches, GC and CPU.

Tried and dropped: workstation GC, a 256 MB gen0, reusing commands per connection (80% fewer bytes per read in
the benchmark, but slower at 100,000 users), and inline socket completions (logins got slower).

## Benchmarks

BenchmarkDotNet on the same 8-vCPU machine:

| | Time | Allocated |
|---|---|---|
| JWT verify | 1.23 µs | 0 B |
| JWT issue | 1.01 µs | 944 B |
| Query `?limit=20&offset=40` | 76 ns | 64 B |
| Article JSON | 294 ns | 0 B |

`DbBenchmarks` compares four ways to run reads against the full seed. Bytes allocated per read:

| | Text as strings | Text as bytes |
|---|---|---|
| One command per read | 11.0 KB | 2.9 KB |
| Npgsql multiplexing | 10.0 KB | 1.8 KB |
| One batch (what the server does) | 9.2 KB | 0.96 KB |
| One batch, commands reused | 8.4 KB | 0.20 KB |

Prepared statements make a read 4 to 5 times faster. Times in this benchmark only compare within a row: an idle
server runs separate commands in parallel, which a fully loaded one can't.

## Tests

```bash
dotnet test --project Tests/Tests.csproj
# with a database the tests may create tables in, also the reader, writer and endpoint tests:
CONDUIT_TEST_DB="Host=127.0.0.1;Username=conduit;Password=conduit;Database=writer_test" dotnet test --project Tests/Tests.csproj
dotnet run -c Release --project Benchmarks -- --filter '*'
bash ../../test/run.sh submissions/csharp-kestrel-xeonfx
```

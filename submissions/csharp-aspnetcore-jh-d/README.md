# Conduit: C# / ASP.NET Core (Kestrel) + Npgsql

**Front: direct.** Kestrel serves the internet on `HOST:PORT` itself (no Nginx), holding every virtual user's keep-alive connection.

| Piece | Version |
|---|---|
| .NET SDK / runtime | 10.0.402 / 10.0.13 (LTS), pinned in `global.json` (`rollForward: disable`), installed by `install.sh` from the official tarball, sha512-checked |
| Web server | ASP.NET Core 10 Kestrel, HTTP/1.1 only, `CreateSlimBuilder`, no MVC, no routing middleware, no logging |
| Postgres driver | Npgsql 10.0.3 (`NpgsqlDataSource`, `NpgsqlBatch`, multiplexing) |
| bcrypt | own (`Bcrypt.cs`), cost 10, up to four hashes interleaved per thread; checked against BCrypt.Net-Next by `tools/BcryptCheck` |
| JWT | hand-written HS256 on `System.Security.Cryptography.HMACSHA256` + `Utf8JsonReader` |
| JSON | `Utf8JsonWriter` / `JsonDocument`, no reflection serializer |

NuGet restore runs in locked mode (`packages.lock.json`); Npgsql is the only package.

## Multicore model

One process. Kestrel's socket transport and the .NET thread pool run request handling on every core; all I/O is async, so a thread
is never parked on Postgres.

**Few connections, many requests each.** Npgsql multiplexing pipelines the commands of concurrent requests onto `DB_POOL_SIZE` connections
(default 4 per core, so 32 on the box; the limit is 95). Postgres then runs a few busy backends instead of many mostly idle ones: 20% less
Postgres CPU per request than one connection per request with a pool of 80, and the pool no longer has to cover every request in flight.

**bcrypt on its own threads.** The only long CPU job (a hash is 40-90 ms) runs on **2 dedicated threads** fed by a queue, so a login storm can't
occupy request threads. A worker that has a job waits up to 200 ms for more and runs up to four together: one Blowfish hash is a chain of dependent
table lookups that leaves most of the core idle, and four independent chains on one thread fill it (about 3x less CPU per hash; `tools/BcryptCheck`
prints the timings). A login's latency is irrelevant next to the CPU a full batch saves. One session in four starts with a hash or a verify, and
before this bcrypt was about a quarter of the app's CPU.

**Server GC.** With tens of thousands of keep-alive connections alive, the default workstation GC paused the whole process about 12% of
the time (roughly ten gen0 collections a second at ~12 ms each) and the latency knee came from that, not from CPU. Server GC collects on all cores
and pauses about 2%. A larger gen0 budget on workstation GC made it worse (fewer but much longer pauses); on Server GC it saved 1% of app CPU and
doubled p99, so it is left alone.

Runtime settings (all inside the process, overridable by `DOTNET_*` variables): Server, non-concurrent GC; tiered PGO on;
invariant globalization; diagnostics and EventSource off; `ThreadPool.UnfairSemaphoreSpinLimit=0`, so an idle pool thread sleeps at once
instead of spinning for work, which burned CPU that Postgres, on the same cores, needs (9% less app CPU per request).

## Rules compliance

* No cache of any kind between requests: every request reads Postgres. Every JWT is fully verified (signature, `alg`, `exp`, `nbf`, `sub`)
  on every request; every login runs a full bcrypt verify; every register/password change runs a full bcrypt hash at cost 10.
* Writes are committed before the response (the default `synchronous_commit`; one implicit transaction per batch).
* Prepared statements and the pool are the only reuse (rule 5). Session-level `SET`s only, passed as connection options:
  `plan_cache_mode=force_generic_plan`, `jit=off`, `max_parallel_workers_per_gather=0`. No schema or server changes.
* `Keep-Alive` idle timeout is 10 minutes, well past 65 s.

Known limits (none matters to the challenge's traffic, all would matter in production): the bcrypt queue is unbounded (no overload response); an
update or delete that races a rename of the same article by the same author can match zero rows and still answer 200/204 (the ownership lookup and the
mutation are two statements keyed by slug); an unknown email answers a login faster than a wrong password does (no bcrypt runs).

## The optimizations and why

1. **One round trip per request.** Every endpoint is a single `NpgsqlBatch` (pipelined statements, one implicit transaction), except creating
   and updating an article, which commit their write batch and then read the stored row back for the response:
   a list is the page plus the capped count; a favorite is the insert plus the article; a comment is one `INSERT ... SELECT`
   keyed by slug (no row back means 404). The reference's separate "does the article exist" lookups are folded into the statement that needs them.
2. **Generic plans.** The reference statements are planned for every execution (planning cost is about as much as executing them).
   With `plan_cache_mode=force_generic_plan` they are planned once per connection. That is only safe if no statement depends on a
   parameter's value to choose a plan, so every `LIMIT` is a literal in the SQL text (one cached text per limit value; a `LIMIT $n`
   falls back to a full scan and sort: 122 ms against 0.2 ms) and the offset stays a parameter. Parameters always carry an explicit type.
3. **Cut the page first.** The global list takes the page of `articles` by id before running the per-row sub-queries (tags, favorites count,
   favorited, following), so skipped `OFFSET` rows cost nothing. Page 5 of the home feed was 4.6x the cost of page 1.
4. **Tags without a join.** The tag array is `ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) ...)`; the reference's hash join
   re-scanned all 200 tags for every article. 10-25% cheaper on every list, identical output (compared with the reference SQL over random viewers/limits/offsets).
5. **Comments in one statement** (`LEFT JOIN LATERAL`): the article's existence and its comments come back together.
6. **Lean per-request CPU.** Hand-written router, hand-written JWT, pooled response buffers with a `Utf8JsonWriter` writing pre-encoded property
   names, timestamps formatted with `Utf8Formatter` (truncated to milliseconds), no DTOs, no reflection, `Content-Length` set (no chunking), no logging, no `Server` header.
   Each of these was measured against the framework alternative and kept because the alternative was slower: Minimal API routing +1.1% app CPU per
   request, `Microsoft.IdentityModel.JsonWebTokens` +1.4%, source-generated System.Text.Json DTOs 1.7x slower to write a page of 20 articles.
   Written entirely the standard way (Minimal APIs, `AddJwtBearer` + authorization, source-generated System.Text.Json DTOs, same SQL and Npgsql layer)
   the server is 26% shorter (821 lines) and passes the same 197 checks and golden transcript, but uses 13.5% more app CPU per request
   (7.1% more with the hand-written JWT instead of `AddJwtBearer`), so it was not used.
7. **No Nginx.** About 11% of the box in the video.
8. **Server GC, multiplexing with 32 connections, no thread-pool spinning, interleaved bcrypt** (see "Multicore model" above). Each was measured on its
   own before adopting it (multiplexing -20% Postgres CPU per request, spin limit 0 -9% app CPU, interleaved bcrypt -12% app CPU). The bcrypt
   implementation is written from the algorithm and checked against BCrypt.Net-Next (`tools/BcryptCheck`: random passwords of 1-72 bytes, every lane
   count, both directions).

## Measurements

A box built to the official description, torn down afterwards: one `Standard_D8as_v5` target (AMD EPYC 7763, 4 cores x 2 threads, kernel capped to 15.9 GB of
RAM, Ubuntu 24.04, Postgres 18.6 and Nginx configured by the repo's `box/setup-box.sh`, the full seed) and three `Standard_D4as_v5` load boxes on the same VNet with
accelerated networking, driven by the repo's own `loadgen search` (the 2-vCPU load boxes I started with were declared load-limited at 120,000 users). The server runs as
`challenge.service` exactly as in `switch.sh`. Steal was 0% and the target ran at 98.5% CPU during the holds (the server is CPU-bound).

**60,000 users** (5-minute hold: p95 281 ms, p99 419 ms, 0.05% errors, 15.4k requests/s). 60,000 was the highest passing probe; 62,000 failed (p95 644 ms).
One run, so the score has about 5% resolution. Postgres is about 72% of the CPU per request. The most expensive
statements while holding 55,000 users (`pg_stat_statements`, share of Postgres time): the "your feed" page 28-32%, the global page 12%, an article's comments 12%, an article
8-10%, the two capped counts 14%, the tag page 6%. I looked for a cheaper feed (merge of the followees' newest ids, one scan of the article index with a semi-join): the
per-followee `LATERAL` scans cost 115 us against 640 us for the alternatives, so the SQL stays; any further gain would have to come from the statements, not the web layer.

## Build and run

```bash
sudo bash install.sh      # .NET SDK 10.0.402 -> /opt/dotnet
bash build.sh             # dotnet publish -> bin/Conduit.dll
DATABASE_URL=postgres://... JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

Environment: `DATABASE_URL`, `JWT_SECRET` (required), `HOST` (127.0.0.1), `PORT` (3000), `DB_POOL_SIZE` (4 per core), `BCRYPT_THREADS` (2),
`BCRYPT_BATCH_MS` (200).
`CONDUIT_STATS=1` prints GC and thread-pool counters to stderr every 10 s (off by default; for tuning).

## Checks

```bash
bash ../../test/run.sh submissions/csharp-aspnetcore-jh-d      # 197 conformance checks + the golden transcript
dotnet run -c Release --project tools/BcryptCheck               # our bcrypt against BCrypt.Net-Next, and its speed
```

# Ruby + Falcon, bare Rack

Front: direct

A plain Rack app on Falcon, with no framework or ORM. I wanted to see how fast Ruby can go on this workload. It's about 1,000 lines, and about a quarter of that is SQL.

## Versions

| | |
|---|---|
| Ruby | 4.0.9, built from source by `install.sh` with YJIT and jemalloc |
| Server | Falcon 0.57.0, serving a plain Rack app |
| Postgres driver | pg 1.7.0 (libpq 16 from Ubuntu) |
| bcrypt | bcrypt 3.1.22, cost 10 |
| JWT | HS256 by hand on OpenSSL (Ruby's openssl 4.0.2) |

Gems are pinned in `Gemfile.lock`, and `build.sh` compiles the native ones from source.

## How it runs

Falcon loads the code once and forks a worker per core. Each worker is a single thread running an event loop with a fiber per connection, so pg hands control back to the loop while Postgres is working. Falcon is configured not to restart crashed workers.

Each worker has one pipelined Postgres connection for reads and up to 2 ordinary connections for writes, so 24 connections in total on the 8 core box.

## Code

```
config.ru                     wires the app to Postgres, the JWT secret and bcrypt
lib/conduit/app.rb            routing and the endpoints
lib/conduit/sql.rb            every statement, plus the batched versions of the reads
lib/conduit/database.rb       the read pipeline (with batching) and the write pool
lib/conduit/input.rb          request bodies, query strings and path segments
lib/conduit/tokens.rb         JWT issue and verify
lib/conduit/passwords.rb      bcrypt off the event loop
```

## Optimizations

All the numbers here are from my machine on the full seed (setup further down).

- Postgres builds the JSON. Most endpoints are a single statement that returns the response body as one text column. For a 10 article list this costs Postgres about the same as returning the rows, and saves Ruby around 40 µs of decoding and `JSON.generate`.
- One statement per request. Anything the reference SQL does in separate statements is combined into one using data-modifying CTEs. For example, following a user is one statement that looks up the user, inserts the follow and returns the profile, and lists get the page and the capped count in the same statement. Creating an article is the exception and runs the spec's transaction as written.
- JIT off and generic plans. With `LIMIT $2` the planner guesses a list returns 10% of the table. That pushed the generic plan over `jit_above_cost`, and Postgres spent 170 ms JIT compiling a query that runs in 0.2 ms. Each connection now sets `jit = off` and `plan_cache_mode = force_generic_plan`. With JIT off the generic plans match the custom ones, so forcing them skips planning, which was costing as much as execution for most statements. Together this halved Postgres's CPU per list request.
- Fewer connections, pipelined. Postgres used less CPU per request the fewer connections it had: 206 µs with 11 connections per worker, 164 with 2 and 151 with 1. A single plain connection per worker meant queries queued up though, and p95 went to 381 ms at 75k users. So each worker sends its reads down one connection in pipeline mode, and a reader fiber hands the results back in order. Writes have their own small pool so a commit waiting on the WAL doesn't hold up reads. At 75k users this took p95 from 95 ms to 8 ms compared to 2 plain connections per worker.
- Batched reads. The first read in a worker waits 10 ms for other requests to queue theirs, then they all go out together under one Sync. That's one write and one Postgres transaction instead of one per read. Reads of the same statement run as a single query, with the parameters passed as arrays and `unnest(...) WITH ORDINALITY` returning a row per request. Parts that don't depend on the request, like the capped count of all articles, only run once. At 60k users this took the app from 156 to 127 µs per request and Postgres from 163 to 122 µs, for about 10 ms of extra latency. Without the wait there was almost nothing to batch, since each worker only sees about 2,000 requests a second. A 20 ms wait saves a bit more again. I checked that batched queries give the same responses by sending bursts of concurrent requests and comparing each one to the same request sent on its own.
- A bigger starting heap. Every GC, even a minor one, scans the stack of every connection's fiber, and under load that's thousands per worker. Each GC was taking 10 to 50 ms no matter how little garbage there was, and with the default heap the workers spent almost 30% of their CPU in GC. `start.sh` starts each worker with a much bigger heap, which cut the number of GCs by about 20x and the app's CPU per request by 20%.
- Tag names by primary key. Postgres was doing a hash join over all 200 tags for every article. Looking each name up by primary key made a 10 article list 14% cheaper.
- Reusing the HMAC key. Creating an `OpenSSL::HMAC` was 7% of the app's CPU, because OpenSSL 3 looks up the algorithm each time. The server keys one at boot and signs with copies of it, which takes 1 µs instead of 5.
- No gzip. Falcon gzips by default, which cost about 10% of each worker's CPU, and compression is optional here.
- bcrypt runs on its own thread. bcrypt releases the GVL, but with a single threaded event loop a login would still block every other request on that worker while it hashes.

Things I tried that didn't help:

- `JSON_OBJECT` and `JSON_ARRAYAGG` instead of `json_build_object`. Same cost.
- Aggregating a page's tags in one query instead of per article. Slower than the primary key lookups.
- 6 workers instead of 8. Postgres used a bit less CPU with fewer backends, but the workers got busier and p95 doubled.
- A bigger heap again, to get past the drop-off at 100k users (see below). No difference.

Serving the app from Falcon's native interface instead of Rack saved 4.5% of the app's CPU (148 vs 155 µs per request). I kept Rack.

Under load the app now uses about 130 µs of CPU per request and Postgres about 130 µs. Only about 25 µs of the app's share is this code and about 7 µs is Rack. The rest is mostly Falcon's HTTP/1.1 handling, the event loop, syscalls and GC.

## Rules

- Nothing is cached between requests, and every request reads from Postgres while it's being served. Batched requests can share one query, including requests for `/api/tags`, but only the requests already waiting when it runs get its results, and nothing is kept afterwards.
- Passwords use bcrypt cost 10, and every login checks the stored hash. Passwords over 72 bytes get a 422, since bcrypt only uses the first 72.
- Every request checks the token's HS256 signature and `exp`, and rejects any other `alg`.
- Writes are committed before the response goes out. Each write is one statement in its own implicit transaction, apart from creating an article, which is one explicit transaction. Favorite and unfavorite count the change they just made in the same statement.

## Local results

Ryzen 5 7600, with Postgres and the app pinned to 8 of its threads and the load generator on the other 4. Each run is a 60 s ramp and then 60 s measured, the same as the scorer's probes.

| Users | req/s | p95 | p99 | CPU (app + Postgres, of 8) | |
|--:|--:|--:|--:|---|---|
| 60,000 | 15,871 | 13 ms | 16 ms | 2.02 + 1.93 | pass |
| 80,000 | 21,154 | 15 ms | 40 ms | 2.76 + 2.69 | pass |
| 90,000 | 23,770 | 21 ms | 67 ms | 3.18 + 3.12 | pass |
| 100,000 | 26,056 | 278 ms | 774 ms | 3.92 + 3.47 | passed 2 of 5 runs |
| 95,000 for 5 minutes | 25,084 | 36 ms | 89 ms | 3.36 + 3.72 | pass, 0 errors |

At 95k users the workers use about 7.3 GB of memory between them, mostly connection fiber stacks.

When a run at 100k fails, it's GC. Requests wait long enough to survive a few GCs and get promoted to old objects. After that every GC has to mark them as well as the stacks of around 13,000 connection fibers per worker, GC ends up taking over 70% of the CPU, and the run doesn't recover.

My machine is a lot faster per core than the benchmark box, so the real number will be lower. For reference, the Go example passes 30k users on my setup and scored 24k on the real box.

## Build and run

```bash
sudo bash install.sh   # once: builds Ruby 4.0.9 into /opt/ruby-4.0.9
bash build.sh          # installs gems into ./vendor/bundle
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

`WEB_CONCURRENCY` overrides the worker count, `DB_POOL` the number of write connections per worker, and `BATCH_WINDOW` how long reads wait to be batched (in seconds, default 0.010).

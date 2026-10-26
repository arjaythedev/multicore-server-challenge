# Ruby + Falcon, bare Rack

Front: direct

My [Rails submission](https://github.com/arjaythedev/multicore-server-challenge/pull/74) was about how a normal Rails app does. This one is the opposite: how far Ruby itself goes when you strip everything away. It's a plain Rack app on Falcon, with no framework or ORM, in about 1,000 lines, a quarter of them SQL.

## Versions

| | |
|---|---|
| Ruby | 4.0.9, built from source by `install.sh` with YJIT and jemalloc |
| Server | Falcon 0.57.0, serving a plain Rack app |
| Postgres driver | pg 1.7.0 (libpq 16 from Ubuntu) |
| bcrypt | bcrypt 3.1.22, cost 10 |
| JWT | HS256 by hand on OpenSSL (Ruby's openssl 4.0.2) |

Gems are pinned in `Gemfile.lock`, and `build.sh` compiles the native ones from source. `install.sh` is the same as the Rails submission's.

## How it runs

Falcon loads the code once and forks a worker per core. Each worker is a single thread running an event loop with a fiber per connection, so pg hands control back to the loop while Postgres works.

Each worker has one pipelined Postgres connection that all its reads share, and up to 2 ordinary connections for writes. That's 24 connections in all on the 8 core box. Reads are batched: each worker collects them for 10 ms and sends them as one group, and reads of the same statement in a group run as a single execution. Falcon is configured not to restart crashed workers.

## Code

```
config.ru                     wires the app to Postgres, the JWT secret and bcrypt
lib/conduit/app.rb            routing and the endpoints
lib/conduit/sql.rb            every statement, by name, and their merged forms for batches
lib/conduit/database.rb       the batching read pipeline and the write pool
lib/conduit/input.rb          request bodies, query strings and path segments
lib/conduit/tokens.rb         JWT issue and verify
lib/conduit/passwords.rb      bcrypt off the event loop
```

## Optimizations

The numbers here are from my machine on the full seed (setup further down).

- **Postgres builds the JSON.** Most endpoints are one statement whose single text column is the response body. Building a 10 article list with `json_build_object` costs Postgres no more than returning the rows does, and saves Ruby about 40 µs of decoding and `JSON.generate` per list.
- **One statement per request.** The checks and changes that the reference SQL does in separate statements go into one, using data-modifying CTEs. Following someone is one statement that finds the user, inserts the follow and returns the profile. Lists fetch the page and the capped count in the same statement. Creating an article is the exception: it runs the spec's transaction as written.
- **JIT off and generic plans.** Each connection runs with `jit = off` and `plan_cache_mode = force_generic_plan`. With `LIMIT $2` the planner estimates a list returns 10% of the table, which pushed the generic plan over `jit_above_cost`, and Postgres spent 170 ms JIT compiling a query that takes 0.2 ms to run. With JIT off the generic plans are the same as the custom ones, so forcing them skips planning on every call. Planning cost as much as executing for most of these statements. Together these halved Postgres's CPU per list request.
- **Fewer connections, pipelined.** Postgres used less CPU per query the fewer connections it had to serve: 206 µs per request with 11 connections per worker, 164 with 2 and 151 with 1. One plain connection per worker queued, though: at 75k users p95 went to 381 ms. So reads go down one connection per worker in pipeline mode, and a reader fiber hands each result back to its request in order. Writes use their own small pool, so a commit waiting on the WAL doesn't hold up the reads behind it. At 75k users this took p95 from 95 ms to 8 ms compared with 2 plain connections per worker.
- **Batched reads.** The first read a worker asks for waits 10 ms while other requests ask for theirs, then the group goes down the pipeline at once under a single Sync. That's one write, and one implicit transaction for Postgres instead of one per query; they're all reads, and in READ COMMITTED each still sees the data as of when it starts. Reads of the same statement in a group run as one execution: its parameters become arrays, and the single statement runs as a correlated subquery over `unnest(...) WITH ORDINALITY`, giving one row per request. Anything that doesn't depend on the request, like the capped count of all articles, runs once per group, and tags requests in the same group share one execution. At 60k users batching took the app from 156 to 127 µs per request and Postgres from 163 to 122, a quarter less CPU in all, for about 10 ms more latency. A longer window saves a little more (20 ms used 3.8 cores at 60k instead of 4.0). Without one there's almost nothing to batch: a worker sees about 2,000 requests a second, so each tick of the event loop had about one request, and groups averaged 1.14 queries. The merged statements give byte-for-byte the same responses as separate ones, which I checked by firing bursts of concurrent requests and comparing each with the same request sent alone.
- **A bigger starting heap.** Every GC, even a minor one, scans the stack of every connection's fiber, and with tens of thousands of keep-alive connections that's thousands per worker. Each GC cost 10 to 50 ms however little garbage there was. At the default heap size the workers spent almost 30% of their CPU in GC. `start.sh` gives each worker a heap with room for a few thousand requests' garbage, which cut GC by about 20x and the app's CPU per request by 20%.
- **Tag lists by primary key.** For the tag names, Postgres picked a hash join that scanned all 200 tags for every article. Looking each name up by primary key made a 10 article list 14% cheaper for Postgres.
- **A keyed HMAC, reused.** Creating an `OpenSSL::HMAC` was 7% of the app's CPU, because OpenSSL 3 looks the algorithm up every time. The server keys one at boot and signs with copies of it, which takes 1 µs instead of 5.
- **No gzip, and bcrypt on its own thread.** These are the same as in the Rails submission. Falcon's default gzip cost about 10% of a worker's CPU. bcrypt releases the GVL, but on a single-threaded event loop a login would still stall every other request on that worker, so it runs on a short-lived thread.

A few things I tried that didn't help:

- The SQL-standard `JSON_OBJECT` and `JSON_ARRAYAGG` instead of `json_build_object`. They cost the same.
- Grouping the page's tags in one aggregate, instead of per article. It was slower than the primary key lookups.
- 6 workers instead of 8. Postgres was a bit cheaper with fewer backends, but the workers got busier and p95 doubled.
- A bigger heap to push back the overload cliff (see the results). Doubling it didn't help.

And one that helped, but that I didn't keep: serving the app from Falcon's native interface instead of through Rack, with a minimal env, cut the app's CPU by 4.5% (148 µs per request instead of 155). That's not worth giving up Rack for.

Where the CPU goes now: under load the app uses about 130 µs per request and Postgres about 130 µs. Of the app's share, only about 25 µs is this code and about 7 µs is Rack. Most of the rest is Falcon's HTTP/1.1 parsing, the event loop, the syscalls and GC.

## Rules

- Nothing is cached between requests. Every request reads from Postgres while it's being served. Requests batched together can share one execution of a read, but only the requests already waiting when it runs get its rows, and nothing is kept once they have their answers.
- Passwords are bcrypt cost 10 and every login checks the stored hash. Passwords over bcrypt's 72 byte limit get a 422.
- Every request verifies the token's HS256 signature and `exp`, and rejects any other `alg`.
- Writes are committed before the response goes out. Each write is a single statement in its own implicit transaction, except creating an article, which is one explicit transaction. Favorites read the new count in the same statement that changes it, so the response counts the favorite it just added or removed.

## Local results

This is on a Ryzen 5 7600, with Postgres and the app pinned to 8 of its threads and the load generator on the other 4, the same setup I used for the Rails submission. Each run is a 60 s ramp and then 60 s measured, the same as the scorer's probes.

| Users | req/s | p95 | p99 | CPU (app + Postgres, of 8) | |
|--:|--:|--:|--:|---|---|
| 60,000 | 15,871 | 13 ms | 16 ms | 2.02 + 1.93 | pass |
| 80,000 | 21,154 | 15 ms | 40 ms | 2.76 + 2.69 | pass |
| 90,000 | 23,770 | 21 ms | 67 ms | 3.18 + 3.12 | pass |
| 100,000 | 26,056 | 278 ms | 774 ms | 3.92 + 3.47 | pass in 2 runs of 5 |
| 95,000 for 5 minutes | 25,084 | 36 ms | 89 ms | 3.36 + 3.72 | pass, 0 errors |

Before batching it held 85k for 5 minutes, with a p95 of 198 ms. The Rails submission held 27k users on the same setup, using about 600 µs of app CPU and 320 µs of Postgres CPU per request; this one uses about 130 µs and 130 µs. At 95k users the workers' memory adds up to about 7.3 GB, mostly the stacks of the connections' fibers.

At 100k it's on a cliff. When a run tips over, requests are held up long enough to survive a few GCs and get promoted to old objects. Then every GC has to mark those as well as the stacks of 13,000 connection fibers per worker, GC takes over 70% of the CPU, and the run falls apart.

My machine is a lot faster per core than the benchmark box, though. The Go example passes 30k users on my setup and scored 24k on the real box. By the same rough guess as in the Rails submission, this would land somewhere around 40-45k.

## Build and run

```bash
sudo bash install.sh   # once: builds Ruby 4.0.9 into /opt/ruby-4.0.9
bash build.sh          # installs gems into ./vendor/bundle
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

`WEB_CONCURRENCY` overrides the worker count, `DB_POOL` the number of write connections per worker, and `BATCH_WINDOW` how long reads are collected for (seconds, default 0.010).

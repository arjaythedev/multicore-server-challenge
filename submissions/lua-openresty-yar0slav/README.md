# Lua + OpenResty, round two: milking the same cow

**Front: direct**

Having had a good time with the $12 server challenge, I decided to stick to the same recipe and see how much more
that cow could be milked: no app server, nginx *is* the app, and the API lives in Lua inside nginx's workers.

Spoiler: the nginx part never gave me a headache. Not once. It was Postgres all the way.

Thanks to Claude Code for substantially speeding up this build: doing the profiling, the A/B harnesses and the
droplet racing by hand would have turned a fun project into a second job (read: I'd probably never have started it).

## The stack

| | |
|---|---|
| Language | Lua 5.1 (LuaJIT 2.1, bundled with OpenResty) |
| Framework | OpenResty 1.31.1.1 (nginx + lua-nginx-module), official OpenResty apt repo, pinned to `1.31.1.1-1~noble1` |
| Postgres driver | [pgmoon](https://github.com/leafo/pgmoon) 1.18.0, pure Lua on nginx's non-blocking sockets. Downloaded by `build.sh` at a pinned version and checksum, and the only dependency |
| bcrypt | Ubuntu's own libcrypt (libxcrypt) through LuaJIT's FFI, in an nginx thread pool |
| JWT | hand-rolled HS256: OpenSSL's `HMAC()` through the FFI (OpenSSL 3 ships with OpenResty) |
| JSON | `lua-cjson` (bundled), for parsing and string escaping; responses are built by concatenation |
| **Front** | **Direct**: OpenResty is nginx, so it serves `0.0.0.0:80` itself and holds every user's keep-alive connection |

## How it works

- **One nginx worker per core**, `reuseport` on the listener, so the kernel spreads users over the workers. Each
  worker is one event loop holding thousands of keep-alive connections, which costs nginx a few hundred bytes each.
- **A Postgres pool per worker**, 8 connections each (64 on 8 cores, never more than 95 in total). The cap is an
  `ngx.semaphore`, because nginx's own pool cap turned out not to hold (see below). Each worker opens its whole pool
  at startup: a new connection costs a SCRAM-SHA-256 handshake (4096 PBKDF2 rounds) on the event loop, and that
  shouldn't happen while users wait.
- **Every statement is prepared once per connection.** A new session runs its settings and ~30 `PREPARE`s in one
  round trip; requests then run `EXECUTE name(...)`. Session settings: `plan_cache_mode = force_generic_plan`,
  `jit = off`, UTC timestamps.

  This is not a cache in the rule 5 sense. A prepared statement keeps a query plan, never data: every request still
  reads its rows from Postgres while it's served, and rule 5 names prepared statements as fine. It's simply what the
  reference Go server's driver (pgx) does on its own: it prepares each statement once per connection and reuses it.
  pgmoon isn't that advanced: it parses and plans every query on every call. So I borrowed pgx's logic and did it
  by hand with `PREPARE`/`EXECUTE`.
- **bcrypt never touches an event loop.** A hash costs ~60-100 ms of CPU, so it runs in nginx's thread pool via
  `ngx.run_worker_thread`, and login hands its Postgres connection back before hashing.
- **Postgres replies are read through a small buffer** (`lua/pgbuf.lua`) instead of pgmoon's two socket calls
  per protocol message. pgmoon itself is unchanged.

## What I optimized, and what it bought

Profiling and A/B tests ran locally, in Docker on the full seed, with Postgres, the server and the load generator
pinned to separate CPU cores (without pinning they stole CPU from each other and the noise drowned anything under
~10%). Numbers are CPU per request at the same fixed load, before vs after, over several alternating rounds.

| Change | Measured |
|---|---|
| **Prepared statements, generic plans.** pgmoon has no prepared statements: every query was parsed and planned on every call, ~41% of Postgres's time | Postgres CPU per request **521 → 354 µs (-32%)** |
| **`jit = off`.** A generic plan doesn't know the `LIMIT`, so the global list's cost estimate crossed `jit_above_cost` and every execution JIT-compiled 45 functions | global list **115 ms → 0.4 ms** per call. Before forcing generic plans, every statement's generic plan was checked against its custom plan on the full seed with skewed inputs (hot and rare tag, prolific and one-article author, heaviest follower's feed, viral article): all 0.4-1.0x |
| **Explicit casts on every numeric parameter.** pgmoon sends Lua numbers as `numeric`, and `bigint_column = numeric` can't use the index | main list query **7 ms → 0.37 ms** |
| **Tag names by primary key** instead of joining `tags`, which made Postgres hash all 200 tags for every article. **List count returned with the list**, and **comments in one statement**: one round trip instead of two for ~35% of requests | Postgres CPU per request **274 → 221 µs (-19%)**, server **191 → 176 µs** |
| **Buffered reads of Postgres replies.** In a LuaJIT profile, pgmoon's per-message socket reads were the server's biggest single cost (23% of Lua time) | server CPU per request **219 → 176 µs (-20%)** |

### Things that were broken before they were slow

- **nginx's connection pool cap doesn't hold** when every request checks a connection out and back in: in an
  isolated test, a worker with `pool_size = 5` reached 15 Postgres sessions. Under load the box ran out of Postgres
  slots and the reconnects cascaded into 500s (0.8-1.7% errors in the failing runs). With a semaphore: **0 errors**,
p99 **403 → 47 ms**.
- **`install.sh` failed on the real box layout.** The openresty package starts a system-wide OpenResty on port 80,
  which the box's nginx already holds, so dpkg failed the whole install. CI never sees it (no nginx there). A
  temporary `policy-rc.d` stops package scripts from starting services during the install.

### Tried and dropped

- Feed via a backward scan over all articles filtered by followees: 2.6x slower than the reference lateral query.
- Tags as a delimited string or an array literal instead of `to_json`: no cheaper.
- 4 Postgres connections per worker: starved throughput.

## Racing the reference

On the 4 vCPU / 8 GB droplets (the 8-vCPU size is locked behind an account tier ticket), the job was simple: race
the reference Go implementation (`examples/go`, the video's best) on the same box, with the same load. Not beating
it was never an option.

Setup: target built with `box/setup-box.sh` and the full seed, run by `challenge.service`; two load droplets
running `bench/cmd/loadgen` over the private network. Every 5-minute hold starts from a fresh copy of the seed and
the same 1000-user warm-up, so neither server inherits the other's data.

| 5-minute hold | Mine | Go (`examples/go`, behind nginx) |
|---|---|---|
| 10,000 users | FAIL (p95 944 ms, 2,481 req/s) | FAIL (p95 2.5 s, 1,967 req/s) |
| 9,500 users | FAIL (p95 577 ms) | — |
| **9,000 users** | **PASS** (p95 210 ms, p99 572 ms, 0 errors) | FAIL (p95 1.8 s, 0.32% errors) |
| 8,000 users | — | FAIL (p95 847 ms) |
| 7,000 users | — | FAIL (p95 899 ms, p99 3.8 s) |

At 9,000 users the box split its CPU into Postgres ~46%, nginx + Lua ~30%. At the same load the Go example used
nginx (11%) *plus* Go (28%), and about the same Postgres CPU while serving ~17% fewer requests; its throughput
stopped at ~2,000 req/s whatever the load.

What still limits it, measured with `pidstat`: the nginx workers carry every user, and they compete for the CPU
with the Postgres backends. At 9,000 users each worker ran 29% of the time and waited for a CPU 44% of the time.
That's why the pool is 8 connections per worker rather than as many as Postgres allows.

These numbers come from a shared-vCPU droplet with 4-10% steal from the neighbours, on half the scoring box. They'll
be updated if I get to the 8-core box.

## Running it

```bash
sudo bash install.sh   # apt: openresty (pinned), libcrypt
bash build.sh          # downloads pgmoon 1.18.0 (pinned, checksummed), syntax-checks the Lua
DATABASE_URL=... JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

Optional knobs, all with defaults: `DB_POOL_SIZE` (connections per worker), `PG_PREPARE=0` (no prepared
statements), `PG_PLAN_CACHE_MODE`, `PG_BUFFERED=0` (pgmoon's own socket reads). The last three exist for A/B tests.

## License

MIT, under the repo's [license](../../LICENSE).

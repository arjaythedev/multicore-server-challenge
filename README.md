# The Multicore Server Challenge

How many users can one **8-core server** handle? **[See the leaderboard](https://benchmarks.arjaythedev.com/multicore)** (also in [LEADERBOARD.md](LEADERBOARD.md)).

I benchmarked Go, Rust, Java and Python on 1, 2, 4 and 8 cores, running a real app (a Medium clone) on Postgres,
with plain unoptimized code in each language's most popular framework. On 8 cores the best of them held 22,000 users.

**Now it's your turn: implement the same app in any language and framework, make it as fast as you can,
and I'll benchmark it on the same 8-core box.**

> **The challenge is closed.** New submissions are no longer benchmarked automatically. The leaderboard stays up with
> every result so far.

## What's here

| | |
|---|---|
| [`SPEC.md`](SPEC.md) | The API you implement: RealWorld's "Conduit", 19 endpoints, exact JSON and errors, and the reference SQL |
| [`schema.sql`](schema.sql) | The Postgres schema (fixed) |
| [`WORKLOAD.md`](WORKLOAD.md) | The seed data, what a virtual user does, and how a run passes or fails |
| [`seed/make-seed.sh`](seed/make-seed.sh) | Builds the seed database: 100k users, 500k articles, 5M favorites, 2.5M comments, 2M follows (or a 2% `--dev` copy) |
| [`bench/`](bench) | The conformance suite (197 checks, your server must pass all of them) and the load generator I score with |
| [`test/run.sh`](test/run.sh) | Builds your submission, starts it on a fresh database copy and runs the conformance suite (what CI runs) |
| [`box/`](box) | How the benchmark box is set up: Postgres config, Nginx config, kernel limits, the systemd unit your server runs in |
| [`examples/`](examples) | The four servers from the video (Go, Rust, Java, Python), with their 8-core scores. Copy one as a starting point |

## Quick start

```bash
bash seed/make-seed.sh --dev                    # needs Go >= 1.27, Postgres + psql; about 30 seconds
mkdir submissions/rust-axum-yourname            # your code + install.sh, build.sh, start.sh, README.md
bash test/run.sh submissions/rust-axum-yourname # needs Go, psql and curl
```

To load test it yourself, see [`bench/README.md`](bench/README.md#load-test-your-own-server-locally).

## Rules

**The stack**

1. Any language, framework, runtime and Postgres driver. Any number of processes or threads.

2. **The database is PostgreSQL 18** on the same box, at `$DATABASE_URL`. No other database, cache server or
   external service (no Redis, Memcached, SQLite). Postgres's config is fixed ([`box/pg-conf.sh`](box/pg-conf.sh)),
   including `max_connections = 100`. Session-level `SET` on your own connections is fine; server-wide changes
   (`ALTER SYSTEM`, `ALTER DATABASE/ROLE ... SET`) are not.

3. The schema and data are fixed. Don't create, alter or drop anything in the database: no tables, columns,
   indexes, views, functions, triggers or extensions. Any SQL you like against the schema as given.

**Correctness**

4. Pass the conformance suite 100% (`test/run.sh`).

5. **No caching across requests.** Every request reads its data from Postgres while it is being served: no
   response caches, query-result caches, in-memory copies of tables, and no remembered JWT verifications or bcrypt
   results. Postgres's own buffers are fine. That's the database. Connection pools and prepared statements are
   fine too: they cache connections and query plans, not data.

6. **Writes are committed before you respond.** No `synchronous_commit = off`, no unlogged tables. Batching several
   requests' writes into one transaction (group commit) is allowed if each response waits for its commit.

7. **Security stays real.** Every password is hashed with bcrypt cost 10, and every login verifies against the
   stored hash. Every token's HS256 signature and `exp` are checked on every request.

8. No hard-coded responses, no detecting the load test, nothing that only works because it's a benchmark.

**The box**

9. It runs on Ubuntu 24.04 x86_64 with **8 vCPUs and 16 GB RAM**. You share the CPU and RAM
   with Postgres (and Nginx, if you use it). If you run out of memory, you lose. If your server crashes, it isn't
   restarted.

10. **Nginx is optional.** Either run behind my Nginx ([`box/site.conf`](box/site.conf), as in the video) on
    `127.0.0.1:3000`, or serve the internet directly on `0.0.0.0:80`. Going direct saves the CPU Nginx uses (about
    11% of the 8-core box in the video), but then your server holds every user's keep-alive connection itself
    (tens of thousands). Put a line `Front: nginx` or `Front: direct` in your README.

11. It is built from source on the box with your `install.sh` and `build.sh`. Pin your dependency versions,
    and don't ship prebuilt binaries. It must answer `GET /api/tags` within 60 seconds of `start.sh`.

12. Nothing on the box gets tuned for you beyond [`box/setup-box.sh`](box/setup-box.sh): no kernel parameters,
    and no pinning of CPU or other processes. Settings inside your own process (GC, thread counts, allocator, pool
    sizes) are fair game.

## Submitting

New submissions are no longer benchmarked automatically. You can still open a pull request, but it won't be run.

Open a pull request that adds one folder, `submissions/<language>-<framework>-<github-username>/`, containing:

| File | What it does |
|---|---|
| `install.sh` | Runs once as root on a clean Ubuntu 24.04: installs your toolchain/runtime (apt, official tarballs) |
| `build.sh` | Builds your app as a normal user (may download pinned dependencies) |
| `start.sh` | Runs the server **in the foreground**, configured only by the env vars in [SPEC.md](SPEC.md#runtime-contract) |
| `README.md` | Language, framework, driver and versions; **`Front: nginx` or `Front: direct`**; the optimizations you made and why |
| your code | Source only: don't commit build output (`bin/`, `target/`, `node_modules/`, …). Add a `.gitignore` |

The [examples](examples) show all three scripts for Go, Rust, Java and Python.

CI runs `install.sh` and `test/run.sh` on every pull request, and it must be green. Don't touch files outside your folder.
By submitting, you license your code under the repo's [MIT license](LICENSE).

## Scoring

I benchmark each passing submission like the video: on the 8-core box, against the full seed, with the load
generator ([`bench/cmd/loadgen`](bench/cmd/loadgen)) on separate machines. A virtual user browses like a person
(about 7 s between pages, sessions of about 15 minutes, 95% reads). The details are in [WORKLOAD.md](WORKLOAD.md).

1. **Warm-up**: 3 minutes at a low load (not scored).

2. **Find the limit**: 2-minute runs, doubling the users until one fails, then narrowing down to within 5%.

3. **Confirm it**: one 5-minute hold at that number. If it fails, step down 5% and try again.

**Your score is the most users that pass a 5-minute hold** with p95 under 500 ms, p99 under 1 s and under 1% errors.
A run where a load generator, not your server, is the limit doesn't count: I add load capacity and run it again.

**After your pull request is merged**, it waits for the next benchmark batch. I run merged submissions in batches,
not one at a time, on no fixed schedule, and share the results once a batch is done.

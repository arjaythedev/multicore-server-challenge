# Zig Reactor — Chemske

Front: direct

This submission implements the complete Conduit API for the Multicore Server Challenge in Zig. The idea is to reduce work per request across the whole machine, especially PostgreSQL, while keeping admission, memory and failure recovery bounded.

The server uses independent readiness reactors, owned non-blocking PostgreSQL connections and bounded bcrypt workers. Each reactor owns its listeners, clients, queues and database sessions. Compatible tags, articles, comments and list pages already waiting before dispatch share SQL work. Dedicated write owners keep reads progressing during slow commits. It never caches database data, JWT checks or bcrypt results.

**Independent v2 result:** 120,000 users held for five measured minutes on an Oracle Ubuntu x86_64 target with eight vCPUs and 16 GiB RAM, using the full seed and three separate load generators: 30,254 requests/s, p50 162.687 ms, p95 470.783 ms, p99 653.823 ms and 0.1024% errors. The unmodified search also records the failed 130,000-user hold. This is an independent result, not an official leaderboard score. Exact source, build fingerprint, hardware, protocol and every search phase are in [v2-oracle.json](benchmarks/results/v2-oracle.json).

**First official result:** [version 1](https://github.com/arjaythedev/multicore-server-challenge/pull/73) held 20,000 users for five minutes at 5,241 requests/s. Its 2,048-task admission ceiling rejected work above that level with CPU still available. The scaling changes and new Linux measurements are described in [SCALING.md](docs/SCALING.md); they do not establish a new official score. Historical Mac measurements remain in [PERFORMANCE.md](docs/PERFORMANCE.md).

## Stack

| Component | Choice |
|---|---|
| Application | Zig 0.17.0 |
| Networking | Zig reactor; kqueue on macOS, epoll on Linux |
| HTTP | Vendored picohttpparser, revision 465a7ff09fbd3432fe56c673451f5460154d1f07 |
| Database | Source-built libpq 18.6, non-blocking connections, prepared statements |
| Authentication | HS256 checked per request; bcrypt cost 10 checked per login, fresh salts |
| Front | Direct HTTP, no proxy or extra service |
| Target | Ubuntu 24.04 x86_64; native macOS ARM64 development |

libpq and picohttpparser are linked C libraries. Source attribution and parser pins are in [vendor/README.md](vendor/README.md). The compiler/client installer checks official archive SHA-256 values. It does not install or configure a PostgreSQL server.

## Native Mac development

From this submission directory:

```sh
source dev/env.sh
bash dev/setup-postgres.sh
bash dev/database.sh start
bash dev/database.sh seed
bash build.sh
bash start.sh
```

Open http://127.0.0.1:3000/api/tags. Defaults use the interactive `conduit_local` database on authenticated loopback port 55432. Tests copy separate seed templates. Stop the application with Ctrl+C and the dedicated cluster with `bash dev/database.sh stop`. No VM, container, package manager, background service or automatic startup is added.

Tools, caches, database files and evidence stay in the surrounding workspace's `work/` directory. Source `dev/env.sh` before direct compiler or test commands. See [DEVELOPMENT.md](docs/DEVELOPMENT.md) for setup and cleanup, including the larger full-seed footprint.

## Ubuntu contract

Run `bash install.sh` once as root on the benchmark's Ubuntu 24.04 x86_64 host, then `bash build.sh` and `bash start.sh` as the unprivileged runner. The installer pins Zig 0.17.0 and builds only libpq 18.6 from checked source under `/opt/conduit-zig-tools`. It leaves the provided PostgreSQL server configuration unchanged. The unchanged upstream GitHub Actions workflow validates this clean installation and runtime path.

Runtime configuration is exactly `DATABASE_URL`, `JWT_SECRET`, `HOST` and `PORT`. `start.sh` executes the server in the foreground. Build-time experiment controls are documented in [PERFORMANCE.md](docs/PERFORMANCE.md).

The Linux build defaults are four HTTP reactors, 40 PostgreSQL connections (16 read owners and 24 dedicated writers), 12,288 admitted tasks and read groups of at most 512 requests. Two shared password workers calibrate complete bcrypt calculations at startup, choosing the fastest supported width up to four; the Oracle EPYC used three. The maximum collection window is 100 ms. Closed profile groups, favorite groups, distinct page enrichment and compact page results are enabled. Every recipient retains its own viewer flags. macOS keeps the smaller interactive defaults.

## Checks

```sh
source dev/env.sh
zig build test -Dpg-root="$PGROOT"
python3 tests/milestone1.py
python3 tests/milestone2.py
python3 tests/milestone3.py
python3 tests/milestone4.py
python3 tests/milestone5.py
python3 tests/tag_batch.py
python3 tests/article_batch.py
python3 tests/comment_batch.py
python3 tests/page_batch.py
python3 tests/connections.py
python3 tests/recovery.py
python3 tests/full_seed.py
```

`tests/full_seed.py` deliberately requires the Go reference to pass too. On a busy Mac its huge-offset query can exceed the unchanged test timeout even when all 197 Zig steps pass; that optional comparison fails visibly rather than ignoring the reference failure.

The unchanged upstream runner can also build and test this folder:

```sh
PORT=3105 bash ../../test/run.sh .
TEMPLATE=conduit_seed PORT=3105 bash ../../test/run.sh .
```

The full-seed commands require the unchanged official full seed in the dedicated cluster. Seed generation is not implicit: allow disk space for the template, one temporary clone and WAL. `tests/full_seed.py` runs Zig and Go sequentially so two full clones are never retained together. Each integration harness removes its temporary servers and databases, including on failure.

There are 27 Zig unit checks and focused groups covering HTTP framing, auth, profiles, article/feed reads, mutations, commit visibility, rollback, disconnected clients and database recovery. Linux also checks 150,000 retained sockets with an HTTP response on each; the native connection test uses 8,000 sockets. These are connection-correctness checks, separate from active-user capacity.

The optional `python3 tests/recovery.py --restart-cluster` restarts only the dedicated project cluster and temporarily interrupts the interactive server. It is kept separate from routine editor tasks.

## Correctness boundaries

Every applicable request verifies its token; every login reads and verifies the current stored bcrypt hash. New passwords above 72 bytes are rejected; login truncation and corrected `$2a$` seed compatibility match Go. A present empty Authorization header is rejected, including on optional-auth routes.

Article lists select page IDs before enrichment and then read the capped count in a separate statement, preserving that reference snapshot order. Counts stop at 1,000 without hiding later pages. Viewer flags, filter precedence, text arrays and UTC millisecond timestamps are computed per request. The feed uses overflow-safe arithmetic for the allowed large offsets.

Comment listing combines article lookup and newest-100 comments into one prepared statement, with explicit ordering and a distinction between missing articles and empty lists. It therefore uses one statement snapshot; a concurrent deletion can be observed differently from the reference's two-query path. Grouped reads share a statement snapshot. Article, comment and page groups retain each request's viewer-specific flags and missing-resource status. List pages still precede a separate count statement. No later request joins a dispatched group or reuses its result.

Writes wait for confirmed commit. Article/tag/link creation is atomic. Failed transactions drain and roll back before reuse. Lost connections retire the active operation without replay, including a write whose COMMIT acknowledgement was lost. Healthy owners continue serving while another reconnects and rebuilds settings/prepared statements.

The configured client ceiling is 196,608, reduced to existing descriptor limits at startup (10,204 here on macOS). The server changes only its own soft descriptor limit within the existing hard/kernel ceiling. Tasks, password jobs, aggregate input/output buffers, per-request sizes and deadlines are bounded. Exceeding a limit can return 503 or close a connection; failures stay in benchmark results. Exact limits and ownership are in [ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Evidence

The current Linux result comes from the full-seed capacity search described above. Historical Mac holds, including failed and confounded comparisons, remain recorded in PERFORMANCE.md; they are not converted into Linux user counts or added together as speedup percentages.

[VALIDATION.md](docs/VALIDATION.md) records the final correctness, fault and Ubuntu checks.

[PERFORMANCE.md](docs/PERFORMANCE.md) records separate, reproducible local comparisons with raw errors and hardware limitations. Short Mac runs use the unchanged generator with accelerated think/session times and share CPU with PostgreSQL; they cannot be converted into official user counts or added together as cumulative speedups.

[BENCHMARKING.md](docs/BENCHMARKING.md) explains honest Mac-to-Ubuntu workload conversion and a small optional Oracle Cloud test layout. [RECOVERY.md](docs/RECOVERY.md) describes the fault matrix, including uncertain commits without replay. [MILESTONES.md](docs/MILESTONES.md) preserves historical checkpoints. [RESEARCH.md](docs/RESEARCH.md) and [COMPETITOR_REVIEW.md](docs/COMPETITOR_REVIEW.md) record the original architecture research and source review.

The organiser's full-seed, five-minute capacity search with separate load generators determines ranking. A separate Linux test retained 150,000 sockets and checked HTTP responses, as described in [SCALING.md](docs/SCALING.md). Neither that socket test nor the local Mac results establish an official workload capacity score.

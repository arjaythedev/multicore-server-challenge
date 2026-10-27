# Zig Reactor — Chemske

Front: direct

This submission implements the complete Conduit API for the Multicore Server Challenge in Zig. The idea is to reduce work per request across the whole machine, especially PostgreSQL, while keeping admission, memory and failure recovery bounded.

The server uses one readiness-driven reactor, four owned non-blocking PostgreSQL connections and a bounded bcrypt pool. It prepares twenty-one queries, batches compatible tags and single-article reads already waiting before dispatch, and keeps mutations on an isolated durable transaction path. It never caches database data, JWT checks or bcrypt results.

**Validation:** the clean Ubuntu 24.04 x86_64 installer, Linux build and unchanged 197-step conformance suite pass with PostgreSQL 18. On native macOS, Zig passes all 197 steps on development and full seeds. All 197 development responses match Go; in the final full-seed comparison, Go times out on the very large offset test and its other 196 responses match. See [VALIDATION.md](docs/VALIDATION.md) for the retained failure evidence. Local performance evidence is documented below; an official leaderboard score remains pending.

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

There are sixteen Zig unit checks and focused groups covering HTTP framing, auth, profiles, article/feed reads, mutations, commit visibility, rollback, disconnected clients and database recovery. The many-connection check uses 8,000 actual sockets with slot replacement and pressure/deadline cases; a separate scheduler unit check exercises 100,000 simulated slots. Neither establishes 100,000 live connections on Linux.

The optional `python3 tests/recovery.py --restart-cluster` restarts only the dedicated project cluster and temporarily interrupts the interactive server. It is kept separate from routine editor tasks.

## Correctness boundaries

Every applicable request verifies its token; every login reads and verifies the current stored bcrypt hash. New passwords above 72 bytes are rejected; login truncation and corrected `$2a$` seed compatibility match Go. A present empty Authorization header is rejected, including on optional-auth routes.

Article lists select page IDs before enrichment and then read the capped count in a separate statement, preserving that reference snapshot order. Counts stop at 1,000 without hiding later pages. Viewer flags, filter precedence, text arrays and UTC millisecond timestamps are computed per request. The feed uses overflow-safe arithmetic for the allowed large offsets.

Comment listing combines article lookup and newest-100 comments into one prepared statement, with explicit ordering and a distinction between missing articles and empty lists. It therefore uses one statement snapshot; a concurrent deletion can be observed differently from the reference's two-query path. Grouped tags and single-article requests also share one statement snapshot. Article groups retain each request's viewer-specific flags and missing-article status. No later request joins a dispatched group or reuses its result.

Writes wait for confirmed commit. Article/tag/link creation is atomic. Failed transactions drain and roll back before reuse. Lost connections retire the active operation without replay, including a write whose COMMIT acknowledgement was lost. Healthy owners continue serving while another reconnects and rebuilds settings/prepared statements.

The configured client ceiling is 131,072, reduced to existing descriptor limits at startup (10,204 here on macOS). The server changes only its own soft descriptor limit within the existing hard/kernel ceiling. Tasks, password jobs, aggregate input/output buffers, per-request sizes and deadlines are bounded. Exceeding a limit can return 503 or close a connection; failures stay in benchmark results. Exact limits and ownership are in [ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Evidence

The latest 8,000-user native release hold fails the latency/error targets while two existing VM workloads share the Mac. The A/B session is also confounded by their startup. These results are retained and do not support an official capacity or isolated throughput-gain claim.

[VALIDATION.md](docs/VALIDATION.md) records the final correctness, fault and Ubuntu checks.

[PERFORMANCE.md](docs/PERFORMANCE.md) records separate, reproducible local comparisons with raw errors and hardware limitations. Short Mac runs use the unchanged generator with accelerated think/session times and share CPU with PostgreSQL; they cannot be converted into official user counts or added together as cumulative speedups.

[BENCHMARKING.md](docs/BENCHMARKING.md) explains honest Mac-to-Ubuntu workload conversion and a small optional Oracle Cloud test layout. [RECOVERY.md](docs/RECOVERY.md) describes the fault matrix, including uncertain commits without replay. [MILESTONES.md](docs/MILESTONES.md) preserves historical checkpoints. [RESEARCH.md](docs/RESEARCH.md) and [COMPETITOR_REVIEW.md](docs/COMPETITOR_REVIEW.md) record the original architecture research and source review.

The organiser's full-seed, five-minute capacity search with separate load generators determines ranking. The local Mac results and Ubuntu conformance checks do not establish an official capacity score or 100,000 live Linux connections.

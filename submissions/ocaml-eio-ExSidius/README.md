# OCaml 5: Eio on io_uring, libpq and ppx_deriving_yojson

**Front: direct**

| Piece | Version |
|---|---|
| Language | OCaml 5.4.0 (standard compiler), built by `build.sh` into a local opam root, from a pinned opam-repository commit |
| Concurrency | [Eio](https://github.com/ocaml-multicore/eio) 1.6 with `eio_linux` (io_uring): one fiber per connection, one event loop per domain |
| HTTP | ~200 lines in `src/http.ml`: HTTP/1.1, keep-alive, `Content-Length` bodies |
| Postgres | [postgresql-ocaml](https://github.com/mmottl/postgresql-ocaml) 5.4.0 (libpq) in non-blocking mode, awaited through Eio; prepared statements, binary results |
| JSON | [ppx_deriving_yojson](https://github.com/ocaml-ppx/ppx_deriving_yojson) 3.10.0 on Yojson 3.0.0 for requests and most responses; batched reads write their JSON directly (`src/json.ml`), byte-identical |
| bcrypt | C threads hashing up to 5 passwords at once (`src/bcrypt_stubs.c`; kernel and tables after `c-epoll-umitaltintas`, generated assembly after `zig-iouring-nick-potts`), checked against libxcrypt at startup |
| JWT | HS256 from [digestif](https://github.com/mirage/digestif) 1.4.1 |

## Design

- **Domains.** `WORKERS` (default 6) domains each run an event loop with their own `SO_REUSEPORT` listener and share
  of the Postgres connections. `BCRYPT_THREADS` (default 2) plain C threads do the hashing at `BCRYPT_NICE` (default 19).
- **Connections.** `PG_CONNECTIONS` (default 30) is split evenly between network domains for unbatched requests.
  Batch lanes use 20 additional connections at the defaults, for 50 total, below the 95-connection limit.
  Statements are prepared once per connection; session settings disable JIT and query parallelism and reuse generic plans.
- **bcrypt never blocks an event loop.** A login's fiber suspends on its job's eventfd. Interleaving 5 hashes costs
  14-29 ms of CPU per hash on the benchmark box, against 51-56 ms alone. A hash waits up to `BCRYPT_WAIT_MS` (default
  400) for others to share its batch, unless no other login arrived recently. Every password still gets its own
  full cost-10 hash, and nothing is kept.

- **Reads and the common writes are batched across domains.** Each kind has a lane: a fiber on one domain with its own connection,
  which takes every request waiting (from any domain), lets more arrive until the oldest has waited the current window,
  and runs them as one statement with array parameters. List lanes have `LIST_LANE_FIBERS` (default 2)
  fibers, one collecting while the other's statement runs, so a slow statement doesn't make the next batch bigger. An article's data is read once however many pages and viewers want it,
  and a viewer's favorites and follows are walked once. Only requests already queued when the statement starts share
  it, and nothing is kept afterwards. Writes in a batch share one statement and one commit, and each response waits
  for that commit. If a batch fails, its requests run alone, so one bad request fails only itself.
- **The window follows the load (`src/load.ml`).** Bigger batches save CPU, which is only worth the wait when CPU is
  short. Five times a second, the window is set from how busy the CPUs are: `BATCH_WINDOW_MIN_MS` (default 15) below
  `BATCH_BUSY_LOW_PCT` (55), `BATCH_WINDOW_MS` (150) above `BATCH_BUSY_HIGH_PCT` (80), linear in between. A longer window
  lowers the load, so it settles.
- **Overload slows accepts down, it doesn't kill the server.** Connections stop being accepted 2,048 below the
  descriptor limit, which leaves room for logins and Postgres reconnects, and new ones wait in the kernel's accept queue.
  `EMFILE` and similar errors from `accept` back off for 50 ms.
- **Feed reads share author work within a batch.** Followed authors are walked once for both capped counts and newest IDs; OCaml merges each viewer's page. Article and comment lookups are sorted by ID to improve locality.
- **An article is rendered once per batch.** Each request joins the shared JSON pieces and adds its viewer's two flags.
- **`OCAMLRUNPARAM` trades memory for fewer collections** (`s=32M,o=400`), because each major collection scans every
  fiber's stack.

## Private benchmark results

Measured on 2026-10-31 at commit `9bad590`, using the submitted defaults without diagnostic counters or
service tuning overrides. The target was an AWS c6a.2xlarge (8 vCPUs, 16 GB RAM), with PostgreSQL 18 and the
full seed on the same machine; the load generator ran on a separate machine. Each run used a fresh database,
a 60-second ramp and a 300-second measured hold. Both runs passed all 197 conformance checks first.

| Users | Requests/s | p95 | p99 | Errors | Verdict |
|---:|---:|---:|---:|---:|---|
| 140,000 | 35,199.9 | 431.6 ms | 562.2 ms | 0 | Pass |
| 150,000 | 37,347.1 | 551.4 ms | 748.5 ms | 0 | Fail: p95 must be below 500 ms |

Neither run was load-generator limited. These are private measurements, not an official leaderboard score;
the maintainer's benchmark after merge determines that score. They predate the load-following window and the accept
limit.

Measured again on 2026-11-01 with those two changes, on new instances of the same types. These instances were slower
at saturation than the earlier ones, so compare within this table. Each row is a 5-minute hold at 140,000 users on the
same pair of machines, on a fresh database, alternating the two settings. Fixed 150 ms is `BATCH_WINDOW_MIN_MS=150`.

| Window | Requests/s | p50 | p95 | p99 | Errors | Verdict |
|---|---:|---:|---:|---:|---:|---|
| Fixed 150 ms | 34,975.5 | 202.6 ms | 518.9 ms | 700.4 ms | 0 | Fail |
| Follows load | 35,088.4 | 195.7 ms | 480.3 ms | 653.8 ms | 0 | Pass |
| Fixed 150 ms | 35,067.6 | 197.8 ms | 485.1 ms | 664.6 ms | 0 | Pass |
| Follows load | 35,074.5 | 194.9 ms | 483.8 ms | 660.5 ms | 0 | Pass |

The box is saturated at this load, so the window gives no extra capacity: it removes waiting below saturation. A search
from 2,000 users gave p50 15.7 ms at 2,000 users and 18.4 ms at 64,000. Its 250,000-user probe, limited by the single
load generator, held 197,952 connections without the server exiting.

The development harness commands were:

```sh
bash dev/aws/aws.sh hold submission-defaults-140k 140000
bash dev/aws/aws.sh hold defaults-no-stats-150k 150000
```

## Development

`dev/aws/aws.sh` syncs this folder to two AWS machines and runs builds, conformance and benchmarks there through the
repo's scoring scripts, with telemetry. `CONDUIT_STATS=1` makes each domain print one line of counters per second;
it's off by default. `dev/bench.sh` and `dev/profile.sh` are older single-machine equivalents. None of `dev/` runs in
a scored benchmark.

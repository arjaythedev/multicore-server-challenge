# Benchmarks

Everything in the Results section of the submission's README comes from these scripts and the raw files in `results/`.

| file | what it does |
|---|---|
| `bench.py` | one measurement: recreates the database from the seed template, restarts nothing itself, starts the server with its own `start.sh` pinned to `SRV_CPUS`, drives it with `loadgen` pinned to `LG_CPUS`, and reports requests/s, p50/p95/p99, errors, and the server's and Postgres's CPU per request |
| `run.sh` | alternating rounds over several contenders (`label=DIR[\|K=V,K=V]`), calling `PG_RESTART` before each run; prints one line per run |
| `parse_run.py` | turns one `bench.py` result into the line `run.sh` prints; flags runs the load generator limited |
| `summarize.py` | medians over rounds, for the full measurement window; skips load-generator-limited runs |
| `steady.py` | the same over the steady part of each run (drops the first `STEADY_SKIP`=5 s), from the load generator's per-second timeline |
| `pg-restart.sh` | restarts the benchmark Postgres (`PGDATA`, `PG_BIN`, `PG_CPUS`) |
| `fetch_rivals.sh`, `rivals.tsv` | fetches the other submissions at the exact PR heads that were measured, and builds them with their own `build.sh` |
| `results/` | the raw output of every run behind the tables (`*.out` = one line per run; `*.merged.json` = the load generator's merged result, with the per-second timeline) |

## Requirements

- Linux with `io_uring`, the challenge's `loadgen` (`bench/cmd/loadgen`, built from the challenge repository), Postgres 18
  with the seed database (`seed/make-seed.sh`, template `conduit_seed`), `psql`, `curl`, `taskset`, Python 3.
- The layout the results use: the server on CPUs 0 and 6, Postgres on CPUs 1–3 and 7–9, the load generator on CPUs 4, 5,
  10 and 11. On another machine, pick CPUs in the same way (the server and the database must not share a core with the load
  generator): `SRV_CPUS`, `LG_CPUS`, `PG_CPUS`.

## Reproduce the 22,000-user comparison

```bash
cd benchmarks
export LOADGEN=/path/to/loadgen RESULTS=$PWD/out PG_RESTART="bash $PWD/pg-restart.sh" PGDATA=/path/to/pgdata
export PGHOST=/tmp PGUSER=postgres          # however you reach the database
mkdir -p out
./run.sh 2 "shipped=../" "previous=/path/to/checkout-of-ed2e521/submissions/zig-iouring-harshitkhandelwal208" \
  "p47=/path/to/rust-epoll-WorriedArrow|READ_WINDOW_US=20000" | tee out/run.out
python3 summarize.py out/run.out shipped previous p47
python3 steady.py out run shipped previous p47
```

`run.sh` takes `label=DIR[|K=V,K=V]`: `K=V` pairs are environment variables for that contender only. The shipped
defaults need no variables. Rivals are built with `fetch_rivals.sh`; each row of `rivals.tsv` names the PR head that was
measured, and the script warns if that head has moved.

## The saturation probe

`bench.py` with `USERS=<n>` (the user count), `SRV_CPUS=0`, `PG_CPUS=1`, `LG_CPUS=2,3,4,5,8,9,10,11`. Above about 28,000
users, widen the ephemeral port range first (`sudo sysctl -w net.ipv4.ip_local_port_range="1024 65535"`) and restore it
afterwards; the load generator otherwise fails with "cannot assign requested address". A probe passes when `summarize.py`
shows p95 < 500 ms, p99 < 1 s, zero errors and `lg-ok`.

## What the numbers are, and are not

- Closed-loop load: each virtual user waits for a response before thinking again, so a slower server offers less load. The
  requests/s columns move with latency for that reason.
- The steady columns exclude the first 5 seconds of the window, where every submission shows the same start-up spike.
- One machine, one load generator, no official box: compare within a table, not across tables or with the leaderboard.
- The saturation probes are single rounds, so differences under about 3% are noise.

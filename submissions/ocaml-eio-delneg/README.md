# OCaml 5 + Eio (delneg)

Front: direct

| | |
|---|---|
| Language | OCaml 5.5.2, opam 2.5.0 (SHA-256 checked), opam-repository pinned to one commit in `install.sh` |
| Libraries | eio 1.6 / eio_linux 1.6 (io_uring), digestif 1.4.1 (SHA-256/HMAC), eqaf 0.10, yojson 3.0.0 (request bodies) |
| HTTP | our own HTTP/1.1 loop on Eio fibers, one `SO_REUSEPORT` listener per domain |
| Postgres driver | our own v3 wire client: extended protocol, named prepared statements, pipelined, binary rows, SCRAM-SHA-256 |
| bcrypt | the 5-lane C core from c-iouring-tigokraft (#10, MIT), cost 10, built from source |

```sh
sudo bash install.sh && bash build.sh
DATABASE_URL=... JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

No caches across requests, no schema or Postgres config changes, no host tuning. Session settings on our own
connections only: `plan_cache_mode = force_generic_plan`, `jit = off`, `max_parallel_workers_per_gather = 0`.

## Design

**Domains.** Six Eio domains on the 8 vCPU box (3/4 of the CPUs, `DOMAINS`), each with its own listener, its
own Postgres connections (8) and its own batch planner. Postgres gets the rest of the CPU.

**Connections.** A connection is a fiber that waits with `Eio_unix.await_readable`, reads into its domain's
64 KB buffer and writes the response with one `write` from the domain's output buffer. An idle connection holds
no buffer of its own, about 5 KB in all (35 KB with `Eio.Buf_read` and a per-connection output buffer, which
would have been ~7 GB at 190k connections).

**Batch planner.** Every waiting read of a domain (article, comments, profile, global/tag/author/favorited
list, feed, tags) goes into one batch, answered in two pipelined round trips on one connection. Phase A runs one
statement per kind present over arrays of distinct keys (`unnest(...) WITH ORDINALITY`). Phase B reads, once
per batch, every article phase A returned (tag ids, favorite count, author), the viewers' `favorited` and
`following` flags, and all tags in name order, so tag ids map to names without a join per article. A planner
loop sleeps 15 ms after it wakes (`PLANNER_WAIT_US`) and then takes everything queued: bigger batches cost
Postgres less per request. Feed counts use a shared proof: the followees most shared by the batch's viewers are
probed once for a 1000th article. Each response body is a closure that writes JSON straight into the output
buffer. The design is the one of our F# entry (#87), which took it from #47.

**bcrypt.** Two hasher threads (runtime released) run up to 5 hashes in lockstep. A hasher starts when 5 are
queued or the oldest has waited 100 ms; logins are about 0.1% of requests, so the wait barely shows in p99.
11.3 ms per hash with 5 lanes against 36 ms for libxcrypt on one core (local). Every hash is full cost 10 and
every login is checked against its stored hash.

**Hot path.** Requests are parsed straight from the domain's read buffer; only the leftover of a partial or
pipelined request is copied. The planner's array parameters are written as literals straight into the Bind
message, and JSON strings are escaped 8 bytes per step (a SWAR test for `"`, `\` and control bytes) with a byte
loop only around hits. Writes to Postgres go out from a per-connection off-heap buffer, with no string per batch.

**GC.** `start.sh` sets `OCAMLRUNPARAM=s=4M,o=400`: a 4M-word minor heap per domain and a lazier major GC. At
saturation about a third of the minor heap outlives a minor collection (requests wait longer than the time
between two of them), so the major GC has real work; `o=400` cut major cycles from ~13 to ~7 per 10 s and app
CPU by ~4%, for ~0.3 GB more memory (`GC_STATS=1` prints the counters).

## Numbers (local, not official)

Measured on one Ryzen 9 7900X3D box under WSL2, server and Postgres pinned to 8 logical CPUs, the loadgen on 12
others, full seed on a fresh copy for each run, `box/pg-conf.sh` for 8 cores / 16 GB. Real think time, each user its
own connection, default settings, 60 s ramp then a 180 s window (shorter than the official 5 minutes).

| users | build | req/s | p95 ms | p99 ms | app µs/req | Postgres µs/req |
|--:|---|--:|--:|--:|--:|--:|
| 60k | first version | 15,898 | 7 | 10 | 195 | 259 |
| 180k | `PLANNER_LOOPS=2` (60 s window) | 45,157 | 429 | 671 | 89 | 80 |
| 190k | current, run 1 | 47,081 | 433 | 744 | 81 | 83 |
| 190k | current, run 2 | 46,978 | 430 | 668 | 81 | 83 |

Four 190k runs of the current build so far: three passed, one failed on p99 (1,209 ms). Every run here slows down for
a few seconds right at the end of the ramp (p99 of several seconds while the last users connect), and that
moment decides the p99 of a short window.

On the same box and harness the current #1 (rust-epoll-theCatWisel) used 27 µs/req of app CPU and 92 of
Postgres at 120k users, so our Postgres side is level with it and the gap is the app.
`experiments/worklog.md` has every experiment, kept or not.

## Settings

All optional. `DOMAINS`, `PG_CONNS_PER_DOMAIN` (8), `PLANNER_LOOPS` (2 per domain), `PLANNER_WAIT_US` (15000),
`PLANNER_MAX` (1024), `PLANNER_CENTRAL=1` (one planner on domain 0: cheaper below saturation, but that domain
becomes the ceiling), `BCRYPT_THREADS` (2), `BCRYPT_WAIT_MS` (100). Diagnostics: `GC_STATS=1` (GC counters on
stderr every 10 s), `MEMPROF=<rate>` (allocation sampling with `Gc.Memprof`, top sites every 30 s).

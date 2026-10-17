# Elixir: a minimal HTTP server on `:gen_tcp` + Postgrex

**Front: direct**

No Phoenix, Plug, Bandit or Cowboy. One BEAM process per keep-alive connection, `:erlang.decode_packet` for HTTP
parsing, hand-built iodata responses, Postgrex for Postgres, `bcrypt_elixir` (NIF on dirty CPU schedulers) for passwords.

## Stack

| Piece | Version |
|---|---|
| Erlang/OTP | 28.5.0.8 (hex.pm's official Ubuntu 24.04 build, sha256-pinned in `install.sh`; amd64 and arm64) |
| Elixir | 1.19.6 (official release zip, sha256-pinned) |
| postgrex | 0.22.4 (with db_connection 2.10.2, decimal 3.2.0, telemetry 1.4.2) |
| bcrypt_elixir | 3.3.2 (comeonin 5.5.1, elixir_make 0.10.0), cost 10 |

All dependency versions and hashes are in `mix.lock`; `build.sh` runs `mix release` with `MIX_ENV=prod`.
JSON is OTP's built-in `:json` for request bodies only; responses are never encoded from maps.

## Why a custom server

- Bandit/Cowboy add a request struct, header maps, a Plug pipeline and per-connection state that a 19-endpoint JSON API
  does not need. With one connection per virtual user and ~0.26 req/s each, tens of thousands of sockets are idle almost
  all the time, so what matters is the cost of an idle connection and the cost of one request, not feature breadth.
- An idle connection here is one process (hibernated if the last request grew its heap beyond `HIB_WORDS`, default 2048
  words) plus one port. Idle connections with no pending input retain no request buffer.
- Accepting: `ACCEPTORS` (16) processes block in `accept`; each one that gets a connection spawns its own replacement and
  then *becomes* the connection process, so there is no ownership hand-off and the accept queue is always served.
- `active: true` on the socket (a client sends its next request only after our response; head and body size are capped),
  so a request costs no `setopts` calls. `decode_packet(:http_bin)` is a C BIF.

## Optimizations and why

- **Front: direct.** Nginx would cost ~11% of the box and gzips nearly every response.
- **One statement per request** (statements adapted from the reference SQL in SPEC.md): each list page and its capped count are one
  statement; slug lookups fold into the statement that needs them; follow/favorite are single CTE statements that return
  the response row; ownership-checked UPDATE/DELETE with a 403/404 probe only when no row matched. Article creation with
  tags is one transaction of two statements (insert article + sorted tag upsert; link tags + read back), without tags it
  is one statement; a deadlock/serialization failure is retried once.
- **One Postgrex pool, 1.5 connections per core** (12 on the 8-core box): reads and writes share it, because a split
  pool leaves one side's connections idle while the other side queues. `POOL` permits host-specific tuning; eight
  connections improved the four-core ARM result below. `cache_statement` names every statement, so each
  is parsed once per connection and costs one Bind/Execute/Sync round trip. Session settings in the startup packet:
  `jit=off`, `max_parallel_workers_per_gather=0`. `queue_target` is raised to 2 s so DBConnection's CoDel does not shed
  load before our own latency budget would. The server refuses to start above 95 connections.
- **Feed rows** return `following` as a constant `true`: the statement reaches each row's author through the viewer's
  follows row in the same snapshot, so the per-row EXISTS is redundant.
- **Raw timestamps**: a custom Postgrex extension returns `timestamptz` as integer microseconds; they are formatted by
  hand (truncated to ms) with no DateTime structs.
- **JSON output** is iodata built directly; strings take a `:binary.match` fast path when nothing needs escaping.
- **JWT**: `:crypto.mac(:hmac, :sha256, ...)`, `:crypto.hash_equals` for the compare, the standard header is recognised
  by string equality (any other header is decoded and must say HS256), a flat `{"sub","iat","exp"}` payload is scanned
  without a JSON parser (anything else takes the general `:json` path, so both agree). Nothing is remembered between
  requests.
- **bcrypt** runs on dirty CPU schedulers (`+SDcpu`, a quarter of the cores and at least 2), which also bounds how many
  hashes run at once; queued hashes wait in the VM's dirty-scheduler queue. Logins are ~0.1% of requests, so their
  small request share can hide authentication tail latency in overall percentiles; more hashing threads take cores from Postgres.
- **Native bcrypt compilation** uses `-O3 -fno-semantic-interposition -flto --param=max-inline-insns-auto=500 -fipa-pta`
  by default (`CFLAGS` can override it). These flags allow inlining across the NIF's C files without changing bcrypt's
  cost or source. Local qualification checked known vectors, native artifact identity and the comparison/wipe code.
  Login verification uses the first 72 password bytes to match the reference bcrypt comparison semantics; registration
  and password changes reject passwords longer than 72 bytes. Existing boundary checks include a UTF-8 character
  crossing byte 72, nonuniform prefixes, and long inputs.
- **VM flags** (`start.sh`, sized from `nproc`): normal schedulers on ~5/8 of the cores (`+S 5:5` on 8), since Postgres
  needs about as much CPU per request as we do; `+sbwt none +sbwtdcpu none +sbwtdio none` so idle schedulers sleep
  instead of busy-waiting on cores Postgres needs; `+P 2000000 +Q 1000000` because the default port limit (65536) would
  cap connections.

## Rules

- Every request reads Postgres while it is served; nothing is cached across requests (statement plans aside).
- Writes are committed before the response (the response is built from the result of the committing statement or
  transaction).
- Every token's signature, `alg`, `exp` (and `nbf` if present) are checked on every request; bcrypt cost 10 on every
  register, login and password change.
- No DDL, no server-wide settings.

## Configuration

`DATABASE_URL`, `JWT_SECRET` (required), `HOST`, `PORT`; tunables `SCHEDULERS`, `DIRTY_CPU`, `POOL`, `ACCEPTORS`,
`HIBERNATE`, `HIB_WORDS`.

## Tests

`mix test` (ExUnit, no database needed): JWT, query-parameter validation, JSON escaping, timestamp formatting,
HTTP header/body limits, fragmented requests and pipelined keep-alive requests.

## Existing local evidence

Host: MacBook Pro M1 Pro (10 cores, 32 GB), running a Lima Ubuntu 24.04 arm64 VM (10 vCPUs, 16 GB), PostgreSQL 18
and the full seed (500k articles, 100k users). These are local experiments, not an eight-core x86_64 challenge score.

- The saved native-build qualification log records `mix test`: 11 tests, zero failures. Its build log uses the native
  compiler flags above; the deployment checked the stripped NIF against the independently tested candidate.
- An earlier build has a saved conformance summary: 197 steps, 197 passed, zero failed. Later dev/full database
  checks each saved a 197-step transcript; those transcripts do not include the pass/fail summary.
- These validation and performance artifacts predate the final FEED-only `following = true` rewrite. The earlier
  results are not a claim of final-revision qualification; a later local load rerun is documented below.

Local performance run `eba_20261017T075317Z` used the optimized bcrypt candidate with server plus Postgres on
vCPUs 0-3 and four Linux load-generator processes on the remaining six vCPUs, over loopback. CPU isolation was
local harness setup; the submission performs no pinning. Each probe used 60 s ramp + 60 s measured + 15 s tail:

| Users | req/s | p50 / p95 / p99 (ms) | Errors | Result |
|---:|---:|---:|---:|---|
| 24,000 | 6,393.3 | 1.0 / 3.5 / 7.0 | 0% | PASS |
| 32,000 | 8,298.2 | 88.3 / 231.2 / 276.5 | 0% | PASS |

Both probes reported `lg_limited: no` and `behind=false`. No five-minute hold or failing upper bound was established
by these two probes. They describe the archived pre-FEED-rewrite build, not a measured ceiling for the final source.

## Revision 87280d7 local rerun

Revision `87280d7` was rebuilt with the submitted compiler flags and tested on the same arm64 lab VM on
2026-10-17 (run `elx87280d7_linux_20261017T103243Z`). Elixir and Postgres shared vCPUs 0-3; four Linux load
generators ran on vCPUs 4-9 over separate loopback addresses. Each probe used a 60 s ramp, 60 s measured window
and 15 s tail, after a 300-user warmup on a fresh full-seed database clone.

| Users | req/s | p50 / p95 / p99 (ms) | Errors | Result |
|---:|---:|---:|---:|---|
| 24,000 | 6,409.7 | 0.9 / 8.0 / 28.6 | 0% | PASS |
| 32,000 | 7,762.5 | 384.8 / 465.7 / 497.7 | 0% | PASS |

All four generators reached their expected user counts, completed matching measurement windows and reported
`behind=false`; both merges reported `lg_limited: no`. The 32k p95 is close to the 500 ms threshold. These short
four-vCPU arm64 probes establish neither a five-minute score nor an eight-core x86_64 capacity limit.

## Subsequent robustness validation

The cumulative 16 KiB request-head limit and startup initialization of the database-outage log limiter passed
19 unit tests and the official 197-step conformance suite on both development and full seeds, on the pinned
Elixir/OTP toolchain. Header-limit tests distinguish body bytes and subsequent pipelined requests from headers.

Run `elx_matched2048_20261017T114653Z` tested these changes with the original runtime settings: three normal
schedulers, six database connections and `HIB_WORDS=2048` on the four-vCPU server/Postgres slice. It restored the
earlier phase sequence: 300-user warmup, 24k probe, 70 s cooldown, then 32k probe. Probe shape remained
60 s ramp + 60 s measured + 15 s tail.

| Users | req/s | p50 / p95 / p99 (ms) | Errors | Result |
|---:|---:|---:|---:|---|
| 24,000 | 6,488.9 | 1.0 / 49.3 / 90.9 | 0% | PASS |
| 32,000 | 7,267.6 | 593.9 / 1,476.6 / 1,647.6 | 0% | FAIL |

All generators reached their expected user counts and reported `behind=false`; both merges reported
`lg_limited: no`. The earlier 32k pass was not reproduced. Smaller scheduler/pool counts and a higher hibernation
threshold also failed the 32k latency criteria, so runtime defaults remain unchanged. These local observations
do not establish a five-minute score or isolate the reason for the difference between runs.

## Local database-driver comparison

An archived experimental source snapshot tested Postgrex 0.22.4, PGO 0.20.0 and epgsql 4.8.0 / Poolboy 1.5.2
behind `Conduit.Db`. The alternative adapters, selector and dependencies were subsequently removed; the submission
uses Postgrex only. All three experimental configurations passed 19 unit tests,
the official 197-step conformance suite on both development and full seeds, and a single-connection database
check covering duplicate-insert rollback, commit, NULL decoding, connection reuse and forced-backend recovery.
The recovery check requires a successful termination and a different backend PID afterwards.

Runs `elx_driver_{postgrex,pgo,epgsql}_20261017` used fresh full-seed clones, the four-vCPU server/Postgres slice,
three normal schedulers, six connections and `HIB_WORDS=2048`. Each used the same 300-user warmup → 24k →
70 s cooldown → 32k sequence, stopping at the first failed probe, with 60 s ramp + 60 s measured + 15 s tail.
Shared workload IDs gave matching random seeds; closed-loop timing can still change the executed requests.

| Driver | Users | req/s | p50 / p95 / p99 (ms) | Result |
|---|---:|---:|---:|---|
| Postgrex | 24,000 | 6,469.5 | 1.0 / 8.1 / 37.8 | PASS |
| PGO | 24,000 | 5,371.6 | 675.8 / 1,157.1 / 1,193.0 | FAIL |
| epgsql | 24,000 | 6,471.9 | 1.1 / 12.9 / 45.3 | PASS |
| Postgrex | 32,000 | 7,681.2 | 476.4 / 570.4 / 610.8 | FAIL |
| PGO | 32,000 | — | — | Not run after 24k failure |
| epgsql | 32,000 | 7,371.6 | 666.6 / 876.5 / 950.8 | FAIL |

All completed probes had zero errors and healthy generators. Neither tested alternative improved on Postgrex,
which remains the submitted driver. These are single local screening runs, not repeated trials or five-minute scores.

PGO's parameter-type cache does not retain named prepared statements: it sends an unnamed Parse per query.
Its 24k PostgreSQL CPU averaged 203.5% versus Postgrex's 142.2% (100% is one core), while BEAM CPU was similar;
the PostgreSQL log showed no maintenance overlap. Parsing/planning overhead is a plausible contributor, but
planning time was not measured. epgsql caches parsed statement records per connection; its adapter adds a
serialized worker hop, a fixed Poolboy pool and an operation watchdog. Queue/deadline behavior differs from
DBConnection, so this compares complete adapters rather than isolating their protocol encoders.

Both 32k measurements overlapped similarly timed comments autovacuum. epgsql used 481.8 MiB average BEAM RSS
versus Postgrex's 403.6 MiB, with 4.0% lower throughput and 53.7% higher p95. The control's normal schedulers
averaged about 36.6% runnable CPU wait; BEAM and PostgreSQL together used about 3.49 of the four shared cores.
Shared CPU contention and request-stage queueing remain better diagnostic targets than an unproven driver swap.

Reconstructing starts minus completions from the control's one-second snapshots estimates about 3,383 outstanding
requests on average at 32k, versus about 33 at 24k. Throughput multiplied by mean response time independently gives
about 3,390 at 32k. Snapshot counter updates can arrive late, so these are approximate HTTP backlog estimates,
not measured database checkout queue lengths. Postgrex binary row decoding happens while the connection is leased;
PostgreSQL backend idleness therefore does not prove a free connection. The missing discriminating measurements
were checkout wait, leased-operation time, ready connections and actual pool queue length; the subsequent experiment
below measured them.

### Isolated 32k candidate tests (2026-10-17)

Five candidates were implemented in an isolated laboratory snapshot and tested separately. Every arm used a fresh
full-seed database, the same workload seed, a 300-user warmup, then 32,000 users with a 60-second ramp and a
120-second measurement. Server and PostgreSQL shared four ARM cores; four Linux generators used six other cores.
Reference settings were three normal schedulers, two dirty CPU schedulers, six connections and `HIB_WORDS=2048`.
Profiling was enabled uniformly for the candidate screens and both controls.

| Profiled arm | req/s | p95 / p99 ms | Verdict |
|---|---:|---:|---|
| Reference, before | 7,230.4 | 1,005.1 / 1,041.9 | FAIL |
| Normal-scheduler I/O polling off | 7,466.7 | 838.1 / 997.9 | FAIL |
| One dirty CPU scheduler | 7,721.4 | 470.5 / 513.3 | PASS |
| Eight connections | 8,034.5 | 476.9 / 510.5 | PASS |
| Two pools, three connections each | 7,643.9 | 624.1 / 720.4 | FAIL |
| Feed enrichment batched by page | 7,696.3 | 532.5 / 567.8 | FAIL |
| Reference, after | 7,616.2 | 596.5 / 675.3 | FAIL |

All runs had zero errors and healthy generators. The first reference averaged 648.6 ms waiting for a connection
within 649.4 ms of handler time. All 120 pool snapshots had zero ready connections; the checkout queue averaged
4,672 requests while the pool mailbox averaged fewer than one message. Eight connections reduced sampled checkout
wait to 200.3 ms. This identifies connection acquisition as the immediate waiting location, without proving that
pool-manager processing alone causes the backlog. Binary row decoding remains part of the leased operation.

Profiling and run variation limit these screens: the unprofiled calibration achieved p95 428.8 ms, and the two
unchanged profiled controls differed by 40.7% in p95. PROFILE timestamps also drifted relative to monotonic time
(up to 544 ms over a run); stage attribution uses approximate neighboring snapshot intervals. These diagnostics
do not replace the load generator's elapsed-time latency measurements.

Eight connections were selected for an unprofiled confirmation because they combined similar screening p95 to
one dirty scheduler with higher throughput, lower average wait and better login latency. A fresh five-minute
32k baseline/candidate pair changed only `POOL=6` to `POOL=8`:

| Unprofiled, 300 seconds measured | req/s | p95 / p99 ms | Verdict |
|---|---:|---:|---|
| Six connections | 7,671.4 | 557.6 / 734.7 | FAIL |
| Eight connections | 8,067.6 | 367.4 / 401.7 | PASS |

Both had zero errors and healthy generators. Eight connections improved p95 by 34.1% and throughput by 5.2% in
this pair. The measured configuration is:

```sh
POOL=8 SCHEDULERS=3:3 DIRTY_CPU=2 HIB_WORDS=2048 ./start.sh
```

Use it when server and PostgreSQL share four cores as tested. The general pool default remains 1.5 connections per
core; this experiment does not establish an eight-core optimum or an official x86 challenge score. Laboratory
profiling, pool sharding and combined tag/favorite batching were not part of that snapshot. Correctness gates passed 19 unit
tests, live transaction/reconnect contracts, and official conformance 197/197 on both dev and full seeds.

The exact submission artifact then passed 19 unit tests and conformance 197/197 on each seed with `POOL=8`.
Its separate uninstrumented 32k run, measured for 300 seconds, achieved 8,042.3 req/s, p95 401.7 ms and p99
457.7 ms with zero errors and healthy generators. Latency kept rising: successive minute medians of the
one-second p50 samples increased from 78.8 to 361.2 ms, and the final second's p95 was about 488 ms.
This is a five-minute passing point with limited late-run margin, not proof of a stable capacity ceiling.

### Three-change package (2026-10-17)

The local candidate combines tags-only feed-page aggregation, selective hibernation, and one dirty CPU scheduler
with the existing eight-connection profile. In inspected ten-article feed plans, aggregation scanned the 200-row tags
table once instead of ten times; exact favorite counts and viewer checks retained their original indexed plans. Hibernation skips partial
request buffers and queued socket input. The candidate runtime settings are explicit; general defaults remain unchanged:

```sh
POOL=8 SCHEDULERS=3:3 DIRTY_CPU=1 HIB_WORDS=2048 ./start.sh
```

The exact candidate passed 19 unit tests, official conformance 197/197 on both dev and full seeds, and 16 SQL
result/order equivalence checks. Generic plans preserved bounded article-tag probes and saved 18 shared-buffer hits
per sampled feed query; all 25 non-feed SQL strings and statement names remained unchanged.

A fresh unprofiled pair used the same workload seed, full-seed clones, four shared server/Postgres cores, and 32k
users with 300 seconds measured after a 60-second ramp and 300-user warmup:

| Configuration | req/s | Mean ms | p95 / p99 ms | Errors | Verdict |
|---|---:|---:|---:|---:|---|
| Control: eight connections, two dirty schedulers, original SQL/hibernation | 8,134.1 | 166.3 | 310.5 / 369.9 | 0 | PASS |
| Combined three changes | 8,237.1 | 117.1 | 304.1 / 358.9 | 0 | PASS |

Both had healthy generators. The package increased aggregate throughput by 1.3% and reduced p95 by 2.1%, but its
early latency advantage largely disappeared: final-minute throughput was 7,851 versus 7,839 req/s, and the median
of per-second p50 samples was 267.8 versus 266.1 ms. Login p95/p99 worsened from 388/449 to 413/507 ms despite
lower mean login latency. Memory remained comparable. This single pair establishes a passing combined candidate,
not a durable capacity gain or an improvement in every metric; it cannot attribute effects to individual changes.

### Confirmed local concurrency boundary (2026-10-17)

The same three-change source was tested with Postgrex, the explicit four-core profile below and profiling disabled:

```sh
POOL=8 SCHEDULERS=3:3 DIRTY_CPU=1 HIB_WORDS=2048 ERL_AFLAGS='+IOs true' ./start.sh
```

Server and PostgreSQL shared four ARM VM CPUs; four Linux generators shared six other CPUs. Each point used a
fresh full-seed clone, a 300-user warmup, then a 60-second ramp, nominal 300-second measurement and 15-second tail.
Native pass criteria were p95 < 500 ms, p99 < 1,000 ms and errors < 1%.

| Users | req/s | p95 / p99 ms | Errors | Verdict |
|---:|---:|---:|---:|---|
| 40,000 | 7,944.87 | 1,595.391 / 1,647.615 | 0 | FAIL |
| 36,000 | 8,104.10 | 892.927 / 934.911 | 0 | FAIL |
| 34,000 | 8,104.07 | 660.991 / 702.975 | 0 | FAIL |
| 33,000 | 8,229.92 | 443.135 / 496.383 | 0 | PASS |
| 33,000, fresh confirmation | 8,103.53 | 474.111 / 527.359 | 0 | PASS |

All four generators reached the full user counts and reported healthy pacing. This establishes **33k as the highest
passing tested point, with a 33k PASS–34k FAIL bracket**, for this nominal-five-minute profile. The 64k probe also
failed: p95 4,003.839 ms, p99 4,005.887 ms and 12.5384% errors, mostly HTTP503 checkout-queue drops; transaction
checkout exceptions also surfaced as HTTP500. Total throughput there included rejected requests.

The confirmation had only 25.889 ms p95 margin. Its median per-second p95 rose from 240.575 ms in the first minute
to 473.343 ms in the last; the result does not establish indefinite sustainable capacity. VM wall-clock corrections
also limit throughput precision: measurement bounds and timeline bins use wall time, while per-request latencies
use monotonic elapsed time. RPS uses the nominal 300-second denominator; exact scored monotonic duration was not
recorded. These are local four-core ARM results, not an official eight-core x86_64 challenge score. General runtime
defaults remain unchanged.

# Nish / standard library

Front: direct

An update of this submission, scored at 91,000 users in #83 (`3de991e`) and
100,000 in #116 (`6e69d72`), on the same design. Since #116, most of it to
cut what Postgres spends a request: favorite counts leave `plan_meta` for a
count lane of their own, an idea of this submission's (below); two HTTP
workers instead of four, for read plans twice the size; feeds share their
followees within a plan; Nish 0.29.0 reads an article's tag ids and the
plan's batches in binary, and runs bcrypt at the width the CPU likes best;
each answer turns delayed ACKs back on for its connection; and a sign-up's
hash waits 20 ms for company instead of 160.

Since #83: the profiles go through the read plans too, the favorites are
folded into them, logins go to bcrypt services in their own processes, every
connection sets `enable_memoize=off`, the viewers' flags are sent as one id
array per viewer, a quarter of the CPUs serve HTTP (two on the box, each with a bigger
read queue than four could have, where #83 ran
two), and Nish 0.23.1 no longer sweeps every idle connection on every turn of
the loop.

Nish 0.29.0 (a statically typed TypeScript subset compiled to native code
through LLVM), built with clang-18 and lld-18 from LLVM 18, against
PostgreSQL 18. The compiler runs on Node.js 22.18.0 at build time only; the
server is one native binary with no runtime dependency beyond libc. Every
import is Nish's own standard library: `nish/net/http1-server` for HTTP/1.1,
`nish/net/postgres` for the PostgreSQL wire protocol (with its array
parameters and its `PgBatcher`), `nish/json`, `nish/crypto/hmac` and
`nish/crypto/bcrypt`. No third-party package is used.

```sh
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

The server needs Nish 0.29.0: 0.26.0 brought binary result columns to
`nish/net/postgres` (`bindStartBinary`, `binaryInt`, `PgBinary`) and
`TCP_QUICKACK` to `netSetOption`, and 0.27.0 the binary `PgBatcher`
(`PgBatchConfig.binary`), `PgBinaryArray` for an integer array column, and
`setNice` and `setIdlePriority` in `nish:process`, and 0.28.0 `bcryptHashN`,
`bcryptVerifyN` and `bcryptCalibrate`, and the policy in
`nish/net/http-compress`. 0.23.1's
`nish/net/http1-server` no longer sweeps every connection on every turn of
the loop (below). 0.23.0 was the
first published release with the `nish/net/postgres` array parameters built in the Bind (`arrayStart`,
`arrayElement`, `arrayInt`, `paramIntArray`) and the `PgBatcher` it uses
(0.22.1 brought `PreforkConfig.restart`, `Http1Config.idleInput` and
`TCP_NODELAY` on `tcpConnect`); `install.sh` installs it from npm. To try an
unreleased build instead, set `NISH_PACKAGES` to the `npm pack` tarballs of
the compiler and its platform package.

## Design and optimizations

- **Processes.** A prefork parent starts the HTTP workers and the bcrypt
  services (a quarter of the CPUs and half of them, at least two each: two
and four on the box), and
  restarts none of them. Each HTTP worker binds `HOST:PORT` with `SO_REUSEPORT` and
  `TCP_NODELAY`, and runs one epoll loop over its listener, its keep-alive
  connections, its PostgreSQL connections and its connection to each bcrypt
  service. Nothing is shared between workers.
- **Direct HTTP/1.1** with a sans-IO parser. Request and head buffers are
  lent to a connection while it reads and taken back while it is idle, so an
  idle keep-alive connection costs about 1.1 KiB of server memory. A busy
  PostgreSQL socket is re-armed in epoll only when its interest changes.
- **Idle sweep.** In Nish 0.23.0, the gate of the server's sweep of idle
  connections (`expire`) counted a head clock that had not started from a
  connection's last move, so while any keep-alive had been quiet past the
  30 s head timeout, which a few hundred of a worker's always are, every
  turn of the loop walked every connection: at 120,000 users `perf` put that
  loop at about 13% of the box, a third of the server's CPU. Sweeping once a
  second took the VM from 120,000 users to 140,000; Nish 0.23.1 fixes the
  gate itself ([amritk/nish#978](https://github.com/amritk/nish/pull/978)),
  so the loop calls `expire` every turn again.
- **PostgreSQL.** Per worker, three read connections and one write
  connection. Every statement is prepared once per connection, with
  `plan_cache_mode=force_generic_plan`, `jit=off`,
  `max_parallel_workers_per_gather=0` and `enable_memoize=off` set as session
  options in the startup packet (no server configuration is changed). The
  generic plan put a Memoize on the comment authors' lookup whose cache is
  emptied every execution (2 hits in 351): the comments statement ran 7–12%
  slower with it. A group is pipelined
  Bind/Execute messages and one Sync, and up to 16 groups are pipelined on
  each connection. A read plan's article rows and its batches come back in
  binary (`bindStartBinary`): ids, counts and times as they are stored, and
  an article's tag ids as an `int4[]` that `PgBinaryArray` walks in place,
  rather than text the server parses back.
- **Read plans.** Postgres is what the challenge's box runs out of, so the
  reads are planned to cost it as little as possible. Every list page (the
  global list, a tag, an author, a user's favorites), every feed, every
  article and its comments by slug, every profile by username, and the tag
  list wait together for the
  worker's next read plan, which answers all of them from a few statements
  over arrays of their distinct keys, in two pipelined groups
  (`src/plan.ts`):
  1. **Group A** finds what each request is about. Each kind of list present
     is one statement, which answers every distinct page (filter, key,
     limit, offset) once, as an array of article ids and one of their
     authors, and every distinct capped count once. Identical requests are
     one page: the global list has five pages a user clicks, and most of a
     plan's global requests read page one. The articles and the comments by
     slug, and the profiles by username, go through nish's `PgBatcher`, each
     distinct key one key of one execution over `unnest($1) WITH
     ORDINALITY`, its rows routed back by ordinal. Every tag is read once,
     by name.
  2. **Group B** reads the rest once for the whole plan: the columns of the
     union of every article group A returned (lists, feeds and article
     pages alike: an article on the first global page, a tag page and an
     article page is read once), and the viewers' `favorited` and
     `following` flags (a profile's too), each viewer's in one index range
     scan over its ids (`= ANY(...)`) rather than one probe per article. The
     plan sends them grouped by viewer, the distinct viewers as one array and
     each viewer's ids as one array, so Postgres does not regroup (viewer, id)
     pairs. An article's tags
     come as ids and are named and ordered from group A's one read of every
     tag.

  Each request is then written from those rows: an article is encoded to
  JSON once a plan, cut where its body and its two flags go, and copied into
  every answer that holds it. A plan that fails sends its requests again
  alone, with the SQL below, where each answers its own error; an article
  group A found and group B did not (deleted in between), or whose slug
  changed in between, is read alone too.

  Nothing outlives its plan: every value in an answer was read from
  Postgres while that request waited, and a plan takes only the requests
  already waiting when it starts.
- **Batch clock.** A plan starts when 256 reads wait (a full plan) or when
  the oldest has waited 10 ms, and up to three are in
  flight per worker (one a read connection). Started at once instead, a plan is whatever arrived
  during the last one's two round trips, about 17 requests at the load
  measured below, and Postgres pays its fixed costs and reads the same
  articles again plan after plan. The window makes plans of about 60
  requests there: it cost about 12 ms of p95 and saved about a fifth of
  Postgres's CPU per request (measured below). The busier the server, the
  sooner a plan fills and the less the window holds a read.
  `READ_PLAN_CLOCK=2` makes the clock adaptive: a worker that sees fewer
  than `READ_PLAN_LIGHT` (32) planned reads a window starts a plan at once
  while none is in flight, and gathers for the window above that, so a
  quiet server answers in a couple of milliseconds instead of ten.
  On the VM below at 120,000 users, 20, 30 and 40 ms windows took Postgres
  from 149 µs a request to 135, 129 and 128, and p95 from 43 ms to 57, 67
  and 74. At 145,000 users, past the knee, 30 ms saved nothing (206 µs a
  request against 208) and p95 was worse, so the window stays at 10 ms.
- **The count lane.** A favorite count walks the article's index entries,
  and the heap of any page writes have touched, so unlike the rest of an
  article it costs by the row: taking the column out of `plan_meta`, to
  measure it, took Postgres from 124 µs a request to 95 at 120,000 users on
  the VM, and p99 from 199 ms to 57. Popular articles are on the pages of
  plan after plan: at 145,000 users, 54% of the entries a plan counted had
  been counted for the same article in the 30 ms before. So each worker runs
  one `plan_counts` at a time, over the union of the articles of every plan
  waiting when it starts, each counted once; the plans stay concurrent and
  only the costly column queues. A run is fixed as it is bound, so every
  count is read after the requests it answers arrived, and it keeps nothing
  once its plans have their counts: this is a batch, not a cache.
- **Two HTTP workers.** Each worker has its own read queue, so fewer workers
  make bigger plans. At 120,000 users on the VM, Postgres spent 150 µs a
  request with four, 129 with two and 117 with one, which ran out of core.
  Each worker has six read connections and up to ten plans in flight; eight
  connections in all left p95 at 400-600 ms at 155,000 users, and six or four
  stop near 37,000 and 29,000 requests a second with CPU to spare.
- **Feeds in a plan.** Followees several viewers of a plan share are looked
  at once: one with 1,000 articles proves its followers' count without a
  count, and the depth-th newest article of one is a floor that stops every
  other followee's walk. The rows matched the old statement on 40 random
  batches of the full seed, and total CPU fell by about 6 µs a request.
- **Delayed ACKs.** A request's answer is often sent within the 40 ms the
  kernel waits to ACK it alone, but a socket with `TCP_NODELAY` drops back
  to quick ACKs. After each answer the worker sets `TCP_QUICKACK` off on
  that connection again, so the next request's ACK can ride on its answer.
  On the VM it cut the server's packets out per request by 5–7%; the
  single CPU that takes the network interrupts is what the box runs out of
  first.
- **Durable group commit.** While a batch is in flight on the write
  connection, the writes that arrive wait. Then up to 128 of them go as one
  group: one transaction, one commit, and one WAL flush. Each response is
  sent after that group's ReadyForQuery. No timer holds a write: an idle
  server sends one at once. A failed batch rolled back every write in it, so
  each write is sent again alone. A write whose connection is lost may have
  committed, so it answers 500 and is never sent again. A batch's favorites
  and unfavorites are one statement of each kind over their (viewer, slug)
  pairs; a viewer with two toggles in one batch keeps its own statements, so
  its toggles stay in order. Once the batch has committed, each toggle's
  article is read by the next read plan, like an article page, rather than
  alone on the write connection: at 140,000 users on the VM that cut p95 by
  about a fifth (183–204 ms against 234–274 ms) at the same CPU per request,
  since the one write connection a worker has no longer waits on full
  article reads between its batches.
- **SQL.** A read plan's statements answer what SPEC.md's reference SQL
  answers, request by request (`src/sql.ts`): a page is the same ids in the
  same order, a count the same capped count (the global one walks the
  primary key from its oldest end, an index-only scan, for the same
  `min(articles, 1000)`), and an article the same columns. A read sent
  alone runs the reference SQL, with four changes that keep its answers:
  - A list page is cut in a subquery before its article metadata is computed.
  - A tag name is a primary-key lookup per tag, not a join that scans every
    tag for every article.
  - The tag list is one `ARRAY(...)` row.
  - An article's comments come in one `LEFT JOIN LATERAL` statement.

  A lookup followed by a write runs as one data-modifying `WITH`, or as two
  statements of one group.
- **Rows straight into JSON.** Result columns are read in place from the
  receive buffer. Articles are written from pre-encoded keys with block
  copies, text arrays are copied whole when they need no escaping, and no
  string is made per row. A read plan encodes each article and each comment
  once, and each answer is block copies of them with its viewer's flags.
- **Tokens.** HS256 over an HMAC keyed once with `JWT_SECRET`: each
  signature copies the two keyed states. The signature, algorithm and
  expiry are checked on every request. Nothing is cached between requests.
- **bcrypt.** Cost 10, with salts from the CSPRNG. Each bcrypt service
  batches up to four hashes or four checks into one four-lane bcrypt call,
  after a collection window of up to 160 ms for checks (logins) and 20 ms
  for hashes (sign-ups, which a 160 ms window kept waiting for company that
  rarely comes). A worker sends a login to the
  service whose batch is closest to full, else the least busy, so batches
  fill before another service is given work. With Postgres keeping every
  core busy, one process got a share of a core too small for the logins:
  at 8,000 users on 4 CPUs (below), login p95 was 1.3 to 1.9 s with one
  service and 0.5 s with two, and one run with one service timed out a
  fifth of its logins. A service a worker cannot reach is given no logins
  while another is up, and is tried again once a second. Passwords are
  wiped once sent and once hashed.

Every request reads PostgreSQL, and there are no result, token or password
caches. There are no schema or configuration changes, no CPU affinity and no
host tuning.

Optional process settings, with their defaults: `HTTP_WORKERS` (a quarter of the
CPUs, at least 2),
`DB_READ_CONNS` (6) and `DB_WRITE_CONNS` (1) per worker, `DB_MAX_IN_FLIGHT`
(16), `DB_READ_PLANS` (10) read plans in flight per worker,
`READ_PLAN_WAIT_US` (10000) and `READ_PLAN_MIN` (512) for the batch clock,
`READ_PLAN_CLOCK` (1; 0 starts a plan at once while none is in flight, 2
is adaptive) and `READ_PLAN_LIGHT` (32), `BCRYPT_WORKERS` (half the CPUs,
at least 2), `BCRYPT_BATCH_MS` (160) and `BCRYPT_HASH_MS` (20),
`BCRYPT_WIDTH` (unset, timed at startup; 1 to 6 lanes a call),
`GZIP` (0; 1 when it saves a TCP segment, 2 whenever it saves anything; at
145,000 users on the VM it cost about 30 µs a request and failed the hold),
`GZIP_MIN` (1300),
`BCRYPT_NICE` (unset; 1 to 19 lowers the bcrypt services' priority with
`setNice`, `idle` moves them to `SCHED_IDLE`; it measured within the spread
between runs, so it stays off), `BCRYPT_PORT` (47391, loopback; the
services listen on it and the ports above), `ACK_DELAY` (1; 0 leaves the
kernel's ACKs alone) and `IDLE_TIMEOUT_MS` (75000). On the box's 8 CPUs that makes 16 PostgreSQL
connections in all, inside the limit of 95.

## Measured

These figures are local, not official scores. They come from a 4-core
container (Intel Xeon at 2.10 GHz, 16 GB) shared by the server, PostgreSQL
18 (configured by `box/pg-conf.sh` for those 4 cores) and the challenge's load
generator, which competes with both for the CPU. Each run starts a build on
a fresh copy of the full seed, warms it up for 20 s with a quarter of the
users, ramps for 15 s and measures 40 s, at `-think-scale 0.1` (4,000 users
make about the requests of 40,000). CPU is the user and system time, from
`/proc`, of every PostgreSQL process and every server process over the
measured window, divided by the requests completed in it; statements are
from `pg_stat_statements`. Before is this submission as first opened,
rebuilt with Nish 0.23.0; it and the new build alternate, run after run.

| 4,000 users, 3 pairs | req/s | p95 | p99 | errors | Postgres CPU / req | app CPU / req | statements / req |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| before | 10,338–10,356 | 22–23 ms | 36–42 ms | 0 | 221–225 µs | 61–62 µs | 1.04 |
| after | 10,128–10,211 | 28–29 ms | 36–40 ms | 0 | 130–134 µs | 65–68 µs | 0.29 |

At 6,000 users the box runs out of CPU, and the build before with it: its
p95 grows tenfold, while the read plans serve 17% more requests with a
quarter of its p95.

| 6,000 users, 2 pairs | req/s | p95 | p99 | errors | Postgres CPU / req | app CPU / req | statements / req |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| before | 12,609–12,641 | 204–216 ms | 338–339 ms | 0 | 185–186 µs | 59–60 µs | 0.78 |
| after | 14,674–14,756 | 54–60 ms | 71–83 ms | 0 | 113–116 µs | 56–58 µs | 0.24 |

The most users each holds, stepping up 1,000 at a time (30 s ramp, 60 s
measured, the challenge's pass rule: p95 < 500 ms, p99 < 1 s, errors < 1%):

| Users | Before | After |
| ---: | --- | --- |
| 6,000 | pass, 12,265 req/s, p95 246 ms | pass, 14,640 req/s, p95 62 ms |
| 7,000 | **fail**, 12,116 req/s, p95 562 ms | pass, 16,348 req/s, p95 102 ms |
| 8,000 | | pass, 17,791 req/s, p95 136 ms |
| 9,000 | | pass, 18,704 req/s, p95 188 ms |
| 10,000 | | pass, 19,468 req/s, p95 236 ms |

The build before holds 6,000 and fails at 7,000; the read plans hold
10,000, the most tried, at about 100 µs of Postgres CPU a request. At 1,000
users, far from any limit, the batch clock shows: p95 is 14.5 ms against
1.7 ms before, and Postgres CPU per request 192 µs against 326 µs.

Each step, on the same load, by Postgres CPU per request (the spread of
two or three pairs against its own control):

| Step | Postgres CPU / req |
| --- | ---: |
| Before | 219–222 µs |
| Articles and comments by slug through `PgBatcher` (no change meant) | 220–222 µs |
| Lists and feeds in read plans | 186 µs |
| Articles, comments and the tag list in them too | 165–166 µs |
| The batch clock, 10 ms | 128–130 µs |

A 20 ms window measured 120 µs, at 37 ms p95. The app's CPU includes the
bcrypt service, 26–31 µs a request. The app's share grew by about 5 µs: a
plan hashes its keys and copies each answer together from the articles it
encoded once. Each read plan allocates about 1 MiB of buffers once (three
per worker); server memory per idle keep-alive connection is unchanged,
1.13 KiB as measured before at 15,000 connections. All 197 conformance
checks pass on the dev seed. A concurrency check makes 339 distinct reads
(articles and comments with and without a viewer, slugs that match nothing
or that Postgres refuses, the tag list, every kind of list and feed, with
known and unknown keys), one at a time and then 13,560 at once in a
shuffled order: every answer matches its serial one byte for byte, and
every serial answer matches the build before byte for byte, in about 4,600
statements where the build before took about 17,200.

### Since the first submission (#83, 91,000 users)

Same method and container as above, two runs of each, the build #83 was
scored at (`3de991e`) against this one, both at their defaults:

| Users | Build | req/s | p95 | Postgres CPU / req | statements / req |
| ---: | --- | ---: | ---: | ---: | ---: |
| 4,000 | #83 | 10,185–10,232 | 25–26 ms | 123–129 µs | 0.29–0.30 |
| 4,000 | this | 10,186–10,200 | 25 ms | 119–120 µs | 0.25 |
| 8,000 | #83 | 18,389–18,564 | 104–107 ms | 100–101 µs | 0.21 |
| 8,000 | this | 18,201–18,897 | 81–113 ms | 98–103 µs | 0.15 |

Profiles in the read plans and the folded favorites take a quarter of the
statements off; what that saves Postgres is within the spread between runs
at 8,000 users. The bcrypt services are what changed the logins (above).
At 1,000 users the adaptive clock (`READ_PLAN_CLOCK=2`) took p95 from 14 ms
to 2–3 ms, at twice the Postgres CPU per request while the box was idle;
under load it measured within the spread of the fixed clock, which stays the
default.

### On a VM like the challenge's box (not official)

Latest, 5-minute holds on the same VM with the official pass rule, from one
load box over four source IPs. Past about 32,000 connections per source IP
the box's own `connect` walked the kernel's port range under a lock, which
stalled it for 8 to 24 seconds around the end of the ramp in every hold above
145,000 users, the top entry's too. The load generator here now gives each
user a fixed source port; the server is not involved, and these holds ran
with that fix and no stall:

| Build | Users | Verdict | req/s | p95 | p99 | Errors | µs a request (Postgres + server) |
|---|--:|---|--:|--:|--:|--:|---|
| before this update | 165,000 | FAIL | 37,407 | 1,750 ms | 2,322 ms | 0.00% | 138 + 74 |
| this one, two holds | 165,000 | PASS, PASS | 42,310-42,402 | 230-254 ms | 379-389 ms | 0.00% | 113 + 62-63 |
| this one, two holds | 175,000 | PASS, FAIL | 43,335-43,366 | 491-514 ms | 562-735 ms | 0.00% | 109 + 64 |
| this one | 190,000 | FAIL | 42,984 | 984 ms | 1,072 ms | 0.00% | 108 + 68 |

Nish 0.29.0 alone measured the same as 0.28.0. Gzip
(`GZIP=1`, `nish/net/http-compress`) cost about 30 µs a request and failed its
holds at 145,000, and stays off.

The challenge's own `loadgen search` (warm-up, doubling probes, bisection to
5%, 5-minute holds; the official pass rule) against an 8-vCPU Intel Xeon
Platinum 8260 VM with 16 GB running PostgreSQL 18 and the server, from a
separate 24-vCPU load box over the public network. The database is reset from
the seed and Postgres and the server restarted before each search. The
build #83 was scored at, `3de991e`, held 90,000 users there against its
official 91,000 (23,031 req/s against 23,401; the same CPU split, server 33%
and Postgres 47%), so the VM reads about 1% low.

| Build | Settings | Held users | req/s | p95 | p99 | CPU server / Postgres / box |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| `3de991e` (#83) | its defaults | 90,000 | 23,031 | 394 ms | 702 ms | 33% / 47% / 81% |
| `40b375e` | `HTTP_WORKERS=2` | 100,000 | 25,241 | 449 ms | 553 ms | 34% / 48% / 83% |
| `40b375e` | `HTTP_WORKERS=3` | 110,000 | 28,224 | 250 ms | 313 ms | 39% / 57% / 96% |
| `40b375e` | `HTTP_WORKERS=4`, three searches | 110,000–120,000 | 28,401–30,483 | 184–419 ms | 232–513 ms | 39% / 58% / 97–98% |
| `40b375e` | `HTTP_WORKERS=5` | 120,000 | 30,055 | 446 ms | 612 ms | 38% / 59% / 98% |
| `0475a77` | its defaults (four workers, sweep once a second), two searches | 140,000 | 35,407–36,107 | 240–406 ms | 333–603 ms | 28% / 67% / 97% |
| `6e69d72` (#116) | its defaults, a 5-minute hold at 150,000 | 150,000 | 38,902 | 175 ms | 661 ms | 31% / 66% / 98% |

With four workers 130,000 failed its probe (p95 730 ms), with throughput flat
at about 30,500 req/s. Two workers left the box about a sixth idle; four use
all of it. Five held as many users with longer tails. During a hold the core
that takes the network interrupts is the first to run out (about 30% of it in
softirq). With the idle sweep once a second, the server's share of the box
fell from 39% to 28%, which Postgres took: 140,000 held at the top of the
searches' range, and 145,000 passed a probe (p95 483 ms) but not a 5-minute
hold (p95 634 ms). #116's build (`6e69d72`), on Nish 0.23.1, held 150,000 in a 5-minute
hold on the official pass rule (`loadgen run`, 60 s ramp and 300 s
measured), above the searches' range. The VM's speed drifts by about 8% over
a day, so the hold was run once a check at 140,000 matched the earlier
measurements. The box was 98% busy: Postgres about 136 µs of CPU a request
and the server 63. At the end of every ramp both VMs retransmit for a few
seconds, which the load generator can report as itself falling behind.

## Credits

Ideas taken from other submissions to the challenge, each written here
from the idea, not the code:

- From [rust-epoll-WorriedArrow](https://github.com/arjaythedev/multicore-server-challenge/tree/main/submissions/rust-epoll-WorriedArrow)
  ([#47](https://github.com/arjaythedev/multicore-server-challenge/pull/47)):
  the batch planner in front of Postgres, in two phases. Pages and capped
  counts answered from one statement per kind of list over distinct keys;
  the union of a batch's articles enriched once; the viewers' flags as one
  `= ANY` range scan per viewer; a batch gathered for a window, the batch
  clock; and the global count walking the primary key from its oldest end.
- From [rust-tokio-Scooter1337](https://github.com/arjaythedev/multicore-server-challenge/tree/main/submissions/rust-tokio-Scooter1337)
  ([#7](https://github.com/arjaythedev/multicore-server-challenge/pull/7)):
  coalescing waiting reads into one statement over arrays, routed back by
  ordinal, and cutting a list page before computing its articles' metadata.
- From [zig-iouring-harshitkhandelwal208](https://github.com/arjaythedev/multicore-server-challenge/tree/main/submissions/zig-iouring-harshitkhandelwal208)
  ([#45](https://github.com/arjaythedev/multicore-server-challenge/pull/45)):
  a batch window that holds reads only while the server is busy (the
  adaptive clock); and bcrypt in four-lane batches gathered for a window,
  off the HTTP loops (it runs threads, these are processes).
- From [go-epoll-MegaPanchamZ](https://github.com/arjaythedev/multicore-server-challenge/tree/main/submissions/go-epoll-MegaPanchamZ)
  ([#61](https://github.com/arjaythedev/multicore-server-challenge/pull/61)):
  a group commit's writes of one kind as one statement over arrays.
- From [zig-fourneau-y2kbugger](https://github.com/arjaythedev/multicore-server-challenge/tree/main/submissions/zig-fourneau-y2kbugger)
  ([#53](https://github.com/arjaythedev/multicore-server-challenge/pull/53)):
  more bcrypt workers than one core's worth, because a saturated box gives
  each only a fair share.
- From [zig-iouring-nick-potts](https://github.com/arjaythedev/multicore-server-challenge/tree/main/submissions/zig-iouring-nick-potts)
  ([#79](https://github.com/arjaythedev/multicore-server-challenge/pull/79)):
  turning delayed ACKs back on after each answer (`TCP_QUICKACK` off), and
  bcrypt at idle priority (`BCRYPT_NICE=idle`, off by default here).
- From [rust-epoll-theCatWisel](https://github.com/arjaythedev/multicore-server-challenge/tree/main/submissions/rust-epoll-theCatWisel)
  ([#132](https://github.com/arjaythedev/multicore-server-challenge/pull/132))
  and rust-epoll-WorriedArrow: the feed's shared followees, a floor for their
  pages and a proof of their count; the statement follows theCatWisel's.
- From rust-epoll-WorriedArrow and zig-iouring-nick-potts: timing bcrypt's
  lane widths at startup and keeping the fastest, here through Nish's
  `bcryptCalibrate`; and from nick-potts, gzip only when it saves a TCP
  segment (`GZIP=1`, off by default).
- `enable_memoize=off` as a session option was set first by
  [c-iouring-tigokraft](https://github.com/arjaythedev/multicore-server-challenge/tree/main/submissions/c-iouring-tigokraft)
  ([#10](https://github.com/arjaythedev/multicore-server-challenge/pull/10)),
  and by [#15](https://github.com/arjaythedev/multicore-server-challenge/pull/15)
  and [#22](https://github.com/arjaythedev/multicore-server-challenge/pull/22)
  the same day.

The source lives here; until Nish 0.23.0 it was staged from
[`bench/multicore/conduit`](https://github.com/amritk/nish/tree/c434ac7b/bench/multicore/conduit)
in the Nish repository, whose README there records the method and the
changes measured, kept or dropped, before the read plans. The SPEC.md SQL
keeps the challenge's MIT notice (`src/LICENSE.md`).

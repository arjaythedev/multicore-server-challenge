# Zig / io_uring

Front: direct

| | |
|---|---|
| Language | Zig 0.17.0 (official tarball, pinned by SHA-256 in `install.sh`) |
| Framework | none: our own HTTP/1.1 server on raw io_uring |
| Database driver | none: our own PostgreSQL v3 wire client (SCRAM-SHA-256, prepared statements, binary rows) |
| Database | PostgreSQL 18 |
| Other dependencies | none. JSON, JWT, HMAC-SHA-256 (with SHA-NI), bcrypt (with hand-written assembly kernels) and the gzip encoder are written here |
| Score on our rig | **150,000 users**, held in two official-style searches with `shed=on,ackdelay=on`. The same build with `ackdelay=off` held 140,000 |

```sh
sudo bash install.sh     # Zig 0.17.0 to /opt/zig-0.17.0, checked against its SHA-256
bash build.sh            # ReleaseFast, x86-64-v3, stripped
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

`HOST` defaults to `0.0.0.0` and `PORT` to `3000`. The server runs in the foreground. It logs one startup line with
the worker count, the connection counts, whether SHA-NI is in use and the flags in force.

### CONDUIT_FLAGS

Start-time switches come from one environment variable, `CONDUIT_FLAGS`, a comma-separated list of `name=on|off`
read once before the server forks. An unset or empty variable means every default. An unknown name or value stops the
server, so a typo can't quietly run the wrong build. The runtime value is turned into a compile-time one at startup,
so each combination of flags is its own specialised copy of the server. Nothing on the request path tests a flag, and
a feature that is `off` costs nothing.

| Flag | Default | What it does |
|---|---|---|
| `shed` | off | While the box's CPU is saturated (a second below 3% idle) the server refuses sign-ups and logins with an immediate `503` and `Retry-After: 1`, and nothing else. A policy choice about which users wait, so it is off unless turned on. See [Overload shedding](#overload-shedding). |
| `gzip` | on | A response that needs three or more TCP segments is gzipped for a client that accepts gzip, and sent that way only if it then needs fewer segments. Fewer segments mean fewer client ACKs on the CPU that takes the network interrupts. Off sends every body as identity. See [Two-segment gzip](#two-segment-gzip). |
| `ackdelay` | on | After each response the server turns `TCP_QUICKACK` off on that client's socket, through io_uring, so the next request's ACK rides on its response instead of leaving as a packet of its own. It only sets an option on the server's own sockets. Worth the last 10,000 users. See [ACK delay](#ack-delay). |

No result, token or password caches: every request reads Postgres. No schema changes, no Postgres configuration
changes, no host tuning.

---

## Contents

1. [Architecture in one picture](#architecture-in-one-picture)
2. [What is new here, as far as we can tell](#what-is-new-here-as-far-as-we-can-tell)
3. [I/O and networking](#io-and-networking)
4. [The drain process and its rings](#the-drain-process-and-its-rings)
5. [The batch clock and coalescing](#the-batch-clock-and-coalescing)
6. [MEGA and the other SQL techniques](#mega-and-the-other-sql-techniques)
7. [Writes and group commit](#writes-and-group-commit)
8. [JSON, JWT and HTTP](#json-jwt-and-http)
9. [bcrypt](#bcrypt)
10. [Overload shedding](#overload-shedding)
11. [ACK delay](#ack-delay)
12. [Two-segment gzip](#two-segment-gzip)
13. [Startup checks and correctness](#startup-checks-and-correctness)
14. [The wall, and why the score is 150k](#the-wall-and-why-the-score-is-150k)
15. [How we measured](#how-we-measured)
16. [What we tried that didn't make it](#what-we-tried-that-didnt-make-it)
17. [Credits](#credits)

---

## Architecture in one picture

At 8 CPUs:

```
                    clients (keep-alive HTTP/1.1)
                               │
          ┌──────────────┬─────┴────────┬──────────────┐   SO_REUSEPORT: one listener per worker
          ▼              ▼              ▼              ▼
     ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐
     │worker 0 │    │worker 1 │    │worker 2 │    │worker 3 │  4 processes (cpus/2), one io_uring each:
     │ io_uring│    │ io_uring│    │ io_uring│    │ io_uring│  accept, recv, parse, route, JWT, JSON, send
     └─┬──┬──┬─┘    └─┬──┬──┬─┘    └─┬──┬──┬─┘    └─┬──┬──┬─┘
       │  │  │        │  │  │        │  │  │        │  │  │
       │  │  └── 2 bcrypt hashers at SCHED_IDLE + 1 normal-priority watchdog, per worker
       │  │
       │  └── 1 write connection per worker ──────────────────────────────►  Postgres
       │       (lone write waits 3 ms, then ≤128 writes in one Sync)          (4 write backends)
       │
       │  ask ring 4 MB  ──►  ┐   per worker, SPSC, in one MAP_SHARED region
       │  answer ring 16 MB ◄─┤   mapped before fork; eventfds wake each side
       ▼                      ▼
     ┌───────────────────────────────────────┐
     │ drain process (one io_uring)          │
     │ one read queue for the whole box      │
     │ 5 ms batch clock, ≤4,096 reads/drain  │──► 5 read connections ──► Postgres
     │ MEGA + batched statements, one Sync   │    (5/8 of the CPUs)       (5 read backends)
     │ answers rows in DataRow layout        │
     └───────────────────────────────────────┘
```

That is 9 Postgres connections in all (5 read, 4 write). A worker turns the drain's raw rows into JSON itself, so the
drain process never touches HTTP or JSON. The parent process forks everything, sets `PR_SET_PDEATHSIG` on its
children, and if any process dies it kills the rest and exits, so a crash stays visible instead of leaving a
half-working server. Several processes are needed anyway: the run's `LimitNOFILE` is 200,000 per process.

With one worker (2–3 CPUs) there is no drain process and the worker keeps its own read connections. Sizing comes from
the CPU count: workers = cpus/2, read connections = (5·cpus + 4)/8, bcrypt threads per worker = ⌈cpus/workers⌉.

Where the CPU goes at 150,000 users (about 39,000 requests a second, an earlier build without ACK delay): the four
event loops together use about 1.34 cores, which is 34 µs per request, and Postgres about 4.3 cores, which is
about 110 µs per request. The server's job is mostly to spend less Postgres. Kernel networking takes most of the rest
of the box.

---

## What is new here, as far as we can tell

We read the other entries. As far as we can tell, these are new to this challenge:

- **A separate drain process with SPSC rings.** One process owns every read connection and one read queue for the
  whole box. Workers reach it through lock-free single-producer single-consumer rings in shared memory.
- **One MEGA statement.** Every list, feed, article, profile, user and tag read in a drain runs as one execution of
  one statement. That statement returns each article entity and the tag list once per drain, beside each read's own
  keys and viewer flags.
- **bcrypt at SCHED_IDLE with a watchdog.** Password hashing only uses CPU nothing else wants. A normal-priority
  watchdog thread takes over any job starved for too long.
- **CPU-idle shedding, off by default.** With `shed=on`, sign-ups and logins are refused while the box's measured
  idle CPU stays under 3%.
- **Startup result-type validation.** Every statement is described against the live database, and the server
  refuses to start unless each one returns exactly the column types its decoder was written for.

These are new only as combinations, since each part exists elsewhere:

- **Everything hand-written, down to the SHA-256 under JWT.** That covers HTTP, the Postgres wire protocol, JSON,
  HMAC-SHA-256 with SHA-NI, and SCRAM. Other entries write their own HTTP or their own Postgres client; we didn't find
  one that also wrote the hash.
- **Assembly bcrypt with per-machine calibration.** Interleaved-lane bcrypt kernels exist in #45 and #53, and #37
  calibrates its lane count. We pick both the kernel and the width at startup by measuring each candidate.

These are common, and we credit them: the batch clock (#47's two-phase gather, with #37 and #50 batching similarly),
group commit (#37, #4, #7), compile-time JSON shapes, and holding no buffers for idle connections.

---

## I/O and networking

**One io_uring per process**, set up with `SINGLE_ISSUER`, `DEFER_TASKRUN` and `COOP_TASKRUN`, with a 65,536-entry
completion queue. Each listener is `SO_REUSEPORT`, IPv6 dual-stack, with a 65,535 backlog. `TCP_NODELAY` is set once
on the listener and accepted sockets inherit it (credit rust-epoll, #152 and #45 for the trick). `RLIMIT_NOFILE` is
raised to its maximum and `SIGPIPE` is ignored.

**Multishot accept, then multishot recv into provided buffers.** These are 4,096 buffers of 4 KB, of the classic
`PROVIDE_BUFFERS` kind. The newer buffer rings return `EINVAL` on the target's 6.8 kernel, and on our development box
they cost more anyway (see the losers). A returned buffer goes back with `IOSQE_CQE_SKIP_SUCCESS`, so it produces no
completion.

**Requests are parsed in place**, straight out of the provided buffer, when they arrived whole. Only leftovers are
copied into the client's own buffer. A client has one request in flight at a time, so pipelined requests are answered
in order.

**One send per response.** The response body is built first, behind a reserved gap for the header. The header is
then written into the gap, and the whole thing leaves in one `send`. The header is 70–71 bytes: header values follow their colon with no space, which HTTP/1.1 allows.

**No per-connection buffers.** Response buffers come from size-class free lists and go back as soon as the send
completes. An idle keep-alive connection costs a small struct and nothing else. Server memory grows by about 7 KB per
user. At the 256,000-user overload probe it peaked at 2.34 GB, with at least 6.75 GB of the 16 GB still free in every
search.

**The loop sleeps only as long as it may.** Each iteration handles every ready completion and takes what the other
side of the rings published. It then fills the Postgres connections, queues their sends, and publishes to the other
side. When reads are waiting for their batch clock, the wait (`io_uring_enter` with `EXT_ARG` and a timeout) ends
exactly when the drain is due.

In a profile, no single user-space function holds more than about 2% of the event loop. Most of an event loop's time
is kernel TCP.

---

## The drain process and its rings

**Why one queue.** We first ran one read queue per worker. On a replay of the benchmark's own traffic, four
independent queues cost 1.211x the Postgres CPU of one shared queue, and all six pairings we measured fell between
1.204 and 1.215. A drain is cheaper per read the more reads it has, because MEGA shares each article and tag fetch
among everything in it. One shared queue on a 12.5 ms clock costs the same CPU as four queues on 50 ms, at a quarter
of the latency. So the box gets one queue, which needs one owner: the drain process.

**The rings.** The parent maps one `MAP_SHARED` anonymous region before forking. Per worker it holds:

- an **ask ring** (worker → drain, 4 MB) and
- an **answer ring** (drain → worker, 16 MB),

each single-producer single-consumer. A record is length-prefixed and 8-byte aligned, and a wrap marker sends the
reader back to the start. Head and tail are atomics on cache lines of their own. Each side publishes a whole batch of
records with one store. The largest record is half the ring (2 MB asked, 8 MB answered), because a wrapped record has
to fit on one side of the producer. A unit test sweeps every start position.

**Wake-ups.** The eventfds are created before fork and read through io_uring like everything else.

- The drain writes a worker's answer eventfd once per loop iteration in which it published answers to that worker.
- A worker writes the drain's eventfd only when the drain is asleep with nothing queued. The drain raises an "idle"
  flag, re-checks every ring, and only then waits. A worker publishes, swaps the flag down, and writes the eventfd only
  if it was up. Both sides use sequentially consistent operations, so no wake-up is lost and a busy drain gets no
  writes at all.

**Back-pressure.** A full ask ring keeps reads in the worker's own FIFO, and a full answer ring spills into a buffer.
Both retry every 1 ms and log once. In testing this caught a real bug. Answers moved out of the spill buffer were only
published if a new answer also arrived in the same iteration. The regression test pushes 100 answers through a 1 KB
ring; before the fix the worker saw 42 of them.

**What crosses the ring.** The worker sends the statement kind and parameters. The drain answers with the rows in
Postgres's own DataRow body layout plus one of four endings: rows, done, fail or reset. The worker writes the JSON
from those bytes, exactly as it would from its own connection. The drain process does no HTTP and no JSON.

**What it costs and buys.** The rings add 1 to 3 µs per request to the event loop. On our development box they saved
3 to 36 µs per request of Postgres, depending on the shape; the two best shapes came to −27 and −11 µs per request in
total. On the scoring-sized box, the drain plus the SQL changes below plus the 3 ms write wait took Postgres from 143
to 117 µs per request against the previous version (per-worker queues). The p95 at 130,000 users fell from 417 ms to
117 ms.

**How many read connections.** Five on 8 CPUs, 5/8 of the cores, measured at −9 µs per request against six at 154,000
users. Fewer backends make bigger drains, and they contend less for buffer pins and locks. Read backends spend 28–33%
of their cycles on those. #56 and #53 also landed on 5/8.

---

## The batch clock and coalescing

**The clock.** Reads wait in the queue until the oldest has waited 5 ms. Then a free read connection takes every
queued read of every worker, up to 4,096, and sends them as one Sync group. Each connection has one group in flight
at a time (depth 1). This is #47's two-phase gather, and #37 and #50 batch similarly. Against sending reads as they
come, it measured −22.5 µs per request [−24, −21], of which −17.5 was Postgres. Instructions per request went from
1,316k to 1,156k.

**Coalescing inside a drain.** Requests for the same statement run as one execution with one array per parameter:
`unnest(...) WITH ORDINALITY` joined `CROSS JOIN LATERAL` to the per-row query (from #7), with rows routed back by
ordinal. Reads that take no parameters and are the same for every viewer, such as the tag list, run once per drain and
are shared.

**The latency trade.** A longer clock makes bigger drains and cheaper reads, and costs latency one for one. On replay:

| Clock | Reads per drain | p95 | Postgres CPU vs #7 (earlier MEGA) |
|--:|--:|--:|--:|
| 5 ms | 135 | 37 ms | 0.665 |
| 20 ms | 525 | 145 ms | 0.621 |
| 50 ms | 1,264 | 245 ms | 0.511 |
| 100 ms | 2,377 | 445 ms | 0.496 |

The final stack at 5 ms costs 1.5–1.7x what it costs at 50 ms. We ship 5 ms because the official search fails on p99
latency well before it fails on CPU, and every longer clock we tried live hurt the tail more than it saved (see the
losers).

---

## MEGA and the other SQL techniques

### The protocol, measured first

Before writing SQL we measured what the wire protocol costs on Postgres's side, with instruction counts on a replay:

| Item | Cost |
|---|---|
| One Sync (round trip, ReadyForQuery, transaction start and end) | 39–49k instructions |
| Parse and plan per execution, against a prepared statement | 3.5–5x |
| Describe | 3–8k instructions |
| An explicit open transaction around many statements | saves 10–22k per Sync |
| REPEATABLE READ instead of the default | nothing measurable |
| Text against binary results | ±4–6% |
| TLS on the connection | 0.978 without it (we don't use it; the connection is TCP to 127.0.0.1) |

So: named prepared statements, `plan_cache_mode = force_generic_plan`, `jit = off` (both session settings), binary
parameters and results, and as few Syncs as possible. A profile of a read backend under #7's statements showed 73.5%
in executor run and 7.7% in executor start. The SQL itself is where the time is.

### MEGA

Above two qualifying reads per drain, everything except comments and logins becomes **one execution of one
statement**. Its input is six binary arrays, one element per job:

| Array | Type | Meaning |
|---|---|---|
| kind | int4 | 1 list all, 2 by tag, 3 by author, 4 favorited by, 5 feed, 6 article by slug, 7 article re-read by id, 9 profile, 10 current user, 12 tags |
| viewer | int8 | the viewer's user id, or 0 |
| i1, i2, i3 | int8 | limit, offset and the kind's key |
| t1 | text | slug, tag or username |

It returns 18 columns. A row's ordinal says what it is: ≥ 1 is a job's own row (its keys, counts and viewer flags),
−1 is an article entity, and −3 is the tag list. Each article and the tag list is sent **once per drain**, however
many jobs refer to it. The worker side (`mega.zig`) keeps the rows until the result is complete, fills each job's rows
from the entities, sorts them per job, and hands them to the same JSON writers a single statement would use.

A drain with fewer than two MEGA jobs uses the ordinary single statements. MEGA has a fixed cost of about 1.7M
instructions per execution, 13x a one-row statement.

Logins look users up by email with a batched statement. Comments use `COMMENTS_LIST_SET` for one request and
`BATCH_COMMENTS_LIST_SET` for two or more. Both run beside MEGA in the same Sync group. If a drain's group fails, each
of its jobs is retried alone, so one bad request can't fail its neighbours. MEGA shares work only among reads that
were queued before it started, inside one execution. No returned data is retained across requests (in #7's wording).

**What it is worth.** In the server, MEGA saved 79k instructions per request (−6.8%) on top of the gather alone; #7's
statements used 1,368k per request in the same rounds. On replay, the final statement stack against #7's statements,
the Postgres CPU ratio was:

| Clock | Ratio to #7 | Notes |
|--:|--:|---|
| 50 ms | 0.354–0.424 | nine estimates |
| 20 ms | 0.406–0.459 | |
| 5 ms (shipped) | 0.598–0.617 | final pass only |

So at the clock we ship, it is about 0.6x of #7's Postgres CPU. The famous 0.35–0.42x needs a 50 ms clock that the
latency budget doesn't allow.

**Where its time goes**, from `pg_stat_statements` on a 50 ms replay:

| Statement | Share of Postgres CPU | Detail |
|---|--:|---|
| MEGA | 71.8% | 882 calls, 59.3 ms each |
| Comments batch | 22.3% | about 368 reads per call, 68 µs per read |
| Writes | 5.9% | |

The feed is the expensive one: about 36% of Postgres CPU for 7.8% of requests, about 290 µs per feed. `EXPLAIN` of
the median 50 ms drain (916 jobs) runs in 52 ms with 45,730 buffer hits, 20% fewer buffers than an earlier version of
the statement.

### The edits inside MEGA that shipped

Each was measured on replay against the version before it.

- **Tag names from one grouped scan**, instead of per article: −2 to −3%.
- **Capped count probes on the index's own columns**, so the `count(*)` limited at 1,000 is index-only: −1%.
- **The feed:**
  - the viewer's followee arrays are read once;
  - `following = true` by construction, since every feed row is from someone you follow;
  - counts walk oldest first;
  - the capped count is *proved* rather than counted where it can be. The drain's 10 most-followed authors get an
    `OFFSET 999` probe each (credit #10, #22, #11 and #4 for the probe), and a viewer who follows one with 1,000+
    articles has a capped count without walking anything. This covers 202 of 275 capped feeds and removes 65–67% of
    feed rows.
- **Counts carried per distinct list request in the page CTE.** This one fixed a plan, not just a cost. Under the
  generic plan every CTE was estimated at 1 row, so Postgres chose a nested loop that compared each read against
  every other: 93 comparisons per read, 598,000 on the largest drain, about 5.2M over the whole replay. Carrying the
  count inside the page CTE removed the join: −10.5% instructions. The change from 5 to 10 proved authors above came
  with it.
- **List flags from one array-key probe per read** (favorited and following together): 0.951.
- **Favorite counts from one grouped scan** of the favorites index: +0.7–1.8% instructions on small drains, but fewer
  buffers, and it pays off on large drains.

**Comments left MEGA.** An earlier MEGA also served comments (kind 8). On their own statements they cost 520.8k
instructions per comments request against 704.7k inside MEGA (−26%).

---

## Writes and group commit

**One write connection per worker.** A lone write waits 3 ms for company. Then up to 128 queued writes go out as one
Sync group **with no BEGIN or COMMIT**. Each statement commits implicitly at the Sync, so they share one WAL flush, and
every write is answered only after ReadyForQuery confirms it.

- Favorite, unfavorite, follow, unfollow and comment create use batched forms when the group has two or more of
  them: arrays in queue order, with the 1-based position returned as the last column so answers route back.
- Register and user update run alone because they can fail on a taken name. A failed group retries its requests one
  per group.
- Re-reads (the article after a favorite, say) go on the read queue once their group has committed, so they see the
  write.
- Article create takes its id with `nextval('articles_id_seq'::regclass)` (−3.5%).

**Numbers.** An explicit BEGIN and COMMIT cost 74k instructions per multi-job group, so we dropped them. One write
connection per worker instead of several raised jobs per group from 1.5 to 2.4. Against the previous write path the
pool cost 66.0 µs per write against 106.0 (−38%). A 1 ms wait measured 77.8 against 103.8 (−25%); we ship 3 ms. Write
p95 went from 2.78 ms to 4.43 ms, which the latency budget absorbs easily.

Write latency spikes come from the virtual disk's fsync, not from us. On an emulated slow disk, this shape had a write
p95 of 38 ms against #7's 79 ms. Group commit itself is common (#37, #4, #7).

**Bad text never reaches a batch.** A NUL byte or invalid UTF-8 anywhere in a write's text, including a JSON
`\u0000` escape, gets the reference server's 500 before it is queued. Otherwise one bad request would fail its whole
group and force every neighbour to retry alone. We checked 129 such cases against the Go reference: all identical (7
differed before). In a burst of 360 good and 6 bad requests, 6 MEGA units were retried before the fix and 0 after.

---

## JSON, JWT and HTTP

**JSON at compile time.** Each response shape is generated at compile time from a field list. A response is then a
fixed sequence of constant copies and value encoders writing straight from the Postgres receive buffer, with no
intermediate objects. Body sizes are byte-for-byte the same as #7's on every read endpoint: list 5,538 bytes, single
article 1,538, tags 2,015.

**JWT.** HS256 is verified on every request. The claims are read in one pass over the payload rather than parsed into
a tree: 570–613 ns per verify fell to 263–294 ns (credit #11, rust-epoll and #15 for the scanning approach).

**SHA-256.** HMAC-SHA-256 uses SHA-NI through inline assembly, picked by CPUID once at startup, with the HMAC key's
inner and outer states precomputed. It is our own `sha256.zig`. The standard library's SHA-256 is used only for SCRAM
at connect time.

**Built for x86-64-v3, not `native`.** Another entry (#18) died with SIGILL on a machine without the instructions it
was built for. A v3 build has 0 AVX-512 (zmm) uses, where a native Zen 5 build has 5,543. On the scoring-sized box,
v3 cost nothing measurable (−1 to −2 µs per request, which is noise).

---

## bcrypt

Cost-10 bcrypt on register and login is the heaviest thing per request in the benchmark, so it got its own research
track.

**The engine.** A lanes engine: one kernel call hashes up to 8 passwords, their Blowfish rounds interleaved so the
S-box lookups of different passwords overlap. Each password has its own lane and salt; identical jobs are never
merged. The shipped kernel on Zen 5 is assembly generated at build time (`asm_gen.zig`) that uses BEXTR at 5 lanes:

| Kernel (Zen 5, isolated bench) | CPU-ms per hash | |
|---|--:|---|
| Ours, asm with BEXTR, 5 lanes | **7.869** | 0.600 cycles and 2.877 instructions per S-box lookup, IPC 4.79 |
| Our portable Zig port of the same lanes | 9.383 | −9.6% for the asm |
| #7's Openwall batch kernel (gcc -O3, 4 lanes) | 10.429 | −21.5% for ours, Wilcoxon p = 0.0001 over 15 pairs |
| Zig's standard library, one lane | about 38 | |

A hash is 68,334,144 S-box lookups. The kernel is bound by four dependent loads per Blowfish round. BEXTR replaces
the `al`/`ah` partial-register reads that Zen 5 penalises: the same instruction count, 8% faster. A sixth lane would
need 12 free registers, and there are 11. On Zen 3 (EPYC Milan) the `ah` variant wins instead, at 14.157 ms against
the port's 16.906 (−16.2%). The Zen 5 comparison against #7 was made on Zen 5 only.

**Calibration.** At startup, once and before forking, the server self-tests every kernel against Openwall, Rust and
Go test vectors. It then times each candidate kernel and width and keeps the one with the least CPU per hash on this
machine. On Zen 5 it picks the 5-lane BEXTR kernel in 40 of 40 runs (31 of 40 before we timed each candidate's
fastest batch). Calibration costs 3.37 CPU-seconds once. In the server, it logs 8.4–8.7 CPU-ms per hash on our Zen 5
development box. The build uses `-mcpu=x86_64_v3+fast_bextr` for these objects.

**Correctness.** 218,496 differential cases against reference implementations, 0 mismatches. 115,200 of our hashes
checked by Go's `CompareHashAndPassword`, 0 rejected. Password bytes follow `golang.org/x/crypto/bcrypt`: every byte
counts, NULs included, and a password over 72 bytes is rejected with 422.

**In the server**, bcrypt-thread CPU went from 37.9 µs per request (one lane) to 9.2, then 8.1, and the app overall
dropped 31 µs per request. The threads retired similar instructions (644 G → 549 G) in 4.2x fewer cycles (537 G →
127 G).

**Batching without waiting.** A job waits for company only if a batch is already hashing, another job is queued, or
one arrived within the last fill window (1 s). Otherwise it is hashed at once. This took the conformance suite's auth
tests from 13.8 s to 0.41 s. A shorter 250 ms window cost 16.2 µs per request more and was not taken.

**SCHED_IDLE hashers.** The hashing threads run at `SCHED_IDLE`, so hashing only gets CPU that nothing else wants:
not the event loops, not Postgres, not the kernel's network softirq. The catch is that an unprivileged thread can never
come back. `RLIMIT_NICE` is 0 and there is no `CAP_SYS_NICE`; if `SCHED_IDLE` fails, the thread falls back to nice 19.
On a saturated box an idle thread could starve forever. So one more hasher per worker, the watchdog (`bcrypt-watch`),
stays at normal priority and takes any job still unfinished after the fill window plus two batches' CPU time (about
1.09 s on one test box). Whichever finishes first answers.

**No locks between them.** The event loop owns the queue and hands each hasher its batch through a slot of its own,
with an atomic state and a futex sleep. A starved idle thread holds nothing anyone else waits on, and nobody spins.
Under a CPU hog plus 400 hashing requests, every request was answered, the slowest in 1.07 s.

Idle-priority bcrypt on its own beat normal priority at 183,000 users in both rounds: p95 −17 and −34 ms, p99 −43
and −64 ms.

**What we learned on the way.** SIMD bcrypt (AVX2 and AVX-512, gathers, hybrids) was always worse, 21–22% below 4
scalar lanes. The largest single effect we found in anyone's bcrypt was a compiler flag: one entry's kernel built at
`-O2` ran 18.68 ms per hash on Zen 5 against 11.23 ms at `-O3`.

---

## Overload shedding

Flag `shed`, **default off**; `CONDUIT_FLAGS=shed=on` turns it on. While the box's CPU is saturated it refuses
sign-ups and logins with an immediate `503`, and nothing else. A user trying to log in during overload waits while a
user already logged in still reads articles. That is a policy choice about which users wait, and it did not raise the
score (below), so the server ships without it.

**Signal.** Every 100 ms the first worker reads the box's idle and iowait time from `/proc/stat`. It adds back the CPU
time of every idle-priority bcrypt hasher, read from `/proc/<tid>/schedstat` (the hashers record their thread ids in a
page all processes share), because CPU spent at idle priority is CPU nobody else wanted. The watchdog hasher is not
counted. A full second of readings below 3% idle turns refusals on, a full second above 8% turns them off, and in
between they hold. Worker 0 publishes the state in the shared page, and every worker reads it.

**Refusal.** An immediate `503` with `Retry-After: 1`, right after routing and before any other work, with the
connection kept open. Each worker logs a line every 10 s in which it was overloaded or refused anything.

**No error budget.** Sign-ups and logins were 0.07% of requests in a hold at 183,000 users, so refusing every one of
them stays far below the 1% error limit on its own.

**Result.** The previous design (v3 below) refused 233 of 246 sign-ups and 9,951 of 10,218 logins and nothing else
in that hold, for 0.067% errors (47,227 req/s, p95 246 ms, p99 401 ms). **It did not raise the score**: the step-up
climb reached 174,000 with it, the same as with the shed before it. Logins are cheap for the box precisely because
their hashing already runs at idle priority, so refusing them mostly frees idle-class CPU. At the knee the box is
88–93% busy, so the 3% trigger doesn't fire there at all.

Earlier designs, all dropped:

| Design | What it did | Why it went |
|---|---|---|
| v1 | Learned per-class costs by NLMS over Sync groups with per-group constants, CoDel-style sojourn times, read deadlines at 750 ms, budget 0.8% | In 12 minutes at 160,000 users it refused one request. The queue was in the kernel, before the parse, where the server couldn't see its age |
| v2 | Kernel receive timestamps (`SO_TIMESTAMPNS` via multishot `recvmsg`), a CPU-wait signal, a p99 back-off, budget 0.5% | Refused 0.49% of requests while serving every request in 5 ms |
| v2 + level cap | Capped the level at what the budget pays | Superseded by the CPU-idle design |
| Queue-age cap | Refused reads older than a bound, 0.5% against 0.8% budget | Bought nothing; about 12M reads were served over age anyway |
| v3 | The same CPU-idle signal, refusing route classes in a fixed cost order (register, login, feed, article create, list, …; costs from an earlier shed and #7), heaviest first, within a fixed error budget | No score gain: at the loads that decide the score it only ever reached sign-ups and logins. Replaced by the simpler shed above. Overhead below the knee +3.7 µs per request [−20, +31], noise |

---

## ACK delay

Flag `ackdelay`, default on. It is the cheapest change in the entry and the last 10,000 users.

**The problem.** The load generator's clients pause between requests. When a connection has been idle longer than
the retransmit timeout, Linux enters quick-ACK mode and ACKs the next incoming request immediately, in a packet of its
own, before the server has even read it. Our reads then wait for the 5 ms clock, so the response follows a few
milliseconds later in a second packet. At 140,000 users, 63% of the server's pure ACKs left within 1 ms of the
request. The receive CPU (one CPU takes every network interrupt; see [the wall](#the-wall-and-why-the-score-is-150k))
was paying for a packet that carried nothing.

**The fix.** After a full response on a kept-alive connection, the server queues a socket `uring_cmd`:
`SETSOCKOPT(IPPROTO_TCP, TCP_QUICKACK, 0)` with `IOSQE_CQE_SKIP_SUCCESS` (kernel 6.7+). That is no syscall and no
completion; it rides along with the next submit. The next request's ACK then waits for its response and leaves in the
same packet. It has to be done after every response: the kernel decides quick or delayed as a request arrives, so
setting it at parse time is too late, and it leaves delayed mode whenever its delayed-ACK timer fires. `EINVAL` or
`EOPNOTSUPP` turns the feature off for the process with one log line. `EBADF` (a connection that just closed) is
ignored.

On loopback, a test request's ACK left at 0.0 ms without it and rode the response at 5.7 ms with it.

| At 140,000 users | Off | On |
|---|--:|--:|
| Server pure ACKs per request | 0.81 | 0.59 (−27%) |
| Receive CPU softirq, cores | 0.56 | 0.49 (−12%) |
| Box CPU per request | 185.8 µs | 184.3 µs |

In an ABBA at 154,000 users the CPU change was −1.45 µs per request, smaller than the 2.3 µs spread between identical
runs. Receive softirq went from 0.66/0.65 to 0.58/0.58 cores (−11%), and the softnet squeeze counter fell from 34 to
4.5. Total CPU barely moves; what moves is the one saturated CPU that decides when the box collapses.

**Score:** the build without it held 140,000 in the official search. With it, 150,000, twice:

| Search | req/s | p50 | p95 | p99 | Errors |
|---|--:|--:|--:|--:|--:|
| 1 | 38,451 | 110 ms | 273 ms | 446 ms | 0 |
| 2 | 38,634 | 93 ms | 225 ms | 398 ms | 0 |

The overload probe at 256,000 users ran at 18–21% errors with no OOM and at least 6.75 GB free.

The irony is that an earlier network study of ours ranked quick-ACK tuning "not worth it". It measured 0.05 pure
ACKs per request at 20,000 users. At 140,000 they were 0.86.

---

## Two-segment gzip

Flag `gzip`, default on. gzip here is aimed at the receive CPU, not at bandwidth. A client ACKs at once when two full
segments are unacknowledged, and otherwise on its delayed-ACK timer. So an answer of three or more segments draws
about 1.5 ACKs or more from the client, and an answer of two or fewer draws about 1. Every one of those ACKs lands on
the CPU that takes the NIC's interrupts (see [the wall](#the-wall-and-why-the-score-is-150k)). A 10-article list is
about 5 KB, four segments.

**The rule.** Segments are counted in each connection's own MSS, read once at accept (`TCP_MAXSEG`: 1,448 bytes on
IPv4, 1,428 on IPv6 with timestamps). A response is gzipped only when the client sends `Accept-Encoding: gzip` and
the identity response needs three or more segments. The gzip form is sent only if the whole response, head included,
then needs fewer segments. Otherwise the identity body goes out. A 10-article list goes from about 4.7 KB to 2.7 KB,
two segments.

**The encoder** (`src/pz.zig`) is written for this. Each response is one gzip member with one dynamic-Huffman block.
Its code lengths are a static code table compiled into the binary, trained offline on seed-shaped JSON and sent in
every response's block header, so nothing is cached and nothing carries from one response to the next. Matches are
looked for only at closing quotes and where each match ends. Every other byte is a literal, coded two per table
lookup. Once the rest of the body fits the two-segment budget as stored bytes, the Huffman block ends and the rest
goes out stored. The CRC-32 folds with PCLMULQDQ. On a CPU without it the server logs `gzip off` and sends identity
bodies. A 5.4 KB list codes in about 3 µs, about 4.6 times faster than libdeflate level 1, and every test output
decodes byte-exact with Go's `compress/gzip`.

**Where the table comes from.** `src/pz_table_anchor.zig` holds static Huffman code lengths (286 literal/length and
30 distance codes) and the block header that sends them, nothing else: no body, no string, no request data.
`tools/mk_table.py` generates it from `tools/counts.txt`, which is 316 symbol totals: pz's own parse run over 2,000
response bodies of three or more segments, captured with a patched copy of the official loadgen (300 users, the
WORKLOAD.md mix) from an earlier build of this server running on a throwaway Postgres filled by `seed/make-seed.sh`. So the training data
was seed-shaped JSON, and the server learns nothing at run time. To regenerate the table, from this folder:
`python3 -I tools/mk_table.py tools/counts.txt`. The capture (175 MB) and the counting harness are not shipped. To
retrain from scratch, dump the 2xx bodies of 3+ segments from a load run and count the literal, length and distance
symbols pz's parse emits for them into the same one-line format (`all`, then the 316 counts).

**Measured.** An ABBA at 154,000 users, first against the build without gzip, then pz against the libdeflate version
of the same rule:

| Per request | No gzip | libdeflate level 1 | pz |
|---|--:|--:|--:|
| Receive-CPU softirq | 16.73 / 17.01 µs | 14.58 / 14.52 µs | 13.09 / 13.14 µs |
| Incoming pure ACKs (nstat) | 1.77 / 1.79 | 1.43 / 1.42 | 1.28 / 1.27 |
| Box CPU | 189.6 / 190.9 µs | 194.7 / 194.8 µs | 188.8 / 189.4 µs |
| Throughput | 39,239 / 39,125 req/s | 39,013 / 38,964 req/s | 39,347 / 39,264 req/s |
| p95 / p99 | 325–353 / 481–507 ms | 369–377 / 495–499 ms | 291–309 / 410–411 ms |

Each pair is a separate ABBA, so compare within a pair. Against no gzip, libdeflate cut the receive CPU by 15% but
cost 3.4 µs per request of total CPU. pz cut the receive CPU by another 10% and total CPU by 5.7 µs per request
against libdeflate, with higher throughput and shorter tails. Gzipping every large body was tried earlier and lost
(see the losers), because it paid the codec on every response without a packet to show for it.

---

## Startup checks and correctness

- **Result types.** At startup every statement is prepared and described against the live database. The server
  refuses to start unless each statement returns exactly the column types its decoder was written for. A schema
  change can't silently become garbage JSON.
- **bcrypt** self-tests every kernel against known vectors before calibration (above).
- **Flags** are validated before fork (above).
- **SHA-NI** is detected once by CPUID and logged.

Checks on the final build: the conformance suite 197/197; an oracle run of 3,000 of 3,000 request pairs identical to
the Go reference server (32 pairs in flight); 54 unit tests, including the ring wrap sweep and the spill regression.

---

## The wall, and why the score is 150k

**The wall is the NIC.** The scoring-sized box (like every VM we tried) has a single-queue NIC, so one CPU takes every
receive interrupt. At 140,000 users, per request, the box takes in 1.0 request plus 1.56 client ACKs, and sends 1.76
data packets plus 0.86 pure ACKs (before ACK delay). A 4 KB response leaves as 2 TSO packets. The receive side costs
about 18 µs per request. The collapse comes one step above the knee: that CPU's softirq reaches about 0.93 cores,
retransmits jump to 25–30%, and total CPU is still only about 90%. The server was never short of CPU at the knee. It
was short of *that* CPU.

**Why 150,000 and not 174,000.** Our step-up climbs (five-minute holds, fresh database each time) reached 158,000 to
174,000 depending on host and build. The official search ages the database as it goes: articles grew by 44% in the
final search (500,000 → 669,000), so later steps read more. It lands about a step below a step-up climb. 150,000 is
what we quote, because it is what the official procedure produced.

---

## How we measured

On a Hetzner CCX33 (8 dedicated vCPUs, EPYC Milan), memory capped with `mem=17664M` so the system sees 15,231 MB,
with 16 load-generator boxes running the official search on a database it ages itself. Changes were compared in ABBA
order; identical runs (A-A) spread by 2.3 µs per request, and anything inside that is called noise here. Postgres CPU
alone moves ±30 µs per request between identical runs. So SQL work was measured on a replay of the benchmark's
traffic on a Zen 5 development box, interleaved, which resolves 2%. A calm gate refused to time anything while CPU
steal was above 1%. Two lessons the hard way: per-thread perf counters inflated the app's CPU by 10–23 µs per request,
and leaked monitoring processes once ate 7.6% of the box's cycles.

---

## What we tried that didn't make it

Numbers are the change against the build at the time, so negative is better. "µs/req" is total box CPU per request
unless noted. Where a number has brackets, it is a 95% interval.

### Event loop and network

Measured on the development box with 3 CPUs at 42,000 users, against the gather build.

| Idea | What it was | Result | Why it lost |
|---|---|---|---|
| Timed io_uring wait | When busy, wait for up to 32 completions or 250 µs per `io_uring_enter` | +16 µs/req total, +2.6 event loop, −12.4k instructions | Fewer instructions, more CPU. Before the gather it had saved 4.5 µs in the loop |
| Registered ring fd | `IORING_REGISTER_RING_FDS`, so each enter skips the fd lookup | +51 total, +7.8 loop | Before the gather it saved 35; on the gather build it lost |
| Provided-buffer ring | The newer buffer ring instead of `PROVIDE_BUFFERS` | +18.5 total, +2.4 loop | Worse, and `EINVAL` on the target's 6.8 kernel |
| Zero-copy send | `SEND_ZC` for responses | +35 total, +5.4 loop | Responses are ~3.4 KB, too small for zero copy to pay. #45 ships it |
| NODELAY off | Let Nagle coalesce | +7 total, +0.9 loop | Worse |
| Direct descriptors | io_uring fixed files for sockets | −4.5 total, +16.5k instructions | Inside the noise |
| `-mcpu=x86_64_v3` | | −1.5 total, +35.4k instructions | Lost on speed; **later adopted for safety** (#18's SIGILL), and cost nothing on the scoring-sized box |
| Request pool | Request state from a free list instead of per connection | −16 [−35, +3], +6.2k instructions | Interval crosses zero |
| Vectorised head scan | SIMD search for the end of the request head | +4 [−13, +21], +1.7k instructions | No gain |
| Timestamp copy | Copy a precomputed date text into responses instead of formatting it | −8.5 [−48, +31] | Noise |
| Sync overlap | Send the next group before the last returns | −5, +25k instructions | Noise, more instructions. Kept as `levers/sync-overlap.patch` |
| Sync depth 2 | Two groups in flight per connection | −12 [−36, +21] | Noise |
| Busy-poll, `TCP_RTO_MIN`, io_uring NAPI | | Not run | Need privilege or a newer kernel than 6.8 |
| RPS | Spread receive processing across CPUs | Worse | Diagnostic only, and host tuning anyway |
| `TCP_THIN_LINEAR_TIMEOUTS` | | Unresolved | Skipped |
| Unix socket to Postgres | | Not run | Blocked by `pg_hba.conf`, which we don't change |
| `TCP_QUICKACK` on (=1) | The opposite of ACK delay | Not built | |
| gzip (libdeflate level 1) | Compress responses | Held 158,000 in a step-up, the same as without; event loop +17 µs/req; p95 +10 to +36 ms | Bytes out −54%, but below the knee there is no network shortage for it to relieve, and the CPU is real |
| gzip tuning | 8 KB hash table, preset Huffman, 1,280-byte cutoff | Codec CPU −30 to −50% | Unresolved end to end. One hand-written encoder had an HDIST bug zlib rejects |
| CPU affinity | Keep threads off the receive CPU (3 detection rounds) | App −4.5, Postgres +4, total 0; p95 230 against 184 ms; −3 to −4 µs at 158/166k | No capacity gain; both builds still failed at 162,000. Postgres runs as another user, so it can't be moved (EPERM) |

### Process layout, batching and sizing

| Idea | What it was | Result | Why it lost |
|---|---|---|---|
| 2 ms batch window | Shorter window under the old cost budget | −22 [−38, −6] | Superseded by the 5 ms clock and drain. Kept as `levers/batch-window-2ms.patch` |
| One worker | One process for everything | +11 µs/req, p99 297 ms against 70 | Tail. Kept as `levers/one-worker.patch` |
| Two workers × (3 reads + 1 write) | Fewer, bigger workers | −10 µs/req | Overtaken by the drain process |
| 1–2 read connections per worker | Fewer backends, bigger batches | −33 / −22 µs/req at 42,000 users | Collapsed at 90,000: 7.7–9.1k and 11.8–16.5k req/s against 17.2–22.2k |
| No clock on the drain | Send reads inline as they arrive | +37 µs/req on the dev box; on the scoring-sized box +18.7 (Postgres +17.5) | Pure ACKs fell 0.33 → 0.13 but receive CPU didn't change |
| 20 ms clock + "alone" gate | Long clock, but send a lone read at once | Postgres −15 on the dev box; at 158,000 on the scoring-sized box −1.2% req/s, +70 ms p95 | Tail. Its p99 hit 1,164 ms (fail) |
| 10 / 20 / 50 / 100 ms clocks | | Cheaper Postgres, longer tails | p99 is the binding limit |
| Load-adaptive clock | Clock follows the arrival rate | −1.5 µs/req | Noise |
| 3 event loops instead of 4 | | About −2 µs/req | Under the spread, and it collapsed in 1 of 2 holds |
| Two parallel MEGAs | 10 ms clock, feeds in one MEGA and the rest in another, on two connections | About 0 µs/req | Collapsed in 2 of 2 holds at 154,000 |
| Key-sharded drains (offline) | Split each drain by key across connections | Kept 7–15% of the sharing gain, against a bar of ⅓ | Sharding by key destroys what MEGA shares. Sharding by kind kept 70–81% (−6 to −8% of MEGA CPU) but was the two-MEGA idea above |
| Drain cap 1,024 | Smaller maximum drain | No gain | Kept 4,096 |
| bcrypt watchdog without duplicates | Stop the watchdog re-hashing a job an idle thread holds | Watchdog hashed only 17 of 14,113 jobs; +0.5 µs/req | Nothing to save |

### SQL (replay, Postgres CPU against the version before unless noted)

| Idea | Result | Why it lost |
|---|---|---|
| MEGA viewer flags as small arrays | 0.806 against 0.665 | Worse |
| Drain-wide flag sets (several variants) | +38% and more | Worse in every variant |
| Custom plans instead of generic | +12% to +35% | Planning on every execution |
| 75 / 100 ms clocks | Inside the noise | Twice the latency for nothing |
| Tags on their own 1-connection pool, 1 ms window, broadcast | 1.032–1.067 | It won on #7's statements (0.960), but MEGA already builds the tag list once per drain; the pool built it 4.6 times as often |
| Article half by array-key lookups | +2.4% instructions | Worse |
| A newer comments batch statement | Not shown cheaper in 2 of 3 passes | Unproven |
| Shared feed walks per followee | +4.6% to +37.6%; a second version tied | |
| Feed counts per distinct followee | 4.05–4.46x the tuples; 1.26–1.30x even with the count proof | |
| Feed paged from its count | +1% | |
| Per-list output arrays | Task-clock not better | |
| Per-column result formats | About 0.1% at best | Not worth the code |
| Feed: k-way merge-append | +22% | |
| Feed: tags joined in the spec | +9% | |
| Feed: custom plans | +38% | |
| Feed: constant `LIMIT 100` | +9.4% | |
| Feed: favorited from one scan | +32% | |
| Feed: count proof from `pg_stats` | 1.065 | The `OFFSET 999` probes won |
| Feed: `articles_pkey` scan | +22% | |
| Feed: bounded page | +3.2% | |
| Lists: favorites fused into the page | +15% to +17% | |
| Lists: count skipped on short pages | +0.86% | |
| Lists: one walk for page and count | −0.07% | Noise |
| Lists: favorite counts from one grouped scan, alone | +1.82% | Lost on lists alone; inside MEGA, where drains are large, it shipped |
| Lists: drain's articles by one `articles_pkey = ANY` scan | +51.9% | The generic plan estimates `= ANY` over a whole-drain array as a large scan |
| Lists: favorited flag from one drain-wide join | +38.1% | Same plan problem |
| Lists: TID-range count probe | −8.7% instructions, +3% cycles | Touches 125 heap pages |
| Article page: comment thread once per distinct slug | +47% | |
| Article page: authors once per drain | +43% | |
| Article page: favorite count and flag in one scan | +12% to +18% | |
| Article page: tags by `array_agg ... ORDER BY` | +24.5% | |
| Article page: lookup by slug and id | +1% to +2% | |
| Article page: tags plus favorite count together | +10.5% | |
| Article page: every follow flag from one hashed set | +11.7% | |
| Comments: followee ids once, threads once per drain | 0.847–0.916 cycles offline; −0.45 µs/req on the box | Didn't survive the live box |
| MEGA tag ids instead of names | 0.984 cycles offline; 0.0 on the box | |
| Tag list body built once (1,036 → 9.8 ns) | 0.0 on the box | Right, but too small to see |
| Comment authors in one scan | +6% to +8% | |
| Array-key entity scans | +2% | |
| Comments outside MEGA, at 50 ms | 1.000 | Subsumed at 50 ms; it won at 5 ms (0.925), which is why it shipped |
| Profile writes without batch forms | +36% to +60% | Batching is the point |
| `NOT EXISTS` inserts | Fewer WAL records, +1.9% to +2.7% CPU | CPU is what we're short of |
| Username-to-id lookups first | +16% to +29% | |
| Describe on every execution, REPEATABLE READ, a Sync per read | Inside the noise | |
| An open transaction across a drain | 0.965 | Not stacked: there is already one Sync per drain |

---

## Credits

The SQL starts from [#7](https://github.com/arjaythedev/multicore-server-challenge/pull/7) (rank 1): list page and
capped count in one statement, tag names by primary key, write CTEs that fold the slug lookup into the mutation, and
the `unnest ... WITH ORDINALITY CROSS JOIN LATERAL` read batching. #7 is also the yardstick for our SQL numbers and the
source of the per-endpoint costs in an earlier shed design. The ideas are reimplemented here; no code is copied.

- **#47**: the two-phase gather behind the batch clock, and the idea of one statement for many reads that MEGA grew
  from. #47 also runs 9 Postgres connections.
- **#37, #50**: similar read batching. **#37, #4, #7**: group commit.
- **#45, #53**: interleaved-lane assembly bcrypt. **#37**: calibrating the lane count.
- **#10, #22, #11, #4**: the `OFFSET 999` capped-count probe.
- **#56, #53**: read connections at 5/8 of the cores.
- **rust-epoll, #152, #45**: `TCP_NODELAY` set once on the listener.
- **#11, rust-epoll, #15**: scanning JWT claims in one pass.
- **#45**: zero-copy send, which ships there and lost here.
- **#18**: the SIGILL that made us build for x86-64-v3.
- **#31**: the precedent for sharing work across concurrent requests within one execution.

Openwall, the Rust `bcrypt` crate and Go's `golang.org/x/crypto/bcrypt` supplied the test vectors. The Go reference
server was the oracle for every byte we send.

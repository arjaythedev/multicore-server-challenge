# Zig / io_uring

Front: direct

| | |
|---|---|
| Language | Zig 0.17.0 (official tarball, pinned by SHA-256 in `install.sh`) |
| Framework | none: our own HTTP/1.1 server on raw io_uring |
| Database driver | none: our own PostgreSQL wire client (SCRAM-SHA-256, prepared statements, binary rows) |
| Database | PostgreSQL 18 |
| Other dependencies | none. JSON, JWT, SHA-256, bcrypt (assembly) and gzip are written here |

```sh
sudo bash install.sh && bash build.sh
DATABASE_URL=... JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

No caches across requests, no schema or Postgres config changes, no host tuning.

## Where the time goes

```
box CPU at 170k users   ████████████████████████████▌   Postgres 57%
                        ████████████████                server   32%  (mostly kernel TCP)
```

Postgres is the bottleneck, so most of the speed comes from making each request cheaper for Postgres. The rest
comes from not preempting it and from sending fewer packets.

## What we learned: the score is set on an ageing database

The search probes upward in 1-minute steps, then has to hold a level for 5 minutes. Every phase writes real rows and
nothing is reset in between, so each hold runs on a bigger, more worn database than the probes before it. Postgres
time per request grew from 88 to 110 µs with the data. `follows` wears worst: in one search autovacuum cleaned it
during the probes but not during any hold, and its pages marked all-visible fell from 96% to 2%. The app's role
can't vacuum. So a faster build can score lower: it passes a higher probe, fails that hold, and every lower hold
gets harder. One failed 210k hold cost about 140 ms of p95 at 200k. That is why the numbers below come from paired
5-minute holds at 200k users on aged databases, not from probes.

## 1. One read queue for the whole box

Most servers batch reads per worker. We batch every worker's reads together in one **drain process** that owns
all the read connections.

```
 typical                                   ours

 worker ─ queue ─ conns ─┐                 worker ─┐
 worker ─ queue ─ conns ─┤                 worker ─┤  lock-free rings     ┌ feeds    (every 80 ms) ┐
 worker ─ queue ─ conns ─┼─► Postgres      worker ─┼─ in shared memory ─► drain  comments (100 ms) ├─► Postgres
 worker ─ queue ─ conns ─┘                 worker ─┘                      └ the rest (80 ms)       ┘
                                                                            8 read connections
 4 small batches                           1 big batch per lane
```

A bigger batch shares more work, so each read costs Postgres less. One shared queue costs about 20% less
Postgres CPU than four separate ones, and the rings add only 1-3 µs per request. Feeds, the most expensive read,
get their own lane so nothing waits behind them. Every 10 s the drain process logs each lane's counters.

Each lane runs at most two drains at once. Late in a run the feed lane sits at that cap most of the time, so once the
oldest queued feed has waited 120 ms it borrows a third slot from the shared lane. Feed drains get smaller and
quicker. In paired 200k holds on an aged database, feed p95 fell by about 450 ms and overall p95 by 59 and 128 ms,
while the other reads waited up to 130 ms longer.

## 2. One SQL statement for every list and article read

```
 1,400 reads in a drain                       one execution of MEGA
 ┌───────────────────────────┐
 │ list all, page 1          │               ┌──────────────────────────┐
 │ by tag "zig", page 2      │   ────────►   │ each article fetched ONCE │ ──► worker builds every
 │ feed for user 812         │               │ for every read that wants │     response from the rows
 │ article "how-to-x"  × 37  │               │ it, plus per-read ids     │
 │ ...                       │               └──────────────────────────┘
 └───────────────────────────┘
```

Every list, feed and article read in a drain runs as **one execution of one prepared statement**, with arrays as
parameters. An article that many reads in the batch need is read once. That costs about 0.6x the Postgres CPU of
per-request batched SQL. Nothing is kept after the execution.

The feed gets exact shortcuts: authors with 1,000+ articles prove a viewer's count without counting, and a
viewer's walk stops early once a shared followee already fills their page.

Three smaller changes trim what MEGA asks of Postgres, each about 1% fewer Postgres instructions per execution:

- **Tags as one text.** Each article's tags come back as one string joined by a separator no tag name contains,
  not as an array. The drain process turns it back into the array bytes Postgres would have sent, so nothing after
  it changes. If a tag name ever contains the separator, that execution falls back to the array.
- **One name lookup per list.** A tag name or username that several list reads share is looked up once.
- **Article ids in id order.** The set of article ids is built sorted, so the later steps that need it sorted
  don't sort it again.

## 3. Event loops don't preempt Postgres, and bcrypt only uses spare CPU

```
 SCHED_OTHER  Postgres
              watchdog: takes over any hash batch held up too long, resumes from its last saved round
 SCHED_BATCH  drain process: the same CPU share, but waking up doesn't preempt a running task
              event loops: the same, at nice 5
 SCHED_IDLE   bcrypt hashers: only CPU nothing else wants
```

Postgres and the server share the 8 CPUs. Under the default policy, an event loop woken by an io_uring completion
preempts whatever runs on its CPU, such as a Postgres backend in the middle of a query. Under SCHED_BATCH the loop
keeps its CPU share but waits until the running task blocks or uses up its slice. At 200k users on our test rig,
p95 fell by 93-172 ms and feed p95 fell from 1.2-1.6 s to 0.7-0.8 s. Of everything here that we measured in holds,
this moved p95 the most.

The event loops also run at nice 5, so when the CPUs are full they yield a little time to the drain process and
Postgres. The drain process waited half as long for a CPU and Postgres 18% less, so every read lane emptied faster.
In paired 200k holds on an aged database p95 fell by 30 and 41 ms; login, which waits on the loops, rose 84 ms at
p95.

Hashing never takes CPU from anything else. The kernel is our own assembly, hashing five passwords at once with
their rounds interleaved. It takes each round's index bytes apart with SHRX and RORX, one micro-op fewer per round
on Intel cores than BEXTR: on our test rig's Xeon a hash costs 5.6% less than with the next-fastest kernel.
At startup it is checked against known hashes and timed for the watchdog.

## 4. Comments read only what the thread needs

```
 one comments execution
   each thread ──► its newest comments ──► their authors ─┬─► each author's profile, read once
                                                          └─► follows: viewer → these authors only
```

Comments have their own batched statement. To set `following` on each comment it looks up only the follows from
the viewer to that thread's comment authors, not the viewer's whole followee list. `follows` is the table that ages
worst, so this pays most late in a run. On a `follows` table aged by a run's follows and unfollows, a 950-request
comments batch costs Postgres 23% fewer instructions. At 200k users, index fetches on `follows` per comments request
fell from 27.7 to 8.3, and paired holds ran 9 and 25 ms lower at p95.

The statement also reads each comment author's profile once per execution and attaches it to every comment by that
author (the idea is from WorriedArrow's #152). Threads fill up as a run goes on, so authors repeat more late in a
run; on a database aged by a full search, 200k-user holds ran 47 ms lower at p95 with it.

## 5. Repeated reads in one execution share one response

```
 one execution, worker 2

 tags                ┐                                        ┌──► client a
 tags                ├──► rows once ──► render + gzip once ───┼──► client b
 tags                ┘                                        └──► client c
 feed for user 812   ───► its rows ───► its own response ────────► client d
```

Many reads in one execution repeat: the tag list, page 1 of the global list, a popular tag's page. Reads with the
same statement and parameters, on the same worker and with the same response head (keep-alive, gzip), get the same
bytes unless their rows set the viewer's `favorited` or `following`. The drain process hands over their rows once.
The worker renders and gzips them once and sends that one buffer to each client. In our 200k-user simulation about
a third of all requests are such repeats. On a replay of that load the server ran 32% fewer user-space
instructions per request. In 200k holds on the test rig it saved about 2-2.6 µs of server CPU per request, with p95
the same within noise.

The buffer is freed when its last send completes, and each execution starts with nothing shared, so a response
never outlives the requests it answers.

## 6. Fewer packets

One CPU handles every incoming packet, and it fills before the rest of the box. A client ACKs every second
segment, so every segment we save is an ACK we don't receive.

**Gzip only when it saves a segment.**

```
 response needs ≤ 2 segments?   → send as is
 gzip it                        → fewer segments now?  → send gzipped
                                → same count           → send as is
```

A 10-article list goes from 4 segments to 2. Our encoder (`src/pz.zig`) uses a fixed code table compiled in, so
nothing carries over between responses. It compresses a 5 KB list in about 3 µs, 4.6x faster than libdeflate.

**ACK delay, off by default.**

```
 off                                       on
 client ── request ──►                      client ── request ──►
        ◄── ACK ──────  (a packet alone)           (ACK held back)
        ◄── response ─                            ◄── response + ACK ──  (one packet)
```

With it on, after each response the server turns `TCP_QUICKACK` off on that socket, as an io_uring command with no
syscall. The next ACK rides on the response: 27% fewer pure ACKs, 12% less load on the network core. A response
sent within 15 ms of its request skips the command, since the kernel already holds the ACK back after a reply that
quick.

start.sh leaves it off (`CONDUIT_FLAGS=ackdelay=off`). At 200k users most replies miss the delayed-ACK window
anyway. In paired 5-minute holds at 200k it ran 33-36 ms lower at p95 with it off, and 64 and 72 ms lower on an
aged database.
`CONDUIT_FLAGS=ackdelay=on` turns it on.

## 7. Writes and the event loop

- **Group commit with no `BEGIN`/`COMMIT`.** Up to 128 writes go out in one round trip and share one disk flush.
  Each is answered only after Postgres confirms it. 38% cheaper than our earlier write path.
- **One io_uring per worker**, multishot accept and receive, one send per response. An idle connection holds no
  buffer.
- **Less ring bookkeeping.** Receive buffers go back to the kernel in runs of consecutive ids, one request per run.
  Client and Postgres sockets sit in the ring's fixed-file table, so the kernel skips the file lookup on each
  operation. A Postgres receive that follows an empty one waits for data before trying. Together these save under
  1 µs per request; with the 15 ms ACK skip from section 6, paired 200k holds ran 7 and 16 ms lower at p95.

## Correctness

- At startup every SQL statement is checked against the live database. The server won't start if a column type
  doesn't match what its decoder expects.
- Batched reads were checked byte-for-byte against the same read sent alone, and responses against the Go reference
  server. bcrypt matched reference implementations on 218,496 cases.
- Shared responses matched the server without sharing byte-for-byte on a replay of 151,226 reads, 3,180 of them with
  `favorited` or `following` set. The io_uring set matched on the same replay, and the three MEGA trims on 4,000
  reads, including tag names built to hit the fallback. The comments follows lookup matched on 1,639 comment reads,
  488 of them with `following` set.
- If any process dies, the parent kills the rest, so a crash is never a half-working server.

Ideas borrowed: #47's gather (the drain gap), #7's array-parameter batching, #61's feed count for authors with
1,000+ articles, #105's hub floor (the early stop for shared followees), and WorriedArrow's #152 for reading comment
authors once. SCHED_BATCH is common to several entries, and #130 measured it. #130 also counts bcrypt
instructions per lane-round, as we did for our kernel. Sharing a response within one execution has #31 as precedent
and follows the form of theCatWisel's #132 and #143. Test vectors: Openwall, Rust `bcrypt`, Go `x/crypto/bcrypt`.

Ours: the single read queue across workers and the feed lane's borrowed third slot, MEGA and its three trims, the
comments follows lookup scoped to the thread's authors, gzip only when it saves a segment and its encoder, ACK delay
as a ring command, the ring bookkeeping set, and the SHRX bcrypt kernel.

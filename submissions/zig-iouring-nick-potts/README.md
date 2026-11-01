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
comes from sending fewer packets.

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

Comments have their own batched statement. It now looks up only the follows among that thread's comment authors,
not the viewer's whole followee list. On a `follows` table aged by a run's follows and unfollows, a 950-request
comments batch costs Postgres 23% fewer instructions. It also reads each comment author's profile once per batch
and attaches it to every comment by that author. Threads fill up as a run goes on, so authors repeat more late in a
run; on a database aged by a full search, 200k-user holds ran 47 ms lower at p95 with it.

## 3. Repeated reads in one execution share one response

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
instructions per request.

The buffer is freed when its last send completes, and each execution starts with nothing shared, so a response
never outlives the requests it answers.

## 4. Fewer packets: ACK delay

One CPU handles every incoming packet, and it fills before the rest of the box. So we cut packets.

```
 before                                    after
 client ── request ──►                      client ── request ──►
        ◄── ACK ──────  (a packet alone)           (ACK held back)
        ◄── response ─                            ◄── response + ACK ──  (one packet)
```

After each response the server turns `TCP_QUICKACK` off on that socket, as an io_uring command with no syscall.
The next ACK rides on the response: 27% fewer pure ACKs, 12% less load on the network core. A response sent within
15 ms of its request skips the command, since the kernel already holds the ACK back after a reply that quick.

This build turns it off by default (`CONDUIT_FLAGS=ackdelay=off` in start.sh). At 200k users most replies miss the
delayed-ACK window anyway, and in paired 5-minute holds at 200k the build ran 33-36 ms lower at p95 without it.
`CONDUIT_FLAGS=ackdelay=on` turns it back on.

## 5. Fewer packets: gzip only when it saves a packet

A client ACKs every second segment, so every segment we save is an ACK we don't receive.

```
 response needs ≤ 2 segments?   → send as is
 gzip it                        → fewer segments now?  → send gzipped
                                → same count           → send as is
```

A 10-article list goes from 4 segments to 2. Our encoder (`src/pz.zig`) uses a fixed code table compiled in, so
nothing carries over between responses. It compresses a 5 KB list in about 3 µs, 4.6x faster than libdeflate.

## 6. Event loops don't preempt Postgres, and bcrypt only uses spare CPU

```
 SCHED_OTHER  Postgres
              watchdog: takes over any hash batch held up too long, resumes from its last saved round
 SCHED_BATCH  event loops, drain process: the same CPU share, but waking up doesn't preempt a running task
 SCHED_IDLE   bcrypt hashers: only CPU nothing else wants
```

Postgres and the server share the 8 CPUs. Under the default policy, an event loop woken by an io_uring completion
preempts whatever runs on its CPU, such as a Postgres backend in the middle of a query. Under SCHED_BATCH the loop
keeps its CPU share but waits until the running task blocks or uses up its slice. At 200k users on our test rig,
p95 fell by 93-172 ms and feed p95 fell from 1.2-1.6 s to 0.7-0.8 s.

Hashing never takes CPU from anything else. The kernel is our own assembly, hashing five passwords at once with
their rounds interleaved. It takes each round's index bytes apart with SHRX and RORX, one micro-op fewer per round
on Intel cores than BEXTR: on our test rig's Xeon a hash costs 5.6% less than with the kernel #117 picked there.
At startup it is checked against known hashes and timed for the watchdog.

## 7. Writes and the event loop

- **Group commit with no `BEGIN`/`COMMIT`.** Up to 128 writes go out in one round trip and share one disk flush.
  Each is answered only after Postgres confirms it. 38% cheaper than our earlier write path.
- **One io_uring per worker**, multishot accept and receive, one send per response. An idle connection holds no
  buffer.
- **Less ring bookkeeping.** Receive buffers go back to the kernel in runs of consecutive ids, one request per run.
  Client and Postgres sockets sit in the ring's fixed-file table, so the kernel skips the file lookup on each
  operation. A Postgres receive that follows an empty one waits for data before trying. Together these save under
  1 µs per request.

## Correctness

- At startup every SQL statement is checked against the live database. The server won't start if a column type
  doesn't match what its decoder expects.
- Batched reads were checked byte-for-byte against the same read sent alone, and responses against the Go reference
  server. bcrypt matched reference implementations on 218,496 cases.
- Shared responses matched the previous build byte-for-byte on a replay of 151,226 reads, 3,180 of them with
  `favorited` or `following` set. The io_uring changes matched on the same replay, and the three MEGA changes on
  4,000 reads, including tag names built to hit the fallback. The comments change matched on 1,639 comment reads,
  488 of them with `following` set.
- If any process dies, the parent kills the rest, so a crash is never a half-working server.

Ideas borrowed: #47's gather (the drain gap), #7's array-parameter batching, #61's feed count for authors with
1,000+ articles, and #105's hub floor (the early stop for shared followees). SCHED_BATCH is common to several
entries, and #130 measured it. Sharing a response within one execution has #31 as precedent and follows the form
of theCatWisel's #132 and #143. Test vectors: Openwall, Rust `bcrypt`, Go `x/crypto/bcrypt`.

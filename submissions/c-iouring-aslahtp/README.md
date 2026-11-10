#  C + io_uring, no framework

**Front: direct.** The server listens on `0.0.0.0:80` itself and holds every user's keep-alive connection.

| Piece | Version |
|---|---|
| Language | C (gnu11), GCC 13.3 from Ubuntu 24.04 (`build-essential`) |
| I/O | io_uring via liburing 2.5 (Ubuntu 24.04 `liburing-dev`) |
| HTTP/1.1, JSON, JWT (HS256), SHA-256, bcrypt | written from scratch, in `src/` |
| Postgres driver | written from scratch: protocol 3.0, SCRAM-SHA-256, named prepared statements, binary rows, pipelining (`src/pg_wire.c`) |

`install.sh` installs `build-essential liburing-dev` from the Ubuntu archive. `build.sh` is one `gcc` call.
`start.sh` runs `bin/conduit`, configured by `DATABASE_URL`, `JWT_SECRET`, `HOST` and `PORT`.

## Design

Postgres does most of the work on this box, so the design aims at the Postgres CPU each request costs, then at
keeping our own processes out of its way.

### Processes

- **One parent, one drain process,** `WORKERS` **worker processes** (CPUs / 2). Children die with the parent; if any
child exits, the parent kills the rest and exits, so a crash is a dead server, never a half-working one.
- **Workers** each run one io_uring (single issuer, deferred task running): a multishot accept on their own
`SO_REUSEPORT` listener and one multishot receive per connection into the ring's provided buffers. An idle
connection owns no buffer: holding 200,000 idle keep-alive connections costs about 360 bytes each. A request is
parsed where it lands; each response is one send (the body is written behind a reserved gap, the header goes in
the gap).
- **ACK delay.** After each response the worker turns `TCP_QUICKACK` off on that socket (an io_uring socket
command on kernel 6.7+, a plain `setsockopt` on older kernels), so the ACK of the next request leaves with its
response instead of as a packet of its own: fewer packets for the receiving CPU.
- `SCHED_BATCH=1` (off by default) puts the parent under `SCHED_BATCH` before forking, so every process and
thread inherits it: our wakeups stop preempting busy Postgres backends. On a CPU-starved test machine it raised
response latency (event loops waited for their time slice), so it stays opt-in.
- **The drain** owns every Postgres read connection (`READ_CONNS`). Workers hand it reads through shared-memory
rings with eventfd wake-ups and get finished responses back the same way.

### Reads: the planner

The hot GETs (article, comments, article lists, feed, profile, tags) are planned: the drain gathers them from all
workers and answers each batch with two pipelined round trips of set-based SQL on one connection.

- **Phase A**, one statement per family present: pages and capped counts per list kind, the feed, articles by
slug, comments, profiles, the tag list. Keys are deduplicated first (one page per distinct filter, limit and
offset; one count per filter; one lookup per slug or username). Pages come back as lean article rows.
- **Phase B**: every distinct article once (tag ids, favorites count), every distinct author once, the tag
dictionary (all tags in name order, so a tag's position is its sort rank), and one statement for every viewer's
favorited/following flags, as a primary-key range scan per viewer instead of a probe per article.
- **The feed** is one statement for counts and pages. Followees shared by several viewers of the batch are looked
at once: one with 1,000+ articles proves the capped count of everyone following it without counting, and its
article at the deepest page any of them needs bounds every followee's walk.
- **Lanes.** Planned reads wait in three queues: feeds (the dearest read), comments, and everything else. A plan
takes requests of one lane only, so no list or article waits behind the feed statement. Each lane runs on its own
clock: a plan starts once the lane's oldest request has waited `LANE_WINDOW_US` and the lane's gap has passed
since its previous plan started (at once if the lane holds a full plan), and only while fewer than the lane's cap
of its plans are running. Below saturation a plan takes everything that arrived in one gap; near it, executions
outlast the gap, the cap binds, and the next plan takes everything that arrived meanwhile, so batches grow with
the load instead of the number of plans competing for the cores. Measured on the full seed at the same load, this
cut Postgres CPU per request by about 30% against starting a plan whenever a connection was free.
- JSON is rendered in C from binary rows; fragments shared by many responses (an article's tag list) are rendered
once per plan. Nothing outlives the plan: every result is dropped once its responses are sent (rule 5).
- Generic plans are forced (`plan_cache_mode`), so page subqueries keep a constant `LIMIT 100` wrapper: a
`LIMIT $n` alone is estimated at 10% of the table and turns index walks into hash joins.

Rare reads (login lookup, current user) go through the drain unplanned.

**Clients that hung up** cost nothing more. Each worker publishes, per connection, a generation number that
changes when the connection closes (a shared-memory table, mapped before fork). A plan leaves out every request
whose client is gone, and bcrypt skips their jobs, so the backlog an overload leaves behind does not spill into the
next load.

### Writes

- Each worker has its own write connection. Queued writes go out together as one Sync, one implicit
transaction, one WAL flush (group commit, up to `WRITE_GROUP`); every response still waits for that commit
(rule 6). A failing group is retried one write at a time; sign-up and profile updates (unique names) always
commit alone.
- Writes find their target themselves (follow, favorite by slug in one statement), so a write is one round trip
plus its read-back in the same transaction.
- A write waits up to `WRITE_WAIT_US` (3 ms) for others to share its group, unless a full group is already queued.
- **Merged writes.** Within a group, favorites, unfavorites, follows, unfollows and new comments of one kind run as
one statement over arrays, and its rows are split back per request. Each favorite's read-back still runs on its
own, after the merged statement. New comment ids are drawn in request order. Any other write (publish, edit, a
delete) keeps its place and ends the run, and so does a user who comes back with another kind of write, so no
user's writes change order. A failing group is still retried one write at a time, unmerged.

### Auth and bcrypt

- JWT HS256 is verified on every request, with SHA-NI when the CPU has it and precomputed HMAC states.
- bcrypt cost 10 runs on one hasher thread per worker at nice 10. The kernel interleaves 4 independent hashes
(one bcrypt is a single dependency chain on S-box loads; 4 chains keep the load ports busy): 2.9x the
throughput of one at a time, bit-identical to the reference implementation. A lone job waits up to
`BCRYPT_WAIT_MS` for company; logins and sign-ups are under 0.1% of requests, so this does not move the
percentiles. A job that waited over 8 s is answered 503 instead of hashed, and a job whose client hung up is
dropped.

### Postgres session

`plan_cache_mode = force_generic_plan`, `jit = off`, `max_parallel_workers_per_gather = 0` on every connection.
`PG_TUNE=1` adds `enable_memoize = off`, `enable_hashagg = off`, `work_mem = 32MB`, `random_page_cost = 1.1`.

## Tuning variables

| Variable | Default | Meaning |
|---|---|---|
| `WORKERS` | CPUs / 2 | worker processes |
| `READ_CONNS` | 8 | drain read connections (one plan each at a time) |
| `WRITE_CONNS` | 1 | write connections per worker |
| `LANES` | 1 | feeds, comments and the rest plan apart, each on its own clock (0: one queue, paced as below) |
| `LANE_WINDOW_US` | 5000 | least time a lane's oldest request waits for company |
| `FEED_GAP_US` / `CMT_GAP_US` / `SHARED_GAP_US` | 80000 / 100000 / 80000 | least time between a lane's plan starts |
| `FEED_CAP` / `CMT_CAP` / `SHARED_CAP` | 2 / 2 / 3 | most plans of a lane running at once |
| `PLAN_PACE` | 1 | with `LANES=0`: load-following plan wait (0: fixed `PLAN_WAIT_US`) |
| `PLAN_WAIT_US` | 20000 | with `LANES=0`: cap on (or, with `PLAN_PACE=0`, the) plan wait |
| `ACK_DELAY` | 1 | `TCP_QUICKACK` off after each response |
| `SCHED_BATCH` | 0 | run under the `SCHED_BATCH` scheduling policy |
| `PLAN_MAX` | 4096 | most requests in one plan |
| `PLANNER` | 1 | 0: every read as a plain per-request query |
| `WRITE_GROUP` | 128 | most writes per group commit |
| `WRITE_WAIT_US` | 3000 | how long a write waits for others to share its group |
| `WRITE_MERGE` | 1 | writes of one kind in a group run as one statement over arrays |
| `SKIP_GONE` | 1 | drop queued reads and bcrypt jobs whose client hung up |
| `BCRYPT_THREADS` / `BCRYPT_BATCH` / `BCRYPT_WAIT_MS` / `BCRYPT_NICE` | 1 / 4 / 1000 / 10 | hasher threads per worker, jobs per kernel run, wait for company, niceness |
| `PG_TUNE` | 0 | extra planner settings (above) |
| `DIRECT_FDS` | 0 | io_uring direct descriptors for client sockets (no measured gain on loopback) |

Total Postgres connections, `READ_CONNS + WORKERS x WRITE_CONNS`, must stay within 95.

### Measured

The lane and connection defaults come from #117 (see Credits); I checked them with my own sweep: about 90 local
runs on the full seed, server and Postgres pinned to 8 CPUs, the load generator on 8 others, about 30k req/s
(the box's rate at 120,000 users). Each setting ran in shuffled rounds, compared on CPU per request (ours plus
Postgres) and p95. Nothing beat the defaults; these were clearly worse:

| Setting | Tested | Result |
|---|---|---|
| `READ_CONNS` | 5, 6, 8, 10, 12 | 5 and 6 collapse (p95 7–10 s); 8 to 12 indistinguishable |
| `SHARED_GAP_US` | 20, 40, 80, 120 ms | 20 ms costs about +12 µs CPU per request; 120 ms adds about 80 ms of p95 |
| `FEED_GAP_US` | 40, 80, 120 ms | no consistent difference |
| `CMT_GAP_US` | 50, 100 ms | no difference |
| `LANE_WINDOW_US` | 2, 5, 10 ms | no difference |
| `FEED_CAP` / `CMT_CAP` / `SHARED_CAP` | 1–3 / 1–3 / 2–4 | a feed cap of 1 breaks feeds (p95 4–10 s); the rest within noise |
| `WORKERS` | 3, 4, 5 | 5 costs about +9 µs CPU per request |

## Tests

- `bash tests/unit.sh`: SHA-256 (generic and SHA-NI), HMAC, PBKDF2, base64, JWT, JSON, bcrypt (every lane count
of the interleaved kernel against the reference) and the Postgres wire format, checked against vectors computed
independently by Python (`tools/gen_vectors.py`).
- `bash test/run.sh submissions/c-iouring-aslahtp` from the repo root: the conformance suite.
- `bash tests/diff/run.sh [TEMPLATE]`: randomized reads and scripted writes against the Go reference server
(`examples/go`), comparing parsed responses.
- `tests/bench/`: `measure.sh` (throughput, latency and CPU per request for us and for Postgres), `prewarm.sh`
(a reusable, cached measurement database) and `conns.c` (holds N idle keep-alive connections and checks none
is dropped).

## Credits

- I got these ideas from nick-potts' [zig-iouring-nick-potts](../zig-iouring-nick-potts) (#79, #117): the drain
process with shared-memory rings, set-based batch reads, the feed shortcut for authors with 1,000+ articles, the
feed/comments/rest lanes with their gaps and read-connection count (checked in Measured above), ACK delay, group
commit without `BEGIN`/`COMMIT`, forced generic plans and the process layout.
- I got the idea of merging runs of favorites, follows and comments into one statement from
[asm-epoll-nickita-khylkouski](../asm-epoll-nickita-khylkouski) (#82, #130),and dropping the queued work of clients that hung up from
[rust-epoll-theCatWisel](../rust-epoll-theCatWisel) (#132).

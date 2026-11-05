# Ruby / io_uring connections in C / forked workers / batch planner

Front: direct

| | |
|---|---|
| Language | Ruby 4.0.7 with YJIT and jemalloc, built from the checksummed source tarball by `install.sh` into `/opt/ruby` |
| HTTP | Own connection layer in C (`ext/ring/ring.c`) on liburing 2.5 (Ubuntu 24.04): io_uring direct descriptors, multishot receive, buffer rings, HTTP/1.1 framing in C. An epoll fallback in Ruby (`epoll_server.rb`, `CONNECTIONS=epoll`) |
| Concurrency | `async` 2.46.0 / `io-event` 1.22.1 fibers, one forked process per worker |
| Postgres driver | `pg` 1.7.0, compiled against libpq 18 from the PGDG repo, used in pipeline mode (`db.rb`) |
| bcrypt | C extension (`ext/bcrypt`): Solar Designer's public-domain Openwall bcrypt core with the lane-interleaved driver from [PR #7](https://github.com/arjaythedev/multicore-server-challenge/pull/7) (MIT), cost 10 |
| JWT | HS256. The byte work (split, base64url, HMAC-SHA256, constant-time compare) is in C on libsodium 1.0.22 (`ext/jwt`); claims, `sub` and `exp` are checked in Ruby |
| Other gems | `json` 3.1.0, `rbnacl` 7.1.2, `ffi` 1.17.4, all pinned in `Gemfile.lock` and compiled from source (`force_ruby_platform`) |

```bash
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

## Design

Postgres does most of the work in this workload, and Ruby runs one thread at a time per process. So the server
spends as little Postgres CPU per request as it can, keeps Ruby's share of each request small, and spreads the
Ruby work over processes.

### Processes

| Process | Does |
|---|---|
| master (`server.rb`) | Loads the code, warms YJIT on the whole request path against the database without writing anything, calibrates the bcrypt lanes, makes every socketpair, then forks. Afterwards it runs `BcryptService` at nice 10 |
| `WORKERS` workers (3/4 of the cores) | Each has its own io_uring ring, 2 `SO_REUSEPORT` listeners and `PG_CONNECTIONS` Postgres connections. The kernel spreads client connections over the listeners |

The YJIT code compiled during warm-up is shared with the workers through fork. If a worker dies, the master stops
the rest and exits: the box doesn't restart a crashed server, and a partly dead one would just be slower.

Three quarters of the cores, because Postgres shares the box and fewer workers make bigger read batches. Locally,
6 workers on 8 cores passed 20,000 users where 8 failed.

### Connections (`ext/ring/ring.c`)

Every client connection is an io_uring direct descriptor, a slot in the ring's registered-file table, so tens of
thousands of keep-alive connections cost no file descriptors. Each connection has one multishot receive armed for
its lifetime, filled from a buffer ring. The C code frames requests (request line, the four headers the app
needs, body) and calls the app directly for GETs. Requests that may wait on a write batch go to a worker fiber
instead. Responses are copied into shared send segments, with one send in flight per connection.

### Reads: the batch planner (`planner.rb`, `sql.rb`)

The design follows `node-uwebsockets-zahidcakici`, which credits [PR #47](https://github.com/arjaythedev/multicore-server-challenge/pull/47).

A read request joins the current batch, and its fiber waits. The first request of a batch opens a 40 ms window
(`READ_WINDOW_MS`). When the window closes, the batch goes to Postgres in two pipelined round trips:

- **Phase A** resolves what each request is about, with one statement per request kind over the batch's
  distinct keys: slugs, usernames, tag and author filters, feed viewers, and capped counts.
- **Phase B** enriches every article that phase A returned once: tags, favorite counts and authors. It also reads
  the `favorited` and `following` flags, only for the (viewer, article) and (viewer, author) pairs that a
  response will show. The flag pairs are deduplicated and written straight into `int8[]` literals.

Each worker runs two batches at once (`READ_LANES`): two planner objects share one intake. With a single lane,
one slow batch held up every read behind it while Postgres had connections to spare. On the full seed at 30,000
users on 4 cores, p95 went from 617 ms to 73 ms.

Batches hold at most `READ_MAX` (256) requests. Nothing outlives a batch: every value in a response was read from
Postgres while that request waited.

After a favorite or unfavorite, the article comes back through the planner (`article_by_id`) instead of a separate
query.

Counts use one capped pass: `(SELECT count(*) FROM (… LIMIT 1000) s)`.

### Writes: group commit (`db.rb`)

The writes of one event-loop pass become one pipeline group with one Sync. If the group fails, each write is
retried on its own, so one bad write can't fail its neighbours. Sign-ups, profile updates and article creation
stay out of groups.

Every write commits before its response is sent.

### bcrypt

Hashes from all workers go to the master over SEQPACKET socketpairs. The master's `BcryptService` runs them
through the interleaved lanes: it waits up to 300 ms (`BCRYPT_WAIT_MS`) to fill a lane and uses 2 threads. The
master runs at nice 10, so request handling and Postgres go first.

### Responses (`ext/fmt`)

Article and comment JSON is built in C, one call per article or comment. The C code handles string escaping and
timestamp formatting. Ruby splices in the per-viewer flags.

### Postgres session settings

- `jit = off`.
- Generic plans are forced.
- `max_parallel_workers_per_gather = 0`.
- Connections use `sslmode=disable` (`PG_SSLMODE`). The box's Postgres has `ssl = on` and `DATABASE_URL` names no
  sslmode, so libpq was otherwise running TLS over loopback.

The total number of connections, `WORKERS × PG_CONNECTIONS` (plus any planner processes), is checked against 95
at start-up.

### GC (`start.sh`)

Every response is a few KB of fresh strings. With the default malloc limits, that growth alone set off most minor
GCs. `start.sh` makes the following changes:

- It raises the malloc limits: `RUBY_GC_MALLOC_LIMIT` to 64 MB and `RUBY_GC_OLDMALLOC_LIMIT` to 128 MB.
- It keeps more free slots after each GC.
- It starts with a larger heap: 1.5M and 500k slots in the two smallest size pools.

In local paired runs at 20,000 users, the malloc limits alone raised throughput from 34–35k to 37–40k req/s. On a
4-vCPU rig at 52,000 users, the larger heap passed 3 runs of 3, against 1 of 4 without it.

YJIT compiles after 5 calls instead of 30.

## Options

The defaults are what's benchmarked.

| Variable | Default | |
|---|---|---|
| `WORKERS` | 3/4 of the cores | HTTP worker processes |
| `PG_CONNECTIONS` | 2 | Postgres connections per worker, one per read lane |
| `READ_WINDOW_MS`, `READ_LANES`, `READ_MAX` | 40, 2, 256 | planner window, batches in flight per worker, requests per batch |
| `BCRYPT_THREADS`, `BCRYPT_WAIT_MS` | 2, 300 | bcrypt service |
| `CONNECTIONS` | io_uring | `epoll` for the Ruby fallback |
| `PLANNERS` | 0 | experimental: shared planner processes behind shared-memory rings (`remote_planner.rb`, `ext/shmq`) |

## What didn't help (measured on the 4-vCPU rig)

- **Shared planner processes** (`PLANNERS=1`). One planner for the whole server cut Postgres CPU by 31%, but that
  one Ruby process ran out of its core. With 2 planners, a 4-vCPU box had too little CPU left. It's kept as an
  option for bigger boxes.
- **Feed scans shared between viewers** (`FEED_SHARED_DEPTH`). Feed Postgres cost doubled.
- **Workers at nice 5**, 2 workers instead of 3, and a 120 ms read window.

## Results on a 4-vCPU test rig

The rig has 4 vCPUs on 2 physical cores (half the official box), with Postgres 18 configured by
`box/setup-box.sh` and the full seed. Each run is 60 s ramp plus 60 s measured, on a fresh copy of the database,
with the load generator on separate VMs.

| | Passes | Fails |
|---|---|---|
| this entry | 50,000 users; 52,000 in some runs (p95 335–441 ms) | 52,000 in others (p95 511–947 ms); 55,000 (p95 646–729 ms) |
| `node-uwebsockets-zahidcakici` | 55,000 | |
| `python-rawsocket-shawal-mbalire` | 40,000 | 45,000 |

These are relative numbers on one rig, not scores.

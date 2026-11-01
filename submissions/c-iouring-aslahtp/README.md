# C + io_uring, no framework

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
- **One parent, one drain process, `WORKERS` worker processes** (CPUs / 2). Children die with the parent; if any
  child exits, the parent kills the rest and exits, so a crash is a dead server, never a half-working one.
- **Workers** each run one io_uring (single issuer, deferred task running): a multishot accept on their own
  `SO_REUSEPORT` listener and one multishot receive per connection into the ring's provided buffers. An idle
  connection owns no buffer: holding 200,000 idle keep-alive connections costs about 360 bytes each. A request is
  parsed where it lands; each response is one send (the body is written behind a reserved gap, the header goes in
  the gap).
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
- **Pacing.** A plan starts when a connection is free and the oldest request has waited
  `typical plan time x (free connections - 1) / connections` (capped at `PLAN_WAIT_US`): no wait at all once the
  other connections are busy, close to one plan's time when most are idle, so batches stay large without a fixed
  delay.
- JSON is rendered in C from binary rows; fragments shared by many responses (an article's tag list) are rendered
  once per plan. Nothing outlives the plan: every result is dropped once its responses are sent (rule 5).
- Generic plans are forced (`plan_cache_mode`), so page subqueries keep a constant `LIMIT 100` wrapper: a
  `LIMIT $n` alone is estimated at 10% of the table and turns index walks into hash joins.

Rare reads (login lookup, current user) go through the drain unplanned.

### Writes
- Each worker has its own write connection. Queued writes go out together as one Sync, one implicit
  transaction, one WAL flush (group commit, up to `WRITE_GROUP`); every response still waits for that commit
  (rule 6). A failing group is retried one write at a time; sign-up and profile updates (unique names) always
  commit alone.
- Writes find their target themselves (follow, favorite by slug in one statement), so a write is one round trip
  plus its read-back in the same transaction.

### Auth and bcrypt
- JWT HS256 is verified on every request, with SHA-NI when the CPU has it and precomputed HMAC states.
- bcrypt cost 10 runs on one hasher thread per worker at nice 10. The kernel interleaves 4 independent hashes
  (one bcrypt is a single dependency chain on S-box loads; 4 chains keep the load ports busy): 2.9x the
  throughput of one at a time, bit-identical to the reference implementation. A lone job waits up to
  `BCRYPT_WAIT_MS` for company; logins and sign-ups are under 0.1% of requests, so this does not move the
  percentiles. A job that waited over 8 s is answered 503 instead of hashed.

### Postgres session
`plan_cache_mode = force_generic_plan`, `jit = off`, `max_parallel_workers_per_gather = 0` on every connection.
`PG_TUNE=1` adds `enable_memoize = off`, `enable_hashagg = off`, `work_mem = 32MB`, `random_page_cost = 1.1`.

## Tuning variables

| Variable | Default | Meaning |
|---|---|---|
| `WORKERS` | CPUs / 2 | worker processes |
| `READ_CONNS` | 12 | drain read connections (one plan each at a time) |
| `WRITE_CONNS` | 1 | write connections per worker |
| `PLAN_PACE` | 1 | load-following plan wait (0: fixed `PLAN_WAIT_US`) |
| `PLAN_WAIT_US` | 20000 | cap on (or, with `PLAN_PACE=0`, the) plan wait |
| `PLAN_MAX` | 4096 | most requests in one plan |
| `PLANNER` | 1 | 0: every read as a plain per-request query |
| `WRITE_GROUP` | 128 | most writes per group commit |
| `BCRYPT_THREADS` / `BCRYPT_BATCH` / `BCRYPT_WAIT_MS` / `BCRYPT_NICE` | 1 / 4 / 1000 / 10 | hasher threads per worker, jobs per kernel run, wait for company, niceness |
| `PG_TUNE` | 0 | extra planner settings (above) |
| `DIRECT_FDS` | 0 | io_uring direct descriptors for client sockets (no measured gain on loopback) |

Total Postgres connections, `READ_CONNS + WORKERS x WRITE_CONNS`, must stay within 95.

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

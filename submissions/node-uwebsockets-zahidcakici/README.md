# Node.js / uWebSockets.js / own Postgres client, one global batch planner

Front: direct

| | |
|---|---|
| Language | JavaScript on Node.js 24.21.0 LTS (official tarball, SHA-256 checked in `install.sh`) |
| HTTP | [uWebSockets.js](https://github.com/uNetworking/uWebSockets.js) v20.71.0, compiled from source by `build.sh` at pinned commits (no TLS, no HTTP/3) |
| Postgres driver | Own v3 wire-protocol client (`pg.js`): SCRAM-SHA-256, named prepared statements, binary parameters and rows, pipelining |
| bcrypt | N-API addon (`native/`): Solar Designer's public-domain Openwall bcrypt core (`crypt-bcrypt.c`, unmodified from libxcrypt 4.4.36) with the lane-interleaved driver from [PR #7](https://github.com/arjaythedev/multicore-server-challenge/pull/7) (MIT), cost 10 |
| JWT | HS256 with `node:crypto` (HMAC with a `KeyObject`) |
| npm dependencies | none |

```bash
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

## Design

Postgres does most of the work on this workload, so the server spends as little Postgres CPU per request as it
can, and the JavaScript side builds responses without creating an object or string per row.

### Threads

| Thread | Does |
|---|---|
| `HTTP_THREADS` HTTP threads (`http.js`) | uWebSockets.js on the shared port (`SO_REUSEPORT`, the kernel spreads connections); routing, query and body validation, JWT verification. A request becomes a few values in a flat array; each event-loop turn sends all new requests to the database thread in one message |
| `DB_THREADS` database threads (`db.js`) | the batch planner with `READ_LANES` Postgres read connections, one group-commit write connection, response assembly. Replies go back in one message per HTTP thread per batch: `(id, status, end)` triples plus one transferred buffer of bodies |
| `BCRYPT_THREADS` bcrypt threads (`bcrypt-worker.js`) | interleaved bcrypt, scheduled by the main thread |

The database threads take turns by time: everything any HTTP thread receives during window *w* goes to database
thread *w* mod `DB_THREADS`, so each window is still **one batch for the whole server**, while the planning and
assembly work is spread over two threads instead of being one thread's serial bottleneck when the box is saturated.

Having one planner for the whole server matters: with a planner per HTTP thread every batch is a fraction of the
size, and the fixed per-batch work (the newest page, the hot articles' enrichment, the tag list, statement
overhead) is paid once per planner. On a local 3-core run at 90,000 users, two planners used 24% more Postgres CPU
than one.

### Batched reads

The planner follows the design of [PR #47](https://github.com/arjaythedev/multicore-server-challenge/pull/47). The
first read to arrive opens a window (`READ_WINDOW_MS`); when it closes, everything waiting goes to a free read
connection as one batch (at most `READ_MAX` requests; a bigger backlog is split over several connections, which
then run in parallel), answered in two pipelined round trips:

1. **Phase A**: one statement per kind of request present (current user, login e-mail, profile, article by slug or
   id, comments, global page, tag / author / favorited page, feed), each over the batch's *distinct* keys
   (`unnest(...) WITH ORDINALITY`), so identical keys are one row: one global page per `(limit, offset)`, one capped
   count per tag, author or viewer, one lookup per slug.
2. **Phase B**: the union of every article phase A returned, across all endpoints, is enriched once per article
   (tag ids, favorite count, author profile), plus the tag names in the database's sort order, plus the per-viewer
   `favorited` / `following` flags as one primary-key range scan per viewer (`= ANY(...)`).

While one batch runs in Postgres the next one is collected. Under load the read connections are busy and batches
grow on their own, so the busier the box, the less Postgres work per request. Nothing outlives its batch: every value
in a response was read from Postgres while that request was waiting.

### Rows straight into responses

`pg.js` never builds an object per row. A row is a list of `(offset, length)` pairs into the receive buffer, which
stays valid until the batch is answered. Responses are assembled as bytes (`out.js`): JSON fragments are copied in,
text columns are copied from the receive buffer with JSON escaping, and integers and binary timestamps
(microseconds since 2000) are formatted in place.

### Writes: group commit

Every write that arrives while the previous group commits goes out as one pipeline (Bind/Execute for each, one Sync),
which Postgres runs as one implicit transaction. Each response is released after ReadyForQuery, i.e. after COMMIT,
and the whole server shares one WAL flush per group. If any statement fails, the group rolls back and each write is
retried in its own transaction; a write whose outcome is unknown (connection lost) is never retried. Profile updates,
which can fail on a unique violation by design, never share a group; sign-ups use `ON CONFLICT DO NOTHING`, so a
taken name is an empty result (422) instead of an error. Writes that return an article (favorite, create, update)
read it back through the planner after the commit, in a new snapshot.

### bcrypt

One bcrypt is a long chain of dependent S-box loads; independent hashes interleaved round by round overlap them.
The addon runs 1–6 hashes at once, and at startup the first bcrypt thread times each lane count on a cheap cost and
uses the fastest on this CPU (6 on the Apple M4 I tested on: 10.6 ms per hash against 39.7 ms for one). The main
thread gathers hashes into sets: a set runs when it is full or `BCRYPT_WAIT_MS` after its first hash arrived. Every
hash runs all 2^10 rounds with its own random salt; logins always verify against the stored hash, with the cost read
from it. A self-test compares every lane count with the original single-hash code at startup.

### Details

- **Postgres session settings** (startup parameters on our own connections, nothing server-wide): `jit = off`,
  `plan_cache_mode = force_generic_plan` and `max_parallel_workers_per_gather = 0` on read connections. The array
  statements would otherwise be re-planned on every execution, and the generic plans' costs can cross the JIT
  threshold.
- **uWebSockets.js build**: fetched by exact commit and compiled from source. Two constants are patched: the HTTP
  idle timeout goes from a hard-coded 10 s to 120 s (users think for up to 70 s, SPEC.md asks for at least 65 s), and
  the listen backlog from 512 to 65535 (the ramp connects tens of thousands of users). TLS and HTTP/3 are compiled out.
- Statements are prepared once per connection. A connection that dies is replaced, and the requests in flight on it
  get a 500 (nothing is replayed).

## Settings

All optional environment variables; the defaults are for the 8-vCPU box.

| Variable | Default | |
|---|---|---|
| `HTTP_THREADS` | cores / 4 | HTTP threads |
| `DB_THREADS` | 2 (1 below 6 cores) | database threads, taking turns by window |
| `READ_LANES` | cores / 2 / `DB_THREADS` | read connections per database thread: about one Postgres backend per physical core in total |
| `READ_WINDOW_MS` | 40 | batch collection window |
| `READ_MAX`, `WRITE_MAX` | 1024, 256 | requests per read batch / per write group |
| `IDLE_FLUSH` | 0 | 1: dispatch at once when no read batch is in flight (lower latency at low load) |
| `BCRYPT_THREADS` | 2 | bcrypt threads |
| `BCRYPT_LANES` | calibrated | hashes interleaved per run (1–6) |
| `BCRYPT_WAIT_MS` | 200 | how long a partial set waits for company |
| `STATS` | 0 | 1: log event-loop utilization and delay, GC, batch sizes every 5 s |

Postgres connections: `DB_THREADS × (READ_LANES + 1)` (6 on the box: 4 read, 2 write).

## Measurements

Local runs, not official scores: Apple M4 Pro, OrbStack Linux VM, Postgres 18.6 with `box/pg-conf.sh`'s settings
for 8 cores / 16 GB, full seed, a fresh database copy and a short warm-up before every run, the challenge's
`loadgen` (60 s ramp + 60 s measured unless stated). Postgres and the server pinned to 4 cores (about the size of
the 8-vCPU box), the load generator on the other 8. The #1 entry
([rust-epoll-WorriedArrow](https://github.com/arjaythedev/multicore-server-challenge/pull/47)) ran the same way
for comparison.

| | users | req/s | p95 ms | p99 ms | errors | server cores | Postgres cores |
|---|--:|--:|--:|--:|--:|--:|--:|
| this server | 110,000 | 28,515 | 144 | 253 | 0 | 1.27 | 1.49 |
| rust-epoll-WorriedArrow | 110,000 | 28,651 | 127 | 210 | 0 | 0.89 | 1.71 |
| this server, 5-minute hold | 105,000 | 27,016 | 219 | 733 | 0 | 1.28 | 1.65 |

Both fail at 120,000 on these 4 cores. What moved the numbers, measured the same way:

- one batch planner for the whole server instead of one per HTTP thread: −19% Postgres CPU (3 cores, 90,000 users);
- a 40 ms read window instead of 20 ms: −12% Postgres CPU; a 4 ms window with immediate dispatch costs ~20% more
  than 20 ms;
- 4 read connections instead of 8 on 4 cores: −25% Postgres CPU, and the difference between passing and failing
  110,000 users;
- capping a batch at 1,024 requests: a backlog is split over several connections instead of running as one long
  batch on one backend (p95 at 110,000 users on 3 cores: 1.8 s → 0.8 s);
- 6 interleaved bcrypt lanes instead of 1: 10.6 ms instead of 39.7 ms of CPU per hash.

## Rules

- No caches: every request reads Postgres while it is served; the process keeps only connections, prepared
  statements and the HMAC key (rule 5).
- Writes are committed before the response (group commit, rule 6). bcrypt cost 10 on every hash and verify; HS256
  signature, `alg` (HS256 only) and `exp` checked on every request (rule 7).
- Session settings only; no schema, index, function or extension touched (rules 2, 3). Nothing detects the load test.
- Built on the box from pinned source: Node from the official tarball, uWebSockets.js by commit, the bcrypt addon
  from `native/`. No prebuilt binaries, no npm packages.

## Tests

`test/run.sh`: 197/197 on the dev seed and on the full seed.

Built with Claude (Anthropic).

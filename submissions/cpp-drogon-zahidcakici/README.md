# C++20 / Drogon / libpq pipelines, one global batch planner

Front: direct

| | |
|---|---|
| Language | C++20 (GCC from Ubuntu 24.04's `build-essential`), `-O3 -march=native` |
| HTTP | [Drogon](https://github.com/drogonframework/drogon) v1.9.14 (commit `3aae769`, its trantor submodule at `78e480f`), built from source by `build.sh` |
| Postgres driver | libpq in pipeline mode (`libpq-dev`): named prepared statements, binary parameters and results, one Sync per round trip |
| bcrypt | Solar Designer's public-domain Openwall bcrypt core (`native/crypt-bcrypt.c`, unmodified from libxcrypt 4.4.36) with the lane-interleaved driver from [PR #7](https://github.com/arjaythedev/multicore-server-challenge/pull/7) (MIT), cost 10 |
| JWT | HS256 with OpenSSL's SHA-256 (the HMAC pad states are computed once from the key) |
| JSON | in: jsoncpp (Drogon's dependency) in strict mode; out: written directly as bytes |
| Allocator | jemalloc (`libjemalloc-dev`) |

```bash
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

## Design

Postgres does most of the work on this workload, so the server spends as little Postgres CPU per request as it can,
and builds responses straight from libpq's binary results without an object per row.

### Threads

| Thread | Does |
|---|---|
| `HTTP_THREADS` Drogon event loops | one `SO_REUSEPORT` listener each (the kernel spreads connections). One pre-routing advice does the routing, query and body validation and JWT verification, then hands the request to the planner or the writer |
| the planner | the batch clock (below); hands batches to free read lanes |
| `READ_LANES` read lanes | one Postgres connection each: run a batch's two pipelined round trips and assemble every response of the batch |
| the writer | one Postgres connection: group commit |
| `BCRYPT_THREADS` bcrypt threads | interleaved bcrypt |

A finished batch goes back to each event loop as **one** queued task holding all of that loop's responses, so an
event loop wakes once per batch instead of once per response.

### Batched reads

The planner follows the design of [PR #47](https://github.com/arjaythedev/multicore-server-challenge/pull/47). The
first read to arrive opens a window (`READ_WINDOW_MS`). When it closes, everything waiting goes to a free read lane
as one batch, at most `READ_MAX` requests; a bigger backlog is split over several lanes, which then run in parallel.
A batch is answered in two pipelined round trips:

1. **Phase A**: one statement per kind of request present (current user, login e-mail, profile, article by slug or
   id, comments, global page, tag / author / favorited page, feed), each over the batch's *distinct* keys
   (`unnest(...) WITH ORDINALITY`), so identical keys are one row: one global page per `(limit, offset)`, one capped
   count per tag, author or viewer, one lookup per slug.
2. **Phase B**: the union of every article phase A returned, across all endpoints, is enriched once per article
   (tag ids, favorite count, author profile), plus the tag names in the database's sort order, plus the per-viewer
   `favorited` / `following` flags as one primary-key range scan per viewer (`= ANY(...)`).

There is one planner for the whole server: every request that arrives in a window, on any event loop, is in the
same batch, so the fixed per-batch work (the newest page, the hot articles' enrichment, the tag list, statement
overhead) is paid once. Under load the lanes are busy and batches grow on their own, so the busier the box, the less
Postgres work per request. Nothing outlives its batch: every value in a response was read from Postgres while that
request was waiting. A request whose connection closed while it waited is dropped before its batch is sent.

Capped counts are one scan that stops at the 1,000th row (`count(*)` over a `LIMIT 1000` subquery). Proving the cap
with `EXISTS (... OFFSET 999)` first, as the reference-style statement does, scans the rows twice whenever the count
is below the cap, which is the usual case for authors and favorites.

### Rows straight into responses

Responses are written as JSON bytes from the binary results: text columns are copied with JSON escaping, and
integers, arrays (`int4[]` tag ids, `text[]` tag names) and timestamps (microseconds since 2000) are decoded and
formatted in place.

### Writes: group commit

Every write that arrives while the previous group commits goes out as one pipeline (all statements, one Sync),
which Postgres runs as one implicit transaction. Each response is released after the Sync's ReadyForQuery, i.e.
after COMMIT, and the whole server shares one WAL flush per group. If any statement fails, the group rolls back and
each write is retried in its own transaction; a write whose outcome is unknown (connection lost) is never retried.
Profile updates, which can fail on a unique violation by design, never share a group. Sign-ups use
`ON CONFLICT DO NOTHING`, so a taken name is an empty result (422) instead of an error. Writes that return an
article (favorite, create, update) read it back through the planner after the commit, in a new snapshot.

### bcrypt

One bcrypt is a long chain of dependent S-box loads; independent hashes interleaved round by round overlap them.
The core runs 1–6 hashes at once, and at startup the server times each lane count on a cheap cost and uses the
fastest on this CPU (6 on the Apple M4 I tested on: about 10 ms of CPU per cost-10 hash instead of about 40 ms).
Hashes are gathered into sets: a set runs when it is full or `BCRYPT_WAIT_MS` after its oldest hash arrived. Every
hash runs all 2^10 rounds with its own random salt (OpenSSL `RAND_bytes`). Logins always verify against the stored
hash, with the cost read from it, and compare in constant time. At startup a self-test checks a known answer and
compares every lane count with the original single-hash code.

### Details

- **Postgres session settings** (startup options on our own connections, nothing server-wide): `jit = off`,
  `plan_cache_mode = force_generic_plan` and `max_parallel_workers_per_gather = 0` on read connections. The array
  statements would otherwise be re-planned on every execution, and the generic plans' costs can cross the JIT
  threshold.
- **Drogon settings**: idle timeout 120 s (Drogon's default is 60 s; users think for up to 70 s and SPEC.md asks
  for at least 65 s), connection limit raised from 100,000, no `Server` / `Date` headers, no gzip.
- **Listen backlog**: trantor listens with `SOMAXCONN` (4096). `build.sh` patches that one call to 65535, because
  the ramp connects tens of thousands of users.
- **JWT**: the signature is compared in constant time. Claims in the exact form this server issues are read
  without a JSON parser; anything else goes through jsoncpp, with the same checks (`alg`, `exp`, `nbf`, `sub`).
- **Request bodies**: strict JSON; invalid UTF-8 is replaced with U+FFFD before parsing. Validation order and
  status codes follow the spec and conformance suite (401 before 422 on auth-required writes).
- Statements are prepared once per connection. A connection that dies is replaced, and the requests in flight on it
  get a 500 (nothing is replayed). If the server stops, it exits at once without running static destructors.

## Settings

All optional environment variables; the defaults are for the 8-vCPU box. CPU counts respect the process's CPU
affinity.

| Variable | Default | |
|---|---|---|
| `HTTP_THREADS` | cores / 4 | Drogon event loops |
| `READ_LANES` | cores / 2 | read connections (about one Postgres backend per physical core) |
| `READ_WINDOW_MS` | 40 | batch collection window |
| `READ_MAX`, `WRITE_MAX` | 2048, 256 | requests per read batch / per write group |
| `BCRYPT_THREADS` | 2 | bcrypt threads |
| `BCRYPT_LANES` | calibrated | hashes interleaved per run (1–6) |
| `BCRYPT_WAIT_MS` | 200 | how long a partial set waits for company |
| `IDLE_TIMEOUT_S` | 120 | keep-alive idle timeout |
| `STATS` | 0 | 1: log batch sizes and times every 5 s |

Postgres connections: `READ_LANES + 1` (5 on the box).

## Measurements

Local runs, not official scores: Apple M4 Pro, OrbStack Linux VM, Postgres 18.6 with `box/pg-conf.sh`'s settings
for 8 cores / 16 GB, full seed, a fresh database copy and a short warm-up before every run, the challenge's
`loadgen` (60 s ramp, 60 s measured unless stated). Postgres and the server were pinned to 4 cores (about the size
of the 8-vCPU box) and the load generator to the other 8, with `HTTP_THREADS=2 READ_LANES=4` (the box's defaults).
The other two rows ran the same way.

| | users | req/s | p95 ms | p99 ms | errors | server cores | Postgres cores |
|---|--:|--:|--:|--:|--:|--:|--:|
| this server | 110,000 | 28,474 | 161 | 209 | 0 | 0.98 | 1.48 |
| this server, 5-minute hold | 110,000 | 28,233 | 235 | 431 | 0 | 1.12 | 1.70 |
| [rust-epoll-WorriedArrow](https://github.com/arjaythedev/multicore-server-challenge/pull/47) (#1) | 110,000 | 28,651 | 127 | 210 | 0 | 0.89 | 1.71 |
| [node-uwebsockets-zahidcakici](https://github.com/arjaythedev/multicore-server-challenge/pull/92) | 110,000 | 28,515 | 144 | 253 | 0 | 1.27 | 1.49 |

115,000 users is the tipping point on these 4 cores: some runs pass with p95 just over or under 500 ms, others tip
into a backlog. All three servers fail at 120,000. Run-to-run noise in this VM is large (Postgres CPU at 110,000
users ranged from 1.48 to 1.85 cores across runs), so differences of a few percent are not significant.

What moved the numbers, measured the same way:

- `READ_MAX` 2048 instead of 1024: at 115,000 users, 26,000–29,000 req/s instead of 20,000–23,000 once the box
  saturates (the larger batches share more work); 4096 and no cap were both worse;
- the single-scan capped count: the author-count statement went from 0.84 to 0.44 ms per 150 keys (identical
  results); feed counts, which mostly reach the cap, cost the same either way;
- 6 interleaved bcrypt lanes instead of 1: about a quarter of the CPU per hash.

Where the time goes at 120,000 users (system-wide profile of the 4 cores): Postgres 60% (mostly B-tree descents),
the Drogon event loops 24% (about half of it in the kernel's TCP stack), bcrypt and response assembly 16%.

## Rules

- No caches: every request reads Postgres while it is served; the process keeps only connections, prepared
  statements and the HMAC key (rule 5).
- Writes are committed before the response (group commit, rule 6). bcrypt cost 10 on every hash and verify; HS256
  signature, `alg` (HS256 only) and `exp` checked on every request (rule 7).
- Session settings only; no schema, index, function or extension touched (rules 2, 3). Nothing detects the load test.
- Built on the box from pinned source: Drogon and trantor by commit, everything else from Ubuntu's apt (rule 11).
  No prebuilt binaries.

## Tests

`test/run.sh`: 197/197 on the dev seed and on the full seed.

Built with Claude (Anthropic).

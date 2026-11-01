# Rust / Tokio: own HTTP/1.1 layer, batched reads, interleaved bcrypt

Front: direct

| Piece | Version |
|---|---|
| Rust | 1.99.0 (rustup-init 1.28.2, sha256-checked, in `install.sh`) |
| Runtime | Tokio 1.53.2, multi-thread scheduler (3 workers) |
| HTTP | own HTTP/1.1 keep-alive layer on `tokio::net`, request heads parsed by httparse 1.10.1 |
| Postgres driver | tokio-postgres 0.7.18, prepared statements, binary results |
| JSON | written straight from the rows; serde_json 1.0.154 parses request bodies |
| JWT | HS256 with hmac 0.12.1, sha2 0.10.9, base64 0.22.1 |
| bcrypt | own EksBlowfish (`src/bcrypt.rs`), cost 10, up to 4 hashes interleaved; cross-checked in tests against the bcrypt crate 0.19.3 (a test-only dependency) |
| Allocator | mimalloc 0.1.52 |

Every dependency is pinned with `=` in `Cargo.toml` and by `Cargo.lock`; `build.sh` builds with `--locked`.

## Front: direct, and why

Nginx would spend CPU that the box shares with Postgres (about 11% of it in the video). Holding the virtual
users' keep-alive connections is cheap here: an idle connection is its socket and a small task, and its read
buffer is freed between requests (about 5 KB of RSS per connection: 839 MB at 160,000 connections locally).
The one hard ceiling of going direct is `LimitNOFILE=200000`, about 199,900 users.

## Design

Postgres takes most of the box, so the work goes into making each request cheap for Postgres first.

**Batched reads.** Eight read connections, each driven by a reader task that runs one statement at a time.
A request queues its read by kind (an article by slug, its comments, a profile, a page of the global, tag,
author or favorited list, a feed page, `GET /api/user`, a login lookup, the tag list). A free reader claims the
kind whose oldest job has waited longest, lets that job age to 20 ms (`READ_BATCH_US`) so others of its kind
can join, then sends all of them (up to 64) as one statement: the per-request query is the inner side of a
LATERAL join over `unnest()` of the requests' parameters, and every row comes back tagged with its request's
ordinal. Every batched statement takes the same four arrays (viewer, n1, n2, s), so one code path serves them.

Much of a cheap statement's cost in Postgres is per statement (protocol, bind, snapshot, executor start and
stop), so this more than halves Postgres CPU per request against batching only what queues while every reader
is busy: 0.62 against about 1.4 cores at 8,000 req/s, same load, measured back to back. Letting jobs age 20 ms
instead of 10 ms cut it by about 6% more: 0.059 against 0.063 ms of Postgres CPU per request at 26,000 req/s
(alternating runs, four and three of them), for about 10 ms more p95. Within a statement,
viewer-independent article data (tag names, favorite count, author) is computed once per distinct article and
joined back to each request; `favorited` and `following` are computed per request. Page 1 of the global list
and the newest articles are what most requests ask for, so a batch shares most of that work.

**Every kind in one statement.** By default (`READ_CROSS=1`) a reader that claims any read kind except the
two user lookups collects the waiting reads of *all* of them and runs them as one statement (`src/cross.rs`).
Each kind passes its requests' parameters as its own arrays; the statement turns every list page and article
page into article ids, reads each distinct article's viewer-independent data (tag ids, favorite count, author)
once however many requests and endpoints show it, each distinct article's comment thread once, and the names
of the tags involved once, ranked by name. Per request it returns only its page of ids, its capped count and
the ids among them that the viewer favorited or whose author the viewer follows: one primary-key range scan
(`= ANY`) per request instead of a probe per row. The server assembles every response from those rows. Back
to back at 26,000 req/s this used 0.052 and 0.053 ms of Postgres CPU per request against 0.065 and 0.063 for
one statement per kind (-17%, Postgres execution time 112 against 142 s), for about 25 ms more p95 (one
statement now carries every kind).

**SQL.** The reference SQL's results, with:
- each page cut to its ids first (bounded by `LIMIT 100`, so the generic plan expects a small page): `OFFSET`
  rows cost an index step and only the page is enriched;
- `a.id = ANY(ARRAY(...))` and LATERAL author lookups, so generic plans stay index lookups instead of hash
  joins over whole tables;
- tag names by primary key (1-4 per article) instead of a join to `tags`;
- `favorited` and `following` skipped for anonymous viewers;
- the capped global count walks the primary key from the oldest end (frozen, all-visible pages); it depends on
  no request, so it runs once per statement;
- feed: each followee's newest `limit + offset` ids merged, the followee set read once per request, and
  `following` is `true` (every feed author is followed by the viewer in that snapshot);
- one statement per mutation: CTEs fold the lookup, the ownership check and the write together (an unknown
  slug writes nothing and returns no row: 404; someone else's article or comment returns its author: 403).
  Creating an article reads existing tags without updating them and inserts only the missing ones;
- session settings only: `plan_cache_mode = force_generic_plan`, `jit = off`, `enable_memoize = off`,
  `max_parallel_workers_per_gather = 0`.

**Writes: group commit.** Two write connections (`DB_WRITE_CONNS`), each driven by a writer task. A free writer
takes every write that is waiting (up to 256) and commits them as one transaction, pipelined: `BEGIN`, the writes,
`COMMIT`. Every response waits for that `COMMIT` (synchronous commit), so one WAL flush covers the whole group and
the write rate no longer depends on how fast the disk flushes. A lone write runs as its own implicit transaction. If
any write in a group fails (a unique violation is 422), the group rolls back and each write runs again in its own
transaction, so one bad write can't fail the others; a group whose commit outcome is unknown (connection lost) is
never retried. Reads after a write (favorite, article edit) are a new statement, whose snapshot sees the commit.

This replaced six connections with one implicit transaction (and one WAL flush) per write. Those capped commits at
about six per flush, and in 5-minute holds a burst of WAL (the first minutes after each checkpoint write full-page
images, and autovacuum right after a checkpoint wrote 110 MB of WAL in one second) queued every write behind the
flushes: write p99 700-860 ms against 58-65 ms with group commit, same load and disk (110,000 users, Postgres
write IOPS capped at 700 to stand in for a slower disk than the test rig's). With the cap at 400, the old path fell
behind for good (writes timing out at 10 s, 9% errors) and group commit held the 5-minute hold (p99 264 ms, no errors).

**HTTP.** One task per connection. The read buffer exists only while a request is arriving or in flight; the
request head is parsed into offsets, so nothing borrowed from httparse lives across the handler's await, and the
handler future is boxed, so an idle connection's task stays small. A response is one write. Pipelined requests
are answered in order. Keep-alive connections are never closed for idleness.

**bcrypt.** A Blowfish round is a chain of dependent S-box loads, so one hash leaves the core mostly waiting.
Two dedicated threads (`BCRYPT_THREADS`) take queued hash and verify jobs in groups of up to four, waiting up to
250 ms for a group to fill (`BCRYPT_BATCH_MS`; at 50 ms most groups held one or two real hashes and the server used 17% more CPU at 100,000 users), and run them in lockstep: each lane is a complete EksBlowfish
with all 1,024 cost-10 key-schedule rounds; the lanes only fill each other's stalls. Locally that is 14 ms of
CPU per hash with 4 lanes against 48 ms for the bcrypt crate. A login never blocks an event loop. New hashes
are `$2b$10$` with 16 salt bytes from `/dev/urandom`; `$2a$`, `$2b$` and `$2y$` verify. Passwords over 72 bytes
are refused at sign-up and password change (422), since bcrypt would ignore the rest.

**JWT.** Verified on every request: the HS256 signature over the presented bytes, `alg` must be HS256, `exp`
required and in the future, `sub` a decimal string. Nothing is remembered between requests.

## Rules

- No caching across requests: every request reads Postgres while it is served. A batched statement serves only
  requests that were all waiting before it started, in one snapshot, and its rows are handed out and dropped.
  Within a statement, the tag list, the global count and per-article data are shared by the requests in it.
  Only connections and prepared statements are reused.
- Every password is hashed with bcrypt cost 10, and every login verifies against the stored hash.
- Writes are committed before the response; no schema or server-wide changes; 10 Postgres connections in all.

## Local results (not the challenge box)

Apple-silicon host, Docker VM: Postgres 18 (the box's `pg-conf.sh` values for 8 CPU / 16 GB) and the server
sharing 8 CPUs, full seed, `bench/cmd/loadgen run` on 4 other CPUs, 60 s ramp + 60 s measured, a fresh database
each run. Other jobs shared the VM, so treat the numbers as rough. CPU is in cores, from `docker stats`.

| users | req/s | p95 | p99 | errors | app CPU | Postgres CPU | app RSS |
|--:|--:|--:|--:|--:|--:|--:|--:|
| 60,000 | 15,864 | 15.7 ms | 19.2 ms | 0 | 0.93 | 1.18 | 324 MB |
| 99,000 | 26,141 | 18.4 ms | 29.6 ms | 0 | 1.33 | 1.83 | 531 MB |
| 160,000 | 42,292 | 31.6 ms | 102.5 ms | 0 | 1.96 | 3.15 | 839 MB |

At 190,000 users the load generators fell behind (flagged LG-limited), so that run says nothing about the server.

## Build and run

```sh
sudo bash install.sh     # Rust 1.99.0 -> /usr/local/rustup, /usr/local/cargo
bash build.sh            # -> target/release/conduit
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

Optional process settings (none are needed): `APP_THREADS` (3), `DB_READ_CONNS` (8), `DB_WRITE_CONNS` (2),
`READ_BATCH_US` (20000), `READ_CROSS` (1), `BCRYPT_THREADS` (2), `BCRYPT_BATCH_MS` (250).

Passes `test/run.sh` (197/197) on the dev and the full seed, and its transcript is byte-identical to
`bench/cmd/conformance/golden-dev.jsonl`. `cargo test` checks timestamp and string formatting, tokens, query
validation, and the bcrypt lanes against the bcrypt crate in both directions.

`src/blowfish_consts.rs` (Blowfish's initial P-array and S-boxes) is from the RustCrypto blowfish crate
(MIT OR Apache-2.0).

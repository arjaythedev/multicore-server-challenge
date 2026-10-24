# Zig: io_uring, own HTTP, own Postgres client, batched reads

**Front: direct**

No framework, no libc, no driver: raw `io_uring` syscalls, a hand-written HTTP/1.1 server, a hand-written PostgreSQL
protocol client (SCRAM-SHA-256, extended protocol, binary parameters and results, pipelined), a streaming JSON writer, HS256
JWTs and bcrypt, all on the Zig standard library.

## Stack

| Piece | Version |
|---|---|
| Zig | 0.17.0 (official tarball, SHA-256 pinned in `install.sh`) |
| I/O | `io_uring` (single issuer, deferred task work, multishot accept, multishot recv on a provided-buffer ring; poll + `recv` if the kernel rejects buffer rings) |
| HTTP | own HTTP/1.1: keep-alive, pipelining, `Content-Length` and chunked bodies, half-close |
| Postgres | own protocol-3.0 client, no `libpq`; PostgreSQL 18 on the box |
| JSON | own writer (vectorised string escape) and strict reader for request bodies |
| JWT | HS256 with `std.crypto` HMAC-SHA256; the key pads are derived once, every request still verifies signature, `alg` and `exp` |
| bcrypt | own EksBlowfish, cost 10, bit-identical to `std.crypto.pwhash.bcrypt`; hand-written x86-64 kernel runs four hashes in lock step |
| Dependencies | none (`install.sh` only unpacks the pinned Zig toolchain) |

`build.sh` runs `zig build -Doptimize=ReleaseFast -Dcpu=native` (built on the box, so SHA-NI / BMI2 paths follow the CPU); the
binary is about 670 KB.

## How it uses the cores

- `WORKERS` workers, by default one per four CPUs (2 on the 8-vCPU box). **Each worker is its own process**: its own
  `SO_REUSEPORT` listener, its own `io_uring`, its own Postgres connections; nothing is shared on the request path. A
  process can hold at most `LimitNOFILE` (200,000) connections, so one process per worker keeps the connection count
  bounded by memory and CPU instead (with a 30,000-descriptor limit, one process accepted 16 k clients and two processes
  accepted all 40 k). A small supervisor stops everything if any worker exits.
- About **one Postgres connection per CPU** (8 on the box, `DB_CONNS`), a quarter of them for writes. More backends than
  cores only add context switches and cache pressure inside Postgres: on a 6-CPU slice 36 connections cost ~20% more
  Postgres CPU than 6 at the same throughput. Depth, not width, keeps each backend busy: a connection pipelines up to 4
  batches (`PG_DEPTH`). The server refuses to start above 95 connections.
- An **idle keep-alive connection costs one 48-byte table slot** (indexed by fd) plus its kernel socket. Receive buffers
  come from a shared provided-buffer ring and belong to a connection only while one of its requests is incomplete.
  100,000 idle connections: ~23 MB RSS for the whole service; 50,000 busy users: 11 MB per worker process.
- bcrypt runs on its own threads at normal priority (`BCRYPT_THREADS`, default CPUs/4 in total). A login waits up to
  250 ms (`BCRYPT_WAIT_MS`) for company, then up to four hashes run interleaved; a job that waited 15 s is dropped.
  At a lower priority the threads starve while Postgres saturates the CPUs and logins time out.
- At saturation Postgres uses ~70% of the CPU and this process ~25% (about a third of that bcrypt).

## Optimizations and why

- **Front: direct.** No Nginx hop, no gzip; one `send` per response (head and body in one buffer).
- **One statement, one round trip per request**, prepared once per connection, binary in and out (Postgres never formats a
  timestamp or integer). Favorite toggles are two statements, publishing an article up to four, each in one transaction.
  Session settings only: `plan_cache_mode=force_generic_plan`, `jit=off`, `max_parallel_workers_per_gather=0`.
- **SQL shaped for generic plans** (checked equal to the SPEC reference SQL, see Tests): list pages pick their ids first
  and decorate only the rows returned; per-row favorited/following checks are index probes, not hashed sub-plans over the
  viewer's whole set; tag names come from the `tags` primary key instead of a join that hashes all 200 tags per article;
  a list and its capped count are one statement (`WITH c AS (count) SELECT … LEFT JOIN LATERAL (page)`) so an empty page
  still carries the count; follow / comment / delete / update fold lookup and write into one CTE; comment threads (up to
  100 rows) test "does the viewer follow this author" against the viewer's followee set hashed once (-27% on a hot thread).
- **Reads are batched, and what requests share is done once.** Reads waiting for a Postgres connection at the same moment
  go out as one statement (`unnest(...) WITH ORDINALITY`). There is no timer and no added wait: at light load a batch has one
  request, as Postgres saturates requests queue and batches grow (up to `BATCH_MAX`, 64). Inside a batch the capped count
  of each distinct filter (the global one is the same for everybody) and the tags / favorite count / author of each distinct
  article are computed once; each request's own page of ids and its favorited/following flags are computed per request.
  `GET /api/tags` is one execution whose rows answer every waiting request. Nothing is kept after the statement: its rows are
  rendered into the responses of the requests that were waiting for it. If a batched statement fails, its requests are
  re-run one by one. (On a 32-request global-list batch: 54 µs per request, against 118 µs for the same 32 as separate
  per-request statements.)
- **Group commit.** A write connection runs one transaction at a time; writes that arrive while it commits wait and then
  go out together as one transaction, one WAL flush for all of them. Every response is sent after its commit. A failed group
  rolled back as a whole, so each member is retried alone (nothing is replayed after a commit). Sign-ups and profile
  updates, which fail by design on a unique violation, are never grouped. On a laptop disk this turned 20-second write
  queues (p95 1.1 s on every write endpoint) into p95 9 ms.
- **bcrypt, 4 lanes in assembly.** One hash is ~1.07 M Blowfish blocks, each a chain of dependent S-box loads. The kernel
  (`src/bcrypt.zig`) keeps four lanes in the 15 usable registers (one shared index temp, renamed by the core), extracts bytes with
  BMI2 `rorx`, and runs the whole 521-block key-expansion loop in registers. On a Ryzen 7 7445HS: 39 ms for one hash, 13.7 ms
  per hash in a full batch (compiled code spills at four lanes: 15.2 ms at three, 39 ms at four). Without BMI2 the build uses
  the compiled kernel.
- **Writes and reads never wait for each other**: writes have their own connections, so a commit never holds up queued reads.
- **Robust to the box**: half-closed clients still get their response; a client holding an incomplete request for 30 s is
  closed; Postgres connections that die are replaced within a second (requests in between get 503; nothing is replayed);
  TCP keep-alive probes detect vanished peers after 10 min.

## Configuration

`DATABASE_URL`, `JWT_SECRET`, `HOST`, `PORT` as in SPEC.md. Optional: `WORKERS` (default CPUs/4), `PROCS` (default = `WORKERS`;
`1` runs the workers as threads of one process), `DB_CONNS` (default CPUs, max 95), `DB_WRITE_CONNS`, `PG_DEPTH` (4),
`BATCH_MAX` (64; `1` turns batching off), `BCRYPT_THREADS`, `BCRYPT_LANES` (4), `BCRYPT_WAIT_MS` (250), `STATS=1`.
Test hooks (off by default): `NO_PBUF`, `TEST_FAIL_GROUPS`, `TEST_FAIL_BATCHES`.

## Tests

- `zig build test`: unit tests (bcrypt against `std`, JSON, JWT, HTTP framing, percent-decoding, wire protocol).
- `test/run.sh`: the 197-step conformance suite, on the dev and on the full seed.
- `tests/sqldiff.py`: the SQL in `src/sql.zig` against the SPEC reference SQL on random viewers, filters, limits and offsets
  (deep and out-of-range offsets, the heaviest followers): thousands of cases, no differences (`zig build sqldump` first).
- `tests/batchdiff.py`: ~1,800 read requests fired 64–200-way concurrently at a batching server and compared byte for byte
  with a non-batching one (`HOT=1` makes the batches full of duplicates); also with `TEST_FAIL_BATCHES=1`.
- `tests/writetest.py`: 200 concurrent clients each posting a comment, a favorite, a follow and an article, exact final
  counts; also with `TEST_FAIL_GROUPS=1`.
- `tests/httptest.py`: raw-socket HTTP: pipelining, byte-at-a-time requests, split and chunked bodies, `Connection: close`,
  HTTP/1.0, half-close, malformed and oversized heads/bodies, conflicting `Content-Length`, request-smuggling guards, abrupt closes.
- Also run: soaks of several minutes (no errors, flat RSS), a ReleaseSafe build (bounds and overflow checks) through the same
  suites, and killing every Postgres backend mid-run.

## Local results (not the official box)

Ryzen 7 7445HS, Postgres 18.6 built from source, full seed, the repo's `loadgen` on other cores of the same machine, fresh
database copy and warm buffers per run. Numbers do not transfer to the benchmark box; they show what each technique buys on
the same machine. One run per cell, with ±30% noise in p95 at the edge of saturation. Server and Postgres are confined to one
physical core (2 threads) so that they saturate before the load generator does. "Aged" is a database where the hot articles'
comment threads are already at the 100-row cap, as they are a minute into a real run.

| aged database, 22,000 virtual users at half think time | req/s | p50 | p95 |
|---|---|---|---|
| `BATCH_MAX=1` (every read is its own statement) | 9.6 k | 425 ms | 525 ms |
| default (shared-work batching) | 11.5 k | 24 ms | 52–59 ms |

The default configuration also serves 13.2 k req/s on the aged database at p95 151 ms, and 13.7 k req/s on the fresh seed at
p95 31–37 ms. 50,000 users with real 7 s think times (6 CPUs for server + Postgres): 13.3 k req/s, p95 1.7 ms, p99 3.5 ms,
0 errors. Other measured effects: Postgres connections 36 → 6 on a 6-CPU slice, -20% Postgres CPU at equal throughput;
hashed followee set in comment threads, -27% on a hot thread; group commit, write p95 1.1 s → 9 ms; bcrypt 39 ms → 13.7 ms per hash.

## Rules

No cache of any kind survives a request (rule 5: no response, query-result or table cache; no remembered JWT verification or
bcrypt result; the process keeps only connections, prepared statements and the HMAC key pads). Every write is committed before
its response (rule 6). bcrypt cost 10 on every hash and verify; HS256 signature, `alg` and `exp` checked on every request
(rule 7). Postgres is only configured through session settings; no schema, index, function or extension is touched
(rules 2, 3). Nothing detects the load test (rule 8). Needs Linux ≥ 5.19 with `io_uring` enabled (Ubuntu 24.04's 6.8 qualifies).

## Known limits

- Chunked request bodies may have at most 1024 chunks, size lines of at most 64 bytes and 4 KiB of trailers (the framing is
  re-checked whenever more bytes arrive, so what it scans is bounded). Bodies over 8 MB and heads over 16 KB are refused.
- Favoriting or unfavoriting an article looks it up by slug twice (the write, then the response). If its author renames it
  (which changes the slug) between the two statements, the favorite is stored but the response is a 404; the SPEC reference
  selects by id instead. Fixing it would need one combined statement, and a data-modifying CTE cannot see its own writes in the
  main query, so the counts would have to be adjusted by hand; it was left as is.
- Needs Linux 5.19 or newer for the provided-buffer ring; older kernels use the poll + `recv` path.

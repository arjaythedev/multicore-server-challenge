# C + io_uring

| | |
|---|---|
| Language | C (GNU C11), Ubuntu 24.04's default GCC, `-O3 -march=native -flto` |
| Framework | none: a hand-written io_uring server (multishot accept, per-connection multishot poll, direct `send`), with an epoll fallback probed at startup |
| Database | PostgreSQL 18 through a hand-written async wire-protocol (v3) client: SCRAM-SHA-256, prepared statements, pipelined batches, one round trip per request |
| JSON / JWT / bcrypt | hand-written: strict JSON scanner, HS256 with pre-absorbed HMAC pads, 4-lane ILP bcrypt verified against libxcrypt |

**Front: direct** — the server listens on `0.0.0.0:80` itself and holds every
user's keep-alive connection, so none of the box's CPU goes to Nginx.

liburing and libxcrypt come from the Ubuntu archive (`install.sh`); everything
else is in `src/`. If the kernel lacks multishot io_uring, the server probes
for it at startup (listen + self-connect + `IORING_CQE_F_MORE`) and falls back
to an epoll loop running the identical request pipeline; if multishot accept is
rejected at runtime the worker switches to single-shot accepts. Both fallbacks
are logged on stderr.

## Design

**Connections.** One event loop per worker, each with its own `SO_REUSEPORT`
listener (`THREADS`, default half the cores). Connections live in a per-worker
slot table addressed by a `(generation, slot)` packed into the 64-bit
`user_data`, so a completion can never point at a recycled connection. An idle
keep-alive owns no buffer: one multishot poll SQE and a ~200-byte struct.
Readiness drains the socket into a shared 64 KiB scratch buffer; bytes that
span events are appended to the connection's input buffer and released when
idle. Backpressure: a connection stops being read with 64 KiB unsent; stalls
(30 s without progress) and long-idle connections are closed; memory
guardrails stop accepting under 192 MB usable and shed idle connections under
96 MB.

**Postgres.** Every endpoint's statements go out as `Bind`/`Execute` pairs
followed by one `Sync`, so a request costs exactly one round trip and its
response is never sent before the `ReadyForQuery` that commits it. Batches
from different requests interleave on one connection, capped at `PG_DEPTH=16`
in flight; overflow waits in a per-worker FIFO that preserves arrival order.
Connections are picked least-loaded. The client speaks the wire protocol
directly (startup parameters carry `jit=off`,
`plan_cache_mode=force_generic_plan`, `max_parallel_workers_per_gather=0`), so
DataRow cells are copied once into the request's arena and the socket is just
another fd in the worker's loop. `DB_READS=9 DB_WRITES=3` per worker keeps the
total under the 95-connection cap on the 8-core box.

**SQL.** Lists run their page and their capped count as two prepared
statements inside the same batch (still one round trip), so an empty page
still carries `articlesCount`. Page ids are picked first in a subquery so the
per-article subqueries (tags, favorite count, the two `EXISTS`) run only for
returned rows. Writes that need no intermediate value are single-statement:
the article insert derives its id from `nextval` inline so the slug embeds it,
comment insert is a CTE joining the author, comment delete returns
404-vs-403-vs-deleted in one row, favorite/unfavorite are
`INSERT ... SELECT ... ON CONFLICT DO NOTHING` against the slug followed by
the full read in the same transaction. Article update/delete check ownership
in a first small batch (they are 0.3% of the workload's page views).

**bcrypt.** Seeded hashes come from Go's `x/crypto/bcrypt`, so the
implementation reproduces its exact semantics (key = password truncated to 72
plus one `0x00`, cycled; `$2a$/$2b$/$2y$` identical for ASCII). Up to
`BCRYPT_LANES=4` independent hashes run step-locked through the Feistel
rounds so their serial dependency chains fill the pipeline together; a lone
job runs immediately with one lane (no batching latency when logins are rare,
which is the steady state: logins are ~0.03% of requests). Non-ASCII or
over-72-byte passwords fall back to libxcrypt on the bcrypt thread. A startup
selftest checks fixed vectors, random round-trips against libxcrypt, and the
seed's own hash; `--bcrypt-selftest` runs it standalone.

**JWT.** The HMAC pads are hashed once at startup: a verification costs two
short SHA-256 continuations, every request, with no cache (rule 5). Signature
compared in constant time; `alg` must be exactly HS256; `exp` required and
checked; `sub` parsed as a strict positive decimal.

**No caching, no shortcuts.** Every response comes from queries run for that
request (rule 5); writes commit before their response (one `Sync` per batch,
rule 6); nothing about the load test is detected (rule 8). Session-level
settings only (rule 2).

## Environment

`DATABASE_URL`, `JWT_SECRET`, `HOST`, `PORT` per the spec, plus optional
`THREADS`, `DB_READS`, `DB_WRITES`, `PG_DEPTH`, `BCRYPT_THREADS`,
`BCRYPT_LANES`, `BCRYPT_WAIT_MS`. `--bcrypt-selftest` runs the selftest and
exits; `--epoll` forces the fallback loop.

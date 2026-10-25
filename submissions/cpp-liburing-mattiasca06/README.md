# C++20 + io_uring + libpq pipeline

**Front: direct.** The server listens on `HOST:PORT` itself and holds every user's keep-alive connection.

| Piece | Version |
|---|---|
| Language | C++20, g++ from Ubuntu 24.04 (`build-essential`) |
| I/O | raw io_uring via liburing (Ubuntu 24.04 `liburing-dev`) |
| HTTP parsing | picohttpparser, pinned commit, SHA-256 checked in `build.sh` |
| JSON input | yyjson 0.10.0, SHA-256 checked in `build.sh` |
| Postgres driver | libpq (Ubuntu 24.04 `libpq-dev`) in pipeline mode, binary results, prepared statements |
| Password hashing | bcrypt cost 10 (`$2b$`), own Blowfish implementation, up to 4 hashes advanced in lockstep per thread |
| JWT | HS256, hand-written on OpenSSL HMAC |

Conformance: 197/197 on `test/run.sh`. No benchmark numbers yet.

## Design

- One io_uring per worker thread (`SINGLE_ISSUER | DEFER_TASKRUN`), multishot accept on a per-worker `SO_REUSEPORT`
  listener, multishot recv with a provided buffer ring (idle connections hold no receive buffer).
- Each request is a C++20 coroutine that awaits Postgres segments and bcrypt jobs, so a worker never blocks.
- Each worker owns its Postgres connections; the sockets are polled through the same ring. Nothing on the request path
  is shared between workers.
- **Reads batch naturally:** requests that queue while the read connections are busy go out as one pipeline segment
  (one Sync). No timer window, so batches are size 1 at low load.
- **Writes** use a dedicated connection per worker and group-commit naturally: writes queue while a segment is in
  flight and then share one Sync (one implicit transaction). Register, PUT user and POST article always go alone. A
  failed group is replayed request by request; a connection lost after the Sync returns 500 and is never retried.
  Responses are released only after the commit.
- **One round trip per request:** lookup and action are merged into one statement (or one segment with a read-back),
  and 404/403 are told apart from the result. POST article takes its id from the sequence and finds it again with
  `currval()` inside one segment.
- bcrypt runs on a small pool of low-priority threads, so hashing never stalls an event loop.
- Session settings on every Postgres connection (rule 2): `jit = off`, `max_parallel_workers_per_gather = 0`, `plan_cache_mode = force_generic_plan` (statements are prepared once, so no per-call planning) and `enable_seqscan = off` (every query has an index path; the planner otherwise scans the 200-row `tags` table once per listed article). Tags are looked up by primary key for the same reason.
- Slugs are generated in SQL; no caching of any kind.
- Postgres connection budget: `WORKERS x (DB_CONNS + 1) <= 95`, checked at startup (defaults: 4 x (3 + 1) = 16).

Environment: `DATABASE_URL`, `JWT_SECRET`, `HOST`, `PORT`; optional `WORKERS` (default 4), `DB_CONNS` (read
connections per worker, default 3), `BCRYPT_THREADS` (default 1: one thread fills the lockstep batches best).

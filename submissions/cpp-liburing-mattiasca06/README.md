# C++20 + io_uring + libpq pipeline

**Front: direct.** The server listens on `HOST:PORT` itself and holds every user's keep-alive connection.

| Piece | Version |
|---|---|
| Language | C++20, g++ from Ubuntu 24.04 (`build-essential`) |
| I/O | raw io_uring via liburing (Ubuntu 24.04 `liburing-dev`) |
| HTTP parsing | picohttpparser, pinned commit, SHA-256 checked in `build.sh` |
| Postgres driver | libpq (Ubuntu 24.04 `libpq-dev`) in pipeline mode, binary results, prepared statements |

## Status

Work in progress. Milestone 2: all 19 endpoints are implemented and the conformance suite passes (197/197). Not yet tuned: writes still share the read connections, and there is no group commit or read batching.

## Design

- One io_uring per worker thread (`SINGLE_ISSUER | DEFER_TASKRUN`), multishot accept on a per-worker `SO_REUSEPORT`
  listener, multishot recv with a provided buffer ring (idle connections hold no receive buffer).
- Each worker owns its Postgres connections; the sockets are polled through the same ring. Nothing on the request path
  is shared between workers.
- Session settings on every Postgres connection: `SET jit = off`, `SET max_parallel_workers_per_gather = 0`.
- Postgres connection budget: `WORKERS x (DB_CONNS + 1) <= 95`, checked at startup (defaults: 4 x (3 + 1) = 16).

Environment: `DATABASE_URL`, `JWT_SECRET`, `HOST`, `PORT`; optional `WORKERS` (default 4), `DB_CONNS` (read
connections per worker, default 3).

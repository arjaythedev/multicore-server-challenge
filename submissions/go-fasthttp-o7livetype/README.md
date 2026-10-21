# Go: fasthttp + pgx, batched (production build)

**Front: nginx**

Conduit built only from maintained libraries, with production basics: input validation, structured logs,
reconnect with backoff and graceful shutdown. Source is in `src/`.

| Piece | Version |
|---|---|
| Go | 1.27.2 |
| HTTP | `github.com/valyala/fasthttp` v1.76.0 |
| Postgres driver | `github.com/jackc/pgx/v5` v5.11.0 (`pgconn`) |
| JSON | `github.com/segmentio/encoding` v0.5.4 |
| JWT | `github.com/cristalhq/jwt/v5` v5.4.0 (HS256, `exp` required) |
| bcrypt | `golang.org/x/crypto` v0.58.0, cost 10 |

## Results

1-minute runs on my machine (not the official box), one session, box configs; everything shares 1 core / 2 GB
or 8 cores / 16 GB. Users = most passing p95 < 500 ms and p99 < 1 s with zero errors; the rest is at the 8-core
limit.

| Implementation | Front | 1 core | 8 cores | req/s | p95 | CPU server / PG / Nginx | Memory server / Nginx / PG | |
|---|---|---|---|---|---|---|---|---|
| `examples/go` | nginx | 5,000 | 37,500 | 9,525 | 319 ms | 2.3 / 4.1 / 1.4 | 182 MB / 316 MB / 610 MB | |
| this build | nginx | 10,000 | 67,500 | 17,780 | 49 ms | 2.1 / 3.7 / 2.0 | 142 MB / 318 MB / 159 MB | **<-- This submission** |
| this build, no Nginx | direct | 13,500 | 100,000 | 25,818 | 318 ms | 3.2 / 4.7 / - | 2.0 GB / - / 159 MB | |
| `go-epoll-o7livetype` | direct | 18,500 | 135,000 | 33,645 | 386 ms | 1.9 / 6.1 / - | 1.3 GB / - / 159 MB | |

Past each limit, runs fail on latency, never errors.

## Changes from `examples/go`

| Change | Why | In production? |
|---|---|---|
| Separate read and write queues | Writes waiting on WAL flushes can't hold up reads | Good: simple isolation |
| 22 connections (20 read, 2 write), one worker each | Fewer backends, less PostgreSQL CPU; 95 raised p99 17x | Good, but tune per box |
| Batch queued requests into one round trip | Up to 32 reads or 128 writes per Sync | Good; failure handling is subtler |
| Group commit: a write batch is one transaction | One WAL flush for many writes; each reply waits for it | Good; a failing write is retried alone so it can't sink others |
| One prepared statement per endpoint (CTEs) | 1 round trip instead of up to 5 | Good; the SQL is harder to read |
| JSON written straight from binary rows | No structs or reflection | Mixed: fast, but more code to maintain |
| Queues sized per connection, 30 s timeout | Overload shows up as latency, not 503s | Good with latency alerts; bad if you prefer failing fast |
| bcrypt capped at cores/2, stretches after 1 s | Logins can't starve PostgreSQL, but don't time out | Good |
| Reconnect with exponential backoff (100 ms to 5 s, jitter) | Survives PostgreSQL restarts without errors or double writes | Essential |
| Input validation (field limits, email shape) | Rejects huge or garbage input before it joins a shared transaction | Essential |
| JSON logs: errors, slow requests, 30 s stats line | Shows problems without logging every request | Essential |
| Behind Nginx | TLS, access logs, slow-client buffering | Good for operations; costs about 1 core and a third of capacity |

## Build and run

```bash
sudo bash install.sh && bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=127.0.0.1 PORT=3000 bash start.sh
```

Optional tuning: see `src/main.go`, `src/db.go`, `src/observe.go` (defaults = measured setup). Passes `test/run.sh` (197/197).

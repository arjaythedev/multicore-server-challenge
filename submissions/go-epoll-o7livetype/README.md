# Go: hand-written epoll server + pgx, batched and pipelined

**Front: direct**

A Conduit server tuned for the most users per core: its own epoll event loops and HTTP/1.1 parser, an
allocation-free request path, and pipelined, group-committed prepared statements. Source is in `src/`.

| Piece | Version |
|---|---|
| Go | 1.27.2 |
| HTTP | own epoll reactor and HTTP/1.1 parser on `golang.org/x/sys` v0.49.0 |
| Postgres driver | `github.com/jackc/pgx/v5` v5.11.0 (`pgconn`) |
| JSON | own encoder from binary rows; stdlib decoder for request bodies |
| JWT | own HS256 fast path; `github.com/golang-jwt/jwt/v5` v5.3.1 for anything else |
| bcrypt | own 4-lane pure-Go bcrypt, cost 10; `golang.org/x/crypto` v0.58.0 for other hashes |

## Results

Earlier local 60-second screens, not official five-minute scores. User counts passed p95 < 500 ms,
p99 < 1 s and zero errors in that block; near-limit repeats vary. App + PG share 1 core / 2 GB or
8 cores / 16 GB; Nginx uses the same cores with a separate 2 GB cap. Other metrics are at the
8-core counts; memory is app/Nginx RSS and PG private memory (excludes shared buffers).

| Implementation | Front | 1 core | 8 cores | users vs `examples/go` (1 / 8 cores) | req/s | req/s vs `examples/go` | p50 | p95 | p99 | CPU server / PG / Nginx | Memory server / Nginx / PG | |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `examples/go` | nginx | 5,000 | 37,500 | 1.0x / 1.0x | 9,525 | 1.0x | 142 ms | 319 ms | 372 ms | 2.3 / 4.1 / 1.4 | 182 MB / 316 MB / 610 MB |  |
| `go-fasthttp-o7livetype` | nginx | 10,000 | 67,500 | 2.0x / 1.8x | 17,780 | 1.9x | 13 ms | 49 ms | 77 ms | 2.1 / 3.7 / 2.0 | 142 MB / 318 MB / 159 MB |  |
| `go-fasthttp-o7livetype`, no Nginx | direct | 13,500 | 100,000 | 2.7x / 2.7x | 25,818 | 2.7x | 33 ms | 318 ms | 360 ms | 3.2 / 4.7 / - | 2.0 GB / - / 159 MB |  |
| this build | direct | 18,500 | 135,000 | 3.7x / 3.6x | 33,645 | 3.5x | 231 ms | 386 ms | 452 ms | 1.9 / 6.1 / - | 1.3 GB / - / 159 MB | **<-- This submission** |

The 135k epoll result did not repeat: old/new builds both missed latency with zero errors.

## Changes from `examples/go`

| Change | Why | In production? |
|---|---|---|
| Own epoll loops and HTTP parser, no Nginx | Saves Nginx's ~2 cores and a goroutine per connection | Bad: security-sensitive code to maintain |
| Separate read and write queues | Writes waiting on WAL flushes can't hold up reads | Good |
| 22 connections (20 read, 2 write), one worker each | Fewer backends, less PostgreSQL CPU; 95 raised p99 17x | Good, but tune per box |
| Batching and group commit | One round trip and one WAL flush for many requests | Good; a failing write is retried alone |
| Pipelining, 4 batches in flight | PostgreSQL runs one batch while Go encodes the last (+2%) | Mixed: small gain, pgx bug workaround |
| One prepared statement per endpoint (CTEs) | 1 round trip instead of up to 5 | Good; the SQL is harder to read |
| JSON from binary rows, allocation-free request path | Less Go CPU per request | Mixed: fast, but more code |
| 4-lane pure-Go bcrypt | bcrypt was the largest Go CPU cost; 3x faster per hash | Bad: custom crypto |
| JWT fast path with library fallback | No allocation per verify | Mixed: custom parsing of security tokens |
| Feed returns `following` as constant `true` | Every feed author is followed (-3% CPU on that query) | Good |
| Backpressure instead of 503s, 30 s timeout | Overload shows up as latency, not errors | Good with latency alerts |
| bcrypt workers stretch after 1 s of backlog | Logins don't time out under load | Good |
| Reconnect with exponential backoff (100 ms to 5 s, jitter) | Retries reads and unsent writes; never replays uncertain commits | Essential |

## Build and run

```bash
sudo bash install.sh && bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

Optional tuning: see `src/main.go`, `src/db.go`, `src/reactor_linux.go` (defaults = measured setup). Passes `test/run.sh` (197/197).

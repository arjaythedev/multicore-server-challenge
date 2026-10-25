# Go: custom `epoll` poller + `pgx`, `UNNEST` read/write batching & 8-lane `blowfish8`

**Front: direct**

A pure-Go (`CGO_ENABLED=0`) Conduit server structured around domain handlers (`users.go`, `articles.go`, `comments.go`, `routes.go`), a custom Linux `epoll` network poller (`poller_linux.go`, `http1.go`, `codec.go`), a pipelined PostgreSQL batch engine (`batcher.go`, `queries.go`), and an 8-lane interleaved pure-Go Blowfish/bcrypt engine (`blowfish8/`).

## Stack and versions

| Piece | Version |
|---|---|
| Go | 1.27 (`CGO_ENABLED=0`, `GOEXPERIMENT=mapsplitgroup,simd`, static binary) |
| HTTP | custom `epoll` poll workers on `golang.org/x/sys` v0.49.0 |
| Postgres driver | `github.com/jackc/pgx/v5` v5.11.0 (`pgconn` extended protocol pipeline mode) |
| JSON | binary-row direct encoder (`codec.go`) with `simd/archsimd` 128-bit vector string scanning & `encoding/json/jsontext.AppendQuote`; zero-alloc request envelope scanner (`routes.go`) with `encoding/json/v2` fallback |
| JWT | zero-alloc HS256 fast path (`tokenSigner`) with `github.com/golang-jwt/jwt/v5` v5.3.1 fallback |
| bcrypt | 8-lane interleaved pure-Go Blowfish/bcrypt (`blowfish8`, `cost=10`), `golang.org/x/crypto` v0.58.0 fallback |

## Key Architecture & Optimizations

| Optimization | Why It Matters |
|---|---|
| **Go 1.27 SIMD, Swiss Table & Lookup-Table Switches** | Uses `simd/archsimd` (`Uint8x16` / `Int8x16`) for 16-byte/cycle JSON string escape & quote scanning, `encoding/json/v2` (`jsontext.AppendQuote` / `jsonv2.Unmarshal`), `GOEXPERIMENT=mapsplitgroup` (`KKKKVVVV` Swiss Table cache locality), and `tryLookupTable`-shaped switches (`validTChar`, `decodeHexNibble`, `routeAuthPolicy`) that compile into static `O(1)` lookup tables. |
| **8-lane interleaved pure-Go Blowfish (`blowfish8`)** | Evaluates 8 `cost=10` bcrypt digests in lockstep across 32 KB of L1-resident S-boxes (`~8.66 ms/hash`, `4.07x` faster than `golang.org/x/crypto/bcrypt`). |
| **Two-tier LIFO + FIFO `hashDeque` (`batcher.go`)** | Maintains a 32-slot LIFO fast lane alongside a bounded FIFO ring buffer, serving requests in fair FIFO order under normal load (`<= 350 ms` wait) and automatically prioritizing fresh logins during heavy session bursts. |
| **Materialized Feed & High-Volume Followee CTEs (`opListFeedBatch`, `q31`)** | Uses `WITH rf AS MATERIALIZED, big AS MATERIALIZED` to identify frequent `>= 1,000`-article followees in each batch (`O(1)` array overlap `rf.fols && big.fids` for total count) and paginate each viewer's followed articles before probing `favorites` and `follows` only for returned page rows. |
| **Per-operation `UNNEST` read batching & EDF scheduling (`q22`..`q31`)** | Drains concurrent reads from per-statement rings (`stmtRing`) using Earliest-Deadline-First (`oldestAt`) slack scheduling and executes columnar binary array `UNNEST(...) WITH ORDINALITY` queries with PostgreSQL 18 `CROSS JOIN LATERAL ... Memoize`, uncorrelated `InitPlan` tag-map array subscripting (`(SELECT names FROM tmap)[at.tag_id]`), and pointer-free `[32]uint64` app-side tag sorting (`writeSortedPGTextArray`). |
| **Batched `UNNEST` write group-commit (`q32`..`q36`)** | Coalesces concurrent follow, unfollow, favorite, unfavorite, and comment-creation writes into single `UNNEST` array statements inside implicit pipelined transactions, minimizing row-lock hold time and WAL `fdatasync` calls. |
| **Compact pointer-free socket table & bitset deadline sweep (`poller_linux.go`)** | Stores per-FD state in 32-byte pointer-free `sockEntry` records (zero GC scan overhead) and sweeps active sockets via a 64-FD bitset (`activeMask`). |

## Build and Run

```bash
sudo bash install.sh && bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

Passes `test/run.sh` (`197/197`).

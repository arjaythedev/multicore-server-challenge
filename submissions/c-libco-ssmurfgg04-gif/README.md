# C + libco coroutines (on the io_uring engine)

| | |
|---|---|
| Language | C (GNU C11) + a C++ coroutine executor, Ubuntu 24.04's default GCC, `-O3 -march=native -flto` |
| Framework | none: hand-written io_uring server (multishot accept, per-connection multishot poll, direct `send`) with an epoll fallback probed at startup; Tencent libco (Apache-2.0, vendored, pinned) for stackful coroutines |
| Database | PostgreSQL 18 through a hand-written async wire-protocol (v3) client: SCRAM-SHA-256, ~30 prepared statements, pipelined batches, one round trip per request |
| JSON / JWT / bcrypt | hand-written: strict JSON scanner, HS256 with pre-absorbed HMAC pads, 4-lane ILP bcrypt verified against libxcrypt |

**Front: direct** — the server listens on `0.0.0.0:80` itself and holds every
user's keep-alive connection, so none of the box's CPU goes to Nginx.

liburing and libxcrypt come from the Ubuntu archive (`install.sh`); libco and
everything else are in `src/` and build from source. If the kernel lacks
multishot io_uring, the server probes for it at startup (listen + self-connect
+ `IORING_CQE_F_MORE`) and falls back to an epoll loop running the identical
request pipeline; both fallbacks are logged on stderr.

## Design

**The coroutine executor** (`src/coro.cpp`). Every request runs on a pooled
libco coroutine (64 KiB stacks, created lazily, recycled LIFO; ~1–2k live at
the target load). The event loop stays the sole owner of all I/O — coroutines
only carry handler state across awaits:

- `pg_go()` suspends the request until its batch completes (or the FIFO
  watchdog fails it);
- `req_bcrypt_submit()` suspends until the bcrypt pool finishes the hash or
  verify;
- completions resume the coroutine, which runs the handler's continuation
  callback on the coroutine stack and parks.

A resume that lands on a nested await first unwinds it, then runs the newly
queued command in the same resume, so one resume always equals "finish what
you were doing, then do the next thing". When the pool is exhausted the
request runs inline with the exact pre-coroutine flow: every await point
checks for an attached coroutine and only yields when one is attached, so
both modes are equivalent by construction. 64 KiB per parked coroutine keeps
100k keep-alive connections (each holding at most one in-flight request)
comfortably inside the box's RAM: stacks are held only by requests that are
actually mid-flight, not by idle connections.

**Connections** live in per-worker slot tables addressed by a
`(generation, slot)` packed into the 64-bit `user_data`, so a completion can
never point at a recycled connection. A detached connection whose requests are
still in flight keeps its struct (fd closed, buffers freed) until the last
request replies, then frees itself.

**Postgres** is a hand-written wire-protocol client: SCRAM-SHA-256 auth, named
prepared statements prepared once per connection, and requests executed as
Bind/Execute pipelines with a single Sync — one round trip per request. Batches
from different requests share a connection up to a depth cap; overflow queues
on a per-worker FIFO that preserves arrival order. A fixed pool well under the
95-connection cap (default 12 per worker) leaves `max_connections = 100` headroom.

## Optimizations aimed at the leaderboard's profile

The scored box runs Postgres at 70–80% CPU on the top entries while the apps
idle at 18–27% — the database is the wall, so the levers below target PG work
per request, not app micro-CPU:

1. **`SET plan_cache_mode = force_generic_plan`** (session SET; rule 2 allows
   these). Custom plans re-plan on every Bind; all hot statements are simple
   index walks whose generic plan is already optimal, so re-planning is pure
   overhead. The best C entry measured +41% throughput from exactly this.
2. **One round trip per request** via pipelined Bind/Execute + one Sync, with
   cross-request batching to a depth cap on each connection.
3. **4-lane ILP bcrypt**: login verification at the steady-state rate
   (users ÷ 15 min) executes four hashes step-locked per core; at 100k users
   that is the difference between ~2 cores of bcrypt and ~0.5.
4. **Direct on :80** — no Nginx (~11% of the box in the reference video).
5. **`-O3 -march=native -flto`**, per-request arenas, zero allocations on the
   hot path, strict JSON scanner, HS256 with pre-absorbed HMAC pads.

## Validation

- Upstream-style conformance (Postgres 18, dev seed, `test/run.sh` equivalent):
  all 197 checks pass on kernel 6.8 with full io_uring + SCRAM-SHA-256,
  including 422/validation edges, permission checks and the `Token <jwt>`
  scheme.
- Local 42-point smoke suite across all 19 endpoints (kernel 5.10, epoll
  fallback path): register/login/JWT echo/PUT user/profiles/follow/articles
  CRUD + permissions/filters/feed/favorite/comments/tags/error paths.
- Parallel-runner load tests: 0% errors, no crashes, ASAN-clean under load.

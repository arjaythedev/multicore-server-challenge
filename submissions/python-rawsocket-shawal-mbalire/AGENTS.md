# AGENT.md: Python Raw-Socket Conduit Server Blueprint

This document serves as the core architectural specification and design reference for building a high-performance, ultra-low-overhead implementation of the RealWorld "Conduit" API for the **Multicore Server Challenge** (`arjaythedev/multicore-server-challenge`).

---

## 1. Core Objectives & Constraints

- **Platform Target:** Ubuntu 24.04 x86_64 running on **8 vCPUs and 16 GB RAM**.
- **Python:** CPython 3.15, installed by `install.sh` through uv 0.13.0 (3.15.0), as in `examples/python`: the measurements here were made on 3.15, and Ubuntu's own `python3` is 3.12. uv's standalone CPython is built against old kernel headers (it has no `select.EPOLLEXCLUSIVE`), so don't assume a Linux constant exists in `select`/`socket`/`os` without a fallback.
- **Database:** PostgreSQL 18 running locally on the same box (`max_connections = 100`, fixed schema).
- **Performance Goal:** Maximize throughput and concurrency while minimizing memory overhead and CPU context switching.
- **Correctness:** Must pass 100% of the conformance test suite (`test/run.sh`).

---

## 2. Architectural Principles: Hexagonal Architecture (Ports & Adapters)

To ensure clean separation of concerns, testability, and strict decoupling, the codebase is organized around Hexagonal Architecture:

1. **Domain (`domain/`):** Pure Python business models, frozen dataclasses (`@dataclass(frozen=True)`), and business logic services. **Zero external dependencies** (no HTTP, no database drivers, no framework imports).
2. **Ports (`ports/`):** Interface contracts defined using Python `Protocol` classes for inbound requests and outbound infrastructure (databases, crypto, token validation).
3. **Adapters (`adapters/`):** Concrete implementations of ports:
   - **Inbound (`adapters/inbound/`):** Non-blocking raw socket server (`selectors`/epoll), decorator-based router (`SocketRouter`), and endpoint controllers.
   - **Outbound (`adapters/outbound/`):** PostgreSQL repository adapter (`psycopg3`: statements on libpq directly through `conn.pgconn`, rows decoded by psycopg's C `Transformer`) and cryptographic/JWT adapter (`bcrypt`, `PyJWT`).
4. **Composition Root (`main.py`):** Wires infrastructure adapters, connection pools, and routers together at startup.

---

## 3. Key Design Choices & Rationale

### A. Business Logic Isolation in the Domain Layer

- **Choice:** All validation rules, slug generation, authorization invariants, and core domain transformations live exclusively inside `domain/services.py` and `domain/models.py`.
- **Why:** Decouples business rules from HTTP transport, database drivers, or JSON parsing, ensuring pure functions that are easily unit-tested and fully independent.

### B. Bypassing Frameworks for Raw Sockets & Epoll

- **Choice:** Implement a non-blocking TCP socket server using Python's `selectors` module (backed by Linux `epoll`) rather than standard frameworks like FastAPI, Flask, or Django.
- **Why:** Eliminates heavy framework middleware and request context overhead, giving us total control over keep-alive socket lifecycles, HTTP/1.1 byte-streams, and memory footprints.

### C. Decorator Routing with Frozen Dataclasses

- **Choice:** A lightweight custom router using function decorators (`@router.get`, `@router.post`) that accept raw requests and return **frozen dataclasses**.
- **Why:** Frozen dataclasses provide type safety, structural immutability, and clean domain modeling. The router serializes a returned dataclass with `orjson` (natively, no `asdict` copy) and builds the HTTP/1.1 response bytes; a returned `bytes` value is an already-encoded JSON body and passes through as is.
- **Current state (2026-10-30, open to revisit):** every route except the three user routes returns a JSON body that Postgres builds (`json_build_object`), so `domain/models.py` no longer constructs those responses at run time. That was done for CPU (see section 5) and is a real departure from this section. The dataclasses stay as the response contract: `scripts/diffsql.py` builds the expected responses with them from the spec's reference SQL and compares every Postgres-built body (reads and writes) against them. Keep that check in step with any new statement. Going back to dataclasses for some routes is the user's call.

### D. Bounded Connection Pooling

- **Choice (default since 2026-10-30, `BROKER=1`):** one broker process (`adapters/outbound/pg_broker.py`) owns every connection: `BROKER_READERS` (default 6) read + `BROKER_WRITERS` (default 2) write pipelines, plus one per worker for the bcrypt helper thread: 14 at `WORKERS=6`. With `BROKER=0`, the per-worker layout below.
- **Per-worker layout (`BROKER=0`):** Per inline worker: `PG_READERS` (default 2) read pipelines + 1 write pipeline + 1 connection for the bcrypt helper thread, opened on first use: 4 per worker, 24 at the default `WORKERS=6`. The loop's own `SingleConnection` is opened only when the pipeline is off (`PIPELINE=0`: 2 per worker). In the optional threaded mode (`THREADS=N`), one total budget of **64 connections** (`DB_BUDGET` in `main.py`) is split evenly across the forked workers as fixed-size `psycopg_pool.ConnectionPool`s. `main.py` refuses to start if `WORKERS × connections_per_worker()` exceeds 95.
- **Why:** PostgreSQL is configured with a hard limit of `max_connections = 100` on the challenge box (spec: keep it at 95 or fewer). A fixed bounded pool prevents connection exhaustion while eliminating per-request handshake overhead.

### D2. Statements on libpq, prepared at connect

- **Choice:** Every SQL statement is a module-level `_Stmt` in `pg_repository.py`, prepared by name on each new connection (`configure_connection`). Execution calls `conn.pgconn.exec_prepared` with text parameters, and one psycopg C `Transformer` per connection decodes the rows. A new query must be added as a `_Stmt`. Parameters are untyped, so add casts (`%s::int`) wherever Postgres can't infer the type.
- **Why:** psycopg's `cursor.execute` spent about 45 µs of Python per statement; this path costs a few µs and returns identical values (`scripts/diffsql.py`: 0 mismatches). Errors are re-raised as the matching `psycopg.errors` class, so `UniqueViolation` handling is unchanged.

### E0. Share-first Workers

- **Choice:** Build everything once in the parent (imports, routes, one `SO_REUSEPORT` listener per worker), `gc.freeze()`, then fork `WORKERS` (default 6; 16 before the Postgres pipeline). Each worker is a single thread: its epoll loop runs the synchronous handlers inline (`THREADS=0`, the default). `THREADS=N` adds a per-worker handler pool instead; that measured about 25% fewer req/s per CPU (GIL handoffs, about 20 context switches per request).
- **Why:** Processes exist only to get past the GIL. Everything else is shared (copy-on-write) so each extra worker costs as little as possible. The one exception, approved by the user: each worker gets its own `SO_REUSEPORT` listener, because served directly every user's long-lived connection stays on the worker that accepted it, and a shared `EPOLLEXCLUSIVE` listener split them 106–846 per worker (`REUSEPORT=0` brings it back). Add workers only when measurement shows the app is CPU-bound while Postgres still has headroom.

### E1. Shared Postgres broker, batched reads, group commit

- **Choice:** workers send their queries to the broker over a Unix socketpair (one `marshal` frame per loop pass); `BrokerClient` has `PgPipeline`'s interface, so the loop and handlers didn't change. The broker queues reads by statement and gives an idle read connection the queue whose oldest request is oldest: a batched statement where one exists (`pg_repository.BATCHED`, from `min_size`), one execution for parameterless ones (`SHARED`: tags), pipelined singles otherwise. Queued writes run as one transaction per unit (group commit), replies released after `COMMIT`; a failed batch or group is retried request by request.
- **Why:** Postgres was ~60% of CPU per request, and concurrent requests repeat its work (same page, same popular article, same count). Batching needs the requests in one place; per worker there were 0–1 in flight. The broker is a process, not a thread, because of the GIL. This is a second exception to "share-first" (approved by the user, 2026-10-30).
- **Rules:** a batch reads each request's data while serving it (rule 5: nothing kept between units); group commit is allowed by rule 6.
- **Every batched statement** must return the single statement's bytes for every request: `scripts/batchcheck.py` (0 mismatches). Look keys up via `LATERAL ... LIMIT 1` and deduplicate from `unnest` of an array, not from a CTE: generic plans can't see that a CTE is small (it merge-joined all of `articles`, and sized a HashAggregate for thousands of rows).

### E. Strict Adherence to Challenge Rules

- **No Cross-Request Caching (Rule 5):** Every request queries PostgreSQL directly. No memoization of JWTs, bcrypt hashes, or query results.
- **Real Security (Rule 7):** Passwords are verified against bcrypt cost 10 hashes; every JWT token signature (`HS256`) and expiration is evaluated dynamically.
- **No Nginx (`Front: direct`):** The submission serves directly on `0.0.0.0:80` (no proxy hop, no extra CPU), relying on non-blocking epoll to hold tens of thousands of keep-alive sockets: every virtual user keeps its own connection. Don't add Nginx-specific behaviour; the 90 s idle timeout exists to outlast the workload's 70 s maximum think time.

---

## 4. Project Directory Structure

```text
conduit_server/
├── domain/
│   ├── models.py            # Frozen dataclasses for entities and responses
│   └── services.py          # Pure business logic, validation rules & slug generation
├── ports/
│   ├── inbound.py           # Inbound handler protocols
│   └── outbound.py          # Database & Crypto port contracts
├── adapters/
│   ├── inbound/
│   │   ├── socket_server.py # Non-blocking epoll raw socket server
│   │   ├── router.py        # Decorator router & JSON/dataclass serializer
│   │   └── controllers.py   # Endpoint handlers utilizing domain services
│   └── outbound/
│       ├── pg_repository.py # Psycopg3 PostgreSQL adapter
│       └── crypto_adapter.py# Bcrypt & JWT verification adapter
└── main.py                  # Composition root & process bootstrap
```

---

## 5. Performance Work: Status and Handover

- **Goal (keep it; don't argue to lower it):** about 50 µs of app CPU per request and 30k req/s on the 8-vCPU box, which is about 267 µs of total CPU (app + Postgres) per request. Report each change as measured ns/request moved toward it.
- **Measure on `conduit_full`** (complete seed; `conduit_lg` lacks most follows and comments). Compare laptop runs only with laptop runs (user's instruction). Capacity is the score: also run `STAGES=0 bash scripts/cpusplit.sh 20000` (and higher) to see where a setup fails, not only CPU per request at 8,000.
- **Measure every change** with `WORKERS=6 bash scripts/cpusplit.sh 8000`. It prints the per-stage ns table (`scripts/stagetimer.py` + `scripts/breakdown.py`; README "Measuring"). After any SQL change, run `scripts/diffsql.py` (must print 0 mismatches) and the conformance suite (`bash test/run.sh submissions/python-rawsocket-shawal-mbalire` from the repo root, 197/197).
- **Where things stand (8,000 test users, laptop, latest run, 2026-10-30):** app about 197 µs and Postgres about 330 µs per request (goal 267 µs total), 10,576 req/s, p99 9.4 ms, PASS. Largest app stages: bcrypt 42k ns, loop + unaccounted 34k, libpq round trip 34k, socket recv 21k, JWT 16k, controllers 14k, socket send 12k (full breakdown under "Pipelined writes" below). Postgres is the larger half. The laptop is a hybrid Ultra 7 255H, where Python stages cost about 5× their single-thread cost under load, so trust before/after differences, not absolute numbers.
- **Not allowed:** CPU pinning or core reservation (README rule 12). The service isn't root, and the Postgres backends belong to another user.
- **Done:** JWT verify skips decoding our own HS256 header and uses one-shot `hmac.digest` (8.4 → 5.7 µs single-thread). `parse_request` skips `parse_qs` for plain query strings and slices the body from raw bytes (3.4 → 2.0 µs). Static routes are looked up by exact path. In single-connection mode the repository skips the per-call context manager and encodes parameters by type lookup (`find_user_by_id` 10.5 → 6.4 µs user).
- **bcrypt (about 43 µs/req, cost 10 fixed by the rules):** the computation runs on the OS's libxcrypt `crypt_rn` through ctypes (40.7 ms per verify against pyca's 47.4 ms; it verifies the seed's `$2a$` hashes, and pyca and libxcrypt verify each other's hashes). The three bcrypt routes are `offload=True`: in inline mode they run on one helper thread per worker with a second connection, so the loop keeps serving. A/B at 4,000 users was inside the laptop's noise. By arithmetic the effect is tens of ms on about 2% of requests, not the source of local p99 failures (those look laptop-wide).
- **Connection balance (direct front), done:** `SO_REUSEPORT` listeners, one per worker, give 470–542 connections per worker at 8,000 users (shared listener: 106–846) and halve the median latency. p95/p99 differences were within the laptop's noise.
- **JSON encode and row decode, done (2026-10-24):** `_run` asks libpq for binary results (list page decode 12.9 → 9.6 µs). Timestamps are formatted in SQL (`_TS` in `pg_repository.py`, `to_char`, matches the old Python formatting on every checked row): ~320 ns of Postgres per value instead of ~750 ns of Python. List and comment rows are tuples in `ARTICLE_ROW`/`COMMENT_ROW` order (`ports/outbound.py`); single rows are still dicts. All JSON goes through `orjson` 3.13.0 (pinned), which serializes the frozen dataclasses natively (list page 19.3 → 4.7 µs). Under load, app CPU went 304 → about 260k ns/req (JSON encode 30k → 12k, controllers 42k → 23k, row decode 22k → 17k, repo glue 19k → 14k, JWT 33k → 26k); Postgres went up about 10k.
- **Open question, orjson and p99:** in an alternating A/B at 8,000 users, the stdlib encoder passed 5/5 runs and orjson passed 3/8. When orjson passes it has the best tails (p99 54–249 ms); when it fails, p99 is 1.3–1.7 s on every endpoint, including `/api/tags`, which looks like workers stalling. There is no known mechanism, and the odds of chance are about 4%. The stdlib alternative was `_json.make_encoder(None, hook, encode_basestring_ascii, None, ":", ",", False, False, True)` built once, with a hook returning a dataclass's `__dict__`.
- **List/feed JSON built by Postgres, done (2026-10-24):** `GET /api/articles` and `/api/articles/feed` return a body Postgres builds (`list_json_stmt`: `json_build_object` + `json_agg`; repository `list_articles_json`/`feed_articles_json` return bytes, the router passes bytes through). Single-thread, a 20-article page: Postgres 540 → 563 µs, app 81 → 24 µs (text concatenation in SQL cost Postgres 643 µs, so not that). In an alternating A/B at 8,000 users: app 257k/254k → 238k/242k ns/req (controllers 24k → 19k, row decode 17k → 11k, JSON encode 12k → 10k); Postgres moved within noise (422k/430k → 415k/434k). 3 of 4 runs passed; the failing one was a new run (p99 1.4 s, the same stall pattern as the orjson question). `scripts/diffsql.py` also compares each JSON body with the rows' response (0 mismatches). This trades away the domain models on these two routes; `_articles_response` stays as the reference. Next candidates the same way: comments list, single article, profile.
- **Postgres pipeline, done (2026-10-24):** the hot reads (≈95% of requests) are generator handlers that `yield` a `Query` (`q_*` repository methods); `RawSocketHttpServer` runs it on a per-worker `PgPipeline` (libpq pipeline mode, socket in the same epoll, one Sync per query) and resumes the handler with the result. Writes now go the same way, as single statements on a separate write pipeline (see "Pipelined writes" below); only the three bcrypt routes run synchronously, on the helper thread. `router.dispatch_sync` runs the queries in place for threads and the offload helper. `PIPELINE=0` turns it off. At 8,000 users, app + Postgres ns/req: 16 workers 565k (mean in-flight depth at submit 0.55), 8: 532k (1.5), 6: 503k (2.5, p99 14 ms), 4: 441–455k (7.7–8.4, p99 270–430 ms). Without the pipeline: 8 workers 548k, p99 1.3 s; 4 workers collapse (3.9k req/s, p95 2.1 s). Default is now `WORKERS=6`. The new loop code isn't timed and shows as "loop + unaccounted" (≈30k at 16 workers); generator resumes added ≈5k to controllers.
- **Local Postgres now matches the box (2026-10-24):** the laptop's Homebrew Postgres had `shared_buffers = 128MB` against the box's RAM/4; with the 1.4 GB `conduit_lg`, 10% of buffer reads missed. Now `pgtune.conf` (from `box/pg-conf.sh --print`, shared_buffers 2 GB to fit free RAM) is included from `/home/linuxbrew/.linuxbrew/var/postgresql@18/postgresql.conf` (backup next to it). Postgres went 415–434k → 350k ns/req, and p99 fell from 0.5–1.4 s to 11–44 ms. Earlier Postgres numbers and p99 failures in this file were measured with the small buffers.
- **plan_cache_mode = force_generic_plan, done (2026-10-24):** under `auto` the list statements were re-planned on every execution (~180 µs each). In an alternating A/B at 8,000 users: Postgres 351k/348k → 320k/317k ns/req, all 4 runs PASS. diffsql 0 mismatches, conformance 197/197.
- **Dataclass/JSON, done:** timestamp formatting via plain `isoformat()` + slicing (805 → 640 ns per call, 0 mismatches over 20,004 cases); the JSON hook returns a frozen non-slots dataclass's own `__dict__`. Single-thread, a 10-row list build went 26.9 → 24.6 µs and its encode 14.3 → 12.6 µs; not visible under load through the noise. What remains: frozen-dataclass construction is 518 ns against 100 ns for a dict, and Python's timestamp formatting floor is about 600 ns (20 per list page). Moving the formatting into SQL would change the repository's contract (datetimes become strings), so ask first.
- **Pipelined writes, JSON from Postgres everywhere (2026-10-30):** profile, article, comments and tags are Postgres-built bodies too, and every write (follow, favorite, create/update/delete article, create/delete comment) is one statement (CTEs) on the write pipeline, returning its response body. The create-article CTE upserts new tags with `ON CONFLICT DO UPDATE`: with DO NOTHING, a tag that another request committed meanwhile was missing from the statement's snapshot and its `article_tags` row was lost (reproduced with two connections; the response still listed the tag). `diffsql.py` checks all of it (934 cases: writes inside rolled-back transactions, including an author who follows themselves). The rows-based statements and repository methods are gone. At 8,000 users (`cpusplit.sh`, one run): 10,576 req/s, p99 9.4 ms, app 197k + Postgres 330k = 527k ns/req (bcrypt 42k, loop + unaccounted 34k, libpq 34k, socket recv 21k, JWT 16k, controllers 14k, socket send 12k, router 8k, HTTP parse 8k, repo glue 6k, JSON encode 3k). This run also moved to uv's CPython 3.15, so the change isn't attributable to one cause.
- **Audit fixes (2026-10-30):** a broken pipeline connection's fd is dropped from epoll at once (a new client could get that fd number and hang while the loop spun); comment ids must be ASCII digits within bigint (else 404, not 500); `limit`/`offset` take ASCII digits only; 500 bodies are generic (details go to stderr); `JWT_SECRET` is required; JWT base64 decoding is strict; the loop's own connection opens lazily.
- **Shared broker, batched reads, group commit (2026-10-30):** see E1. Laptop, `conduit_full`, one run each: at 20,000 test users `BROKER=0` failed (18.6k req/s, p95 1.3 s), the broker passed (25.5k req/s, p95 121 ms, p99 223 ms); at 24,000 it passed with 8 readers (p95 494 ms) and failed with 6 (588 ms). At 8,000: app + Postgres 477–509k → 389–407k ns/req (2 readers). IPC costs ~35k ns/req of app CPU. 2 readers is cheapest per request but capped throughput at 13k req/s (one backend = one core): keep enough readers for the box's 8 cores. At saturation Postgres is the limit (4.7 cores locally); the feed (unbatched, ~30% of Postgres time), then tag/author lists, were the next statements to batch. Login p99 and the remaining loop cost are unchanged.
- **Batched feed and author lists (2026-10-30):** each request's count and page are its own, article data once per unit, pages assembled in one grouped join (`_pages_json`; a per-request subquery rescanned all of `w`, O(N²)). Tag and favorited batches measured 15–35% slower than singles (keys rarely repeat), so they stay single. Alternating capacity A/B at 24,000 test users, 6 readers: before 0/2 pass (24.9–26.1k req/s, p95 506–590 ms), after 2/2 (27.5–28.8k req/s, p95 271–351 ms); Postgres 161–174 → 143–146 µs/req. 28,000 now passes with 6 readers (29.7k req/s, p95 443 ms, p99 957 ms); 8 readers failed there (p95 608 ms), so the default stays 6. At 8,000 users the effect is small (Postgres 184–188 → 177–179k ns/req): units are small at low load. Remaining gap to the budget is the app (~215k ns/req against 50k; bcrypt alone ~40k): event loop ~42k, broker IPC ~39k, socket recv 17k, JWT 15k.
- **Next steps, by expected saving:**
  1. Settle the orjson p99 question above, then controllers (23k): faster frozen-dataclass construction via a generated constructor in `domain/models.py` (518 ns against 100 ns for a dict; needs the user's OK).
  2. Postgres (374 µs/req, now the larger half): per-statement cost with pgbench; fewer statements in write paths.
  3. Tune `WORKERS` on the real box (4/6/8): with the pipeline, fewer workers mean deeper batches and less CPU, up to where a worker's single core saturates.


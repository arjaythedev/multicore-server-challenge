# rust-iouring

Front: direct

- **Language / runtime:** Rust 1.99.1 (pinned in `install.sh`), no async runtime, no web framework.
- **I/O:** raw `io_uring` (own ~450-line wrapper over the kernel ABI), one ring per worker thread.
- **HTTP:** `httparse` for parsing, hand-written router and JSON writers.
- **Postgres driver:** hand-written wire-protocol client (v3, SCRAM-SHA-256, extended protocol with
  binary parameters and binary results, pipelined). No driver crate.
- **Crypto:** `ring` 0.17 (HMAC-SHA256 for JWT, PBKDF2/HMAC for SCRAM), `bcrypt` 0.17 (cost 10).
- **Other crates:** `libc`, `crossbeam-channel`, `serde_json` (request bodies only), `base64`, `memchr`.

## Architecture

```bash
              ┌────────────── worker thread (one per core, share-nothing) ──────────────┐
client TCP ─► │ io_uring: multishot accept → multishot recv (provided buffer ring)      │
              │   parse → route → encode ONE pipelined batch → write to a PG socket     │
              │ io_uring: PG send / PG recv (2 connections owned by this worker)        │
              │   ReadyForQuery → render JSON straight from the receive buffer → send   │
              └─────────────┬──────────────────────────────────────────────▲────────────┘
                            │ bcrypt job (register / login / password change)  │ eventfd
                            └────────────► bcrypt thread pool (SCHED_BATCH) ───┘
```

- Each worker binds its own `SO_REUSEPORT` listener; the kernel spreads connections.
- Every request is **one Postgres round trip**: a few Bind/Execute pairs and a single Sync (one
  implicit transaction, committed before the response is written). Reference flows of the form
  "SELECT → decide → UPDATE → SELECT" are folded into conditional SQL plus a result select in the
  same batch (404/403 are decided from the first statement's rows).
- Requests from many clients are **batched into one `send()`** per Postgres connection per event
  loop iteration, and answered in order from one `recv()`.
- bcrypt never runs on an event loop; results come back through a channel + `eventfd`.
- Start-up/shutdown hygiene: a plain-`bind` probe refuses to start next to a stale instance (SO_REUSEPORT would
  silently let both listen); SIGTERM/SIGINT `shutdown(2)` every Postgres socket so backends free their slots at once.

## Optimizations

- Thread-per-core `io_uring` with `SINGLE_ISSUER | DEFER_TASKRUN` (falls back to COOP_TASKRUN / plain
  on older kernels), multishot accept + multishot recv with a provided-buffer ring (idle keep-alive
  connections own no buffer), responses built once into pooled buffers with the HTTP head written
  last (no copy).
- Binary protocol both ways: parameters and results (int8, bool, timestamptz, text, text[]) are never
  converted to/from text; timestamps are formatted with an allocation-free civil-date routine.
- Prepared statements per connection, `plan_cache_mode = force_generic_plan`, `jit = off`,
  `max_parallel_workers_per_gather = 0` (session `SET`s). List pages use a literal `LIMIT`
  (lazily prepared per limit value) so the generic plan keeps walking the index instead of assuming 10%
  of the table; the page is selected as `(ids only, LIMIT/OFFSET)` joined to the expensive per-row columns,
  so skipped rows (OFFSET) never evaluate the tag/favorite/follow sub-selects.
- JWT: strict `alg == HS256`, constant-time HMAC verify on every request, no cache; fast path for the
  header we mint, hand-rolled claim scan with a `serde_json` fallback.
- No locks and no atomics on the request path.

## Knobs (environment)

| variable | default | meaning |
| --- | --- | --- |
| `HOST`, `PORT`, `DATABASE_URL`, `JWT_SECRET` | per SPEC | standard contract |
| `WORKERS` | number of CPUs | io_uring worker threads |
| `PG_CONNS_PER_WORKER` | 2 | Postgres connections per worker (about 2 x cores in total; capped at 90). Only the first is mandatory |
| `BCRYPT_THREADS` | cpus/2 (min 2) | bcrypt pool size |
| `PLAN_CACHE_MODE` | `force_generic_plan` | set to `auto` to disable generic-plan forcing |

## Requirements

Linux with `io_uring` enabled (`/proc/sys/kernel/io_uring_disabled` = 0). Kernel ≥ 6.0 for multishot recv.
The Postgres socket is TCP loopback (the box's `pg_hba.conf` uses `peer` auth on the unix socket, which
would not accept the `conduit` role from the service user).

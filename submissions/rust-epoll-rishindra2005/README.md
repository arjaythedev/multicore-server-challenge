# rust-epoll-rishindra2005

Front: direct

High-performance Conduit (RealWorld) API server combining Rust, x86-64 Assembly, and C, built on Linux `epoll` (`SO_REUSEPORT`) with custom binary PostgreSQL v3 wire protocol client. Zero external crate dependencies (`std` only).

## Architecture & Design Highlights

- **Rust, C, and Assembly Integration**:
  - **Assembly (`asm/fast_asm.s`)**: Cycle-accurate cycle counting and AVX2 string operations.
  - **C Glue (`c_src/fast_glue.c`)**: Socket tuning (`TCP_NODELAY`, `SO_REUSEPORT`, `SO_REUSEADDR`), direct CPU affinity helpers, and process memory configurations (`PR_SET_THP_DISABLE`).
  - **Rust**: Type-safe channel orchestration, non-blocking PostgreSQL v3 wire protocol engine with SCRAM-SHA-256 authentication, and zero-allocation streaming JSON serialization.
- **Direct Epoll Reactor**:
  - 4 `SO_REUSEPORT` reactor threads running under `SCHED_BATCH`.
  - Kernel file descriptor table isolation via `unshare(CLONE_FILES)` to eliminate lock contention on `files_struct` and atomic `fget_light` refcounting.
  - Intrusive $O(1)$ idle LRU connection pool sized dynamically from `RLIMIT_NOFILE`.
  - Zero-allocation HTTP/1.1 request parsing directly out of thread-local buffers.
  - Direct `writev` vectorized socket responses.
- **PostgreSQL 18 Wire Engine**:
  - Session-level planner configuration:
    - `plan_cache_mode = force_generic_plan`
    - `jit = off`
    - `max_parallel_workers_per_gather = 0`
    - `work_mem = 64MB`
    - `random_page_cost = 1.1`
    - `effective_io_concurrency = 256`
  - Prepared statement catalog initialized at startup in binary wire format.
  - **Read Batching**: Exponentially Weighted Moving Average (`EWMA_BATCH_LEN`) queue combining overlapping requests into unified B-Tree window scans and array lookups (`unnest(...) WITH ORDINALITY`). Single-pass `PlanSlot` interning shares rendered `Arc<[u8]>` payloads across identical queries in the batch.
  - **Feed Optimization**: Materializes author cutoffs and caps prolific author queries (`cap_authors`) to eliminate redundant sequential scans.
  - **Write Group Commit**: Mutations batched in atomic pipelined transactions with responses held until commit acknowledgment (strictly adhering to Rule 6).
- **Cryptographic Acceleration**:
  - Multi-lane word-sliced EksBlowfish bcrypt (cost 10) dynamically coalesced (`CRYPTO_LOCK` + EWMA timeout) across 8-way SIMD lanes to guarantee maximum vector throughput.
  - Hardware SHA-NI / scalar HMAC-SHA256 JWT validation reusing precomputed inner/outer pad midstates.
- **Scheduling**:
  - Dynamic CFS unpinned scheduling across all 8 cores/threads (`AFFINITY_MODE=cfs`), eliminating runqueue wait penalties and maximizing instruction throughput.

## Build & Run

Requires: Linux x86-64, GCC/Clang, `binutils`, and Rust stable.

```bash
# 1. Install toolchain dependencies
bash install.sh

# 2. Build release binary
bash build.sh

# 3. Run server
export DATABASE_URL="postgres://conduit:conduit@127.0.0.1:5432/conduit"
export JWT_SECRET="multicore-server-challenge"
export PORT="3000"
bash start.sh
```

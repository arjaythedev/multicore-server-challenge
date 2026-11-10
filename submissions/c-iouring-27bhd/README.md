# C: Thread-Per-Core + io_uring + Pipelined PostgreSQL v3 Wire Engine

**Front: direct**

Ultra-low-overhead, zero-framework C implementation designed specifically for the 8-core, 16 GB RAM PostgreSQL 18 environment of The Multicore Server Challenge.

## Stack

| Piece | Details |
|---|---|
| Language | C (C11, GCC 13+) with `-O3 -march=native -mtune=native -flto -fno-plt` |
| Network Architecture | Multi-worker thread-per-core pinned via `pthread_setaffinity_np()`, `SO_REUSEPORT`, TCP keep-alive, Linux `io_uring` |
| Database Engine | Native PostgreSQL v3 wire protocol (`pg_wire.h`) with dedicated 128 KB RX / 128 KB TX buffers; `libpq` used solely for boot startup/parse |
| Crypto & Password Hashing | Precomputed HMAC-SHA256 key midstates for JWT; dedicated 4-thread `SCHED_BATCH` Bcrypt pool with non-blocking `eventfd` notifications |
| JSON & Serialization | Direct buffer serialization with in-place AVX2 string escaping (`res_append_escaped`), length-bounded parsing, and zero-memmove header prepending |

## Key Architectural Optimizations

1. **Front: direct**: Bypasses Nginx completely, eliminating reverse-proxy hops, saving ~11% CPU for PostgreSQL, and holding tens of thousands of concurrent keep-alive client TCP sockets directly.
2. **Thread-Per-Core Shared-Nothing**: Worker threads are pinned to dedicated hardware cores. Listening sockets use `SO_REUSEPORT` with `TCP_DEFER_ACCEPT` and `TCP_NODELAY`.
3. **Native PostgreSQL v3 Wire Pipelining (`pg_wire.h`)**:
   - Zero runtime `PQexec` / `PGresult` allocations on the hot path.
   - Pipelined single round-trip execution for `favorite`, `comments`, and article mutations.
   - Pipelined `[list_*][count_*][Sync]` in 1 network write/read for list endpoints.
4. **CTE Snapshot-Safe Fusions**:
   - `db_favorite`: Pipelined `[fav_ins/del_slug][art_by_slug][Sync]` so the read-back sees the command counter increment in a single round-trip without CTE snapshot isolation bugs.
   - `db_update_article`: Fused target lookup, update, and full article read-back in 1 query.
   - `db_delete_article` & `db_delete_comment`: Single CTE checking 404 vs 403 and deleting in 1 query.
   - `db_follow`: Single CTE resolving target user and updating `follows` in 1 query.
5. **Session-Level Database Tuning**: Connections run with `SET jit = off; SET plan_cache_mode = force_generic_plan; SET TimeZone = 'UTC';` to eliminate query re-planning overhead.
6. **Literal Fast-Path Queries**: Prepares literal `(10, 0)`, `(5, 0)`, and `(20, 0)` fast-path statements for all list filters and feeds to guarantee optimal backward index scans without cost-planning pauses.
7. **Dedicated Bcrypt Worker Pool**: High-cost Bcrypt operations (cost 10) are offloaded to dedicated background threads so network loops never stall on 35 ms password hashes.
8. **C-Side Slug Generation**: Slugs are generated directly in C (`slugify_title`) in branchless ASCII lookup loops, bypassing heavyweight POSIX regex engines in PostgreSQL.
9. **Deduplicated & Sorted Tags**: `tagList` arrays are sorted and deduplicated in C memory prior to transaction execution, and inserted via `WHERE NOT EXISTS` with `ORDER BY u.name` to eliminate locking deadlocks.
10. **Zero-memmove Response Prepending**: Status lines and headers are formatted backwards in a 256-byte header reserve offset directly in front of response bodies, transmitting in a single `io_uring_prep_send`.


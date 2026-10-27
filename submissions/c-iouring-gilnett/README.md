# c-iouring-gilnett — Zero-Framework C11 (`io_uring` + Coalesced Read Batching + 6-Lane Bcrypt)

Front: direct

A surgical, zero-framework C11 RealWorld (Conduit) implementation built directly on Linux `io_uring`, raw PostgreSQL wire protocol v3, connection-driven SQL read coalescing with shared article enrichment, single-CTE mutations, and 6-lane interleaved OpenBSD `2b` EksBlowfish bcrypt.

## Architecture & Key Optimizations

### 1. Shared-Nothing `io_uring` Event Loops (`src/server.c`)
- **4 event-loop threads** on the 8-vCPU host (`cpus / 2`, `SO_REUSEPORT` listeners, `IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_COOP_TASKRUN | IORING_SETUP_DEFER_TASKRUN`).
- **Zero-buffer idle keep-alive connections**: Idle sockets hold no read/write heap buffer (`~200 B` per `req_t` struct). Multishot `IORING_OP_POLL_ADD` triggers a `recv()` into a thread-local 256 KiB scratch buffer (`w->rx_scratch`), parses HTTP/1.1 in-place, and resets the request's inline bump arena (`3 KiB` inline) once `writev()` completes.
- **SIMD AVX2 JSON Escaper & SHA-NI JWT Verification** (src/util.c): 32-byte SIMD vector scan via _mm256_movemask_epi8 and hardware SHA-NI instructions (_mm_sha256rnds2_epu32) for sub-microsecond token HMAC computation.
- **Core Pinning & Cache Affinity**: pthread_setaffinity_np isolates io_uring workers on physical cores 0..3 and confines bcrypt threads to higher cores.

- **Strict Read/Write separation**: Each worker opens 13 dedicated read connections and 3 dedicated write connections (52 read + 12 write = 64 total backends across 4 workers, fully utilizing the 8 physical vCPUs while staying safely below max_connections = 100).
- **Zero Read-Behind-Write Head-of-Line Blocking**: Read queries never wait behind `synchronous_commit = on` WAL flushes.
- **Session-level planner tuning**: Every backend sets `-c synchronous_commit=on -c plan_cache_mode=force_generic_plan -c jit=off -c max_parallel_workers_per_gather=0 -c work_mem=16MB` during startup and prepares all 36 statements once via Extended Query Protocol `Parse` + `Sync`.

### 3. Connection-Driven Read Coalescing & Shared Article Enrichment (`src/api.c`)
- **Zero-timer adaptive batching**: Read requests arriving during an `io_uring` CQE batch or while read connections are busy accumulate in per-endpoint queues (`RQ_TAGS`, `RQ_LIST_ALL`, `RQ_LIST_TAG`, `RQ_LIST_AUTHOR`, `RQ_LIST_FAV`, `RQ_FEED`, `RQ_ARTICLE`, `RQ_COMMENTS`, `RQ_PROFILE`, `RQ_USER`, `RQ_LOGIN`).
- **Single-item fast path (`n == 1`)**: At low concurrency, a single queued request executes its direct prepared statement with zero array/CTE overhead and zero artificial timer delay.
- **Coalesced `unnest(...) WITH ORDINALITY` batch path (`2 <= n <= 32`)**:
  - **Page & Filter Deduplication (`u_flt`, `u_pages`)**: Identical `(filter, limit, offset)` tuples within a coalesced batch execute the capped 1,000-row count and base index scan **only once** inside the SQL statement snapshot.
  - **Shared Article Enrichment (`u_arts`)**: Distinct articles across all coalesced requests in the batch enrich `tagList` (via `tags_pkey` lookup), `favoritesCount`, and author profile **only once**, joining viewer-specific `favorited` (`v_fav`) and `following` (`v_fol`) via primary-key index probes.
  - **All 11 Read Endpoints Coalesced**: Includes `GET /api/articles/:slug/comments` (`S_COMMENTS_BATCH`), `GET /api/articles/feed` (`S_FEED_BATCH` where `author.following` is constant `true`), `GET /api/tags` (`MAX_COALESCE_TAGS = 64` live broadcast to requests waiting in the same drained batch), `GET /api/profiles/:username`, `GET /api/user`, and `POST /api/users/login`.
  - **Fast Capped Count (`OFFSET 999 LIMIT 1`)**: `S_LIST_ALL` and `S_LIST_TAG` check `EXISTS (SELECT 1 ... OFFSET 999 LIMIT 1)` before falling back to `count(*)`, avoiding MVCC visibility churn on recently inserted heap pages.

### 4. Single-CTE Durable Mutations (`src/api.c`)
- **`POST /api/articles` (`S_INSERT_TAGS` + `S_CREATE_ARTICLE`)**: Pre-filters existing tags via `WHERE NOT EXISTS (SELECT 1 FROM tags t WHERE t.name = u.name) ORDER BY u.name` (avoiding `tags_id_seq` sequence page dirties and index lock contention when reusing the 30 seeded tags) and returns the newly created article directly from `RETURNING` + `users` without a second `SELECT_ARTICLE` round-trip.
- **`POST/DELETE /api/profiles/:username/follow` (`S_FOLLOW_PROFILE` / `S_UNFOLLOW_PROFILE`)**: Combines user lookup and `follows` insert/delete into a single CTE statement.

### 5. 6-Lane Interleaved EksBlowfish Bcrypt (`src/bcrypt.c`)
- **L1d-resident 6-lane interleaving (`BC_LANES = 6`)**: Six Blowfish states (`6 × 4,168 B = 25,008 B`) fit entirely inside a 32 KiB L1 data cache per physical core while hiding the 4-cycle L1 load-to-use latency across all 16 Feistel rounds.
- **`SCHED_BATCH` scheduling**: Bcrypt worker threads run under `SCHED_BATCH` so the Linux scheduler prioritizes `io_uring` event loops and PostgreSQL backends without context-switch thrashing.
- **Verified against `libxcrypt`**: Run `./bin/conduit --bcrypt-selftest` to verify 1..6 lanes against `crypt_rn`.

## Credits & License

MIT License. Builds upon the architectural insights and open-source MIT submissions in this repository, notably [`c-iouring-tigokraft`](../c-iouring-tigokraft), [`rust-tokio-Scooter1337`](../rust-tokio-Scooter1337), and [`csharp-sockets-jh-d`](../csharp-sockets-jh-d).

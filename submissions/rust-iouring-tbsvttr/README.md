# rust-iouring-tbsvttr (Multicore Server Challenge)

Front: direct

Zero-dependency Rust implementation (`[dependencies]` is empty in [`Cargo.toml`](Cargo.toml)) for the RealWorld **Multicore Server Challenge**.

## Architecture & Modules

- **[`src/reactor.rs`](src/reactor.rs)**: Multi-reactor I/O runtime using `SO_REUSEPORT` TCP listeners, Linux `io_uring` (`SYS_IO_URING_SETUP` + multishot `IORING_OP_POLL_ADD` on `ep_fd` + `SYS_IO_URING_ENTER`) with non-blocking `epoll_wait` event harvesting, zero-allocation HTTP/1.1 request parser, and `writev` scatter-gather response transmission.
- **[`src/router.rs`](src/router.rs)**: Fast byte-level route classifier for all 19 RealWorld API endpoints (`/api/users`, `/api/user`, `/api/profiles/:username`, `/api/articles`, `/api/articles/feed`, `/api/articles/:slug/comments`, `/api/tags`, `/health`).
- **[`src/auth.rs`](src/auth.rs)**: Pure-Rust SHA-256 with hardware `x86_64` SHA-NI (`sha256rnds2`, `sha256msg1`, `sha256msg2`) acceleration and scalar fallback, precomputed `HMAC-SHA256` midstates (`Sha256Precomputed`), HS256 JWT generation/verification, and 6-lane SIMD (`u32x8` AVX2) interleaved Eksblowfish (`bcrypt_hash_many`, `bcrypt_verify_many`) with priority-split background workers (`nice 5` watchdog worker for tail latency + `nice 15` throughput workers for full 6-lane batches).
- **[`src/codec.rs`](src/codec.rs)**: Strict RFC 8259 JSON parser/validator, zero-allocation byte formatters (`write_i64`, `write_json_escaped`, `format_pg_timestamptz`), and slug generation.
- **[`src/wire.rs`](src/wire.rs)**: Direct PostgreSQL v3 binary wire protocol client (`PgConn`) supporting `AuthenticationOk`, `AuthenticationCleartextPassword`, and `AuthenticationSASL` (`SCRAM-SHA-256`), pipelined `Parse`/`Bind`/`Execute`/`Sync` batching, and zero-copy binary row decoding.
- **[`src/queries.rs`](src/queries.rs) & [`src/engine.rs`](src/engine.rs)**:
  - **Multi-Worker Two-Phase Pipelined Read & Write Engine (`ReadWorker` / `WriteWorker`)**: Parallel `ReadWorker` and `WriteWorker` threads drain partitioned sharded queues (`LANE_FAST`, `LANE_HEAVY`) over persistent PostgreSQL connections.
  - **Deduplicated Author-Centric Feed Execution (`feed`)**: Passes distinct `(viewer_id, lim, off)` tuples (`uf`) and pre-aggregated viewer ids (`ff AS MATERIALIZED`) to PostgreSQL so each followed author's `articles_author_idx` index is scanned **at most once per batch** (`LIMIT 48`), then merges and paginates each viewer's followee articles in L1 cache in Rust before Phase-2 enrichment.
  - **Two-Phase Enrichment (`enrich`) & Pre-Rendered Arena Cache**: Phase 1 fetches only lightweight structural keys (`article_id`, `author_id`, `favorited`, `following`, `total_count`), and Phase 2 bulk-enriches only cache-missed article/user/tag rows into a shared `RenderCache` arena (`PreRenderedArticle`, `PreRenderedComment`).

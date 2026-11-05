# rust-iouring-tbsvttr (Multicore Server Challenge)

Front: direct

Zero-dependency Rust implementation (`[dependencies]` is empty in [`Cargo.toml`](Cargo.toml)) for the RealWorld **Multicore Server Challenge**, built on `tbsvttr`'s shared Rust foundation and evolved from [`nelua-epoll-tbsvttr`](../nelua-epoll-tbsvttr).

## Architecture & Modules

- **[`src/sys.rs`](src/sys.rs)**: Direct Linux `libc` syscall bindings (`epoll_create1`, `epoll_ctl`, `epoll_wait`, `accept4`, `eventfd`, `getrandom`, `clock_gettime`, `setpriority`, `sched_getaffinity`) and TCP socket tuning (`SO_REUSEPORT`, `TCP_NODELAY`, `TCP_DEFER_ACCEPT`, `TCP_QUICKACK`).
- **[`src/buf.rs`](src/buf.rs)**: Zero-allocation byte formatters (`put_int` with a 2-digit lookup table, RFC 8259 `put_json_string`, and `put_timestamp` converting binary PostgreSQL `timestamptz` microseconds since `2000-01-01` UTC into RFC 3339 `"YYYY-MM-DDTHH:MM:SS.mmmZ"`).
- **[`src/json.rs`](src/json.rs)**: Single-pass recursive-descent RFC 8259 JSON validator and zero-allocation field extractor (`valid`, `find`, `object`, `body_object`, `obj_field`, `required`, `next_element`, `decode_string`).
- **[`src/jwt.rs`](src/jwt.rs)**: Pure-Rust SHA-256, `HMAC-SHA256` with precomputed `ipad`/`opad` SHA-256 midstates (`JwtKey`), `PBKDF2-HMAC-SHA256` (for PostgreSQL `SCRAM-SHA-256` authentication), constant-time `ct_eq`, strict unpadded `base64url`, and per-request HS256 JWT verification (`alg == "HS256"`, `exp > now`, decimal `sub`).
- **[`src/blowfish.rs`](src/blowfish.rs) & [`src/bcrypt.rs`](src/bcrypt.rs)**: Pure-Rust multi-lane interleaved Eksblowfish (`1..=6` lanes, calibrated at startup via `calibrate_lanes`) hashing and verifying up to 6 passwords simultaneously per helper thread so their key schedules share instruction streams inside L1D cache.
- **[`src/pg.rs`](src/pg.rs)**: Pure-Rust PostgreSQL v3 wire protocol client supporting `AuthenticationOk`, `AuthenticationCleartextPassword`, and `AuthenticationSASL` (`SCRAM-SHA-256`), single-round-trip pipelined statement preparation (`s00`..`s21`), and zero-copy binary `DataRow` (`Row`) and `int8[]` (`Int8s`) cursors.
- **[`src/server.rs`](src/server.rs) & [`src/main.rs`](src/main.rs)**:
  - **In-Process Shared-Memory Queues + `eventfd` Wakeups**: Replaces `nelua-epoll-tbsvttr`'s multi-process Unix `socketpair` and `SOCK_DGRAM` IPC with in-process thread queues (`WorkerInbox`, `DbInbox`, `BcryptPool`) and coalesced `eventfd` notifications.
  - **22 Prepared Statements & Set-Based Read Batching (`PAGES`, `FEED`, `COMMENTS`)**: Uses 22 SQL statements (`s00`..`s21`), folding the 4 article list endpoints (`LIST_GLOBAL`, `LIST_TAG`, `LIST_AUTHOR`, `LIST_FAVORITED`) and `ARTICLE` into `PAGES` (`s08`), running `FEED` on a dedicated hub-floor lateral merge statement (`s12`), and scoping `follows_pkey` probes in `PAGES` (`s08`) and `COMMENTS` (`s19`) to only the authors present on each page/comment thread so `Arc<[u8]>` response buffers are shared zero-copy across signed-in viewers with identical `(favorited=false, following=false)` flags.
  - **Once-Per-Batch Pre-Formatted JSON Fragments & Disconnected-Client Pruning**: In `pages_finish` and `comments_finish`, each distinct tag (`k = -2`), author (`k = -1`), article (`k = 0`), and comment (`k = 0`) row returned by PostgreSQL is JSON-escaped, timestamp-formatted, and tag-sorted **once per batch** into a contiguous arena buffer. Disconnected clients are pruned before starting or batching queued DB and bcrypt work via per-slot generation counters (`WorkerInbox::is_alive`).

# rust-epoll-theCatWisel

Front: direct

HTTP/1.1 backend written in Rust on top of Linux epoll (`SO_REUSEPORT`) and a custom binary PostgreSQL v3 wire client. Everything in the binary (Linux syscall FFI, HTTP parsing, JSON codec, Base64/Base64URL, SHA-NI / scalar SHA-256, HMAC-SHA256, and multi-lane EksBlowfish bcrypt) is implemented in-tree with zero external crate dependencies (`std` only).

## Design

Four `SO_REUSEPORT` reactor threads accept connections with `accept4` and parse HTTP/1.1 requests directly out of a thread-local 256 KiB read buffer whenever a request arrives in one read, avoiding per-connection heap allocations on idle keep-alive sockets. Responses are written back with `writev`.

Database work is split across 12 read workers and 1 write worker, each holding a single persistent PostgreSQL connection with prepared statements in binary wire format and session-level planner tuning (`plan_cache_mode = force_generic_plan`, `jit = off`, `max_parallel_workers_per_gather = 0`, `enable_memoize = off`, `work_mem = 32MB`, `random_page_cost = 1.1`, `effective_io_concurrency = 200`):

- Read workers pace batch draining with a self-clocked closed-loop controller derived from Little's Law (`L = lambda * W`) and active fair-share slicing (`fq_codel`), using live EWMA service times (`EWMA_BATCH_US`) and batch lengths (`EWMA_BATCH_LEN`) with zero hardcoded sleep timers. Each batch executes in two pipelined PostgreSQL round trips over reusable byte arenas and reusable `ArrayEncoder` buffers. Phase A deduplicates identical lookups (`unnest(...) WITH ORDINALITY`), shares lookup CTEs across count and page branches on filtered article feeds, computes shared prolific-author floor cutoffs on `feed`, and caps `articlesCount` at 1,000. Phase B fetches tags and favorite counts once per unique article (`artx`), resolves author profiles once per unique author (`artau`), and evaluates per-viewer `favorited` and `following` flags via grouped primary-key array lookups (`flags`). Viewer-independent JSON fragments are formatted once into a batch-local byte buffer and spliced with each viewer's boolean flags.
- The write worker wraps each batch of mutations in a single `BEGIN ... COMMIT` pipeline, grouping concurrent favorite and follow operations into sorted `unnest` statements and falling back to per-item execution if a statement fails. Post-commit article reads are handed to the read queue so their enrichment shares Phase B with concurrent reads.
- Crypto worker threads (`cores.max(4)`) verify and hash passwords in multi-way word-sliced lockstep (`bcrypt_lanes<N>` with 64-byte cache-line aligned `BfState`), auto-calibrating the lane width `N` at startup against the host CPU's L1D cache and register file (`N = 4` on x86-64) and pacing batch collection proportionally via `BUSY_CRYPTO_WORKERS` and `EWMA_BCRYPT_US`. JWT verification reuses precomputed SHA-256 `ipad`/`opad` midstates for the server secret.

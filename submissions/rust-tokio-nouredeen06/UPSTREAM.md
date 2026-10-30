# Provenance

Starting point: `submissions/rust-tokio-Scooter1337` at
[challenge commit c3012257](https://github.com/arjaythedev/multicore-server-challenge/tree/c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e/submissions/rust-tokio-Scooter1337).
That submission credits cknutson12's MIT-licensed Rust/hyper implementation for
its API and initial SQL.

The server, vendored tokio-postgres modifications, native bcrypt implementation,
HTTP parser, JSON writer, authentication, durable group commit and existing read
coalescing are derived from that source, with the original licenses preserved.
See `vendor/tokio-postgres/MODIFICATIONS.md` and `native/README.md` for those
components' details and attribution.

New work in this folder: distinct filtered-list count/page queries and selection,
the exact global-count cap fast path, comment batching and routing, increased
bounded bcrypt concurrency, benchmark/reproduction tools and regression checks.
The later batching pass adds single-parse sharing selection, integer-array
capacity reservation, reuse of empty database job buffers, one-time write
encoding and packed write submission. Bounded correctness checks are documented
separately from the earlier throughput measurements.
The README and measurement report describe this derivative, not the upstream
submission's machine or results.

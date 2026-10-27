# Research and architecture selection

Research date: 2026-10-24. Challenge revision: `c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e`.

## Objective

I want the strongest practical chance of a leading official score while developing entirely on a native ARM64 Mac. That means balancing performance headroom with the ability to test, understand and finish the implementation. I cannot assign a defensible numerical probability to a first-place finish before building and measuring candidates.

## Evidence

The official leaderboard currently puts Rust/Tokio first at 100,000 users and 26,279 requests per second, with p95 119 ms and p99 185 ms. Its reported application/PostgreSQL CPU shares are 20%/70% of the whole machine. C#/Sockets follows at 95,000 users. Both use direct serving and database-work batching.

The reference Go server scores 24,000 users. The C++/Asio entry, which uses libpq pipelining, scores 68,000. These results show that the language or driver name alone does not explain the ranking. They are not controlled experiments that isolate an individual design choice.

I inspected the leading Rust entry's SQL, database routing and read-batching code. Its useful ideas include selecting page IDs before enrichment, prepared plans, limited database connections, sharing viewer-independent enrichment inside a batched statement, and keeping writes away from read pipelines. Those are evidence for a research direction, not measurements of my own implementation.

Open Zig PRs #45 and #53 propose io_uring, custom database clients, read batching, group commit and interleaved bcrypt. Their local results and reported tests are author claims, not official scores I have reproduced. They also show that using Zig is no longer a unique contribution by itself.

## Selection

**My recommended starting architecture is a direct Zig reactor with libpq, picohttpparser, bounded queues and workload-aware SQL batching.**

This is an engineering judgement under my constraints, not a benchmark conclusion. It leaves room for the techniques used by leading entries while avoiding an immediate rewrite of PostgreSQL authentication and protocol handling. It also keeps the application runnable on my Mac rather than making Linux-only I/O the foundation.

| Candidate | Strength | Main constraint | Decision |
|---|---|---|---|
| httpz + pg.zig | Small amount of integration work; native Zig; Mac/Linux support | Ordinary handlers and one active query per connection do not directly expose the scheduling model I want | Useful reference option; not the selected end architecture |
| Own Zig reactor + libpq + small HTTP parser | Explicit ownership, asynchronous database work, portable core, existing protocol implementation | More socket and HTTP-lifecycle work; C interop and libpq result allocations | Selected starting point |
| Own Zig HTTP and PostgreSQL wire clients | Maximum control over buffers, messages and decoding | SCRAM, framing, recovery and transaction semantics substantially enlarge the correctness burden | Revisit only if profiling identifies a meaningful libpq limit |
| Linux io_uring/fiber framework | Potentially efficient Linux I/O | Cannot execute that backend natively on macOS; performance depends on framework-specific behaviour | Deferred under the Mac-only constraint |

The inspected httpz revision uses event-loop workers plus a handler thread pool. `Response.disown()` removes the socket from httpz's ownership; it is not a ready-made facility to suspend a normal request and later resume its existing HTTP lifecycle. Extending that model is possible, but no longer the simple framework integration it first appeared to be.

The inspected pg.zig revision rejects a new query when its connection is busy. It supports prepared statements and can execute set-based SQL batches; it should not be described as inherently slow. My reason for preferring libpq is its explicit supported non-blocking and pipeline interfaces, not a measured advantage over pg.zig.

Picohttpparser provides stateless request/header parsing without internal allocation. It is small enough to compile from pinned source without installing another app. It does not provide complete HTTP policy: my server must still implement body framing, conflicting-header rejection, limits, connection lifetime, partial reads and partial writes.

## Performance hypotheses

1. Reducing repeated PostgreSQL execution work will matter more than polishing an already small routing path.
2. Combining compatible queued reads can amortize statement overhead and avoid repeated enrichment within one execution.
3. A small set of busy backends can outperform a large connection pool because PostgreSQL shares the application's CPU budget.
4. Direct serving can reduce proxy work, provided idle connections remain cheap and output backpressure is handled correctly.
5. Separating writes from reads can prevent WAL-flush waits from holding up read work on the same connection.

Each is a hypothesis to test. None justifies hard-coded benchmark responses, a response cache, a schema change or a claim of guaranteed speedup.

## What could make this design beat a strong baseline

The opportunity is a scheduler that batches useful overlap without creating long queues. I will first batch by query family and use the oldest waiting work to select the next dispatch. I will then test deduplicating repeated page/count/article enrichment within a single SQL execution while retaining per-viewer flags. Highly personalised feeds may benefit less and should not be forced through a slower shared path.

Batch size, worker count and connection count are experimental variables. Deep pipelining is not a goal in itself: sending more work to an already saturated backend can make p99 worse. A useful batch saves more work than it adds in parameter encoding, planning, sorting, result allocation and response demultiplexing.

I will measure the database path before introducing grouped writes or specialised bcrypt. Standard bcrypt cost 10 remains the reference. Portable interleaving is a possible later experiment; untestable x86-only assembly is not part of the initial plan.

## Meaning of a successful run

The challenge requires all 197 conformance checks, then a full-seed hold with p95 below 500 ms, p99 below 1 second and errors below 1%. The official hold has a 60-second ramp followed by 300 measured seconds. The load generator must not be the limiting resource.

My Mac has six cores and 8 GiB RAM. Running server, PostgreSQL and load generation together is useful for controlled local comparisons but cannot reproduce an eight-vCPU/16-GB Ubuntu target with separate generators. Neither a large local requests/second number nor successful cross-compilation proves an official score. Linux CI checks functionality, not representative capacity.

## Decision gates

- Demonstrate native libpq integration and correct non-blocking read/write progress before expanding the server.
- Reach a correct single-request database path before batching.
- Pass unchanged conformance on development and full data before pursuing capacity claims.
- Compare each SQL rewrite and batch path against reference results, including empty results, deep offsets and concurrent mutations.
- Keep the simple path as a control for repeated A/B runs; alternate run order and record memory pressure and generator limitations.
- Replace libpq only if profiling shows a material application-side cost that survives SQL and scheduling improvements.
- Submit only after clean Ubuntu installation/build and runtime checks succeed.

## Sources and inspected revisions

- [Challenge rules](https://github.com/arjaythedev/multicore-server-challenge/blob/c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e/README.md), [API](https://github.com/arjaythedev/multicore-server-challenge/blob/c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e/SPEC.md), [workload](https://github.com/arjaythedev/multicore-server-challenge/blob/c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e/WORKLOAD.md), [leaderboard](https://github.com/arjaythedev/multicore-server-challenge/blob/c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e/LEADERBOARD.md).
- [Rust leader](https://github.com/arjaythedev/multicore-server-challenge/tree/c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e/submissions/rust-tokio-Scooter1337), [C# runner-up](https://github.com/arjaythedev/multicore-server-challenge/tree/c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e/submissions/csharp-sockets-jh-d), [C++/libpq](https://github.com/arjaythedev/multicore-server-challenge/tree/c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e/submissions/cpp-asio-c-hatton).
- [Zig PR #45](https://github.com/arjaythedev/multicore-server-challenge/pull/45), head `ed2e521f6d367005b10682460e8003f1cfdcbdd6`; [Zig PR #53](https://github.com/arjaythedev/multicore-server-challenge/pull/53), head `fdc37b33ded89d19e76bb7942de7de433a260c73`.
- [httpz](https://github.com/karlseguin/http.zig/tree/e8272bfd5727aade0dcee3e2aba6c50f57c374b6), [pg.zig](https://github.com/karlseguin/pg.zig/tree/0ccd7d9dabce32e4cee0dd789d8007934099a0f9).
- [Picohttpparser](https://github.com/h2o/picohttpparser/tree/465a7ff09fbd3432fe56c673451f5460154d1f07): candidate revision, not yet vendored or built.
- PostgreSQL 18: [asynchronous processing](https://www.postgresql.org/docs/18/libpq-async.html), [pipeline mode](https://www.postgresql.org/docs/18/libpq-pipeline-mode.html), [thread ownership](https://www.postgresql.org/docs/18/libpq-threading.html), [protocol flow](https://www.postgresql.org/docs/18/protocol-flow.html).

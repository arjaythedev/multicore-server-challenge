# Competitor source review

Reviewed on 2026-10-24. I inspected selected request, scheduling, SQL, connection and authentication paths rather than treating README claims as a code audit. This is not a complete security review or a reproduced capacity benchmark.

## Revisions and scope

The leaderboard entries below were read at challenge revision `c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e`. The two additional Zig trees were fetched into separate research refs without checking them out over my implementation branch.

| Entry | Official users at this checkpoint | Main source paths inspected |
|---|---:|---|
| Rust/Tokio, Scooter1337 | 100,000 | src/sql.rs, read_batch.rs, db.rs, writer.rs, http.rs, password_batch.rs |
| C#/Sockets, jh-d | 95,000 | src/Batch.cs, CpuWork.cs, Program.cs and relevant handler/SQL paths |
| C/io_uring, tigokraft | 84,000 | src/server.c, pg.c, conduit.h and API query construction |
| COBOL/GnuCOBOL, benmandrew | 84,000 | selected pd-loop.cpy, pd-pgconn.cpy and pd-app.cpy paths; lighter coverage |
| Zig/io_uring, PR #45 | Not officially scored in this leaderboard | src/http.zig, api.zig, server.zig, pg.zig, bcpool.zig, jwt.zig and configuration |
| Zig/fourneau, PR #53 | Not officially scored in this leaderboard | src/main.zig, shard.zig, batch.zig, SQL construction and jwt.zig |

Zig #45 head: `ed2e521f6d367005b10682460e8003f1cfdcbdd6`. Zig #53 head: `fdc37b33ded89d19e76bb7942de7de433a260c73`. I did not audit the external fourneau runtime in full or run either Linux server on this Mac.

## Strong techniques worth keeping

**Rust #1:** its SQL moves enrichment after pagination and shares useful viewer-independent work within one batched execution. Connection routing considers queued work and query family; actor queues are bounded. Writes and reads use separate connections, and the HTTP layer releases buffers while sockets are idle. This is already a sophisticated implementation. My opportunity is to test a simpler ownership model and better batch composition, not assume that removing Rust overhead is sufficient.

**C# #2:** the read dispatcher waits for connection capacity and chooses the query family with the oldest waiting request, with per-family occupancy limits. This is a valuable alternative to a deep pipeline: a backlog in PostgreSQL cannot be rearranged by the application. Its row decoder and response writer also avoid unnecessary intermediate objects. The code deliberately avoids some shared-row work inside batches; comparing that approach with statement-local enrichment sharing is a useful experiment rather than an automatic win.

**C #3:** the io_uring workers own their sockets and database connections. The database path caps in-flight request batches (default depth 16) and leaves excess work in a worker FIFO. Statements are prepared and responses wait for the relevant transaction boundary. This makes pipelining practical, but one request group is still not the same as combining many requests into one set-based SQL execution. The newer SQL-sharing designs offer an additional opportunity to reduce per-request database work.

**COBOL #4:** selected source paths show explicit asynchronous request completion and transaction boundaries, with direct buffer-oriented processing. Its score is a useful warning against making the language the explanation. Its documented bcrypt collection window is up to 500 ms: an intentional workload tradeoff, not evidence that the hash itself is skipped.

**Zig #45:** compact per-connection state, generation-tagged completions, SQL batching, isolated grouped-write fallback and a small dependency surface are strong ideas. The Linux-only I/O and x86-specific hash path are unsuitable foundations for my native-Mac development requirement, even if they are valid competition choices.

**Zig #53:** the database-capacity-driven scheduler, batching by family and within-statement sharing are particularly relevant. Fixed result slots bound active work. The sequential-looking fiber API is convenient, but its connection model has a larger memory budget. I will keep the scheduling idea without requiring a stack/fiber for every idle client.

## Two concrete parser findings in Zig #45

### Empty Authorization loses the distinction between absent and invalid

At src/http.zig:81, an empty Authorization value becomes null. At src/api.zig:98–105, null is accepted as anonymous when authentication is optional. For example, GET /api/articles with an explicitly empty Authorization header therefore follows the anonymous path according to the inspected code, whereas SPEC.md requires an invalid present header to return 401 on optional-auth endpoints.

I ran a native ReleaseSafe check against the exact parser source using an HTTP/1.1 request with Host and an empty Authorization field. The parser accepted the request and returned auth == null. The endpoint consequence follows from source inspection; I did not run the Linux API end to end. This is an API edge case, not a claim of privileged authentication bypass.

My fix by design: preserve header presence separately from its value; validate a present empty value as invalid on optional/required-auth routes. Tags retain their documented no-auth exception.

### Connection token order can override close

At src/http.zig:94–99, tokens are processed in order and both close and keep-alive overwrite the same flag. A request containing Connection: close, keep-alive returns keep_alive == true. Reversing the order changes the result.

A second native ReleaseSafe check reproduced this parser result. RFC 9112 sections 9.3 and 9.6 require close to prevent connection persistence; a later token should not undo it. This is a connection-management defect, not evidence of a benchmark failure or a demonstrated request-smuggling exploit.

My fix by design: close wins regardless of token order or repeated header lines. Add request-framing and connection-policy checks alongside API conformance. A mature parser does not remove the need for correct policy around its parsed fields.

The two observation checks passed because they asserted the problematic behaviours actually present in the parser. They were not tests asserting standards compliance. The harness lives under the local research area and does not change the competitor or my implementation.

## Confirmed tradeoffs and risks, not reproduced bugs

| Observation | Evidence | What I will do differently |
|---|---|---|
| C# pending-read and bcrypt containers are not capacity-bounded at those enqueue sites | Batch.cs:69 and CpuWork.cs:13; Enqueue/Run add work without a container capacity check | Set request-count, byte and age limits before admitting queued work; do not infer unlimited whole-process memory from these containers alone |
| Fixed bcrypt collection waits add endpoint latency | Rust password_batch.rs:23–29 defaults to 160 ms; Zig #45 main.zig:70 defaults to 250 ms; C# configuration defaults to 300 ms | Begin without an intentional wait; measure a bounded, load-sensitive collection policy if interleaving proves worthwhile |
| Zig #45 can keep stale bcrypt jobs for 15 s | bcpool.zig stale_ns and worker stale check; the challenge generator times out requests at 10 s | Carry request deadlines and avoid starting known-useless queued work; do not cancel or replay a write with an uncertain commit outcome |
| Zig #53 reserves sizeable slot storage | 2,048 slots per shard, 256 KiB each, configured in main.zig/shard.zig | Budget active memory in bytes and allocate scarce large storage only where needed |
| Zig #53 also has a per-connection fiber | shard runtime setup and dependency model; its README reports about 28 KiB per idle client and about 4 GB at 128k clients | Use compact idle records and buffers for active work; these reported RSS figures were not reproduced by me |
| Deep pipelines can trap latency behind expensive work | C default depth 16 and request-FIFO pipeline; Rust per-connection actor batching | Start shallow, let free backend capacity drive read dispatch, and measure query families separately |

For Zig #53, the slot calculation is **512 MiB of reserved address space per shard**, about 1 GiB across two shards. Its allocation intentionally leaves pages untouched, so this is not proof of 1 GiB resident memory. Nor is it the same allocation as the reported per-connection fiber cost.

Long bcrypt windows can improve this particular aggregate score because logins are rare and interleaving can save CPU. Removing the wait is not automatically faster overall. My aim is to find the CPU/latency tradeoff with explicit bounds, not impose a preference without measurement. Likewise, global dispatcher locking in C# is a possible contention point; I have not measured it as a bottleneck.

## Local validation performed

- Two focused observations on Zig #45's unmodified HTTP parser: 2/2 passed, built and run natively with Zig 0.17.0 ReleaseSafe.
- Existing tests in Zig #53 src/jwt.zig: 2/2 passed natively in ReleaseSafe. This validates only those tests, not its server or complete authentication policy.
- No PostgreSQL environment installed, no full competitor server started, no new capacity benchmark and no 197-check conformance claim.

All generated research files and caches were directed into the project workspace. No dependency or system service was installed for this review.

## Stack decision after reading the code

I keep the direct Zig reactor, picohttpparser and non-blocking libpq recommendation. The reactor uses kqueue on macOS and epoll on Linux; libpq supplies protocol/authentication handling, and the Zig scheduler controls admission, query-family dispatch, batching and response ownership. Standard-library JSON and cryptography remain the first correctness path. Binary PostgreSQL results and tighter serializers are measured follow-up work.

The concrete initial performance experiment is **capacity-driven, bounded read batching versus the same server's unbatched prepared path**. Only dispatch work already waiting, preserve viewer-specific fields, and avoid stacking large batches on a saturated connection. Compare small batch caps by family before sharing distinct article/page enrichment. Group commit and bcrypt interleaving follow only after the read path is correct and measured.

Libpq may cost more allocation/copying than the custom wire clients used by the leaders. I have not established parity. It is selected to improve the chance of finishing a correct, testable contender, with an interface that can be replaced if profiling demonstrates a material limit. A custom driver is an evidence-triggered option, not a guaranteed prerequisite for first place.

## Sources

- [Leaderboard and fixed source revision](https://github.com/arjaythedev/multicore-server-challenge/tree/c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e).
- [Rust source](https://github.com/arjaythedev/multicore-server-challenge/tree/c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e/submissions/rust-tokio-Scooter1337/src), [C# source](https://github.com/arjaythedev/multicore-server-challenge/tree/c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e/submissions/csharp-sockets-jh-d/src), [C source](https://github.com/arjaythedev/multicore-server-challenge/tree/c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e/submissions/c-iouring-tigokraft/src), [COBOL source](https://github.com/arjaythedev/multicore-server-challenge/tree/c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e/submissions/cobol-gnucobol-benmandrew/src).
- [Zig #45 HTTP parser](https://github.com/harshitkhandelwal208/multicore-server-challenge/blob/ed2e521f6d367005b10682460e8003f1cfdcbdd6/submissions/zig-iouring-harshitkhandelwal208/src/http.zig#L76), [authentication](https://github.com/harshitkhandelwal208/multicore-server-challenge/blob/ed2e521f6d367005b10682460e8003f1cfdcbdd6/submissions/zig-iouring-harshitkhandelwal208/src/api.zig#L98).
- [Zig #53 shard storage](https://github.com/y2kbugger/multicore-server-challenge/blob/fdc37b33ded89d19e76bb7942de7de433a260c73/submissions/zig-fourneau-y2kbugger/src/shard.zig#L160), [configuration](https://github.com/y2kbugger/multicore-server-challenge/blob/fdc37b33ded89d19e76bb7942de7de433a260c73/submissions/zig-fourneau-y2kbugger/src/main.zig#L50).
- [RFC 9112 persistence](https://www.rfc-editor.org/rfc/rfc9112.html#section-9.3) and [connection tear-down](https://www.rfc-editor.org/rfc/rfc9112.html#section-9.6).

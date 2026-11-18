# Architecture

I use independent readiness-driven Zig reactors for HTTP, each with its own PostgreSQL owners, listener, client slots, queues and event loop. Bcrypt runs in a separate bounded worker pool. The same application uses kqueue on macOS and epoll on Linux; no thread is created per client. All API routes pass the unchanged conformance suite on both development and full seeds on the native Mac. The clean Ubuntu 24.04 x86_64 installation and the unchanged 197-step suite also pass with PostgreSQL 18.

## Ownership and request flow

The request path is receive/frame HTTP → validate input and authentication → enqueue a typed operation → dispatch SQL → consume and validate all results → confirm commit where required → serialize/send → release storage.

A database owner retains its operation through every query, commit and rollback. Only the reactor manipulates its PGconn. libpq connection establishment, output flushing and input consumption advance from socket readiness. Results and parameter storage have explicit lifetimes; borrowed PGresult strings cannot survive its release. A disconnected recipient does not release an operation still owned by PostgreSQL or bcrypt. Generation-tagged HTTP and database slots reject stale completions and readiness events.

The checked build-time database range is 1–95 in total. The optional dedicated write subset leaves at least one read and one write owner per reactor. Separate intrusive FIFOs prevent queued writes from blocking read dispatch; each free owner takes the oldest eligible task. An owner retains the complete operation, including commit and response reads. Connection counts are totals, split across reactors. There is no speculative retry or SQL pipeline.

## Connection scheduling and resource bounds

The configured HTTP ceiling is 196,608. Startup reads the process descriptor limits, reserves database/control descriptors and raises only its own soft limit when the existing hard limit permits it. On macOS it also reads the existing kernel ceiling without changing it. The effective limit on my Mac is 10,204 with four database owners. A separate Linux test has retained 150,000 sockets and checked an HTTP response on each; this does not establish workload capacity.

A linked free list allocates/releases slots in constant time. Independent intrusive read/write FIFOs add and remove queued requests in constant time. An indexed min-heap holds one deadline per live socket, with logarithmic updates/cancellation. The loop no longer scans all clients on every turn. Deadline expiry closes at most 512 sockets per turn; accepts are limited to 64 per turn. Descriptor exhaustion pauses listener admission for 250 ms while existing work progresses.

Idle connections retain a compact record and release their input allocation. The admitted task ceiling is a checked build control (2,048–32,768 is the useful experiment range); aggregate allocated input and framed-output budgets remain 32 MiB and 64 MiB. These totals are split across reactors rather than multiplied by their number. These aggregate buffer limits do not include kernel socket memory, task arenas, libpq or thread stacks. Per-request limits remain 16 KiB headers, 64 KiB bodies, 84 KiB buffered input and 4 MiB article retained fields/serialized output. Individual violations return an error or close the socket; overload remains counted in benchmarks.

Idle sockets expire after 70 seconds. The nine-second partial-request deadline starts at the first byte and is not renewed by trickled bytes. Queued/active work retains a deadline; sending a response has its own nine-second bound. Each database session has an eight-second statement timeout and reconnect setup has a twenty-second deadline.

Picohttpparser parses headers; my layer owns framing, Content-Length/Transfer-Encoding policy and ordered keep-alive responses. Ambiguous framing and chunked bodies are rejected and the connection closed. One request executes per HTTP connection while already received pipelined bytes remain ordered. Responses first attempt an immediate non-blocking write; partial output uses write readiness. Immediate pipelined responses advance iteratively, avoiding one recursive frame per request. Paused Linux sockets retain an EPOLLONESHOT registration, which is rearmed on resumption; a pending HUP/ERR cannot spin the event loop.

## SQL and read groups

Forty-seven fixed queries are prepared separately on each connection, including eleven mutation/lookup statements and an optional compact comment representation and three grouped favorite statements. The mutation state machine retains one parameterized command at a time; BEGIN, COMMIT and ROLLBACK keep their existing protocol and transaction boundaries. Setup fully drains each session command and preparation before admitting the connection. Replacements rebuild this state. Session-only plan/JIT choices and their comparison controls are described in PERFORMANCE.md; no role, database or server-wide tuning is applied.

Article lists select page IDs in descending order before enrichment, then issue a separate capped count. This retains the reference's page-then-count statement snapshots. Counts stop at 1,000 without hiding accessible pages beyond that offset. Filter precedence, nullable fields, viewer flags and UTC millisecond formatting are explicit. Every request reads current data from PostgreSQL.

Comment lists use one prepared statement: article lookup plus a lateral newest-100 comment/author query. A leading article ID distinguishes a missing article (404) from an existing article without comments (200 with an empty list). The outer order explicitly preserves creation time and ID descending. Compared with the reference's separate lookup/read, this uses one statement snapshot; a simultaneous article deletion may therefore be observed differently. Ordinary API responses match the reference on both seeds.

When the oldest eligible queued task is a tags read, dispatch gathers compatible tasks from a bounded lookahead. The read-group capacity is a checked build control, 2–512 requests; lookahead is at most four times that capacity, with a minimum of 64 candidates. It executes one tags query for that closed group. Each recipient keeps its own connection, framing, deadline and lifetime. No collection delay is added, and no request can join after dispatch. Results are released when the group completes; a later request always executes a new query. The unbatched control remains available with `-Dtag-batch=false`.

Single-article reads use the same closed-group dispatch rule and a maximum of 256 KiB of input parameters. Two typed PostgreSQL arrays carry each request's viewer and slug. A materialized query enriches each distinct article once and computes favourite/follow flags per request, returning an ordinal for exact response ownership. Missing slugs remain individual 404s. The ordinary single-read query is used when no compatible request is already queued. Array values escape quotes/backslashes and reject NUL. Each recipient retains at most 4 MiB of article fields; the aggregate HTTP output budget still applies. `-Darticle-batch=false` retains the comparison control.

Comment groups capture viewer/slug arrays, materialize the requested articles and newest-100 comments once per distinct slug, and compute follow flags for each distinct viewer. An ordinal and nullable article ID distinguish missing articles from empty comment lists. Ordering uses the original timestamp before formatting, retaining sub-millisecond order.

List groups carry viewer, limit, offset and filter arrays. All five families (global, tag, author, favorited and feed) share page metadata only within this closed group, keeping viewer flags distinct. A second statement reads capped counts after the page statement is fully drained. The owner stays assigned through both phases, including when the primary HTTP recipient disconnects. An injected external insert between these statements changes the count without changing the captured page; subsequent requests read the new page.

A group's reads share one PostgreSQL snapshot. Success/error is delivered to all captured recipients after the command is fully drained. Followers are finished before the primary task's response arena is released, including when the primary disconnects. A connection failure returns 503 to the group without replay. No result or rendered-response cache survives a group. Tests count actual wire executions, check post-dispatch freshness and inject SQL failure.

## Writes and durable responses

Article creation keeps its article, distinct tags and links inside an explicit transaction, confirms COMMIT, then reads the committed article by ID. New/concurrent tag upserts use a subsequent statement to avoid the data-modifying-CTE snapshot trap. Ownership predicates belong in update/delete statements. Favourites and follows are idempotent; deletion returns a bodyless 204.

Ordinary errors are drained and explicit transactions roll back before reuse. A failed rollback or uncertain boundary retires the owner. A lost COMMIT acknowledgement may mean the write succeeded: the server returns 503 and never replays it. Responses are not sent speculatively, and durable commit settings are unchanged. Optional favorite groups use one implicit transaction, wait for its confirmed completion and then read fresh article state. Only a confirmed rollback permits independent fallback; an uncertain outcome is never replayed.

## Authentication

HS256 signature, algorithm, subject and expiry are checked on every applicable request. Optional auth distinguishes an absent token from a present invalid token. Bcrypt verifies the current stored hash on every login; new hashes use cost 10 and fresh random salts. There is no identity, password or verification cache. The worker budget is selected by measurement; at most 64 jobs, including running/completed jobs awaiting collection, are outstanding. Saturation returns 503 and is retained in load results.

The bcrypt adapter normalizes only a corrected Go `$2a$10$` marker to Zig's `$2b$10$` rendering before the full bcrypt calculation. Registration rejects passwords above 72 bytes, while verification follows Go's truncation behaviour. Password buffers are cleared after work.

The worker backend interleaves two to four independent hashes to overlap dependent Blowfish lookups on one CPU. Each lane retains its own password, salt, full cost-ten rounds and result. Singletons use the standard-library path. `bcrypt-lanes` selects the maximum width; `bcrypt-gather-ms` gives one collector per pool a bounded collection window. Other workers release the mutex while waiting. Collection stops at the fixed deadline, full width or shutdown. Results stay attached to their original job, including malformed stored hashes and disconnected clients. Linux defaults share two workers across reactors, calibrate complete public dummy calculations at startup and permit up to 100 ms collection. macOS retains scalar workers without a collection delay. Five- and six-lane calculations remain diagnostic only because they were slower on the measured CPU.

## Recovery and portability

Each failed owner reconnects independently with 250 ms–5 s exponential backoff. Healthy owners continue. Unsent work fails promptly if no usable owner for its read/write class remains. The numeric loopback benchmark address avoids potentially blocking DNS inside libpq. See RECOVERY.md for the fault matrix and uncertain-commit proof.

Linux validation checks the source installer, linked executable, actual progress on every reactor, partial writes, pipelining, SQL errors, reconnects and conformance. The optional Linux socket test checks 150,000 live connections separately from workload capacity; the organiser's benchmark remains required for a score. The source-built libpq and compiler installer target Ubuntu only and are never run on my Mac.

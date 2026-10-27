# Architecture

I use one readiness-driven Zig reactor for HTTP and four independently progressing PostgreSQL owners. Bcrypt runs in a separate bounded worker pool. The same application uses kqueue on macOS and epoll on Linux; no thread is created per client. All API routes pass the unchanged conformance suite on both development and full seeds on the native Mac. The clean Ubuntu 24.04 x86_64 installation and the unchanged 197-step suite also pass with PostgreSQL 18.

## Ownership and request flow

The request path is receive/frame HTTP → validate input and authentication → enqueue a typed operation → dispatch SQL → consume and validate all results → confirm commit where required → serialize/send → release storage.

A database owner retains its operation through every query, commit and rollback. Only the reactor manipulates its PGconn. libpq connection establishment, output flushing and input consumption advance from socket readiness. Results and parameter storage have explicit lifetimes; borrowed PGresult strings cannot survive its release. A disconnected recipient does not release an operation still owned by PostgreSQL or bcrypt. Generation-tagged HTTP and database slots reject stale completions and readiness events.

The checked build-time database range is 1–95; four is the local measured default. More connections can take CPU away from PostgreSQL on the shared benchmark host. There is no separate write pool, pipeline or speculative retry.

## Connection scheduling and resource bounds

The configured HTTP ceiling is 131,072. Startup reads the process descriptor limits, reserves database/control descriptors and raises only its own soft limit when the existing hard limit permits it. On macOS it also reads the existing kernel ceiling without changing it. The effective limit on my Mac is 10,204 with four database owners. This is not evidence of 100,000 real connections on Linux.

A linked free list allocates/releases slots in constant time. An intrusive FIFO adds/removes queued requests in constant time. An indexed min-heap holds one deadline per live socket, with logarithmic updates/cancellation. The loop no longer scans all clients on every turn. Deadline expiry closes at most 512 sockets per turn; accepts are limited to 64 per turn. Descriptor exhaustion pauses listener admission for 250 ms while existing work progresses.

Idle connections retain a compact record and release their input allocation. Limits are 2,048 admitted request tasks, 32 MiB aggregate allocated input buffers, and 64 MiB aggregate framed responses. These aggregate buffer limits do not include kernel socket memory, task arenas, libpq or thread stacks. Per-request limits remain 16 KiB headers, 64 KiB bodies, 84 KiB buffered input and 4 MiB article retained fields/serialized output. Individual violations return an error or close the socket; overload remains counted in benchmarks.

Idle sockets expire after 70 seconds. The nine-second partial-request deadline starts at the first byte and is not renewed by trickled bytes. Queued/active work retains a deadline; sending a response has its own nine-second bound. Each database session has an eight-second statement timeout and reconnect setup has a twenty-second deadline.

Picohttpparser parses headers; my layer owns framing, Content-Length/Transfer-Encoding policy and ordered keep-alive responses. Ambiguous framing and chunked bodies are rejected and the connection closed. One request executes per HTTP connection while already received pipelined bytes remain ordered. Slow output uses write readiness.

## SQL and read groups

Twenty-one fixed queries are prepared separately on each connection. The later mutation state machine retains parameterized single-query execution. Setup fully drains each session command and preparation before admitting the connection. Replacements rebuild this state. Session-only plan/JIT choices and their comparison controls are described in PERFORMANCE.md; no role, database or server-wide tuning is applied.

Article lists select page IDs in descending order before enrichment, then issue a separate capped count. This retains the reference's page-then-count statement snapshots. Counts stop at 1,000 without hiding accessible pages beyond that offset. Filter precedence, nullable fields, viewer flags and UTC millisecond formatting are explicit. Every request reads current data from PostgreSQL.

Comment lists use one prepared statement: article lookup plus a lateral newest-100 comment/author query. A leading article ID distinguishes a missing article (404) from an existing article without comments (200 with an empty list). The outer order explicitly preserves creation time and ID descending. Compared with the reference's separate lookup/read, this uses one statement snapshot; a simultaneous article deletion may therefore be observed differently. Ordinary API responses match the reference on both seeds.

When the oldest queued task is a tags read, dispatch can gather up to 31 compatible reads from at most the next 64 already queued tasks. It executes one tags query for that closed group. Each recipient keeps its own connection, framing, deadline and lifetime. No collection delay is added, and no request can join after dispatch. Results are released when the group completes; a later request always executes a new query. The unbatched control remains available with `-Dtag-batch=false`.

Single-article reads can use the same closed-group dispatch rule with up to 32 requests and 256 KiB of input parameters. Two typed PostgreSQL arrays carry each request's viewer and slug. A materialized query enriches each distinct article once and computes favourite/follow flags per request, returning an ordinal for exact response ownership. Missing slugs remain individual 404s. The ordinary single-read query is used when no compatible request is already queued. Array values escape quotes/backslashes and reject NUL. Each recipient retains at most 4 MiB of article fields; the aggregate HTTP output budget still applies. `-Darticle-batch=false` retains the comparison control.

A group's reads share one PostgreSQL snapshot. Success/error is delivered to all captured recipients after the command is fully drained. Followers are finished before the primary task's response arena is released, including when the primary disconnects. A connection failure returns 503 to the group without replay. No result or rendered-response cache survives a group. Tests count actual wire executions, check post-dispatch freshness and inject SQL failure.

## Writes and durable responses

Article creation keeps its article, distinct tags and links inside an explicit transaction, confirms COMMIT, then reads the committed article by ID. New/concurrent tag upserts use a subsequent statement to avoid the data-modifying-CTE snapshot trap. Ownership predicates belong in update/delete statements. Favourites and follows are idempotent; deletion returns a bodyless 204.

Ordinary errors are drained and explicit transactions roll back before reuse. A failed rollback or uncertain boundary retires the owner. A lost COMMIT acknowledgement may mean the write succeeded: the server returns 503 and never replays it. Responses are not sent speculatively, and durable commit settings are unchanged. Group commit was not selected in this round; the transaction path retains its existing failure guarantees.

## Authentication

HS256 signature, algorithm, subject and expiry are checked on every applicable request. Optional auth distinguishes an absent token from a present invalid token. Bcrypt verifies the current stored hash on every login; new hashes use cost 10 and fresh random salts. There is no identity, password or verification cache. The worker budget is selected by measurement; at most 64 jobs, including running/completed jobs awaiting collection, are outstanding. Saturation returns 503 and is retained in load results.

The bcrypt adapter normalizes only a corrected Go `$2a$10$` marker to Zig's `$2b$10$` rendering before the full bcrypt calculation. Registration rejects passwords above 72 bytes, while verification follows Go's truncation behaviour. Password buffers are cleared after work.

## Recovery and portability

Each failed owner reconnects independently with 250 ms–5 s exponential backoff. Healthy owners continue. Unsent work fails promptly if no usable database connection remains. The numeric loopback benchmark address avoids potentially blocking DNS inside libpq. See RECOVERY.md for the fault matrix and uncertain-commit proof.

The clean Ubuntu CI run validates the installer, linked Linux executable, epoll request progress and all official conformance steps. It does not establish 100,000 live Linux connections or official capacity; the organiser's benchmark remains required. The source-built libpq and compiler installer target Ubuntu only and are never run on my Mac.

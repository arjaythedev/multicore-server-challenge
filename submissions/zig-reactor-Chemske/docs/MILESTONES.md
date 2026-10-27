# Implementation checkpoints

## Milestone 1: native bring-up

Date: 2026-10-24. This checkpoint implements only the tags route and the local test environment.

- PostgreSQL/libpq 18.6 built from official checked source into the workspace.
- Dedicated SCRAM-authenticated, loopback-only cluster; no automatic service.
- Development seed verified against upstream row counts and fingerprints: 100k users, 10k articles, 200 tags; approximately 95 MB seed database.
- Unmodified Go reference: 197 steps, 197 passed, zero failed on the native cluster.
- Zig ReleaseSafe build and protocol unit tests passed.
- Focused integration: 11 scenarios passed, including 64 requests over 16 simultaneous keep-alive connections, a split request, pipelined requests, close-token dominance, conflicting framing rejection, fresh data after mutation, SQL error/reuse and backend loss returning 503.
- Linux x86_64 object-only semantic compilation passed. This is not a linked or executed Linux validation.
- Bash helper syntax and Zsh environment-path checks passed.

The first implementation has one owner/event loop, one non-blocking database connection, generation-tagged clients and no data cache. HTTP inputs are limited to 16 KiB headers/32 KiB buffered data. Large tag responses are bounded at serialization, client slots are capped at 256, idle clients at 70 seconds, and active work has deadlines. No capacity score is implied by these correctness checks.

## Milestone 2: execution plan

Implement the four users/auth routes before profiles or articles. I keep the existing single-owner database path while adding parameterized statements and per-request storage. A response to a write waits until libpq has drained the statement through its completion boundary.

Two bcrypt workers share a maximum of 16 outstanding jobs, including running jobs and uncollected completions. A non-blocking pipe wakes the reactor. Workers only touch their job's fixed password/hash buffers; they never own sockets, PGconn objects or request allocators. Generation-tagged recipients prevent a late completion from reaching a reused client slot. Saturation returns 503 instead of growing memory without a bound.

HTTP framing gains a 64 KiB body limit and preserves pipelined bytes. JSON input is copied into request-owned storage before the receive buffer moves. HS256 verification validates the signature, algorithm, decimal string subject and integer expiry on every authenticated request. Registration and login issue the specified three claims; current-user responses preserve the presented token. No authentication or data cache is added.

The gate is: existing tags regressions, focused auth/concurrency/failure checks, and the unchanged upstream conformance transcript. The auth section must pass; failures in later, unimplemented endpoints remain visible. I will check Linux semantics without claiming a linked Linux run or an official performance result.

## Milestone 2: results

Date: 2026-10-24. Registration, login, current-user read and current-user update are implemented.

- ReleaseSafe build and six unit checks passed, including the unchanged Go seed's $2a$ bcrypt hash.
- All 50 users/auth steps in the unmodified upstream suite passed. The full run reports 137 steps, 61 passed, 76 failed and an abort in later unimplemented routes. It is not a full conformance pass.
- All 11 existing tags regression scenarios still pass, including 64 concurrent keep-alive requests and backend-loss handling.
- Thirteen auth scenarios passed: upstream contract; parameterized Unicode/quotes and signed claim checks; byte limits/NUL text; separate-session commit visibility; blocked-write acknowledgement; additional invalid tokens; current-hash verification; bcrypt cross-verification with the unmodified Go reference; fragmented bodies and pipelining; bounded overload with tags progress; disconnected bcrypt clients and 64 concurrent reads; duplicate-write contention; SQL error/reuse.
- The observed 40-login overload run accepted 16 and returned 503 for 24. Both outcomes are counted. No capacity score is inferred.
- New hashes have cost 10 and fresh secure salts. Both directions of Go/Zig interoperability passed for 72-byte ASCII, 72-byte UTF-8 and embedded-NUL passwords. Long login inputs preserve Go's verification semantics; long new passwords are rejected.
- Linux x86_64 semantic/object-only compilation passed; no linked or executed Linux validation.

No new application, package manager installation or background service was added. Test databases and temporary servers are removed by the test scripts. Results and the unchanged suite's complete log/transcript stay in work/results/milestone2; selected evidence is copied to outputs.

## Milestone 3: execution plan

Implement profile reads, follow and unfollow. Profile reads allow anonymous access only when the Authorization header is absent; a present invalid header returns 401. Follow/unfollow require a verified token. The viewer is a parameter on every query, never connection state or cached profile data.

Dynamic usernames are matched as one encoded path segment, decoded exactly once, validated and copied before the HTTP input buffer moves. This preserves literal plus signs, Unicode and encoded separators without turning a username into a different route.

Each follow/unfollow uses one parameterized SQL statement containing the target lookup and the mutation in its own implicit transaction. Repeated operations return the requested following state even if no row changes. The response uses the target snapshot and explicit operation result; it does not reread the follows table inside the data-modifying CTE's old snapshot. No success is sent until libpq reaches the completed transaction boundary. This follows [PostgreSQL 18's documented CTE semantics](https://www.postgresql.org/docs/18/queries-with.html#QUERIES-WITH-MODIFYING).

The gate is the unchanged upstream users/auth and profiles sections, targeted viewer isolation/idempotence/commit/failure tests, a comparison with the unchanged Go reference, and the earlier milestone regressions. Feed and article routes remain the next checkpoint. No new installed software is needed.

## Milestone 3: results

Date: 2026-10-24. Profile reads, follow and unfollow are implemented. The request-lifetime module is now named requests.zig because it serves both users and profiles; SQL and username-path policy for profiles live in profiles.zig.

- ReleaseSafe build and eight unit checks passed, including route boundaries and single-pass URL decoding.
- All 50 users/auth and all 16 profile steps reached before comment creation pass in the unchanged suite. The full Zig run reports 137 steps, 73 passed and 64 failed, then aborts at unimplemented comment creation. Two profile calls in the later comments section remain unreached. This is not a full conformance pass.
- A fresh full run of the unchanged Go reference passed 197/197 steps. All 16 reached normalized profile responses match it exactly.
- Fifteen profile scenarios passed: upstream contract; normalized comparison; an independent Go/Zig follow/unfollow trace; encoded names; strict auth; committed row counts; self-follow; fresh reads after mutation/rename; fragmented/pipelined requests with changing identities; invalid paths; 64 contending requests; blocked follow and unfollow; deferred commit failure; SQL errors/reuse; client disconnect during a blocked write.
- The deferred-failure test inserts a relation, rejects the transaction at its commit boundary, requires 503, verifies that the row rolled back, and confirms connection reuse. Its temporary trigger exists only in the disposable test clone. No official schema or seed file changes are involved.
- The 11 tags and 13 auth regression scenarios still pass. Linux x86_64 semantic/object-only compilation passed; no linked or executed Linux validation or performance score is claimed.

The specification says a present invalid Authorization header is 401 even on optional-auth routes. The Go reference's Header.Get check treats an empty value as absent. I preserve header presence and return 401; a focused regression records this deliberate difference. Self-follow remains allowed, matching the fixed schema and the reference. Repeated operations are idempotent.

No software installation or automatic service was added. Both test clones and all temporary servers are removed. Results live under work/results/milestone3, with selected evidence copied to outputs.

## Milestone 4: execution plan

Implement article lists, the personal feed and single-article reads. Lists select IDs in descending order before enriching the selected page. Tag, author and favourited filters use the first non-empty value in that priority order; duplicate query parameters use their first value. Pagination accepts digit-only integers, with limit 1–100 and a non-negative signed-64-bit offset.

Keep the reference's page-then-capped-count execution order, with a separate statement snapshot for each stage. The HTTP request owns both results, and no partial response escapes if either stage fails. The same connection owner drains each query completely before starting the next stage. Empty pages still run the count. The feed keeps the reference's per-followed-author candidate selection but uses overflow-safe arithmetic for valid large offsets.

Zig serializes the API objects, validates PostgreSQL text-array results and omits body only in list objects. UTC timestamp formatting is explicit in SQL and truncates to milliseconds. Viewer-dependent favourites/following are evaluated on every request. No response, count or relationship cache is added.

The gate is the unchanged read-only portion of the upstream script before favourite writes, normalized comparison with the Go reference, targeted filter/pagination/serialization/freshness/failure checks and all earlier regressions. Later reads that depend on unimplemented writes remain visible failures. Source, test databases and caches stay in the existing workspace.

## Milestone 4: results

Date: 2026-10-24. Article lists, the personal feed and single-article reads are implemented. URL path decoding moved from profiles.zig to url.zig; the same module now owns query decoding/pagination. Article query families and DTO serialization live in articles.zig. Shared test lifecycle helpers were extracted from milestone 3 without removing its checks.

- ReleaseSafe build and eleven unit checks passed. Linux x86_64 semantic/object-only compilation passed; no linked Linux runtime is claimed.
- All 119 upstream steps before favourite writes passed, including all 51 article/feed read checks. Every normalized response in that prefix matches the unchanged Go reference. Its fresh full run passed 197/197.
- The full Zig run reports 141 steps, 123 passed and 18 failed, then aborts at missing comment creation. Favourite/comment writes and reads depending on those writes remain incomplete. Two later profile calls remain unreached. This is not a full conformance pass.
- Fifteen article/feed scenarios passed: upstream read gate; normalized comparison; single-object escaping/arrays/UTC dates; ordering and compact lists; precedence and empty pages; duplicate/encoded query parameters; feed and viewer flags; auth; mutation freshness; fragmented/pipelined requests; 96 concurrent reads; all five count families above the cap and large offsets; count-stage failure; page-stage failure/reuse; slow readers and response bounds.
- Five query families retain articlesCount = 1000 even for pages after offset 1000. Valid offsets through signed-64-bit maximum produce empty pages without integer wraparound. A tested reference feed request at offset 2147483647 fails with 500 due to int32 casts; my query follows the allowed pagination range instead.
- A private row-level-security fault rejects only the second/count statement. Both a populated and an empty first page return 503 with no leaked partial list, then the connection works after fault removal. No schema file or shared database is changed by this check.
- Slow/disconnected readers of a 3 MiB article do not prevent tags from progressing. Escaped output beyond the 4 MiB response bound returns 503. This is a correctness/resource test, not a throughput measurement.
- The earlier 11 tags, 13 auth and 15 profile scenarios still pass, including the deferred-commit failure check.

No new tools or automatic services were installed. Temporary databases/servers are removed. Complete logs and normalized transcripts are under work/results/milestone4; selected evidence is copied to outputs. Optimisation, Linux runtime validation and an official score remain outstanding.

## Milestone 5: execution plan

Complete article writes, favourite writes and all comment routes. Validate authentication and request bodies before starting SQL. Ownership predicates belong in the mutation itself; status results distinguish missing targets (404) from another author's rows (403).

Article creation uses an explicit transaction: BEGIN, insert article, insert distinct tags, link tags, COMMIT, then read the committed article by ID. A fresh statement after tag upserts avoids the data-modifying-CTE snapshot trap for new or concurrently inserted tags. Failures drain completely, roll back and retain the original error. A failed rollback or an uncertain connection state retires the database connection. Writes are never automatically replayed after connection loss.

Other mutations use parameterized statements and committed follow-up reads where required. Comments list the newest 100 by timestamp and ID; creation returns author.following false, as specified. Deletes return a bodyless 204 with no Content-Length. Request-owned operation state must survive disconnects until its transaction is finished and drained.

The gate is the full unchanged 197-step suite, normalized comparison with the unchanged Go reference, focused rollback/commit/ownership/concurrency checks and the existing regressions. No performance or Linux-runtime claim is implied by the Mac correctness run.

## Milestone 5: results

Date: 2026-10-24. All API routes are implemented, including article writes, favourite writes and comments. operations.zig owns their query stages and transaction lifecycle; requests.zig validates and retains their parameters. The comment result decoder shares existing typed profile and timestamp conventions.

- ReleaseSafe build and twelve unit checks passed. Linux x86_64 semantic/object-only compilation passed; no linked Linux runtime has been run.
- The unchanged official test/run.sh runner passed 197/197 on a fresh development-seed clone.
- The focused harness and unchanged Go reference each passed 197/197. All 197 normalized transcript entries match exactly.
- Fifteen write scenarios passed: full suite; normalized comparison; committed articles/tags/links; validation and ownership; tag/link rollback; deferred commit failure; blocked transaction visibility; eight simultaneous Zig/Go creates sharing a new tag; 64 favourite writes; concurrent comment IDs/newest-100 ordering/self-follow semantics; scoped comment deletion; failed post-commit read; disconnect during creation; bodyless-204 pipelining/cascades; backend loss without write replay.
- Separate sessions confirm committed rows and idle transaction state. Failed tag/link/commit stages leave no partial article or newly introduced tags. A successful commit followed by a failed response query leaves exactly one article and returns 503 without replay.
- Earlier gates remain green: 11 tags scenarios, 13 auth scenarios, 15 profile scenarios and 15 article/feed scenarios. The profile gate now reaches and compares all 18 profile calls.

No new application, dependency or automatic service was installed. All disposable databases/servers were removed. The complete evidence is in work/results/milestone5, with selected deliverables in outputs. The test seed has 10k articles; full-seed, clean Linux installation/runtime, recovery improvements and capacity benchmarking remain outstanding. No leaderboard score is claimed.

## Optimisation 1: named prepared queries

Date: 2026-10-25. I rechecked the official rules and leaderboard at upstream `c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e`; they are unchanged. The leading official score remains 100,000 users. Prepared statements are explicitly permitted.

Nineteen fixed users/profile/tags/article-read queries are prepared once per connection during startup. PostgreSQL retains its default plan-selection heuristic. The article/comment operation state machine keeps its original parameterized execution, and all commit/drain boundaries remain intact. `-Dprepared-queries=false` retains an unprepared control.

- Three runs per build in A-B-B-A-B-A order, each on a fresh development-seed clone with the unchanged load generator: median 3,055.7 versus 4,523.6 requests/s (+48.0%). Median p95 is 35.615 versus 17.471 ms; median p99 is 48.287 versus 28.047 ms.
- All 687,440 measured requests succeed. No run reports a generator limit. These are thirty-second local windows with accelerated think/session times on the six-core, 8 GiB Mac; the generator shares the machine. They do not establish full-seed or official capacity.
- The prepared build passes twelve unit checks, all 197 unchanged upstream steps, exact normalized comparison with the Go reference, and all 11/13/15/15/15 focused scenario groups. The unprepared build also passes the complete write gate and 197-step comparison.
- Linux x86_64 object-only semantic compilation passes with the build options module. No linked Linux runtime or clean installer is claimed.
- The final default executable has the same SHA-256 as the measured candidate. Complete settings and limitations are in PERFORMANCE.md, with raw evidence under work/experiments/prepared-statements/comparison.

No tools, applications or services were installed. All benchmark/test clones and temporary servers were removed. The workspace footprint remains about 1.7 GiB under work; the dedicated cluster is approximately 437 MiB.

## Milestone 6: bounded concurrency and recovery

Date: 2026-10-25. One reactor now owns a fixed pool, with one active operation per connection and four connections as the measured local default. `-Ddb-connections=1` retains the serial control; build-time limits reject zero or more than 95 connections. The client state separates queued work from work already owned by a database slot.

Each failed slot retires its connection and active operation without replay. Independent replacement uses readiness-driven authentication and session/statement setup, a twenty-second setup deadline and 250 ms–5 s exponential retry backoff. Generation-tagged database registrations protect replacement sockets. Healthy owners continue serving; an entirely unavailable pool fails unsent work with 503. Each owned session sets an eight-second statement timeout, matching the existing application deadline without changing global PostgreSQL configuration.

- Twelve unit checks and all earlier 11/13/15/15/15 focused scenario groups pass with four owners. Every one of the 197 normalized responses matches the unchanged Go reference, and the unchanged official runner passes 197/197.
- Ten recovery/concurrency scenarios pass: setup completion; isolated backend replacement; stalled authentication with HTTP progress and bounded attempts; admission refusal with retry backoff; lost COMMIT acknowledgement without write replay; repeated replacement/concurrent clients; independent reads during a blocked write; timeout rollback; full restart of the dedicated project cluster; all 197 upstream steps after recovery.
- The wire proxy drops the connection after PostgreSQL reports COMMIT completion but before libpq receives it. The request returns 503, the article exists exactly once, and later replacement/new writes do not duplicate it. The proxy retains only protocol names/setup counts, never credentials or parameter values.
- Recovery is also checked with the one-owner control. The retained unprepared build passes the full write gate and 197-response comparison. Linux x86_64 semantic/object-only compilation passes; linked Linux runtime and clean installation remain outstanding.
- Nine fresh-clone load runs, three per setting: median 4,430.1 / 6,163.1 / 6,447.0 requests/s for one/two/four owners. Four improves the one-owner median by 45.5%; median p95 is 17.679 versus 2.073 ms and p99 is 25.999 versus 5.447 ms. All 1,549,517 measured requests succeed. Details and limitations are in PERFORMANCE.md; this is not official capacity or a full-seed measurement.

The original single-connection tests now wait for actual commit/idle state after a disconnected write instead of assuming a tags response on another owner is a barrier. Their rollback, ownership and visibility assertions remain. All new code, proxy fixtures, binaries and evidence stay in the existing workspace; no application, dependency or service was installed.

## Final optimisation round: execution and selection

Date: 2026-10-25. I replaced per-turn client scans with constant-time free/queue operations and an indexed deadline heap. The configurable ceiling is 131,072, reduced to existing process/kernel descriptor limits. Fixed partial-request deadlines, per-turn expiry/accept budgets and aggregate input/output limits keep idle-connection scaling bounded. Native checks cover 8,000 sockets and 4,000 replacements; a unit test covers 100,000 simulated scheduler slots.

The unchanged full seed was generated and every official row-count/content fingerprint verified. Zig and the unchanged Go reference each pass 197/197 on successive fresh full clones; all normalized responses match. Eleven read query families/phases were profiled with automatic and forced-generic plans before selecting session-only generic planning. Short queries also disable session JIT; global settings and durable commit remain unchanged.

Comments now use one prepared lookup/list statement with explicit newest-100 ordering and an empty-list/missing-article distinction. There are twenty named preparations. Queued tags reads form closed groups of at most 32, without a collection timer or later joins. A wire test confirms shared executions, a fresh query after the group and complete SQL-error delivery. The mutation state machine preserves its isolated transaction/rollback/no-replay behaviour.

Three full-seed runs per configuration compare automatic/unbatched ReleaseSafe, tuned ReleaseSafe and tuned ReleaseFast: medians 7,532.7 / 8,789.2 / 9,734.6 requests/s. These candidates have two bcrypt workers and all have password-queue rejections, retained in the report. The combined fastest median is 29.2% above that experiment's control, not a claim about the final worker setting or official capacity.

A separate three-run-per-setting comparison chooses four bcrypt workers. Two/four medians are 8,610.2 / 8,422.0 requests/s, with 726/36 errors respectively. Four performs more real password verifications and cuts failures by 95.0%; outstanding jobs remain bounded at sixteen. The default rebuild matches the measured four-worker executable. These comparisons share the Mac with PostgreSQL and the unchanged generator, with accelerated sessions, and remain separate from prior optimisation percentages.

The source-only Ubuntu installer pins/checks Zig and PostgreSQL source archives, builds only libpq, and leaves the provided server unchanged. It is never run on the Mac. Actual Ubuntu installation and runtime remain a final-review requirement; source/cross-link checks cannot replace that.

## Next checkpoint: final review

Review the final diff, rules and evidence; validate clean Ubuntu installation, epoll runtime and target descriptor limits through the challenge's Linux CI path. Preserve source-only submission scope and all no-cache/commit/auth guarantees. The official organiser capacity search, with separate generators and a five-minute full-seed hold, determines ranking. No local result is an official score, and no PR is opened during this optimisation round.

Final native regression: fifteen unit checks, all 11/13/15/15/15 focused scenario groups, tags-group execution/freshness/error proof, 8,000 live sockets with 4,000 replacements, and ten recovery scenarios including a dedicated-cluster restart pass. The unchanged official runner also passes 197/197 with `TEMPLATE=conduit_seed`. The default native executable matches the measured four-worker fingerprint. A separate cross-link produces an x86_64 Linux ELF server and source-built libpq without running Linux; its client has TLS disabled, so it is a link/semantic proof rather than validation of the Ubuntu OpenSSL installer.

The selected build completes a 300-second full-seed local hold after a 60-second ramp: 2,568,539 measured requests, 8,561.8 requests/s, p95 61.631 ms, p99 96.063 ms and 403 errors (0.01569%). All failures remain counted. This uses 512 accelerated users and a co-located generator on the Mac, not an official capacity search.


The initial long hold exposed a password admission issue hidden by the aggregate error rate: 4.7% of logins were rejected. A separate two-run-per-setting A-B-B-A comparison increases the bounded outstanding-job limit from sixteen to sixty-four, retaining four workers and full cost-10 verification. Errors are 51 versus 16 with a 1.3% lower throughput median; the larger queue is selected for burst headroom. The auth overload regression now uses 160 simultaneous requests, and all auth/write/reference checks still pass.

The selected 64-job executable passes another five-minute full-seed stress hold: 2,817,230 measured requests, 9,390.8 requests/s, p95 52.351 ms, p99 78.079 ms, 12 errors (0.000426%). Sequential long holds do not isolate throughput gains. No official user count is inferred.

A separate normal-clock full-seed hold now passes for 8,000 actual Mac virtual users: 636,920 requests over 300 seconds, 2,123.1 requests/s, p95 1.251 ms, p99 3.659 ms, zero errors. This is a measured local lower bound, not a searched ceiling. The final accelerated throughput corresponds to approximately 35,386 users' normal request traffic at that observed rate; the mixed authentication pressure and untested socket population prohibit treating it as a score. Optional Ubuntu/Oracle validation and a calibrated reference-comparison method are in BENCHMARKING.md.

Final selected-build checks also repeat the fifteen Debug unit tests, grouped-tag proof, all ten recovery cases including cluster restart, and the unchanged official runner on the full seed. The selected source cross-links again to x86_64 Linux after the queue-size change. Native and cross-linked fingerprints remain distinct; no Linux execution is claimed.

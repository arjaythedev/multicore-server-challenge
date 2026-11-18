# Scaling beyond the first official result

## What failed in version 1

The [first official run](https://github.com/arjaythedev/multicore-server-challenge/pull/73) at `a026224` held 20,000 users for five minutes: 5,241 requests/s, p50 1.2 ms, p95 318 ms, p99 453 ms and 0.15% errors. Above that level, errors were predominantly admission 503s, with total target CPU still at 44%. The four-connection pool and 2,048-task ceiling could leave work waiting while the box had spare CPU. Raising a limit alone would only turn rejection into a longer queue.

I changed the ownership and SQL paths, then compared actual Linux binaries rather than extrapolating from the Mac.

## Changes

- Independent reactors own their listeners, client slots, queues, database sessions and bcrypt jobs. Linux distributes connections with `SO_REUSEPORT`. No reactor is restarted after failure.
- Read and write queues have separate database owners. A transaction waiting on a lock or durable commit cannot occupy every read connection. Counts stay part of their original read operation.
- Tags, article details, comments and all five list families group compatible requests that are already queued. There is no collection delay. Nothing joins a dispatched group, and no returned data survives it.
- Page metadata and capped counts are computed once per distinct filter/window within the group, while favourite/follow flags remain specific to each viewer. Pages and counts remain separate statements in that order.
- Responses try a non-blocking send immediately. Partial writes resume on readiness; pipelined immediate responses advance iteratively. Linux pauses keep an `EPOLLONESHOT` registration rather than removing and adding a descriptor around each query.
- Typed JWT claims avoid generic object maps while retaining signature, algorithm, subject, expiry and claim-type checks on every request. Bcrypt still verifies the stored hash at cost 10 on every login.
- Per-reactor logs distinguish capacity rejection, password admission and database failures. The comparison harness records each reactor thread's CPU and PostgreSQL wait classes without collecting application SQL or parameter values.

Resource limits remain explicit. Connection counts and task/buffer budgets are totals split across reactors; adding a reactor does not multiply them. No data caches, schema changes, server-wide PostgreSQL settings, asynchronous commits or uncertain-write replay are introduced.

## First Linux diagnostic: more concurrency alone

[Run 40684259256](https://github.com/Chemske/multicore-server-challenge/actions/runs/40684259256) compared the original binary with the earlier scaling revision through `4fdf976`, before grouped pages and dedicated writers. It used Ubuntu 24.04 x86_64, PostgreSQL 18, the unchanged full seed and published database settings in a disposable CI service. Application, database and generator shared a four-vCPU, 16-GiB runner. This is a relative comparison, not the official eight-vCPU box with an external generator.

Each variant passed all 197 unchanged full-seed conformance steps. The repeated order was A-B-C-D-D-C-B-A, 20,000 normal-clock users, 15-second ramp, 30-second measurement and three-second tail. Medians of the two per-run values:

| Variant | Reactors / DB owners / admitted tasks | Requests/s, including errors | p95 ms | p99 ms | Errors |
|---|---|---:|---:|---:|---:|
| A: official version 1 | 1 / 4 / 2,048 | 5,210 | 84 | 2,993 | 11.36% |
| B: early scaling revision | 1 / 4 / 2,048 | 5,213 | 128 | 2,608 | 10.01% |
| C: early scaling revision | 2 / 8 / 8,192 | 4,989 | 1,952 | 3,202 | 0.83% |
| D: early scaling revision | 4 / 16 / 8,192 | 5,110 | 1,163 | 1,892 | 0% |

Every run reported `lg_limited=false`; that does not make the shared runner equivalent to the official topology. B reached exactly its admission ceiling and its 503s were capacity rejections. D eliminated those rejections but still failed the latency limits. This is why I added page groups and read/write isolation instead of declaring the larger queue a success. Reactor CPU samples also did not show a saturated event-loop core on this runner, so these results alone do not prove a single-reactor CPU bottleneck.

## Correctness and reproducibility

Twenty-two Zig unit checks cover framing, claims, typed arrays, queue unlink/reuse, 100,000 simulated scheduler slots and independent bcrypt lanes. Focused integration tests compare every grouped page family against sequential results, mix authenticated viewers and missing resources, retain sub-millisecond comment order, inject SQL errors, and verify fresh reads after a group completes.

A count-boundary test pauses the second SQL statement, inserts a new article externally, and proves that the page remains the captured page while the later count sees the insert. Dedicated-writer tests block every writer, queue more writes, verify fresh reads still progress, then check every committed write. Recovery tests retain the lost-COMMIT-acknowledgement case without replay.

`tests/reactor.py --reactors N` requires every Linux reactor to serve real requests; an existing listener is insufficient. It also checks 384 concurrent reads, 2,048 pipelined immediate errors and partial output. Darwin's `SO_REUSEPORT` does not balance these listeners like Linux, so native Mac validation uses one reactor.

`tests/linux_connections.py` checks 150,000 retained sockets and an HTTP response on each, followed by database reads on reused sockets. It uses several loopback source addresses to avoid the per-destination ephemeral-port ceiling. It does not claim 150,000 workload users. The test changes no kernel settings; the CI helper raises only its own descriptor limit to match the benchmark service.

Build-time controls live in `build.zig`: `reactors`, `db-connections`, `write-connections`, `max-tasks`, `max-clients`, `read-batch-size`, `bcrypt-workers`, `bcrypt-jobs`, `bcrypt-lanes`, `bcrypt-gather-ms`, `feed-prune`, `page-batch`, `comments-batch`, `compact-comments`, `favorite-batch`, `article-batch`, `tag-batch`, `generic-plans`, `prepared-queries`, `eager-write` and `epoll-pause`. Runtime configuration remains exactly the four variables in the challenge contract.

`benchmarks/linux_compare.py` preserves raw results, endpoint histograms, workload mix, error counts, generator-limit flags, executable fingerprints and diagnostics. Each run uses a fresh full-seed clone and removes its temporary server/database even on failure. CI-only workflow changes stay on the fork's separate diagnostic branch, outside the submission pull request.

## Independent password work

[Run 40775117771](https://github.com/Chemske/multicore-server-challenge/actions/runs/40775117771) compared full cost-ten bcrypt calculations on one x86_64 CPU thread, with three trials of 60 distinct password/salt pairs per variant. Median CPU time per hash was 60.833 ms for the standard library, 58.433 ms for one custom lane, 30.850 ms for two, 22.750 ms for three and 19.233 ms for four. All trial checksums agreed. The full-width backend therefore delivered about 3.16 times the scalar throughput in this microbenchmark. This measures complete hash work, not application throughput or user capacity.

The worker integration keeps each hash independent and uses the scalar path for a singleton. `tests/password_batch.py` mixes concurrent registrations, correct logins and incorrect logins, verifies response ownership, checks fresh independent salts, asks the unchanged Go reference to verify each new hash, and changes a stored hash externally before another login group. Its log check requires an actual multi-job calculation rather than merely enabling the build flag. A bounded collection window is experimental; its effect on tail latency must be measured with external generators before changing defaults.

## Integrated Linux validation

[Run 40961667314](https://github.com/Chemske/multicore-server-challenge/actions/runs/40961667314), on 29 October, passed the integrated revision with two reactors, 16 total database connections including four dedicated writers, 8,192 admitted tasks, read groups up to 128, four password lanes and a maximum 75 ms password collection window. It passed all 22 unit checks, grouped page/comment fault tests, mixed password jobs, blocked-writer isolation, real progress on both reactors, 15 mutation scenarios and nine recovery scenarios. Zig and the Go reference each passed all 197 unchanged conformance steps on the development seed. Post-recovery conformance passed too.

The same run retained 150,000 real Linux sockets, obtained an HTTP response on every socket and then read from the database over reused connections. The application reported approximately 28.3 MiB RSS in this socket check, excluding the kernel, PostgreSQL and the generators. Idle CPU rounded to 0.00% of one core over the test's interval. This establishes the socket machinery's correctness under that test; it does not establish 150,000 active workload users, full-load memory consumption or a new leaderboard score.

## Feed candidate pruning

A bounded rank lookup can reduce the number of followed-author articles merged for a page. Let `depth = offset + limit`. If one followed author has at least `depth` articles, its `depth`-th article ID is a safe lower bound: the union already contains `depth` articles at or above that ID. Older articles from any author cannot enter this page. The bound and page are read within the same statement, and the separate count statement remains unchanged.

The optional `feed-prune` control probes at most eight followed authors and at most 256 ranks. Without a usable bound, including deeper pages, the query retains the ordinary merge. The fallback is the minimum signed article ID, so correctness does not depend on positive IDs. No bound survives the statement. Both individual and grouped feeds use the same SQL generator.

The first separate-generator 100,000-user diagnostic did not show an end-to-end improvement from this control: both variants failed, with approximately 22–23% errors. It remains disabled. Correctness alone is not evidence of a useful performance change.

`tests/feed_prune.py` compares 62 API results with the independent full feed relation. Cases include empty/sparse follow sets, early authors without enough rows, interleaved authors, negative IDs, deep offsets, maximum integer offsets and fresh follow/article changes. The existing grouped-page and page-before-count tests still apply. A related within-statement rank-bound strategy appears in the [Rust epoll submission's feed query](https://github.com/arjaythedev/multicore-server-challenge/blob/2f2b650/submissions/rust-epoll-theCatWisel/src/queries.rs); this implementation retains its own separate page/count snapshots and bounded per-page probe.

## Prepared mutation statements

The read catalog already retained prepared plans. Eleven mutation and follow-up lookup statements now use the same lifetime, instead of being parsed and planned again after each write. Their SQL, parameter ownership and transaction sequencing are unchanged. BEGIN, COMMIT and ROLLBACK retain their existing execution path. Recovery requires all 47 statements to be rebuilt before reusing a replacement connection. Native verification passed all 197 unchanged steps, the 15 write cases and nine failure/concurrency cases, including a lost COMMIT acknowledgement without replay.

## Compact comment groups

The optional compact representation is selected only when at least half of a captured comment group's slugs repeat. Other groups retain the ordinary query. The SQL returns each comment's metadata once and separate recipient IDs, order positions and following flags. Position is derived from the original timestamp and ID order before millisecond formatting. Missing articles and empty lists remain distinct.

The primary task owns the metadata and its standard-encoded JSON. A recorded boolean offset allows each recipient's following flag to be emitted without re-encoding the shared strings. No raw user string enters JSON without standard escaping, and no internal encoding field is exposed by the API. Every follower is serialized before the primary arena is released. Nothing survives the group, and no later request can join it.

Native checks passed 24 unit tests, the mixed comment/freshness/SQL-error cases, 197 unchanged steps and the Go comparison. A targeted test disconnects the primary socket after the group reaches PostgreSQL while other recipients remain active, then verifies every surviving response. This is still an experimental control until a separate-generator measurement shows a useful gain.

## Grouped favorite mutations

The optional `favorite-batch` control combines already queued favorite requests of the same kind. One parameterized, implicit transaction applies distinct mutations, then its ReadyForQuery must confirm an idle connection before a separate fresh article read. Missing targets remain individual 404s. No recipient receives success before commit.

A confirmed SQL failure and completed rollback allow that closed group to fall back to independent operations, preserving each original deadline and disabling further grouping for those tasks. Connection loss, malformed results or an uncertain transaction outcome fail the affected requests without replay. Follow-up reads use article IDs, so a concurrent slug rename does not redirect them.

`tests/favorite_batch.py` requires actual grouped wire executions, checks repeated and missing targets, mixes a foreign-key failure with valid requests, and drops the implicit commit acknowledgement after PostgreSQL has committed. It verifies durable rows and no individual replay, then waits for the write owner to recover. Native runs passed with both shared and dedicated write pools. This remains disabled until a workload comparison supports enabling it.

## Distinct article enrichment and loopback transport experiments

The optional `shared-page-metadata` control separates each captured group's selected IDs from enrichment. Article fields, tags and favorite totals are computed once per distinct article within that statement, then mapped back to each page and viewer. Pagination, viewer flags and the subsequent fresh count statement retain their existing semantics. Native checks passed all five grouped page families and their fault/snapshot tests, 62 independent feed cases, 15 mutation cases and all 197 unchanged steps against Zig and Go.

The optional `loopback-no-tls` control avoids optional encryption only for a numeric loopback database without explicit TLS, channel-binding, service or remote routing options. Libpq still parses the entire connection string. Explicit URL and environment security choices keep their normal behavior; non-loopback destinations are never downgraded. No database URL is rewritten in benchmark configuration. This is a local transport experiment, not a reason to disable encryption for networked databases.

## Shared password execution experiment

With `shared-bcrypt`, reactors retain separate request state, completion notifications and fair outstanding-job quotas, while a common bounded FIFO feeds the password workers. This lets independent jobs from different reactors fill one cost-ten calculation. It shares execution capacity, never password results. Each job keeps its owner until that owner's reactor collects the result; other reactors cannot drain its notifications or take its completed tasks.

Workers capture the recipient mask before publishing completions, because a reactor may immediately free its completed job. Password buffers are wiped after calculation. The existing fixed collection deadline, fresh salts, stored-hash verification and no-cache policy remain unchanged. The global pool outlives every reactor.

A unit check fills both owner quotas and independently collects worker completions over both notification pipes. Native validation passed 26 unit checks, mixed cost-ten jobs with independent Go verification, grouped page snapshot/fault tests, all 15 mutation cases and all 197 unchanged Zig and Go steps. Read-group experiments now permit up to 512 captured requests, retaining the existing 256 KiB parameter ceiling and each request's deadline and response limit. Larger groups require workload evidence before becoming defaults.

## Shared feed proofs

The optional `shared-feed-hubs` control selects at most sixteen authors shared by keys in the captured feed group. Their current articles can prove facts useful to every captured viewer following them. A depth-th article ID proves a safe lower page bound; a 1,000th article proves that viewer's capped count is 1,000. These are deductions from the current statement's rows, not remembered statistics or assumptions about the seed.

The page statement limits rank probes to depths of 256. A deeper request, a sparse author or no useful shared author retains the complete merge through the minimum signed article ID. Bounds use the deepest page needing that author, which can weaken a bound but cannot exclude a requested row. Count proofs are rebuilt independently in the subsequent count statement, so a follow committed between page and count changes the count. Negative IDs, empty follow sets and maximum signed offsets retain their ordinary semantics.

Native validation passed 26 unit checks, 256 grouped feeds compared with the independent full relation, all five page-family snapshot/fault checks, 62 feed edge cases, 15 mutation cases and all 197 unchanged Zig and Go steps. The fixture includes a prolific author, sparse authors, missing follows, negative article IDs, distinct viewer favorites and an external follow committed between page and count. Revoking read access to follows also tests a failed proof query and subsequent reuse. The control remains disabled pending a workload comparison.

The statement-local shared-author approach was informed by reviewing [the Rust epoll submission's query catalog](https://github.com/arjaythedev/multicore-server-challenge/blob/4c5287e/submissions/rust-epoll-theCatWisel/src/queries.rs). My query generator preserves the existing separate page/count snapshots and retains its own fault and relation comparisons.

[Linux run 41025555309](https://github.com/Chemske/multicore-server-challenge/actions/runs/41025555309) passed the preceding shared-password revision on four reactors: 26 unit checks, 24 blocked writers, mixed password ownership, recovery across 40 database owners, 197 unchanged steps and the separate 150,000-socket correctness check. The latter remains a socket result, not an active-user score.

## CPU-specific password width

The Oracle EPYC 9J14 comparison ran three single-thread trials of sixty complete cost-ten hashes per backend while the application was idle. Median wall time per hash was 53.183 ms for the standard library, 27.050 ms for two independent lanes, 19.950 ms for three and 47.967 ms for four. All checksums agreed. The earlier CI CPU favored four lanes; a fixed width was therefore not portable. This is a CPU microbenchmark, not a user-capacity result.

The optional `bcrypt-calibrate` control runs three complete dummy calculations at each permitted width before starting workers. Trial order alternates, median time is normalized by the number of hashes, and only the selected execution width is retained. Calibration never uses user passwords, never stores a result for later requests and does not reduce cost ten. Fixed lane controls remain available for comparisons. Every supported width is now checked exactly against the standard library at cost ten, as well as at boundary inputs. Native tests passed all 26 checks, mixed fresh-salt jobs with Go verification, 15 mutation scenarios and 197 unchanged Zig and Go steps.

## Closed profile groups

The optional `profile-batch` control captures compatible profile reads already waiting in the same reactor. A parameterized statement reads distinct usernames once, then computes each recipient's following flag independently. Missing usernames remain individual 404s. No later request joins the group or reuses its data. The prepared catalog now contains 48 statements, including this query, and recovery rebuilds all of them.

Native checks compare 64 mixed profiles, quoted and Unicode names, distinct viewers and missing users with sequential requests. They verify fresh external changes, a disconnected primary recipient and recovery after a SQL failure. All 197 unchanged steps, the independent Go comparison, 15 mutation cases and nine recovery/concurrency scenarios passed. Performance remains an experiment until measured with separate generators.

## Article encoding inside a result group

The optional `shared-article-json` control decodes and standard-encodes each distinct article once within a closed result group. Each recipient still reads its own favorite and following booleans from the result. Two offsets recorded during normal JSON encoding allow those booleans to be emitted independently, without re-encoding repeated strings. The primary task owns shared metadata until followers finish; page metadata also survives the subsequent count statement. No bytes are reused by a later request or another statement result.

All 27 unit checks pass, including exact JSON comparisons for every flag combination, escaped text and both full articles and body-free list entries. Grouped article and page checks cover missing resources, fresh changes, SQL errors, viewer isolation and a primary socket disconnected between page and count. The independent Go comparison and all 197 unchanged API steps pass. This remains experimental pending a workload comparison.

The separate `compact-pages` control also normalizes the database result: distinct article metadata precedes recipient references containing order positions and independent viewer booleans. The API emits ordinary article objects. The SQL still selects each page before enriching it, and the count remains a separate, fresh statement. Empty pages retain an explicit recipient row. The decoder validates recipient bounds, positions and metadata references before responding. The page/failure tests, 256 independent feed comparisons and unchanged Zig/Go conformance also pass in this representation.

## Linux candidate defaults

The selected Linux candidate uses four reactors, 40 total database owners including 24 writers, 12,288 admitted tasks, read groups up to 512 and two shared password workers. Complete hash calibration permits widths one through four with a 100 ms collection ceiling. Closed profiles, grouped favorites, shared page metadata, shared feed proofs, local loopback transport, group-local article encoding and compact page results are enabled. Individual feed pruning and compact comment groups remain disabled. Explicit build controls still permit isolated comparisons; macOS retains the small interactive settings.

On an eight-vCPU, 16-GiB Oracle EPYC 9J14 target with three separate generators, the compact four-reactor candidate passed a 120-second measured probe at 120,000 normal-clock users: 31,194.825 requests/s, p50 60.191 ms, p95 190.975 ms, p99 276.735 ms and zero errors. Two reactors also passed, with p95 265.471 ms; one password worker with two reactors passed with p95 275.199 ms. The database was freshly copied from the full seed, passed all 197 checks, reset again, then warmed before these sequential comparisons. Database age differs between candidates, so these probes do not establish an isolated percentage speedup or a five-minute capacity score.

The same CPU's isolated three-trial comparison measured 19.983 ms per complete hash at width three, versus 40.183 ms at five and 37.483 ms at six. Checksums agreed. Wider diagnostic calculations were therefore not integrated into the runtime worker pool.

## Verified independent capacity search

The plain Linux build at `1f32410627405c139eb926a2ece95bbd9ddc7a5f` passed the unchanged full-seed conformance suite, then the unchanged switch script reset the database and dropped caches. The unchanged distributed search used three separate four-vCPU/eight-GiB load generators, normal think/session times, a three-minute warm-up, two-minute probes including their ramps and five measured minutes for each hold. The target was Ubuntu 24.04, eight vCPUs on four EPYC 9J14 physical cores with SMT, 15,983 MiB RAM and no swap. PostgreSQL used the published configuration; there was no CPU affinity or extra kernel tuning.

| Phase | Users | Requests/s, including errors | p50 ms | p95 ms | p99 ms | Errors | Result |
|---|---:|---:|---:|---:|---:|---:|---|
| Probe | 100,000 | 26,397 | 17.2 | 54.3 | 83.1 | 0% | Pass |
| Probe | 130,000 | 32,695 | 175.2 | 497.4 | 679.9 | 0.60% | Pass |
| Probe | 140,000 | 34,651 | 239.2 | 640.5 | 866.3 | 5.22% | Fail |
| Five-minute hold | 130,000 | 32,375 | 207.2 | 580.1 | 795.1 | 1.75% | Fail |
| Five-minute hold | **120,000** | **30,254** | **162.687** | **470.783** | **653.823** | **0.1024%** | **Pass** |
| Later boundary probe | 125,000 | 30,894 | 242.943 | 667.135 | 926.719 | 3.1061% | Fail |

The 150,000- and 190,000-user probes also failed. [Sanitized aggregate evidence](../benchmarks/results/v2-oracle.json) retains every probe and hold, endpoint distributions, generator load and measured target CPU/steal. The five-minute result is the capacity evidence; the higher short probe is not substituted for it. Oracle hardware and CPU steal differ from the organizer's dedicated host, so this result cannot establish a leaderboard rank or a same-machine speedup against the official v1 score.

The additional 125,000-user probe followed the completed search on its aged database and also failed. It narrows the tested gap above the successful hold to 4.17%. It does not change the search's 120,000-user result. The runtime files and build settings remained identical throughout; the retained source matches the measured runtime at `1f32410`.

## Rejected shared author candidate experiment

I tested reading bounded article-ID prefixes for up to sixteen authors already shared by a captured feed group. The longest needed prefix was read once per author inside the page statement, with each viewer taking only its own prefix before the ordinary merge. Deep windows retained the indexed path, and counts kept their separate later snapshot.

The first form passed all 27 unit checks, 256 independent feed comparisons, page snapshot/fault checks, mutations and unchanged Zig/Go conformance. A read-only comparison also confirmed identical complete result relations on the aged full database. However, its median 512-viewer query was 224.607 ms against 213.131 ms without it. Separating shared and ordinary authors improved the large-group comparison slightly (211.493 versus 216.896 ms) but worsened 128-viewer groups (88.419 versus 85.727 ms). This was isolated SQL work, not user-capacity evidence. The inconsistent result did not justify adding the control to the runtime, so it was removed and the proven query retained.

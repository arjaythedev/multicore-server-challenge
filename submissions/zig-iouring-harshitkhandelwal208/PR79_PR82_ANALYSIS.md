# PR #79 / #82: historical pre-implementation comparison

Source review prepared by **GPT-6.1 Sol (max effort)** on 2026-10-27.

> **Status update: the local backlog is now implemented.** This report preserves the **pre-implementation** comparison
> against `e0cc458` plus the then-existing EOF fixes. All “our gap,” “we do not,” architecture/default descriptions and
> recommended experiments below refer to **that earlier phase**, not today's implementation. Packed reads, batch-local
> feed proofs, overlap-aware comments, an optional fork-shared read coordinator, owned/pooled responses, independent read
> depth, optional network/write/bcrypt policies, JSON/JWT fast paths and startup OID checks now exist, with subsequent
> correctness-audit fixes. See [README.md](README.md#current-local-pr-79--82-implementation) for current behavior/defaults,
> and [OPTIMIZATION_REPORT.md](OPTIMIZATION_REPORT.md) and [VERIFICATION.md](VERIFICATION.md) for completed final
> post-audit results. Implementation is not proof of a throughput win;
> the final full-seed matrix/load evidence must not be inferred from this historical analysis. Our relative source links
> below now open the evolving checkout; only the competitor snapshots are pinned. Attribution remains
> **GPT-6.1 Sol (max effort)**, at the author's request.

## Historical scope and evidence

This compared exact source snapshots with our **working tree at comparison time, before the PR #79 / #82 implementation**,
not just the PR descriptions:

| Submission | Inspected revision | Status when checked | Capacity evidence |
|---|---|---|---|
| Our pre-implementation baseline, [#45][pr45] | `e0cc4585c49d4b8021b41c8bb6b249e2bccaa1cf` **plus the then-existing uncommitted EOF fixes** | #45 merged | **110,000 official**, 28,835 req/s, p95 162 ms, p99 477 ms, 0.77% errors **at e0cc458, before those EOF fixes** |
| Nick Potts, [#79][pr79] | `af5474262c33148bb37c70c287bbceb02a7dd894` | Open; no official result | Author reports **150,000** twice on an 8-vCPU Hetzner CCX33; #7 reportedly holds 120–130k there |
| Nickita Khylkouski, [#82][pr82] | `da7d8b7b0cdc6139fcb0770a67275455afd19390` | Open; no official result | Author reports **200,000**, 51,734 req/s in the latest listed hold, on an AWS c7i.2xlarge; #7 reportedly holds 130k there |

**These are not comparable scores.** The [official leaderboard][leaderboard] uses one 8-dedicated-vCPU / 16-GB target. #82's AWS target has four physical cores / eight hardware threads; #79 uses a different host, and even their #7 controls differ from its official 100k. Neither PR establishes that it beats us on the official target, or by how much. #82 also hit its search ceiling and per-process descriptor limit. Its README shows substantial variation between two hosts of the same instance type. [Measurement sources: #79][79-measure], [#82][82-measure].

#79's only PR comment is an automated review that **could not complete**, against an older revision; it is not a benchmark or a completed review of the inspected head. #82 had no comments or reviews when checked.

Our latest [official result][official45] reports app 22% / PostgreSQL 63% CPU and a 120k hold that failed on errors, not the latency thresholds. The EOF fixes had local validation documented in [VERIFICATION.md](VERIFICATION.md), but **no official post-fix capacity result**. That EOF-fixed working tree was the proposed baseline for subsequent optimization tests; it is not the later implemented candidate.

### Bottom line at comparison time

The main opportunity is **less PostgreSQL work and less data movement per successful request**, not changing languages or adding io_uring/assembly. We already have those low-level optimizations.

The most promising combination is:

1. Their batch-local feed count proofs.
2. Their single-statement, packed read results, extending our existing sharing.
3. Their service-wide read pooling, without giving up our multi-process connection scaling.
4. Their selective treatment of low-overlap comment reads.
5. Target-dependent packet reduction, only after measuring the network bottleneck.

## Historical architecture at eight CPUs

These are source-derived **pre-implementation** defaults, not current settings or measurements of which layout is best.

| Area | Ours before this backlog | #79 | #82 |
|---|---|---|---|
| HTTP execution | 2 worker processes | 4 worker processes | 3 Tokio workers in one process |
| Read ownership | 3 PG connections per worker; 6 total, **two independent pools** | One drain process, 5 read connections, shared-memory SPSC rings to HTTP workers | One service-wide queue per family, 6 read connections, separate DB runtime |
| Write connections | 2 total | 4 total | 2 total |
| Read groups in flight per connection | Up to 4 | 1 | Shared actor awaits its take before taking another |
| Read collection | Adaptive; flushes immediately when a local read backend is idle; configured maximum hold 100 ms while busy | 5-ms gather clock; up to 4,096 reads per drain | No collection timer; oldest family, up to 256 queued requests |
| Shared read SQL | Two-phase cross-family planner from 16 staged reads; otherwise per-kind batching up to 64 | One cross-family MEGA statement, except comments/login, from 2 qualifying reads | One shared statement per family, with packed output where selected |
| Compression | None | Compress only if it reduces the response's TCP segment count | Adaptive libdeflate level 1 when egress and retransmit thresholds indicate congestion |

Sources: our [main defaults](src/main.zig), [scheduler](src/server.zig) and [planner](src/plan.zig); [#79 sizing][79-main], [#79 scheduler][79-db]; [#82 defaults][82-main], [#82 queue][82-sched], [#82 actor][82-actor].

**Important:** our `BATCH_MAX=64` is not the planner's cap. `PLAN_MAX` is already 2,048. Nor does `READ_WINDOW_US=100000` mean every read waits 100 ms: the idle-backend flush fixes are present. Calling either of these a missing feature would misdiagnose our code.

## Historical verified differences and their likely value

“Verified” below means the mechanism existed in the inspected source. The benefit **over our then-current implementation was unmeasured**. All competitor performance numbers are their authors' results, against their own comparison builds.

### 1. They can finish a shared article read in one database statement

**What they do:** #82 selects distinct count/page keys, collects article IDs, enriches those entities, computes viewer flags, and returns everything in one statement. #79 goes further: its MEGA statement shares entities across global/tag/author/favorited lists, feeds and single-article reads, with profile/user/tag reads alongside them. Comments and login lookups stay separate. [#82 SQL][82-lists], [#79 SQL][79-mega].

**Our gap:** our planner already shares counts, pages, enrichment and viewer membership. But it executes **phase A**, copies/decodes that reply, gathers article IDs and viewer pairs in Zig, then sends **phase B** containing up to four more statements. That adds another application/database exchange, executor starts, array encoding and result handling. Base article columns can also repeat across distinct pages or families before the app deduplicates their IDs. See `onReplyInner`, `collect` and `encodeB` in [plan.zig](src/plan.zig), and `plan_defs` in [sql.zig](src/sql.zig).

**Why this matters:** PostgreSQL is our largest measured CPU consumer. Removing application-mediated phase boundaries is a substantive difference, not just a new name for batching. A single statement also makes the shared operation use one statement snapshot rather than separate statement snapshots.

**What to test:** an ID-only page-selection CTE feeding one shared enrichment/flags stage. Start with a packed per-family version; then test cross-family fusion separately. Keep the cheap single-request path and isolated fallback. A giant MEGA statement has fixed overhead and generic-plan risks, so it is not automatically best for every batch size.

### 2. They pack database output more completely

**What they do:** #82 sends each distinct article once, plus **one header per request** containing count, ordered page IDs and flag-ID arrays. The app distributes reference-counted row handles without copying their payloads. #79 sends article entities once across MEGA, plus **narrow per-request/article rows**; it does not use #82's exact one-header-per-list format. [#82 output/demux][82-demux], [#82 row storage][82-rows], [#79 SQL][79-mega].

**Our gap:** the per-kind fallback decorates each distinct article once in SQL but still returns its full fields once per requesting page row. The planner reduces this duplication substantially, but phase A still returns base text per distinct page/family, and `assemble` reconstructs PostgreSQL-format rows in `w.synth` before the API parses them again. It also rebuilds binary tag arrays. See `listBatch` in [sql.zig](src/sql.zig) and `articleCols`/`assemble` in [plan.zig](src/plan.zig).

**Author evidence:** #82 reports a 64-viewer global batch shrinking from **526 kB to 32 kB**, with PostgreSQL time **3.5 to 1.6 ms**. That is against its old wide-output path, **not our already-shared planner**. [Source][82-readme-changes].

**What to test:** serialize JSON directly from batch-owned entity views and request-local flags, instead of manufacturing another wire-protocol reply. Measure PG-to-app bytes, allocations, copied bytes and total CPU. Preserve ownership until every dependent response has been rendered.

### 3. Both pool reads across the whole service, rather than per HTTP worker

**What they do:** every #82 read connection pulls from the same family queues. #79 preserves multiple HTTP processes but sends their reads to one drain process through lock-free SPSC rings. This combines opportunities to share work and lets any read backend serve any worker's backlog. [#82 queue][82-sched], [#79 drain][79-drain].

**Our gap:** `Worker.stages`, read connections and planner batches are worker-local. We balance correctly **within** a worker, including preferring idle backends, but a busy worker cannot use another process's idle read connection. Requests for overlapping pages are split into separate sharing domains.

**Author evidence:** #79's replay found four private queues consumed **1.211×** the PG CPU of one shared queue in its stack. It reports 1–3 µs/request of IPC overhead. **We have two pools, not four**, and different SQL, so this does not predict a 21% saving for us. [Source][79-drain-readme].

**What to test:** quantify potential sharing by merging captured worker batches offline, then prototype a shared read coordinator while keeping HTTP worker count and total DB connections fixed. Measure the coordinator's CPU and ring copies too. Avoid changing worker count, SQL and connection count all at once and attributing the combined result to pooling.

### 4. They prove many feed counts reach the cap without walking every viewer's first 1,000 articles

**What they do:** both read followee IDs once for reuse by count/page selection, identify a bounded number of frequently shared followees, and check whether each has a 1,000th article. A viewer following one proven-heavy author necessarily has a capped feed count of 1,000. #82 checks up to 8 shared followees; #79 checks up to 10. Other viewers fall back to real counting/probing in the same statement. [#82 feed][82-feed], [#79 SQL][79-mega].

**Our gap:** we already have a generic `OFFSET 999` cap proof and force feed `following=true`. But `a_feed` repeats the viewer's followee lookup in count/page work and does the cap walk for each distinct viewer. It has no shared-author proof. The per-kind feed has the same missing shared proof. See `feed_sql`, `b_feed` and `a_feed` in [sql.zig](src/sql.zig).

**Author evidence:** #82 reports **20.3 to 18.2 ms** for a 64-viewer batch with its heavy-followee shortcut. Its other tests also show that superficially similar feed rewrites can be slower. [Source][82-readme-changes].

**What to test first:** add the batch-local followee array and shared proof, preserving exact fallback counts. This is a narrower experiment than replacing the planner. Derive candidates from live queued requests and current database rows: **no hard-coded author IDs, seed assumptions or cross-request count cache**. Test empty feeds, 999/1,000/1,001 rows, sparse authors and arbitrary offsets.

### 5. They avoid expensive shared comment paths when there is little to share

**What they do:** #82 selects packed/shared slug reads only when distinct non-viewer keys are at most 50% of the batch by default. Otherwise comments/articles use ordinary batched lateral queries. #79 explicitly keeps comments out of MEGA and uses dedicated single/batch comment statements. [#82 selection][82-selection], [#82 comment SQL][82-feed], [#79 comments][79-comments].

**Our gap:** our planner includes comments whenever a mixed plan reaches `PLAN_MIN`. It interns slugs and moves viewer-following flags to phase B even when nearly every slug is unique. A mixed batch's comments also wait for the plan's other enrichment before assembly. Our normal comment query already hashes a viewer's followees once; that part is **not** missing.

**Author evidence:** #82 reports 99% distinct slugs in sampled high-load batches, and **16.7 ms shared versus 6.7 ms unshared** for comments. #79 reports fewer instructions with comments outside its earlier MEGA variant. Neither is a measurement against us. [#82 rejected experiments][82-dropped], [#79 discussion][79-mega-readme].

**What to test:** record actual duplicate ratios, then compare a dedicated one-statement comment path against planned comments. Keep sharing for genuinely repeated threads. Do not blindly adopt 50% as a universal threshold.

### 6. Their read depth and collection policies keep more work available for coalescing

**What they do:** both normally execute one read group per connection before taking the next. #82 coalesces whatever has naturally accumulated, without a timer. #79 intentionally gathers for 5 ms, then submits a large mixed drain. These are **different policies**, not evidence that one fixed delay wins everywhere. [#82 actor][82-actor], [#79 scheduler][79-db].

**Our gap/opportunity:** `PG_DEPTH=4` can assign future batches to a backend before those requests can coalesce with later arrivals. Our adaptive hold also has a different latency/batch-size tradeoff. #82's author found two pipelined groups reduced coalescing; #79 found longer clocks cheaper for PG but worse for p99. [#82 experiments][82-dropped], [#79 experiments][79-dropped].

**What to test:** read depth 1/2/4; zero versus short bounded collection under load; per-kind caps 64/128/256; planner cap independently. Do not describe 64→256 as enlarging our 2,048-request planner. Our `PG_DEPTH` currently affects writes too, so isolate read-depth effects rather than silently changing both paths.

Backend sizing is another experiment, not a free win. #79 has 5 reads, #82 has 6, and ours has 6. A true 5-read pool cannot be obtained by simply dividing our current total evenly between two workers: `main.zig` floors the per-worker counts. Record **actual started counts** in every run.

### 7. They avoid some response copies and pool more response sizes

**What they do:** #79 builds the response in a request-owned, size-class pooled buffer and sends that same allocation; release happens after send completion. It pools 4 KiB through 4 MiB classes. #82 also keeps separate request/response pools, including 16/64-KiB response classes. [#79 buffers][79-buf], [#79 send lifetime][79-ack], [#82 pools][82-http].

**Our gap:** API rendering uses worker-wide `w.out`; `sendCopy` then allocates/takes a connection-owned buffer and copies the entire response. Only 4-KiB response slabs have an explicit reuse pool; larger responses allocate/free through the allocator. This matters more as comment threads and response sizes grow. See `finish` in [api.zig](src/api.zig) and `sendCopy`/`freeOut` in [server.zig](src/server.zig).

**What to test:** transfer ownership of the rendering buffer to the send path and replace the worker's buffer from a bounded size-class pool. Measure allocation and memory-retention costs. Keep the zero-copy notification barrier, partial-send handling and fd/generation lifetime fixes intact; removing a copy is not permission to recycle a still-referenced buffer.

### 8. #79 reduces packets with delayed ACKs; we do not

**What it does:** after a complete keep-alive response, #79 queues `TCP_QUICKACK=0` through an io_uring socket command, so the next request's ACK has a chance to ride its response. It disables the feature on unsupported-kernel errors. This is **not** disabling `TCP_NODELAY` or turning Nagle back on. [Code][79-ack].

**Our gap:** we set `TCP_NODELAY`, but do not have this post-response delayed-ACK policy.

**Author evidence:** #79 reports private full searches at **140k without versus 150k with** ACK delay, and about 11–12% lower receive-CPU softirq in its comparisons. Its diagnosis was one saturated NIC receive CPU, not overall CPU exhaustion. [Source][79-ack-readme].

**What to test:** count pure ACKs, retransmits, per-CPU softirq and tail latency on the actual remote-load target. Preserve fd lifetime for pending socket commands, and test idle keep-alive, fragmented requests, pipelining and unsupported-command fallback. Do not assume our target has the same single-queue bottleneck.

### 9. Both selectively compress responses; our response path cannot

**#82:** libdeflate level 1 for clients accepting gzip and bodies at least 1 KiB, with a compression share adjusted every 50 ms. Default activation needs over 100 MB/s egress and at least 0.5% retransmitted segments. On its CPU-bound fast-link setup it deliberately sends identity. [Code][82-http].

**#79:** use the connection's MSS, attempt compression for responses needing at least three segments, and send gzip only when it reduces total segment count. Its custom codec targets packet reduction, not maximum compression. [Code][79-buf], [measurements][79-gzip-readme].

**Our gap:** `Head` does not retain gzip negotiation, and `finishResponse` sends uncompressed JSON. Compression could relieve either link bandwidth or ACK/receive-CPU pressure, but costs real application CPU.

**What to test:** identity versus a proven gzip library with adaptive and segment-saving policies, separately from ACK delay. Measure successful req/s, CPU, bytes, packets and p99. Respect encoding quality values and verify decompressed output with an independent decoder. Only consider a custom codec after profiling proves the library's CPU cost matters. Do not copy a fixed 100-MB/s threshold without measuring the actual link.

### 10. They collect larger write groups; #79 also batches mutations in SQL

**What they do:** #82 waits up to 1 ms for a lone write and groups up to 128; #79 waits 3 ms, groups up to 128 and uses array statements for common mutations such as follow/favorite/comment-create. [#82 writes][82-writes], [#79 writes][79-writes].

**Our gap:** we already do durable group commit and isolate failed groups, but dispatch the first idle write immediately, cap groups at 32, and concatenate individual executions rather than array-batching common mutations. See `writeSubmit`/`sendGroup` in [server.zig](src/server.zig).

**What to test:** a small bounded collection interval and batched mutations inside our existing durable transaction, with conflict and ordering tests. Writes are a smaller optimization target than the read path. Preserve commit-before-response and immediate cross-connection visibility. #79's omission of explicit BEGIN/COMMIT is a distinct protocol experiment, **not a change to copy casually**, especially given our earlier write-visibility bugs.

### 11. Their bcrypt scheduling is more adaptive, but a faster kernel is not yet a proven advantage over ours

**#79:** startup self-tests and calibrates kernel family and width (4–8 lanes), with portable/assembly variants. Idle-priority hashers spare PostgreSQL and HTTP; a normal-priority watchdog handles starvation. Lone low-load jobs need not always wait for the fill window. [Calibration][79-bcrypt-engine], [scheduling][79-bcrypt].

**#82:** five interleaved lanes, normally one hashing worker, 160-ms collection and an 8-second stale-job cutoff. [Code][82-bcrypt].

**Our gap:** fixed maximum four lanes, two normal-priority hashing workers total on eight CPUs, 250-ms collection and a 9.5-second stale cutoff. We **already have interleaved assembly bcrypt, independently salted hashes and stale-job rejection**. See [bcrypt.zig](src/bcrypt.zig), [bcpool.zig](src/bcpool.zig) and [main.zig](src/main.zig).

**Caveats:** #79's headline kernel percentage is against **#7's Openwall kernel on Zen 5**, not our four-lane BMI2 assembly, and its preferred kernel differs on Zen 3. #82 reports that a second hasher fixed logins but reduced overall throughput by taking CPU from PG. Neither establishes the best choice for our implementation on the official CPU. [#79 measurements][79-bcrypt-readme], [#82 discussion][82-readme-changes].

**What to test:** real bcrypt CPU/hash across kernels/widths, then whole-service goodput and per-endpoint errors. Earlier stale-job rejection can avoid wasted work, but 503s remain errors. Do not lower thread priority without starvation protection, and do not trade away password verification to inflate a score.

### 12. #82 fuses JSON scanning and copying; we scan then copy

**What it does:** its SSE2 loop stores each clean 16-byte block while checking escapes. It also uses a two-digit timestamp table and an exact-issued-payload JWT parsing shortcut after signature verification. [Escaping/timestamps][82-json], [JWT][82-auth].

**Our gap:** `putEscaped` already uses SIMD to find special bytes, but then `putSlice` copies those clean spans. Timestamp digits are written arithmetically. JWT HMAC pad states and the canonical-header shortcut are already present; claims use our lightweight parser, not a heavyweight object tree. See [jw.zig](src/jw.zig) and [jwt.zig](src/jwt.zig).

**What to test:** fused check/copy and timestamp pairs as isolated microbenchmarks, then CPU at a fixed successful request rate. #82's reported 3-KB-page improvement, 1.6→0.8 µs, is versus its previous encoder, not ours. These are lower priority than DB work. Preserve general valid JWT handling, signature/algorithm/expiry/nbf checks and exact JSON bytes.

## What was not a missing optimization at comparison time

- **Batching, distinct-key counts/pages, shared enrichment, grouped favorite/tag scans, set-based viewer flags, capped-count probes and feed `following=true`:** already in our planner/SQL. #82's flag/enrichment improvements largely overlap what we do; its one-statement layout, packed results and once-resolved author-key path are the narrower differences worth measuring.
- **io_uring, raw binary PG, prepared generic plans, durable group commit, bufferless idle sockets, multi-process fd scaling and assembly bcrypt:** already implemented. #82's separate Tokio runtime fixes a Tokio scheduling issue; its reported “40% backend idle” must not be assigned to our event loop without measurement. A dedicated drain may still help us, but instrument PG completion-to-refill delay first.
- **More HTTP workers or fewer PG backends:** not intrinsically better. Both PRs document failed sizing experiments. Changing our worker count also changes per-worker DB and bcrypt allocation.
- **No zero-copy sends:** #79 rejected SEND_ZC on its workload. We enable it for initial sends from 256 bytes. This is a strong reason to A/B `SEND_ZC=0` and larger thresholds, not proof it is slower here. Keep the existing ENOMEM fallback and notification-lifetime fixes whichever policy wins. [#79 experiments][79-dropped].
- **Startup SQL result-type checks:** #79 describes and validates result columns/OIDs; our `prepareAll` primarily checks preparation success. This is useful verifier-facing hardening, **not a demonstrated throughput gain**. It would be especially valuable during a packed-row rewrite. [#79 validation][79-types], [our preparation](src/pg.zig).
- **Route-class shedding:** #79 refuses expensive route classes first within an intended 0.9% error budget. Its README explicitly asks for a maintainer ruling and says its measured shedding change **did not raise its score**. We should not treat rejecting almost all logins as an unconditional advantage or assume this policy is approved. Honest 503s still count against the <1% total error limit. [Source][79-shed].

## Historical recommended order of work

This was the experiment backlog, **now implemented locally**, not a claim that the gains add together or are proven wins.
The current report linked above owns implementation decisions, final audit details and final validation status.

| Order | Experiment | Why / decision metric |
|---|---|---|
| 0 | Establish the then-current EOF-fixed baseline on the scoring-style target | Separate error recovery from new speed changes; no claim of 120k until a real hold passes |
| 1 | Batch-local feed followee reuse + heavy-author cap proofs | Narrow change targeting expensive indexed walks; PG CPU per correctly answered feed |
| 2 | One-statement packed lists/feed; direct entity-view rendering | Reduce phase boundaries, duplicate text, executor starts and synthetic-row copies |
| 3 | Overlap-aware dedicated comment path | Avoid sharing overhead and cross-family waits when threads do not repeat |
| 4 | Service-wide read coordinator | Larger sharing domain and load balancing; retain multi-process HTTP; include IPC cost |
| 5 | Retune read depth, caps, short gather policy and actual pool sizes | Test after SQL/coordinator changes, because those change the optimal settings |
| 6 | Owned response buffers / size-class pooling; copied SEND versus SEND_ZC | Reduce app copies/allocations/notification costs without sacrificing lifetime safety |
| 7 | ACK delay and selective gzip, independently and together | Promote earlier only if remote-target packet/bandwidth measurements show the network is binding |
| 8 | Write collection/array mutations, bcrypt calibration/scheduling, JSON fusion | Smaller or hardware-specific opportunities; require an end-to-end win |

## Validation requirements proposed before implementation

1. **Correctness first:** unchanged 197-check suite, Safe/Fast builds and normal/fallback I/O. Reuse our fixture-backed and batched/non-batched differential tests; include distinct and repeated keys, multiple viewers, legitimate misses, inline/heap key boundaries, empty pages and exact counts around 1,000. Do concurrent create/favorite/follow/comment/read-after-write checks and poisoned-batch recovery. Check output against the reference, not only one implementation against another mode of itself.
2. **SQL cost:** replay the same request batches at several sizes and overlap ratios, against both fresh and realistically aged full-seed databases. Collect `EXPLAIN (ANALYZE, BUFFERS, SETTINGS, TIMING OFF)`, backend CPU, wire bytes, queue wait and allocations. Use existing PG statistics facilities if available; do not add forbidden schema objects/extensions. Fewer buffer hits alone do not prove less CPU.
3. **Network/ownership:** separate load host; measure per-CPU softirq, packets/ACKs, egress and retransmits. Re-run slow readers, large responses, partial sends, half-closes, pipelining, fd reuse and real low-MEMLOCK pressure. Exercise unsupported socket-command fallback. Independently decode every tested gzip variant and compare JSON bytes.
4. **Capacity:** alternate baseline/candidate runs in ABBA order with repeated controls, identical CPU/RAM/kernel/PG configuration, seed, loadgen, think time and actual connection counts. Reset to the same starting database **between full searches**, not between their phases: growth during search is part of the challenge. Keep CPU steal, monitoring overhead and load-generator limits visible.
5. **Acceptance:** record successful responses/s, each endpoint's failures, overall errors including EOFs/timeouts/503s, p95/p99, CPU, memory and the final **five-minute hold**. Passing a short probe, a microbenchmark or a fresh-DB fixed run is not a capacity result. Do not extrapolate our official score from another author's #7 ratio.

No schema/index changes, cross-request result/token/password caches, benchmark-phase detection or relaxed durability/security are proposed. See the [challenge rules][rules].

## Work performed for the original comparison

- Retrieved PR metadata/comments and rechecked that both inspected heads were still current and open.
- Downloaded only the two pinned submission trees into ignored `.zig-cache/pr-comparison/` analysis storage. No competitor install/build/start script was executed.
- Read the relevant SQL, scheduling, row storage, HTTP/compression, buffer ownership and bcrypt paths and compared them with our source at that time.
- Added this report only during the original analysis phase. Existing implementation fixes and reports were left untouched then; implementation followed separately.
- **No new application benchmarks or conformance runs were performed in that original analysis-only phase.** Earlier verification remains recorded separately in `VERIFICATION.md`; competitor measurements above were not independently reproduced. The later status-note refresh does not turn this historical comparison into a final implementation or benchmark report.

## Source links

Competitor source links below are pinned to the inspected commits so later PR edits do not change this analysis's evidence.

[pr45]: https://github.com/arjaythedev/multicore-server-challenge/pull/45
[pr79]: https://github.com/arjaythedev/multicore-server-challenge/pull/79
[pr82]: https://github.com/arjaythedev/multicore-server-challenge/pull/82
[official45]: https://github.com/arjaythedev/multicore-server-challenge/pull/45#issuecomment-6420772705
[leaderboard]: https://github.com/arjaythedev/multicore-server-challenge/blob/main/LEADERBOARD.md
[rules]: https://github.com/arjaythedev/multicore-server-challenge/blob/main/README.md#rules
[79-measure]: https://github.com/nick-potts/multicore-server-challenge/blob/af5474262c33148bb37c70c287bbceb02a7dd894/submissions/zig-iouring-nick-potts/README.md#L617-L641
[82-measure]: https://github.com/nickita-khylkouski/multicore-server-challenge/blob/da7d8b7b0cdc6139fcb0770a67275455afd19390/submissions/rust-tokio-nickita-khylkouski/README.md#L79-L105
[79-main]: https://github.com/nick-potts/multicore-server-challenge/blob/af5474262c33148bb37c70c287bbceb02a7dd894/submissions/zig-iouring-nick-potts/src/main.zig#L25-L47
[79-db]: https://github.com/nick-potts/multicore-server-challenge/blob/af5474262c33148bb37c70c287bbceb02a7dd894/submissions/zig-iouring-nick-potts/src/db.zig#L1-L48
[82-main]: https://github.com/nickita-khylkouski/multicore-server-challenge/blob/da7d8b7b0cdc6139fcb0770a67275455afd19390/submissions/rust-tokio-nickita-khylkouski/src/main.rs#L61-L87
[82-sched]: https://github.com/nickita-khylkouski/multicore-server-challenge/blob/da7d8b7b0cdc6139fcb0770a67275455afd19390/submissions/rust-tokio-nickita-khylkouski/src/sched.rs#L60-L147
[82-actor]: https://github.com/nickita-khylkouski/multicore-server-challenge/blob/da7d8b7b0cdc6139fcb0770a67275455afd19390/submissions/rust-tokio-nickita-khylkouski/src/writer.rs#L508-L660
[82-lists]: https://github.com/nickita-khylkouski/multicore-server-challenge/blob/da7d8b7b0cdc6139fcb0770a67275455afd19390/submissions/rust-tokio-nickita-khylkouski/src/read_batch.rs#L333-L551
[79-mega]: https://github.com/nick-potts/multicore-server-challenge/blob/af5474262c33148bb37c70c287bbceb02a7dd894/submissions/zig-iouring-nick-potts/src/sql/MEGA.sql#L1-L113
[82-demux]: https://github.com/nickita-khylkouski/multicore-server-challenge/blob/da7d8b7b0cdc6139fcb0770a67275455afd19390/submissions/rust-tokio-nickita-khylkouski/src/read_batch.rs#L817-L913
[82-rows]: https://github.com/nickita-khylkouski/multicore-server-challenge/blob/da7d8b7b0cdc6139fcb0770a67275455afd19390/submissions/rust-tokio-nickita-khylkouski/vendor/tokio-postgres/src/row.rs#L98-L193
[82-readme-changes]: https://github.com/nickita-khylkouski/multicore-server-challenge/blob/da7d8b7b0cdc6139fcb0770a67275455afd19390/submissions/rust-tokio-nickita-khylkouski/README.md#L9-L24
[79-drain]: https://github.com/nick-potts/multicore-server-challenge/blob/af5474262c33148bb37c70c287bbceb02a7dd894/submissions/zig-iouring-nick-potts/src/drain.zig
[79-drain-readme]: https://github.com/nick-potts/multicore-server-challenge/blob/af5474262c33148bb37c70c287bbceb02a7dd894/submissions/zig-iouring-nick-potts/README.md#L173-L216
[82-feed]: https://github.com/nickita-khylkouski/multicore-server-challenge/blob/da7d8b7b0cdc6139fcb0770a67275455afd19390/submissions/rust-tokio-nickita-khylkouski/src/read_batch.rs#L638-L809
[82-selection]: https://github.com/nickita-khylkouski/multicore-server-challenge/blob/da7d8b7b0cdc6139fcb0770a67275455afd19390/submissions/rust-tokio-nickita-khylkouski/src/read_batch.rs#L244-L298
[79-comments]: https://github.com/nick-potts/multicore-server-challenge/blob/af5474262c33148bb37c70c287bbceb02a7dd894/submissions/zig-iouring-nick-potts/src/sql/BATCH_COMMENTS_LIST_SET.sql#L1-L8
[82-dropped]: https://github.com/nickita-khylkouski/multicore-server-challenge/blob/da7d8b7b0cdc6139fcb0770a67275455afd19390/submissions/rust-tokio-nickita-khylkouski/README.md#L141-L169
[79-mega-readme]: https://github.com/nick-potts/multicore-server-challenge/blob/af5474262c33148bb37c70c287bbceb02a7dd894/submissions/zig-iouring-nick-potts/README.md#L268-L342
[79-dropped]: https://github.com/nick-potts/multicore-server-challenge/blob/af5474262c33148bb37c70c287bbceb02a7dd894/submissions/zig-iouring-nick-potts/README.md#L645-L743
[79-buf]: https://github.com/nick-potts/multicore-server-challenge/blob/af5474262c33148bb37c70c287bbceb02a7dd894/submissions/zig-iouring-nick-potts/src/buf.zig#L33-L172
[79-ack]: https://github.com/nick-potts/multicore-server-challenge/blob/af5474262c33148bb37c70c287bbceb02a7dd894/submissions/zig-iouring-nick-potts/src/loop.zig#L284-L350
[79-ack-readme]: https://github.com/nick-potts/multicore-server-challenge/blob/af5474262c33148bb37c70c287bbceb02a7dd894/submissions/zig-iouring-nick-potts/README.md#L504-L545
[79-gzip-readme]: https://github.com/nick-potts/multicore-server-challenge/blob/af5474262c33148bb37c70c287bbceb02a7dd894/submissions/zig-iouring-nick-potts/README.md#L549-L586
[82-http]: https://github.com/nickita-khylkouski/multicore-server-challenge/blob/da7d8b7b0cdc6139fcb0770a67275455afd19390/submissions/rust-tokio-nickita-khylkouski/src/http.rs#L14-L241
[82-writes]: https://github.com/nickita-khylkouski/multicore-server-challenge/blob/da7d8b7b0cdc6139fcb0770a67275455afd19390/submissions/rust-tokio-nickita-khylkouski/src/writer.rs#L205-L315
[79-writes]: https://github.com/nick-potts/multicore-server-challenge/blob/af5474262c33148bb37c70c287bbceb02a7dd894/submissions/zig-iouring-nick-potts/README.md#L346-L371
[79-bcrypt-engine]: https://github.com/nick-potts/multicore-server-challenge/blob/af5474262c33148bb37c70c287bbceb02a7dd894/submissions/zig-iouring-nick-potts/src/bcrypt/bcrypt.zig#L270-L355
[79-bcrypt]: https://github.com/nick-potts/multicore-server-challenge/blob/af5474262c33148bb37c70c287bbceb02a7dd894/submissions/zig-iouring-nick-potts/src/bcrypt.zig#L113-L327
[82-bcrypt]: https://github.com/nickita-khylkouski/multicore-server-challenge/blob/da7d8b7b0cdc6139fcb0770a67275455afd19390/submissions/rust-tokio-nickita-khylkouski/src/password_batch.rs#L20-L75
[79-bcrypt-readme]: https://github.com/nick-potts/multicore-server-challenge/blob/af5474262c33148bb37c70c287bbceb02a7dd894/submissions/zig-iouring-nick-potts/README.md#L395-L450
[82-json]: https://github.com/nickita-khylkouski/multicore-server-challenge/blob/da7d8b7b0cdc6139fcb0770a67275455afd19390/submissions/rust-tokio-nickita-khylkouski/src/json/escape.rs#L21-L227
[82-auth]: https://github.com/nickita-khylkouski/multicore-server-challenge/blob/da7d8b7b0cdc6139fcb0770a67275455afd19390/submissions/rust-tokio-nickita-khylkouski/src/auth.rs#L48-L142
[79-types]: https://github.com/nick-potts/multicore-server-challenge/blob/af5474262c33148bb37c70c287bbceb02a7dd894/submissions/zig-iouring-nick-potts/src/pg.zig#L554-L599
[79-shed]: https://github.com/nick-potts/multicore-server-challenge/blob/af5474262c33148bb37c70c287bbceb02a7dd894/submissions/zig-iouring-nick-potts/README.md#L454-L500

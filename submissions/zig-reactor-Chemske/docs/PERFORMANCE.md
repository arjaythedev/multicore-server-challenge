# Performance work

These sections record the original Mac experiments. The official 20,000-user result and subsequent Linux scaling work are in [SCALING.md](SCALING.md). Percentages from separate experiments must not be added together.

## Rules and leaderboard recheck

Checked on 2026-10-25 against upstream `c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e`. Fetching upstream showed no changes to the rules, schema, workload, test harness or leaderboard since my previous review.

At that review, the official leaders were Rust/Tokio at 100,000 users, C#/Sockets at 95,000, and C/io_uring at 84,000. The leading Rust run reports 26,279 requests/s, p95 119 ms and p99 185 ms, with 20% application CPU and 70% PostgreSQL CPU. These are results on the official eight-vCPU, 16 GB box, with the full seed and separate load generators.

The score requires a five-minute hold with p95 below 500 ms, p99 below one second and fewer than 1% errors. A load-generator-limited run does not establish server capacity. The application shares its CPU and memory budget with PostgreSQL.

I keep these constraints throughout optimisation:

- Every request reads its data from PostgreSQL during service; no response, data, authentication or password-result caches.
- The schema, indexes, seed, workload and shared test files remain fixed. Prepared statements and connection pools are explicitly allowed. Total application database connections must stay at or below 95.
- Writes wait for durable commit. No asynchronous commit, speculative success or automatic replay after an uncertain write outcome.
- Every applicable request verifies HS256 and expiry. Every login verifies the current stored bcrypt hash; new hashes use cost 10 and fresh salts.
- Direct HTTP must eventually support tens of thousands of idle connections. The configured ceiling is now 131,072, clamped to existing descriptor limits; the Mac live-socket check covers 8,000.
- The submission must build from pinned source on Ubuntu 24.04 x86_64 and pass the unchanged conformance suite. A Mac run cannot establish this.

Sources: [rules and scoring](https://github.com/arjaythedev/multicore-server-challenge/blob/c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e/README.md), [runtime contract](https://github.com/arjaythedev/multicore-server-challenge/blob/c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e/SPEC.md), [workload](https://github.com/arjaythedev/multicore-server-challenge/blob/c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e/WORKLOAD.md), [leaderboard](https://github.com/arjaythedev/multicore-server-challenge/blob/c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e/LEADERBOARD.md).

## Experiment 1: named prepared queries

The control sends each statement with `PQsendQueryParams`, which parses the SQL again. The candidate prepares nineteen fixed queries on its own connection during startup and uses `PQsendQueryPrepared` for the existing users, profiles, tags and article-read path. The article/comment operation state machine retains its original parameterized path for this experiment. SQL text, parameters, serialization, commit boundaries, queueing, limits and worker counts are otherwise the same.

Preparation is completed and drained before the connection is admitted to the reactor, within the existing twenty-second startup budget. A preparation failure closes the connection and fails startup. Prepared names live only as long as that connection. This creates no persistent schema objects and retains no returned data. Database reconnection is still a separate checkpoint.

I keep PostgreSQL's default `plan_cache_mode=auto`. Forcing generic plans could reduce planning work further, but skewed tags, authors and pagination sizes can need different plans. That needs its own measured experiment. See [PostgreSQL PREPARE](https://www.postgresql.org/docs/18/sql-prepare.html) and [asynchronous libpq commands](https://www.postgresql.org/docs/18/libpq-async.html).

Build the current control with:

```sh
source dev/env.sh
zig build -Doptimize=ReleaseSafe -Dpg-root="$PGROOT" -Dprepared-queries=false
```

The normal build enables prepared queries. Copy each executable into a distinct directory under `work/` before comparing; rebuilding replaces `zig-out/bin/conduit`.

The standard-library-only `benchmarks/compare.py` launches the unchanged upstream load generator against fresh development-seed database copies. Its default order is A-B-B-A-B-A, with three runs of each build. It preserves complete raw results, failed requests, per-endpoint histograms, workload mix, generator-limit flags and binary fingerprints. It removes each temporary database and server, including on failure.

Example, using already saved executable copies:

```sh
python3 benchmarks/compare.py \
  --control "$CHALLENGE_WORK/experiments/prepared-statements/baseline" \
  --candidate "$CHALLENGE_WORK/experiments/prepared-statements/candidate" \
  --think-scale 0.005 \
  --out "$CHALLENGE_WORK/experiments/prepared-statements/comparison"
```

The output directory must be new. The measured run uses 128 virtual users, a ten-second ramp, thirty measured seconds and a three-second tail. Think times and sessions are accelerated together. The database has 100,000 users and 10,000 articles. Generator, server and database share this six-core Apple Silicon Mac with 8 GiB RAM. These short local comparisons can select a candidate; they cannot be converted into official user counts or compared directly to leaderboard throughput. Background Mac activity and stochastic workloads remain sources of noise.

### Results

The control is the saved ReleaseSafe executable from commit `68280865c4b2ec8efe3c191493ba1f973e4c1a0c`. The candidate uses the same compiler, optimisation mode, database and process limits, with the prepared-query change described above. No other tests or builds ran during the six-run comparison. The later default rebuild has the same SHA-256 as the measured candidate.

| Run | Build | Requests/s | p95 ms | p99 ms | Errors / measured requests |
|---|---|---:|---:|---:|---:|
| 1 | Control | 3,281.3 | 30.655 | 42.655 | 0 / 98,439 |
| 2 | Prepared | 4,756.5 | 16.543 | 28.047 | 0 / 142,696 |
| 3 | Prepared | 4,523.6 | 17.471 | 26.719 | 0 / 135,707 |
| 4 | Control | 3,008.1 | 38.015 | 49.791 | 0 / 90,243 |
| 5 | Prepared | 4,289.5 | 21.071 | 32.671 | 0 / 128,684 |
| 6 | Control | 3,055.7 | 35.615 | 48.287 | 0 / 91,671 |

Median throughput increases **48.0%**, from 3,055.7 to 4,523.6 requests/s. The median of the per-run p95 values decreases from 35.615 to 17.471 ms, and the median p99 from 48.287 to 28.047 ms. Every prepared run exceeds every control run. There are zero errors across 687,440 measured requests, with approximately 5% writes in each run. All generator-limit flags are false. Host-wide CPU sampling is unavailable on macOS; the generator reports about 3.2–4.3% process CPU across the first three runs. I do not infer an official generator-capacity verdict from that.

Throughput drifts down across the experiment, so the alternating controls matter. The result supports keeping this change on the development workload. It does not prove a 48% improvement on the full seed or the official hardware. The complete JSON, endpoint distributions, binary hashes and transcripts remain under `work/experiments/prepared-statements/comparison/`, outside the submitted source.

The candidate passes twelve Zig unit checks, the unchanged official runner's 197 steps, normalized comparison of all 197 responses against the unchanged Go reference, and the existing 11/13/15/15/15 focused scenario groups. The optional unprepared build also passes the complete write gate and 197-step reference comparison. Linux object-only semantic compilation succeeds; a linked Linux runtime, clean installer and full-seed run remain outstanding.

## Experiment 2: bounded database concurrency

I compared one, two and four connections in the same implementation, including the same automatic recovery and session timeout. This isolates pool size from the earlier prepared-query change. One reactor owns all connections and dispatches the oldest queued request to an idle owner. Each owner retains its request until all stages and transaction boundaries are complete. No read batching, pipelining, dedicated write pool or data cache is added.

Build each setting with `-Ddb-connections=1`, `2` or `4` and the same ReleaseSafe optimisation. The harness accepts a third executable:

```sh
python3 benchmarks/compare.py \
  --control "$CHALLENGE_WORK/experiments/database-concurrency/one" \
  --candidate "$CHALLENGE_WORK/experiments/database-concurrency/two" \
  --third "$CHALLENGE_WORK/experiments/database-concurrency/four" \
  --order ABCCBAABC --think-scale 0.005 \
  --out "$CHALLENGE_WORK/experiments/database-concurrency/comparison"
```

The host, development seed, 128 virtual users, ten-second ramp, thirty-second measured windows and three-second tails match the first experiment. Every run gets a fresh clone. No tests or builds ran during these nine load runs. This is a new within-session comparison; I do not add or compound improvements from separate sessions.

| Run | Connections | Requests/s | p95 ms | p99 ms | Errors / measured requests |
|---|---:|---:|---:|---:|---:|
| 1 | 1 | 5,006.9 | 12.927 | 19.919 | 0 / 150,208 |
| 2 | 2 | 6,219.5 | 5.151 | 9.951 | 0 / 186,584 |
| 3 | 4 | 6,439.1 | 2.073 | 5.475 | 0 / 193,172 |
| 4 | 4 | 6,447.0 | 2.343 | 5.447 | 0 / 193,409 |
| 5 | 2 | 6,046.9 | 7.031 | 12.767 | 0 / 181,407 |
| 6 | 1 | 4,406.6 | 18.543 | 27.999 | 0 / 132,197 |
| 7 | 1 | 4,430.1 | 17.679 | 25.999 | 0 / 132,904 |
| 8 | 2 | 6,163.1 | 5.415 | 8.983 | 0 / 184,894 |
| 9 | 4 | 6,491.4 | 1.770 | 4.071 | 0 / 194,742 |

| Connections | Median requests/s | Median per-run p95 ms | Median per-run p99 ms |
|---:|---:|---:|---:|
| 1 | 4,430.1 | 17.679 | 25.999 |
| 2 | 6,163.1 | 5.415 | 9.951 |
| 4 | 6,447.0 | 2.073 | 5.447 |

All 1,549,517 measured requests succeed and all generator-limit flags are false. Four connections improve median throughput by 45.5% over one, and 4.6% over two, with lower tail latency in every four-connection run. I retain four as the current local default. At this think-time/user setting, the fastest variant approaches the offered workload, so the measurement does not establish its capacity ceiling. The full seed and official eight-vCPU target can need a different setting. Host-wide generator CPU remains unavailable on macOS.

Recovery validation covers stalled authentication, bounded retry backoff, isolated and repeated backend loss, prepared-statement/session rebuilding, lost COMMIT acknowledgement without replay, healthy-owner progress during a blocked write, statement-timeout rollback, a full project-cluster restart and all 197 unchanged conformance steps after recovery. See [RECOVERY.md](RECOVERY.md). The usual twelve unit checks and earlier API/fault regressions also pass.

Raw results, endpoint distributions and executable fingerprints are under `work/experiments/database-concurrency/comparison/`; fault-injection evidence is under `work/results/recovery/`. The default executable is checked against the measured four-owner fingerprint after rebuilding.

## Experiment 3: full-seed planning and queued tags groups

The official full seed was generated with unchanged code/schema and all count/content fingerprints verified. The generator's temporary data was removed. It contains 500,000 articles and uses 2,314 MiB. The unchanged 197-step suite passes for Zig and Go on successive fresh full clones, and all normalized responses match.

Before tuning SQL, I replaced the 256-client linear scans with a descriptor-aware configurable ceiling, a free list, an intrusive pending FIFO and an indexed deadline heap. A preliminary full-seed, 128-user A/B pair gave 6,186 versus 6,149 requests/s (about -0.6%, not a gain), with zero errors. The scheduler is retained for bounded scaling, not for a claimed throughput improvement at 128 users. Native testing opens 8,000 sockets and replaces 4,000 of them; the 100,000-slot test is simulated state, not live Linux sockets.

Eleven read query families/phases were profiled on the full seed using six prepared executions each under automatic and forced-generic plans. Only private session settings changed. Representative warmed planning/execution times in milliseconds were 0.273/0.168 versus 0.003/0.167 for the all-article page, 0.296/0.182 versus 0.003/0.174 for a tag page, and 0.096/0.027 versus 0.001/0.025 for a single article. These representative parameters do not establish every skew/offset plan. Raw EXPLAIN ANALYZE/BUFFERS JSON is preserved.

The current read path adds one prepared comments statement, combining article existence and newest-100 comments. This reduces a round trip and uses one statement snapshot. The SQL keeps explicit ordering and distinguishes missing articles from empty lists. Mutations retain their isolated parameterized transaction stages.

Queued tags groups take at most 32 reads from work already waiting before execution, scanning at most 64 queued candidates. No collection delay is added. A wire-proxy test observes 64 correct responses from six PostgreSQL executions; a later request executes a new query and sees an external insert. An injected SQL failure is delivered to all 64 recipients from two executions; subsequent requests recover. The exact number of executions depends on arrival/dispatch timing. This is evidence of grouping and freshness, not a standalone throughput claim.

I compared three builds, each with the same scheduler, four database owners, two bcrypt workers and twenty preparations:

| Build | Changes | Median requests/s | Median per-run p95 ms | Median per-run p99 ms |
|---|---|---:|---:|---:|
| A | ReleaseSafe, automatic plans, no tags groups | 7,532.7 | 61.887 | 80.767 |
| B | ReleaseSafe, forced generic plans, tags groups | 8,789.2 | 55.903 | 80.639 |
| C | Same tuning as B, ReleaseFast | 9,734.6 | 46.943 | 64.287 |

There are three runs per build in A-B-C-C-B-A-A-B-C order, on fresh full-seed clones, with 512 virtual users, a ten-second ramp, thirty-second measurement, three-second tail and think-scale 0.005. No other tests or builds ran during measurement. The compiler is Zig 0.17.0; the host is the same six-core, 8 GiB native Mac. All flags report no generator limit, but host-wide generator CPU is unavailable here, so this is not an official generator-capacity verdict.

B's median is 16.7% above A; C's is 29.2% above A. These compare combined candidates and do not isolate the separate generic-plan, grouping and compiler effects. ReleaseFast removes implicit Zig runtime safety checks; explicit parsing, size, authentication, transaction and ownership validation remain. Both the tuned ReleaseSafe and ReleaseFast paths pass the correctness regressions.

Every run has errors: A has 304/286/254, B has 296/371/333, and C has 280/317/300. All are 503 responses on login/registration, where the bounded two-worker password pool saturates. They are retained in throughput/error distributions; none are filtered out. Total error rates remain below 1%, but these failures motivate a separate bcrypt-admission comparison. A higher throughput number obtained while rejecting more logins is not sufficient to select the final build.

The setup commands also set session-only `jit=off`. This has no JIT effect in my non-LLVM native PostgreSQL build, but avoids compilation overhead for short statements on a JIT-capable target. No schema, indexes, global settings or durable-commit settings change.

Raw evidence is under `work/experiments/final-round/full-options/`, with the scheduler pilot under `full-pilot/` and query plans in `query-plans.json`. Historical experiments above remain separate; their percentages must not be added or compounded.

## Experiment 4: bcrypt admission and final build

Two and four bcrypt workers were compared with identical ReleaseFast, generic-plan, grouped-tags executables and four database owners. All authentication work remains bcrypt cost 10 against the current stored hash; the outstanding-job limit remains 16. The order is A-B-B-A-B-A, three runs each, with the same full seed and 512-user/think-scale 0.005 local settings as experiment 3.

| Workers | Median requests/s | Median per-run p95 ms | Median per-run p99 ms | Errors / requests across all three runs |
|---:|---:|---:|---:|---:|
| 2 | 8,610.2 | 55.839 | 73.343 | 726 / 848,724 |
| 4 | 8,422.0 | 65.311 | 88.063 | 36 / 783,195 |

Four workers reduce errors from 726 to 36 (95.0% fewer). They complete more real logins instead of rejecting them, consuming additional CPU shared with SQL. I choose four despite a small lower overall throughput median. These are repeated stochastic runs, not identical request traces; background/thermal drift is visible, and no performance claim is based on the first fast control alone. All failures remain 503 responses in the password path and remain included in the report. The final build is not described as error-free.

The selected defaults are ReleaseFast, prepared queries, forced generic plans, session JIT off, grouped queued tags, four database owners and four bcrypt workers. The default rebuild matches the measured four-worker executable byte for byte. Raw evidence and fingerprints are in `work/experiments/final-round/bcrypt-options/`.

| Control | Default | Allowed alternative |
|---|---|---|
| Optimisation | `build.sh`: ReleaseFast | direct `zig build -Doptimize=ReleaseSafe` |
| Prepared statements | `-Dprepared-queries=true` | `false` |
| Plan selection | `-Dgeneric-plans=true` | `false` for PostgreSQL auto |
| Queued tags groups | `-Dtag-batch=true` | `false` |
| Queued single-article groups | `-Darticle-batch=true` | `false` |
| Database owners | `-Ddb-connections=4` | 1–95 |
| Bcrypt workers | `-Dbcrypt-workers=4` | 1–8 |
| Outstanding bcrypt jobs | `-Dbcrypt-jobs=64` | 16–128 |
| Configured HTTP slots | `-Dmax-clients=131072` | 256–262144, descriptor-clamped |

Session JIT off and the eight-second statement timeout are fixed setup choices. None change global database settings. Build controls are diagnostic experiment choices, not runtime environment variables.

## Initial five-minute hold: sixteen outstanding bcrypt jobs

The selected executable ran with 512 virtual users, think-scale 0.005, a sixty-second ramp, 300 measured seconds and a fifteen-second tail. The generator is unchanged and co-located with the application and PostgreSQL on the six-core, 8 GiB Mac. The database is a fresh clone of the verified full seed. No builds or other tests ran during the hold.

| Measured requests | Requests/s | p95 ms | p99 ms | Errors | Error rate |
|---:|---:|---:|---:|---:|---:|
| 2,568,539 | 8,561.8 | 61.631 | 96.063 | 403 | 0.01569% |

All errors remain in the report. The local merged latency/error verdict passes and the generator reports no limit. Host-wide generator CPU is unavailable on macOS; this does not certify the official generator-capacity condition. The application stayed alive for the full run; sampled RSS was around 7 MiB (samples, not a peak or total host-memory figure). About 4.91% of requests are writes.

These latency/error values are inside the challenge thresholds, but this remains an accelerated native Mac workload with a co-located generator. It is not a capacity search, official user count or leaderboard score. It does not prove the same behaviour on the eight-vCPU Ubuntu host. Raw request/endpoint histograms, workload mix, fingerprints and generator metadata are preserved under `work/experiments/final-round/full-hold/`.

## Experiment 5: bounded password-queue headroom

The first long hold's low total error rate hid 395 rejected logins out of 8,376 (4.7%). I kept four bcrypt workers and tested 16 versus 64 outstanding jobs, including running/completed jobs awaiting collection. This adds bounded burst headroom without adding hashing threads, reducing cost, caching results or changing request deadlines. A build option retains the smaller control. An overload regression now sends 160 simultaneous logins and still verifies 503 under excess load while tags progress.

Two fresh-clone runs per queue size in A-B-B-A order use the same 512-user/full-seed/think-scale 0.005 settings:

| Outstanding jobs | Median requests/s | Median per-run p95 ms | Median per-run p99 ms | Errors / requests |
|---:|---:|---:|---:|---:|
| 16 | 8,636.2 | 61.951 | 97.503 | 51 / 518,170 |
| 64 | 8,527.3 | 63.583 | 100.607 | 16 / 511,638 |

The larger queue reduces measured errors from 51 to 16; median throughput is 1.3% lower. There are only two runs per setting, with visible run-to-run variation. The choice favours fewer dropped authentication attempts and bounded resource use. Auth, write/reference and fifteen unit checks pass. The default rebuilt executable matches the measured 64-job candidate byte for byte.

The selected 64-job build then completes a new five-minute hold, with the same 60-second ramp/300-second measure/15-second tail:

| Measured requests | Requests/s | p95 ms | p99 ms | Errors | Error rate |
|---:|---:|---:|---:|---:|---:|
| 2,817,230 | 9,390.8 | 52.351 | 78.079 | 12 | 0.000426% |

The full run remains a co-located native Mac stress test, not an official score. No builds or tests run alongside it. Compared with the earlier long hold, errors fall from 403 to 12; these sequential holds are not a controlled paired estimate of throughput gain. All failures are retained. The generator reports no limit, but host-wide CPU sampling is unavailable on macOS. Raw evidence is under `queue-options/` and `full-hold-64/` in `work/experiments/final-round/`.

## Normal-clock native hold: 8,000 real users

To separate real user count from accelerated clock demand, the selected build also runs 8,000 actual virtual users with `think-scale=1`, the full seed, a 60-second ramp, 300 measured seconds and 15-second tail. The generator and PostgreSQL remain on the Mac. Each virtual user owns its normal keep-alive connection; this is distinct from the earlier idle-socket test.

| Real users | Measured requests | Requests/s | p95 ms | p99 ms | Errors |
|---:|---:|---:|---:|---:|---:|
| 8,000 | 636,920 | 2,123.1 | 1.251 | 3.659 | 0 |

The run passes the local latency/error verdict and reports no generator limit. Host-wide generator CPU is unavailable on macOS. This establishes a successful 8,000-user native hold, not the maximum: no user-count capacity search was run. The Mac's existing descriptor ceiling prevents a comparable 100,000-socket test without changing host settings, which I do not do.

Observed normal demand is 0.265383 requests/s/user. Dividing the accelerated hold's 9,390.8 requests/s by this rate gives about 35,386 users' request traffic. That is a traffic conversion, not a tested population or Ubuntu prediction. Accelerated sessions impose much more bcrypt demand per browsing request. See BENCHMARKING.md for the separate authentication calculation, scenario table and optional cloud calibration plan. All raw evidence is under `work/experiments/final-round/normal-hold-8000/`.

## Final-check requirements

Clean Ubuntu 24.04 x86_64 installation, linked runtime and epoll request progress now pass in the unchanged upstream CI workflow. Target high-connection capacity and an organiser-run hold remain unmeasured. The five-minute native full-seed hold is still a co-located, accelerated experiment, not official capacity. A real leaderboard score requires the organiser's unchanged workload and separate load generators.

## Submission round: queued single-article reads

The final read optimisation batches up to 32 already queued single-article requests. Each request carries its own viewer and slug in typed PostgreSQL arrays and receives its own ordinal, flags and missing-article status. The statement enriches each distinct slug once. It adds no collection delay and retains no data after the closed group. Isolated reads keep the original one-article query. Page/count ordering and the durable mutation path are unchanged. A wire-level regression serves 64 mixed authenticated/anonymous/missing reads in two queries, checks array escaping, verifies a fresh external update on a later request and drains 64 SQL failures without poisoning the owners.

The control disables only `article-batch`; both builds have the same 21 preparations, four owners, four bcrypt workers, 64 outstanding jobs, ReleaseFast and generic plans. The unchanged generator uses fresh full-seed clones, 512 users, think-scale 0.005, ten-second ramps, thirty-second measurement windows and three-second tails in A-B-B-A-B-A order. No heavy builds or other test suites run during measurement. Existing Mac background work remains active; the machine also shows substantial swap use.

| Run | Article groups | Requests/s | p95 ms | p99 ms | Errors / requests |
|---|---|---:|---:|---:|---:|
| 01-A | off | 3,784.8 | 220.287 | 526.335 | 465 / 113,543 |
| 02-B | on | 3,635.1 | 195.455 | 752.127 | 430 / 109,054 |
| 03-B | on | 3,767.7 | 199.679 | 272.127 | 499 / 113,030 |
| 04-A | off | 2,986.6 | 238.079 | 987.135 | 605 / 89,598 |
| 05-B | on | 2,878.6 | 235.647 | 605.183 | 683 / 86,359 |
| 06-A | off | 3,100.0 | 259.839 | 489.471 | 488 / 92,999 |

Median throughput is 3,100.0 versus 3,635.1 requests/s (+17.3%), and median per-run p95 is 238.079 versus 199.679 ms. Median p99 increases from 526.335 to 605.183 ms. Median error rates are 0.525% and 0.441%; these are overload responses, not an error-free run. Not every adjacent pair improves, and substantial downward drift prevents treating +17.3% as a stable target-machine speedup. This session's rates must not be compared to earlier, less busy Mac sessions as an implementation regression or gain. The generator reports no limiting flag, but macOS host CPU sampling is unavailable.

A separate read-only full-seed EXPLAIN diagnostic uses forced generic plans, session JIT off, one warm-up and six measured repetitions. For 8 distinct articles, summed single-query planning/execution is 0.9935 ms versus 0.5585 ms for one group; for 32 it is 5.3240 versus 1.5525 ms. For repeated slugs, groups of 8/32 are also cheaper. Two repeated-slug reads can cost more (0.1990 versus 0.2265 ms), so batching is not a universal per-query win. These timings exclude network/HTTP cost and remain local diagnostics. Reduced execution count and the larger-group SQL savings support retaining the bounded option; they do not establish leaderboard capacity.

Sanitized aggregate results and binary fingerprints are in [article-groups.json](../benchmarks/results/article-groups.json). Complete local transcripts, endpoint distributions and query plans remain under `work/experiments/submission/`, outside Git. The final release is rebuilt from the same behaviour with the option enabled by default; final validation is listed in [VALIDATION.md](VALIDATION.md).

### Host contention found during the release hold

After the 8,000-user release hold, a process inventory showed two active preexisting VMware virtual machines and 5,295 MiB of used swap. Their elapsed process times place their startup after the first A/B control, during the comparison session. This is a material confounder: the arithmetic +17.3% median difference above does **not** establish an implementation-caused throughput improvement. The wire-execution and SQL-plan diagnostics remain evidence of less database work per group; the mixed-workload throughput benefit requires a controlled host. The VM workloads were not modified.

The release's full-seed normal-think-time hold (30-second ramp, 300 measured seconds, 15-second tail, same co-located generator) returned 562,572 requests, 1,875.24 requests/s, p95 2,127.871 ms, p99 3,901.439 ms and 54,987 HTTP 503s (9.774%). It **fails** the latency/error thresholds. The server stayed alive and the generator reports no limiting flag; the result is retained in article-groups.json rather than replaced with the earlier baseline's successful hold. Concurrent VM/memory contention prevents attributing the difference to the code or estimating target capacity from it.

# PR #79 / #82 optimization implementation and final verification

**Date:** 2026-10-27. **Status:** implemented and locally verified for follow-up review; no new official score.
**Implementation, audit and validation:** **GPT-6.1 Sol (max effort)**, at the author's request.

## Outcome

The backlog from [PR79_PR82_ANALYSIS.md](PR79_PR82_ANALYSIS.md) is implemented. The existing SEND_ZC pressure recovery,
notification barrier and asynchronous HTTP shutdown lifetime fixes are retained. A final audit additionally fixed PG
socket/buffer retirement, unacceptable identity encoding, and concurrent idempotent favorite counts.

Final native units passed **49/49 in both Safe and Fast**. Explicit full-seed validation passed **88/88 configurations**:
the original 80-case sweep plus eight added combined-feature/failure runs on unchanged production binaries. Both exact
repository verifiers, real low-memlock recovery, SQL comparisons and fresh sustained holds passed. The five-minute hold
completed **3,175,759 measured requests with zero errors**. A recovered PostgreSQL deadlock in the publication gate is
recorded below, not hidden by an error-free-log claim.

**This does not establish that we are faster than PR #79 or #82.** The final local ABBA comparison was effectively flat:
**13,162.69 candidate versus 13,125.44 baseline req/s (+0.28%)** at the tested offered load. That is not a convincing capacity
or throughput gain. Nor is a speedup over graded `e0cc458` established: the A/B baseline already included local EOF fixes,
and the local rig is not the official target. Optional target-dependent mechanisms remain off by default rather than being
enabled speculatively.

## What was implemented

| Backlog item | Implementation / important boundaries |
|---|---|
| One shared read statement | `src/packed.sql` / `src/packed.zig` combine eligible lists, feeds, articles, profiles and tags into one statement snapshot. `PACKED_READS=1` selects it; the default two-phase/per-kind/single paths remain available. |
| More completely packed results | Article entities are returned once, with narrow request headers, ordered page IDs and viewer-membership arrays. JSON renders directly from batch-owned row views rather than synthetic PostgreSQL rows. Borrowed PG bytes remain live through rendering. |
| Service-wide read pooling | `src/hub.zig` and `src/main.zig` add an optional separate coordinator with fork-shared SPSC rings, eventfd wakeups and backpressure. HTTP workers retain their multi-process descriptor headroom; writes/bcrypt remain local. IPC still has copying and scheduling costs. |
| Feed count proofs | Followee sets are reused within a statement/batch. At most eight batch-selected shared authors are probed for a 1,000th article; following a proven-heavy author establishes the SPEC's capped count. Sparse/mixed feeds retain an exact capped fallback. No hardcoded authors or cross-request result cache. |
| Low-overlap comments | Two-phase comment sharing is chosen by distinct-slug percentage (`COMMENTS_SHARED_PCT`, default 50), rather than forcing every comment read through shared enrichment. Packed plans leave comments on their dedicated path. |
| Independent read depth | `READ_DEPTH` inherits `PG_DEPTH` (normally 4), but can be tuned independently. Both clamp to 1–32. The adaptive idle-backend flush is preserved; no deliberate idle-read hold was reintroduced. |
| Response ownership / size classes | Normal rendering transfers its allocation into the send lifetime, removing the complete response copy. The existing 4 KiB slab cache is complemented by bounded power-of-two retention through 4 MiB. Live response memory is not capped by the idle pool limits. |
| Optional ACK policy | `ACK_DELAY=1` queues async `TCP_QUICKACK=0`, without disabling TCP_NODELAY. FD/generation retirement waits for the command's CQE; unsupported-operation results disable the option for that worker. |
| Selective gzip | `src/gzip.zig` uses libdeflate level 1. `GZIP=1` requires body-byte savings; `2` requires fewer estimated TCP segments. Quality values, explicit/wildcard exclusions, Content-Length, Vary, keep-alive and bodyless 204s are covered. |
| Bounded write collection / SQL arrays | `WRITE_GROUP_MAX` supports 1–128; `WRITE_WINDOW_US` optionally collects writes. `WRITE_ARRAYS=1` handles eligible homogeneous follow/unfollow, favorite/unfavorite and comment-create groups. Mixed/ineligible groups keep individual executions. Explicit BEGIN/COMMIT, commit-before-response and original isolated-retry encodings are retained. |
| Bcrypt policy | Optional real cost-10 startup calibration selects 1–4 lanes, unless `BCRYPT_LANES` is explicit. Idle bypass and a configurable bounded stale cutoff are available. Cost, password checks and normal thread priority are unchanged; stale rejections still count as errors. |
| Fused JSON work | SIMD clean-string scanning and copying are fused, and timestamps use a digit-pair table. Escaping and boundary cases have unit coverage. |
| Additional safe fast paths | Exact issued JWT payloads have a claims shortcut only after signature/algorithm checks, with expiry still checked. Other layouts use the general parser. Startup/reconnect Prepare/Describe validates result column counts and OIDs against decoders. |

The main integration lives in `src/server.zig`; SQL and encoding changes also touch `src/sql.zig`, `src/pg.zig`,
`src/api.zig`, `src/buf.zig`, `src/jw.zig`, `src/jwt.zig`, `src/bcrypt.zig` and `src/bcpool.zig`.
Bcrypt/reconnect helper stacks are 1 MiB for compatibility with the libc-linked thread implementation.

### Audit fixes and red/green evidence

1. **PG descriptor and buffer lifetime.** Previously, `pgFail` closed the numeric descriptor and reset active buffers while
   another send/receive could still be queued or in flight. It now marks the connection dead, synchronously shuts down only
   that failed socket, and retains the FD plus active buffers until both CQEs retire. Replacement I/O is generation-tagged;
   dead completions cannot submit partial-send tails or parse/rearm receives. Replacement adoption waits for retirement.
   The deterministic regression was **red before the fix** (`expected 3, found -1`) and is green in both unit builds.
   Normal success adds no shutdown syscall. Live backend-termination/recovery checks passed in the final matrices.
2. **Identity exclusion.** `identity;q=0` previously disappeared during negotiation, allowing a small or insufficiently
   compressible response to be sent in a forbidden encoding. Accepted enabled gzip is now forced in that situation,
   regardless of the normal threshold/savings test. Otherwise the response is empty **406**. A bodyless **204** is unaffected.
   Parser, response-policy and independent live decompression/same-socket checks cover this behavior.
3. **Concurrent favorite counts.** A conflicting insert/delete can wait for another transaction and then return no changed
   row while retaining its original statement snapshot. Using only `ins`/`del RETURNING` deltas produced true/0 or stale
   unfavorite counts. Single statements now reconcile snapshot viewer membership with the requested state; arrays reconcile
   all distinct targeted viewers per article. Controlled blockers reproduced **four failures before the fix**. The new
   `tests/favorite_counts.py` passes **16/16 normally and 16/16 with forced generic plans**, including COMMIT/ROLLBACK waits,
   duplicate targets, binary types and independently persisted rows. Unrelated concurrent writers retain normal snapshot
   semantics; this is not a claim of globally serializable counts.

## Defaults and dependency impact

The always-on changes include feed/count SQL, comment-plan selection, owned/pooled response buffers, fused serialization,
JWT parsing and result-shape checks, plus the reliability fixes above. The more workload-sensitive paths remain opt-in:

| Option | Retained default | Bounds / policy |
|---|---:|---|
| `PACKED_READS`, `READ_COORDINATOR` | 0 | Eligible packed reads / separate shared-read coordinator |
| `READ_DEPTH` | `PG_DEPTH` (4) | 1–32; independent of write depth |
| `COMMENTS_SHARED_PCT` | 50 | At most 100 |
| `WRITE_GROUP_MAX` | 32 | 1–128 |
| `WRITE_WINDOW_US`, `WRITE_ARRAYS` | 0 | Collection at most 10,000 µs / optional homogeneous arrays |
| `GZIP`, `ACK_DELAY` | 0 | Gzip 0–2 / optional async socket policy |
| `GZIP_MIN` | 1024 | Floored at 1024; identity exclusion can force smaller gzip |
| `SEND_ZC`, `SEND_ZC_MIN` | 1 / 256 | Existing bounded ENOMEM retry and notification ownership preserved |
| `BCRYPT_AUTO`, `BCRYPT_IDLE_MS` | 0 | Optional startup calibration / idle bypass |
| `BCRYPT_STALE_MS` | 9500 | 1,000–9,500 ms |

See [README configuration](README.md#configuration) for every knob. There is no globally fastest setting established by
these local tests. Gzip consumes CPU, ACK policy depends on the network/kernel, extra shared-read IPC can outweigh reuse,
and larger write collection can increase latency. Turning all options on is not justified by the measurements.

**New build/runtime dependency:** the binary links **libc and system libdeflate**, even when gzip is disabled.
`install.sh` installs `libdeflate-dev`; the hand-written production PostgreSQL client still does not use libpq.
`favorite_counts.py` uses libpq via Python ctypes **only for testing**. Builds passed with the installed libraries; a clean
Ubuntu bootstrap of `install.sh` was not executed locally. A container check was attempted, but the Docker daemon was
unavailable; no host Docker service or system settings were changed.

## Final correctness validation

All results below use the post-audit production/test sources, not the earlier EOF-only or pre-audit binaries.

| Check | Result |
|---|---|
| Native ReleaseSafe / ReleaseFast units | **49/49 in each** |
| Fast / Safe production builds | Passed |
| Base 20-case sweep, Fast/Safe × normal/fallback | **80/80 configurations, 364/364 checks** |
| Combined-feature/failure publication extension, same binaries | **8/8 configurations, 84/84 checks** |
| Cumulative 22-case/four-mode matrix coverage | **88/88 configurations, 448/448 checks, 17,336/17,336 conformance steps** |
| Exact repository wrapper, dev and full seed | **197/197 each** |
| Additional full-seed adaptive runs, Fast and Safe, 2 MiB memlock | Passed, **197/197 each**, with actual ENOMEM warnings |
| All local official-conformance executions combined | **18,124/18,124 steps** |
| Feed boundary suites | **52 suites / 3,328 checks** |
| Gzip / negotiation / independent decode suites | **20 suites** |
| Injected read/write failure cases | All **28 runs** proved injection and passed; all required array cases executed nonzero array groups |
| Favorite-conflict SQL tests | **16/16 normal + 16/16 generic**; eight confirmed waits each |
| Source list/feed SQL vs SPEC references | **300 cases, zero mismatches**; packed SQL is covered separately by API comparisons/fixtures |
| Strict actual-pressure streams, Fast/Safe × pbuf/poll | **4/4 passed**, zero-copy enabled, 2 MiB child memlock, same-socket assertions |
| Coordinator supervision | Killing only the owned coordinator caused supervisor exit 1 |
| Integration log audit | **564 base + 108 extension raw logs**: no 25P02, panic/assert or unexpected PG batch matches; one recovered 40P01 documented below |
| Source / binary integrity | 40 source/test/tool/build files unchanged during the base sweep and holds; the extension changed only verifier coverage, not production source/binaries |

Each final matrix clone **explicitly used `conduit_seed`**, with private-cluster identity, UTF8 and unchanged template counts
(**100,000 users / 500,000 articles**) checked. The earlier `final_suite.py` optimization sweep actually used `conduit_dev`;
its 80 passes are development-seed, pre-audit evidence and are **not** substituted for this new full-seed run.

Fallback matrices mean `NO_PBUF=1 SEND_ZC=0`. The four separate pressure-stream tests retain `SEND_ZC=1`, including the
poll/recv variants, and require the actual pressure warning. A configured memlock limit alone is not counted as recovery.
Unsupported ACK command results are unit-tested; rejection on a genuinely unsupported live kernel was not tested here.
The selected 88 configurations are broad regression coverage, not every possible combination of all knob values.

One initial integration wrapper attempt failed before startup because an **audit-only cache shim** supplied an unsupported
flag. Only that ignored shim was corrected; the exact wrapper retry passed. A post-PASS status-15 supervisor log was traced
to the wrapper's SIGTERM cleanup trap. Original failed audit records and their resolution are retained, not hidden.

### Combined-feature publication gate and recovered conflict

The added `all-features` and `failed-all-features` cases run the coordinator, packed reads with `READ_DEPTH=1`, gzip mode 2,
ACK delay, 128-member array writes with 1 ms collection, and bcrypt auto/idle/stale policies together. Both modes run known
reads, feed caps, HOT=0/1 differential, 200 concurrent writers, independent gzip, HTTP, streams and reconnect. They require
nonzero array groups and actual calibration in both HTTP workers; the failed variant proves both packed and write-group
failure warnings. All **eight** Fast/Safe × normal/fallback runs passed on fresh full-seed clones. All four normal runs
proved actual ENOMEM at 2 MiB child memlock; copied-send fallback correctly skips that assertion.

The gate observed one **real PostgreSQL `40P01` deadlock**, not an injected `s9999` error, between tag inserts arbitrating
uncommitted unique keys. Exact tag names/within-group lock order were not logged. `ON CONFLICT DO NOTHING` does not take
update locks on already committed tags. PostgreSQL aborted the affected group; the existing explicit rollback and isolated
member retry recovered. Independent checks confirmed **200/200 completed writers, zero bad responses, and exact persisted
article/comment/favorite totals**. No premature success or duplicate committed write was demonstrated.

This is a recovered transaction conflict, **not an error-free database-log result**. Retry is bounded: a further conflict
in a standalone retry can still surface as an error. Sorting one statement would not prevent cross-member group cycles, so
no speculative serialization or SQL rewrite was added just to suppress this log. No test suite can guarantee zero future
errors. The existing commit-before-response, rollback and no-ambiguous-write-replay guarantees remain intact.

The extension changed only `tests/verify.py`; original 20-case behavior was statically preserved, and all Zig source and
production binary hashes stayed unchanged. Evidence is in `.zig-cache/publication-check/summary.{md,json}`,
`production-findings.json`, `commands.json`, `verify-change.patch`, and per-run logs. The new private UTF8 PG cluster and
full seed were identity/count guarded, then stopped and removed; previous evidence and external data were untouched.

## Final-binary performance checks

### Environment and method

Linux **7.2.11-arch1-1**, **12 logical CPUs**, Zig 0.17.0, PostgreSQL 18.6 with 256 MiB shared buffers. Application,
PostgreSQL and the official repository load generator shared this local host, without CPU pinning. This is **not** the
isolated official 8-vCPU target.

Each run used a fresh full-seed clone, **two worker processes**, **8 PG connections total (6 read / 2 write)**,
`BCRYPT_WAIT_MS=250`, the default adaptive planner and zero-copy sends. Optional packed/coordinator/network/array/bcrypt
policies were off. The worker/connection topology was controlled explicitly; it is not the 12-CPU host's automatic default.
No expensive compilation or other verification suite was run concurrently with the measured loads.

All six final load runs had **zero errors**, passing merge verdicts and **`lg_limited=false`**, totaling **6,178,653 measured
requests**. Raw endpoint totals and HTTP status totals were reconciled with merged counts. Non-LG-limited at this offered
workload does not establish that server capacity was reached.

### ABBA: final candidate versus pre-optimization local baseline

The baseline is the pre-optimization source **with the existing EOF fixes**, not pristine scored `e0cc458`.
Both were ReleaseFast/native. Order was baseline / candidate / candidate / baseline; each run had 2,000 users,
`think-scale=0.04`, a 5-second ramp, 45-second measured hold and 2-second tail.

| Run | Build | req/s | p95 ms | p99 ms | Errors |
|---|---|---:|---:|---:|---:|
| A0 | Baseline | 13,132.89 | 1.762 | 7.007 | 0 |
| B1 | Final candidate | 13,135.22 | 1.506 | 3.401 | 0 |
| B2 | Final candidate | 13,190.16 | 1.461 | 2.783 | 0 |
| A3 | Baseline | 13,118.00 | 1.531 | 3.035 | 0 |

Mean throughput: baseline **13,125.44**, candidate **13,162.69 req/s**, **+0.28%**. Two short runs per build at a controlled
offered load do not establish a statistically meaningful improvement or a saturation knee. The earlier pre-audit ABBA was
also essentially flat (about 13,151 candidate versus 13,160 baseline). **No throughput/capacity win is claimed.**

### Sustained and constrained-memlock holds

Both final candidate runs used 20,000 users, `think-scale=0.5`, a 5-second ramp and 2-second tail:

| Measured hold | Child soft memlock | Requests | req/s | p50 ms | p95 ms | p99 ms | Errors | Verdict |
|---|---|---:|---:|---:|---:|---:|---:|---|
| 300 seconds | Local default, 8 MiB | **3,175,759** | **10,585.86** | 0.310 | **1.457** | **3.079** | **0** | PASS, not LG-limited |
| 60 seconds | **64 KiB** | **636,962** | **10,616.03** | 0.289 | **1.441** | **3.453** | **0** | PASS, not LG-limited |

The pressure run's intact per-worker snapshots prove **at least 582,916 recovered SEND_ZC ENOMEM completions**
(287,767 + 295,149). Counters include ramp/tail; interleaved stderr lines are excluded, so this is a process-lifetime lower
bound, not a measured-window request count. Every parsed complete fatal-send counter was zero.

These are robustness/local performance checks, not a new official 110k/120k capacity result. Earlier high-user probes were
load-generator-limited and are not evidence of a server capacity gain. The old scored EOFs have no remote errno data;
passing local checks does not prove the cause or elimination of every official EOF.

## Reproduction and evidence

Configure noninteractive PG admin access to an inactive challenge-seeded **test** template. The runner clones it, and its
backend-kill/table-lock tests must never be aimed at production. See [README tests](README.md#tests) for requirements.

```sh
bash build.sh
zig build test -Doptimize=ReleaseSafe -Dcpu=native
zig build test -Doptimize=ReleaseFast -Dcpu=native
zig build -Doptimize=ReleaseSafe -Dcpu=native --prefix zig-out/safe

python3 tests/verify.py --template conduit_seed --output zig-out/verify-fast-normal
python3 tests/verify.py --template conduit_seed --fallback --output zig-out/verify-fast-fallback
python3 tests/verify.py --template conduit_seed --binary zig-out/safe/bin/conduit --output zig-out/verify-safe-normal
python3 tests/verify.py --template conduit_seed --binary zig-out/safe/bin/conduit --fallback --output zig-out/verify-safe-fallback
python3 tests/verify.py --template conduit_seed --case adaptive --memlock-bytes 2097152 --output zig-out/verify-pressure

zig build sqldump
PGDATABASE=conduit_seed python3 tests/sqldiff.py 17 300
```

The commands are reproduction procedures; they require a running private seed instance. Final evidence remains locally in
ignored **`.zig-cache/perf-upgrade/`**:

- `audit-unit-{safe,fast}.txt`, `audit-build-{safe,fast}.txt`: final units/builds; `pg-retire-red-safe.txt`: pre-fix PG regression.
- `audit-{fast,safe}-{normal,fallback}/`, `audit-pressure-{fast,safe}/`, `audit-wrapper-*.txt`: full-seed integration evidence.
- `audit-20261027T034151Z-integration/audit-summary.{md,json}`: seed guards, counts, manifests, log audit and cleanup; its
  `audit-resolutions.json` preserves the audit-only shim/teardown issues.
- `audit-stream-*.{txt,server.log}`: strict actual-pressure streams.
- `audit-abba-*`, `audit-hold-300s.*`, `audit-pressure-load-60s.*`: raw/merged load JSON, merge verdicts and server logs.
- `audit-load-summary.json`, `audit-load.txt`, `audit_load.py`: final load aggregates, integrity checks and local harness.
- `.zig-cache/favorite-counts/`: separate controlled favorite-count red/green SQL evidence.
- `.zig-cache/publication-check/`: eight additional combined-feature runs, production conflict evidence and recovery,
  original-case preservation check, source/binary manifests, and new private-cluster cleanup.

| Binary | SHA-256 |
|---|---|
| Final Fast `bin/conduit` | `3ec6615ef46a7f9e31a86dac8a98f657ebf668a1c6633f11eefc35569ecc8db5` |
| Final Safe `zig-out/safe/bin/conduit` | `59bc90aed607bd7369a579d6086be1bb9d66cd54da0b7f7e3ed31384004815b7` |
| Local pre-optimization native baseline | `9e60b510d107cb2e40f8586ee6424056210e18f71e04abc3b28a92c7d1c03bfd` |

All owned app/load-generator processes and the private PostgreSQL cluster were stopped, and disposable clones were dropped.
The generated private `pgdata`, unused SQL_ASCII setup attempt and seed TSV directories were removed after verification;
logs and binaries remain. **The original external PG data directory was not used or modified.** No host memlock/sysctl
setting was changed; pressure limits applied only to child servers.

No schema, indexes or stored functions were added. No cross-request result/JWT/password cache, weaker authentication,
benchmark detection, non-durable commit, or ambiguous-write replay was introduced. The old official score remains tied to
`e0cc458`; an isolated official-target rerun is required before making any claim about beating PR #79 / #82.

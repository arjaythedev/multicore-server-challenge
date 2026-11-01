# PR #45 follow-up: optimization and local verification

## Current PR #79 / #82 implementation phase (locally verified follow-up)

The competitive optimization backlog is implemented, with conservative defaults retained for optional paths. See
[OPTIMIZATION_REPORT.md](OPTIMIZATION_REPORT.md) for the implementation, configuration decisions and performance evidence.
**Implementation and validation attribution: GPT-6.1 Sol (max effort)**, at the author's request.

The post-implementation audit also found and fixed three correctness issues:

- PostgreSQL failure handling now retains the failed socket and active send/receive buffers until both I/O completions
  retire. Replacement I/O is generation-tagged; stale completions cannot modify a new connection. A deterministic regression
  failed before this change (`expected 3, found -1`) and passes afterward.
- `Accept-Encoding` identity exclusions now force acceptable gzip even below the normal size/savings threshold, or produce
  an empty `406` when no supported representation is acceptable. Bodyless `204` responses remain bodyless.
- Single and array favorite/unfavorite counts reconcile the snapshot membership of targeted viewers with the requested
  state. Controlled concurrent conflict tests reproduced four stale-count failures before the SQL fix and pass afterward;
  unrelated concurrent writers still have normal statement-snapshot semantics.

### Final frozen-source correctness validation

| Check | Post-audit result |
|---|---|
| Native ReleaseSafe and ReleaseFast unit suites | **49/49 in each** |
| Production Fast and Safe builds | Passed |
| Base full-seed Fast/Safe × normal/fallback, 20 cases each | **80/80 configurations**, **364/364 checks**, **15,760/15,760 conformance steps** |
| Combined-feature/failure extension, same production binaries | **8/8 configurations**, **84/84 checks**, **1,576/1,576 conformance steps** |
| Cumulative 22-case/four-mode matrix coverage | **88/88 configurations**, **448/448 checks**, **17,336/17,336 conformance steps** |
| Exact repository wrapper, development and full seed | **197/197 on each** |
| Additional adaptive Fast and Safe, 2 MiB child memlock | Both passed, **197/197 each**, with actual `SEND_ZC` `ENOMEM` evidence |
| Combined local official-conformance executions | **18,124/18,124 steps** |
| Feed-cap boundary regressions | **52 suites / 3,328 checks** passed |
| Independent gzip / negotiation / same-socket regressions | **20 suites** passed, including forced small gzip and empty `406` |
| Injected read/write failures | All **28 injected-case runs** confirmed the injection and passed; all required array-write cases executed nonzero array groups |
| Favorite SQL, normal and forced generic plans | **16/16 each**, with eight independently confirmed conflict waits per run |
| Source list/feed SQL against SPEC references | **300 cases, zero mismatches**; not a packed-SQL differential |
| Coordinator fail-fast supervision | Owned coordinator kill caused supervisor exit 1 |
| Production/test/build integrity | All **40 files unchanged** during the base sweep and holds; the extension changed only verifier coverage, not production source or binaries |
| Server/test log audit | **564 base + 108 extension raw logs**: no `25P02`, panic/assert or unexpected PostgreSQL batch matches; one recovered `40P01` documented below |
| Formatting / syntax / whitespace | `zig fmt --check src`, six changed Python test-file compilations, shell syntax and `git diff --check` passed |

Every matrix clone explicitly used **`conduit_seed`**, with the private cluster's identity, UTF8 encoding and unchanged
**100,000 users / 500,000 articles** checked. Fallback is `NO_PBUF=1 SEND_ZC=0`; it is not zero-copy-pressure coverage.
The separate adaptive pressure checks retain zero-copy and require the actual warning.

The earlier optimization-phase `final-*` 80-configuration runner used **`conduit_dev`**, despite its separate load checks
using the full seed; do not label that earlier matrix full-seed. Those pre-audit artifacts remain separate and unchanged.
The final-binary sustained-load rerun is recorded separately in [OPTIMIZATION_REPORT.md](OPTIMIZATION_REPORT.md).

Evidence root: `.zig-cache/perf-upgrade/`. `audit-{fast,safe}-{normal,fallback}/`, `audit-pressure-{fast,safe}/`,
`audit-wrapper-*.txt` and `audit-20261027T034151Z-integration/audit-summary.{md,json}` hold the final integration results,
seed guards, manifests and log classification. `pg-retire-red-safe.txt` records the deterministic PG regression's pre-fix
failure; `audit-unit-{safe,fast}.txt` records the 49-test green runs. Favorite red/green evidence remains separately in
`.zig-cache/favorite-counts/`.

One initial **audit-only wrapper shim** used an unsupported `--global-cache-dir` flag before server startup. The ignored
shim was corrected and the exact wrapper rerun passed; production code was unchanged. A wrapper's post-PASS supervisor
status 15 was traced to its official SIGTERM cleanup trap, not a request-time failure. Both original audit records and the
resolution are preserved in `audit-20261027T034151Z-integration/audit-resolutions.json`.

### Combined-feature publication extension and recovered transaction conflict

The base 80-configuration sweep and the eight-configuration extension ran separately on the **same final production
binaries**; this was not a single rerun of all 22 cases. `tests/verify.py` adds `all-features` and `failed-all-features`,
combining the read coordinator, packed reads, gzip, asynchronous ACK, array writes, bounded collection, independent read
depth, bcrypt calibration and adaptive polling. The failure variant injects both packed-read and write-group errors.

Both cases passed in Fast/Safe × normal/fallback modes, including feed caps, HOT=0/1 differential reads, 200 concurrent
writers, HTTP, same-socket streams and PostgreSQL reconnects. All eight configurations proved actual array groups and
bcrypt calibration in both workers; all four failure variants proved both injected failure paths. All four normal-I/O
configurations proved actual `SEND_ZC` `ENOMEM` at 2 MiB child memlock. The original 20 cases were statically verified
unchanged. A full 22-case invocation now has 111 ordinary summary checks, or 114 with all three pressure proofs, and
4,334 conformance steps; those per-invocation totals describe the runner, not an additional executed sweep.

One **real PostgreSQL `40P01` deadlock** occurred in the Safe/normal failure variant between tag inserts arbitrating
uncommitted unique keys. This was not an injected failure or an update lock on already committed tags. Exact tag names
and lock order were not logged. Existing write-group rollback and isolated member retry recovered: independent checks
confirmed **200/200 completed writers, zero bad responses and exact persisted article/comment/favorite totals**. No
production SQL change was made. This is a recovered transaction conflict and latency caveat, not evidence of lost writes;
retry is bounded, so another standalone conflict could still surface an error. These results do **not** guarantee that
all future workloads or logs will be error-free.

Extension evidence: `.zig-cache/publication-check/summary.{md,json}`, `production-findings.json`, `commands.json`,
source manifests, `structure-check.json`, `verify-change.patch` and raw per-run logs. The deadlock is recorded at
`postgres-matrix-safe-normal.log:1863–1871`, with independent writer results in
`safe-normal/failed-all-features-writes.txt`. The extension used a separate private UTF8 full-seed cluster and removed
its owned processes, database data and generated seed TSVs after verification. Earlier evidence was retained unchanged.

A clean Ubuntu bootstrap was not run. The Docker executable is installed, but the daemon was unavailable; no container
validation is claimed and no host service or system setting was changed. The new runtime dependency is `libdeflate`
(and libc), installed by `install.sh` through `libdeflate-dev`.

### Final-binary sustained load and cleanup

Four strict pressure-stream runs passed with zero-copy enabled: Fast/Safe × provided buffers/poll, each with a 2 MiB child
memlock limit and actual ENOMEM evidence. The subsequent controlled full-seed ABBA comparison averaged **13,162.69 candidate
versus 13,125.44 baseline req/s (+0.28%)**, effectively flat rather than proof of a capacity or throughput gain.

Two further full-seed final-candidate holds used two worker processes, 8 total PG connections (6 read / 2 write),
20,000 users, `think-scale=0.5`, 5-second ramp and 2-second tail, with optional tuning paths off:

| Measured hold | Child soft memlock | Requests | req/s | p95 / p99 | Errors | Verdict |
|---|---|---:|---:|---|---:|---|
| 300 s | Local default 8 MiB | **3,175,759** | **10,585.86** | **1.457 / 3.079 ms** | **0** | PASS, not LG-limited |
| 60 s | **64 KiB** | **636,962** | **10,616.03** | **1.441 / 3.453 ms** | **0** | PASS, not LG-limited |

Intact worker snapshots in the pressure hold establish **at least 582,916 recovered SEND_ZC ENOMEM completions**
(287,767 + 295,149), including ramp/tail; interleaved stderr lines are excluded. Every complete parsed fatal-send counter
was zero. All six final ABBA/hold runs totaled **6,178,653 measured requests with zero errors**. Raw endpoint/status counts,
merge verdicts and generator-limited flags were reconciled. The same-host, offered-load-controlled runs do not establish
a saturation knee or official capacity. See [OPTIMIZATION_REPORT.md](OPTIMIZATION_REPORT.md) for environment and caveats.

`audit-load-summary.json`, `audit-load.txt`, `audit-abba-*`, `audit-hold-300s.*`, `audit-pressure-load-60s.*` and
`audit-stream-*` preserve these results under `.zig-cache/perf-upgrade/`. Final SHA-256 values:

- Fast: `3ec6615ef46a7f9e31a86dac8a98f657ebf668a1c6633f11eefc35569ecc8db5`.
- Safe: `59bc90aed607bd7369a579d6086be1bb9d66cd54da0b7f7e3ed31384004815b7`.

All owned processes and private PostgreSQL were stopped, clones dropped, and the generated private `pgdata`, unused
SQL_ASCII setup attempt and seed TSV directories removed. Logs/binaries remain. The original external PG data directory
was not used or modified; no host memlock/sysctl setting was changed. An available test seed is needed for reproduction.

The sections below preserve the completed **earlier EOF-only** and original PR validation phases. Their 34-test and
32-configuration counts describe those phases, not the current suite. No follow-up changes have an official score yet.

---

## Earlier connection EOF follow-up starting from e0cc458

**Starting point:** merged `e0cc4585c49d4b8021b41c8bb6b249e2bccaa1cf`. The connection EOF fixes described here combine
zero-copy pressure fallback and an asynchronous-shutdown lifetime barrier. They were subsequent, then-uncommitted
changes, not part of that scored commit, and are included in this follow-up contribution. **Local validation of that
phase is complete** as recorded below; a fresh reviewer-side benchmark is still needed. PR #45 is already merged.

**Implementation and validation attribution:** **GPT-6.1 Sol (max effort)**, at the author's request.

### Official baseline and scope

The [latest maintainer comment on PR #45](https://github.com/arjaythedev/multicore-server-challenge/pull/45#issuecomment-6420772705)
reports that `e0cc458` was **merged at #2**: **110,000 users held for 5 minutes**, **28,835 req/s**, p50 21.2 ms,
**p95 162.4 ms**, **p99 476.7 ms**, **0.77% errors**, with no server restart. The earlier GET stalls and false 404s were
resolved. The passing hold still had **66,926 `conn_closed`/EOF transport errors**, about 0.8% of reads and 0.05% of writes.
The 120,000-user hold failed with **2.74% errors** despite p95 of 285 ms.

**No official server errno data is available.** Neither the locally reproduced `ENOMEM` close nor the source-proven
shutdown lifetime gap establishes the cause of every official EOF, elimination of those EOFs, or 120,000-user capacity.
The isolated native HTTP EOF described below has no proven causal link to either mechanism.

### Proven SEND_ZC pressure mechanism and A/B controls

The baseline was the authentic archived `e0cc458` source with **only a diagnostic warning added**, not an injected send
failure. With the child server's soft `RLIMIT_MEMLOCK` set to **2 MiB (2,097,152 bytes)**, the existing 6 MiB stream test
produced a real zero-copy send CQE: **`res=-12` (`ENOMEM`), `flags=2` (`MORE`)**. The original error branch closed an
otherwise healthy TCP connection; the client raised **`RemoteDisconnected` while the server remained alive**.

| Archived original control | Child soft memlock | `SEND_ZC` | Existing 6 MiB stream test |
|---|---:|---:|---|
| Local default limit | 8 MiB | 1 | Passed |
| Constrained limit, copied sends | 2 MiB | 0 | Passed |
| Constrained limit, zero-copy sends | 2 MiB | 1 | Failed with `RemoteDisconnected`; real `ENOMEM` CQE, server alive |

The 8 MiB default is the local control environment's limit, not a claim about every host's default.

### Separate native EOF investigation (before the shutdown fix)

One ReleaseSafe / 2 MiB adaptive HTTP run saw a **fresh GET return EOF after chunk-abuse checks** (`res=None`, about
0 seconds). **`zc_nomem=0` at that failure**; the observation does not support attributing this EOF to `ENOMEM`. The subsequent
60,000-request pipeline check passed. The failed run is preserved under `final-pressure-safe/` and `final-pressure-safe.txt`;
it is investigation evidence, **not a passing combined validation**.

Before the shutdown-lifetime fix, the following attempts to reproduce the native EOF all passed:

- **15 full HTTP repeats and 1,500 chunk-abuse cycles** across zero-copy/low-memlock, copied-send/low-memlock and
  zero-copy/default-memlock controls.
- **64-client close-churn probes** with provided-buffer and poll/recv receive paths, each validating **51,200 responses**.

These passing probes do not prove absence of a lifetime race, establish what caused the isolated EOF, or show that the
subsequent shutdown fix cured that native failure. They remain pre-fix investigation, not final combined-suite passes.

### Source proof of the asynchronous SHUTDOWN lifetime gap

`closeConn` queued asynchronous `SHUTDOWN`, but `maybeFinishClose` waited only for receive, send and zero-copy notification
completion. It could therefore queue `CLOSE` and permit numeric-FD reuse while shutdown was still pending.

The audited **upstream Linux v7.2.11** paths explain why retaining only the numeric FD was unsafe:
[`io_shutdown_prep`](https://github.com/gregkh/linux/blob/v7.2.11/io_uring/net.c#L125-L153) sets **`REQ_F_FORCE_ASYNC`**;
[`io_queue_iowq` / `io_wq_submit_work`](https://github.com/gregkh/linux/blob/v7.2.11/io_uring/io_uring.c) defer file assignment
until worker execution. Pending shutdown work could thus outlive the old descriptor and reach a reused numeric slot.
Installed Arch-specific backports were not independently audited. This is source-level lifetime proof for that kernel
path, **not an end-to-end causal reproduction of the isolated native EOF**.

A deterministic unit regression was **red before the fix: 30/31 in ReleaseSafe, `expected 1, found 2`**. After tracking
shutdown lifetime, the expanded suite passed **34/34 in both ReleaseSafe and ReleaseFast**, cleanly with expected injected
warnings quieted only in unit tests. Evidence is `shutdown-red-safe.txt`, `shutdown-green-safe.txt` and `shutdown-green-fast.txt`
under `.zig-cache/connection-eof/`.

### Combined fix, diagnostics and regression coverage

- **Bounded pressure fallback:** on `SEND_ZC` `ENOMEM`, retry once with ordinary copied `SEND`, using the unchanged
  response buffer. Failure of that copied retry follows the bounded error path rather than looping indefinitely.
- **No pressure-based disable:** transient `ENOMEM` does not globally disable zero-copy or make future sends ineligible.
  Unsupported-operation `EINVAL`/`EOPNOTSUPP` still disables zero-copy only for the affected worker.
- **Notification lifetime:** retain the `MORE` notification barrier even for a negative send completion. The response
  buffer is not released early because the copied retry or a notification completed first.
- **Shutdown lifetime barrier:** `Conn.shutdown_live` tracks the asynchronous `SHUTDOWN` request with an FD/generation-tagged
  CQE. Retirement now also waits for shutdown; **successful or failed completion** retires that barrier. Poll-cancel
  completions have a distinct ignored tag and cannot retire it accidentally.
- **Closed connections stay closed:** fallback must not resurrect a closed connection. The extended unit case covers all
  **24 receive/send/notification/shutdown completion permutations** when closing during fallback, alongside copied-retry
  failure bounds, notification ordering and future zero-copy eligibility.
- **Unchanged request footprint:** `Conn` remains **64 bytes** and the shutdown bookkeeping adds **no syscall on the
  successful-request path**.
- **Observable pressure:** per-worker `STATS` includes `zc_nomem` and `send_errors`. The first pressure event emits
  `SEND_ZC returned ENOMEM; falling back to copied SEND` **once per affected worker**.
- **Unmasked stream failures:** the expanded stream test includes **16 concurrent persistent clients**, each reading a
  large/small/large response sequence, with **no automatic client retry**. The final test also asserts socket-object identity
  and rejects `Connection: close`, so a reconnect between responses cannot masquerade as keep-alive success.
- **Permanent close/reopen HTTP regression:** `tests/httptest.py` now runs **32 concurrent clients × 32 close/reopen cycles**,
  validating **2,048 responses with no automatic retries**. This is distinct from the earlier exploratory 64-client probes.
- **Unit-only warning quieting:996539** expected injected warnings are scoped quiet only in unit tests. The completed 34-test
  Safe/Fast runs are clean and quiet; production warnings and the live pressure runner's warning requirement remain intact.

### Final validation of the combined fixes

These are newly executed results on the combined production fixes, not reused pre-shutdown passes or historical totals.
The earlier `final-*` runs, the interrupted attempt and the isolated failed HTTP run remain preserved separately.

| Check | Final result |
|---|---|
| Deterministic shutdown regression before adding the barrier | Red: **30/31 Safe**, `expected 1, found 2` |
| Expanded unit suite, ReleaseSafe and ReleaseFast/native | **34/34 passed in each**, including all 24 close-completion permutations; expected injected warnings are quiet only in units |
| Production ReleaseFast and ReleaseSafe/native builds | Passed |
| Full eight-case matrix, Fast/Safe × normal/fallback I/O, full seed | **32/32 configurations passed** |
| Additional adaptive verifier, Fast and Safe, child memlock 2 MiB | Both passed, including mandatory evidence of actual `ENOMEM` recovery |
| Exact repository `test/run.sh`, development and full seeds | **197/197 passed on each seed** |
| Conformance across 32 matrix cases, two pressure cases and two wrappers | **7,092/7,092 steps passed**: 6,304 + 394 + 394 |
| Independent fixture-backed reads across the 34 verifier configurations | **53,504 responses checked**, no mismatches or incomplete responses |
| Batched/non-batched reads, ordinary and duplicate-heavy workloads | **108,000 comparisons**, zero mismatches; all three rounds per file counted, not just the footer |
| Concurrent writers, normal and injected group failures | **2,000/2,000 completed workers** across ten runs, with independent persisted-total checks |
| HTTP close/reopen regression | **12,288 responses** across six adaptive runs, no retries or EOFs |
| Single-connection 60,000-request HTTP pipeline | All six runs passed, **360,000 responses** total; **2.9–3.6 seconds** per run |
| Backend termination/recovery and malformed-request checks | Passed in all four matrices and both pressure-aware adaptive runs |
| Actual-pressure streams, Fast/Safe × pbuf/poll, `SEND_ZC=1`, 2 MiB | All four passed; repeated after adding strict same-TCP-socket assertions, all four passed again |
| Final reference/test server-log audit | **68 logs**: no `25P02`, unexpected PostgreSQL/batch messages, panics or assertion failures |
| Formatting, Python syntax and whitespace | Zig formatting and all eight Python test-file syntax checks passed; `git diff --check` passed |

The eight cases are `adaptive`, `per-kind`, `planner`, `split`, `failed-per-kind`, `failed-planner`, `failed-writes`
and `threads`. Fixed-window cases use 20 ms to exercise batching. Fallback means `NO_PBUF=1 SEND_ZC=0`; the separate
poll/recv pressure-stream runs retain `SEND_ZC=1`. The threaded case exercises two workers in one process, while the
load checks below exercise three worker processes. Failure injections must actually appear in server logs.

Scheduling checks completed queued idle bursts within **0.92–1.72 ms** and queued reads after backend release within
**1.09–1.40 ms**, across the six adaptive runs. These are well below the 75 ms scheduling limit; independent adaptive/threaded
fixture latency checks also passed their 50 ms threshold.

One final **test-only** change tightened persistent-client socket identity after the full matrices. It was rerun in all
four actual-pressure build/receive combinations as `strict-stream-*`; production binaries were unchanged. Matrix results
and these later targeted checks are recorded separately rather than pretending all artifacts have the same test-file hash.

The changed Zig source has no editor diagnostics. Changed Python tests have no diagnostic errors, but style/annotation
warnings remain, including the warning about `preexec_fn` in the **single-threaded** verifier parent. Child HTTP test threads
run in separate processes; do not embed that process-launch helper in a multithreaded parent without revisiting it.
`send_errors` in abuse/abandoned-reader tests can reflect deliberate client disconnects and is not required to stay zero there.

### New full-seed local load checks

Official repository load generator; fresh full-seed clone per run; **20,000 users**, **120-second measured hold**,
10-second ramp and tail, `think-scale=1`. Production defaults on this 12-logical-CPU host were kept: **three worker
processes**, three read plus one write PostgreSQL connection per worker, and **`BCRYPT_WAIT_MS=250`**. Normal provided-buffer
receives and `SEND_ZC=1` remained enabled in both runs. Only the second server's soft memlock limit was deliberately reduced.

| Child memlock | Measured requests | req/s | p50 | p95 | p99 | Errors / 404s | Merge verdict |
|---|---:|---:|---:|---:|---:|---|---|
| Local default, 8 MiB | 636,575 | 5,304.79 | 0.257 ms | **1.093 ms** | **2.303 ms** | **0 / 0** | PASS, not LG-limited |
| Pressure, 64 KiB | 635,160 | 5,293.00 | 0.253 ms | **1.058 ms** | **2.287 ms** | **0 / 0** | PASS, not LG-limited |

Raw endpoint status counts were independently reconciled with both merged totals: **1,271,735 measured requests**,
including **1,207,661 GETs**, only HTTP 200/201/204, and **zero reported transport errors**. A successful `loadgen run`
exit alone was not treated as a passing verdict; both `loadgen merge` verdicts and generator-limited flags were checked.

The pressure run's intact per-worker snapshots prove **at least 535,895 recovered `SEND_ZC` ENOMEM completions**
(189,817 + 175,656 + 170,422). These counters span process lifetime, including ramp/tail, not just measured requests.
The three processes emitted exactly **three pressure warnings**, one each; every recorded fatal-send counter was zero.
Worker `STATS` writes can interleave on shared stderr, so only complete-format lines are counted. An earlier loose parse
estimated 562,125 recoveries; that estimate is superseded by this conservative intact-line lower bound. Raw load-generator
JSON and its zero-error totals are unaffected by stderr interleaving.

This is a realistic-workload recovery/performance check, **not an official 110k/120k capacity run or a statistically
controlled throughput comparison**. App, database and load generator shared the local host. The isolated pre-shutdown
HTTP EOF remains unattributed, and fresh official-box validation is still required.

### Fresh environment and evidence

This follow-up used a **newly initialized private PostgreSQL cluster**, not a copy of the old external cluster used for
the historical report. The fresh full seed contained **100,000 users and 500,000 articles**. Environment: Linux
`7.2.11-arch1-1`, 12 logical CPUs, Zig 0.17.0, PostgreSQL 18.6, Go 1.27.3, 256 MiB PostgreSQL shared buffers; no CPU pinning.
This is not the official isolated 8-vCPU target. No new runtime dependency, schema/index change or response cache was added.

All owned app/load-generator processes and the private PostgreSQL instance were stopped; per-run databases were dropped.
The owned `pgdata/`, `seed-dev/` and `seed-full/` directories were then removed. **The original external seed cluster was
not started or modified.** Logs, binaries, seed-setup logs, raw/merged load JSON and audit summaries remain; no host limit
or sysctl was changed. Reproduction requires an available seed template, not the removed disposable cluster.

Evidence root: **`.zig-cache/connection-eof/`**. Paths below are relative to that directory:

- `baseline-source/`, `baseline/`, `baseline_probe.py`, `baseline-probe.txt`: archived-baseline material and reproduction helper/output.
- `baseline-default.txt`, `baseline-default.server.log`: original 8 MiB control.
- `baseline-low-memlock-copy.txt`, `baseline-low-memlock-copy.server.log`: original 2 MiB copied-send control.
- `baseline-low-memlock-zc.txt`, `baseline-low-memlock-zc.server.log`: original 2 MiB zero-copy failure and diagnostic CQE evidence.
- `fixed-pressure-fast.txt`, `fixed-pressure-fast.server.log`, `fixed-pressure-safe.txt`, `fixed-pressure-safe.server.log`:
  provided-buffer pressure-stream passes **before the shutdown fix**.
- `fixed-pressure-fast-poll.txt`, `fixed-pressure-fast-poll.server.log`, `fixed-pressure-safe-poll.txt`,
  `fixed-pressure-safe-poll.server.log`: poll/recv pressure-stream passes **before the shutdown fix**, retaining `SEND_ZC=1`.
- `final-{fast,safe}-{normal,fallback}/` and matching `.txt` logs, plus `full-regressions-summary.json`: the earlier
  **pre-shutdown** 32-configuration matrix evidence, not the new combined result set.
- `interrupted-safe-normal/`, `interrupted-safe-normal.txt`: the preserved interrupted earlier attempt.
- `final-pressure-safe/`, `final-pressure-safe.txt`: preserved isolated HTTP EOF run; **not a passing combined validation**.
  `final-pressure-fast/` and `final-pressure-fast.txt` also belong to the pre-shutdown pressure-run investigation.
- `http-full-*.txt`, `http-close-{zc-low,copy-low,zc-default}.server.log`, `http_close_probe.py`: repeat/chunk investigation
  across the three controls; those passes occurred before the shutdown fix.
- `close-churn-results.json`, `close-churn-{pbuf,poll}-before-shutdown-fix.server.log`, `close_churn_probe.py`: the earlier
  64-client close-churn investigation, not proof that the lifetime gap caused the isolated EOF.
- `shutdown-red-safe.txt`, `shutdown-green-safe.txt`, `shutdown-green-fast.txt`: deterministic missing-barrier failure and
  the clean 34/34 Safe/Fast unit runs after the fix.
- `verified-{fast,safe}-{normal,fallback}/`, `verified-pressure-{fast,safe}/`, matching outer `.txt` logs and
  `verified-regressions-summary.json`: completed combined-fix matrices and pressure-aware verifier runs.
- `verified-stream-*` and `strict-stream-*` `.txt` / `.server.log` pairs: completed real-pressure stream checks; the latter
  include the final same-socket assertions. `verified-wrapper-conduit_{dev,seed}.txt` records both exact verifier passes.
- `load-{default,pressure}-20000.json`, matching `.merged.json`, `.merge.txt` and `.server.log`: raw and merged load evidence.
- `verified-load-summary.json` and `verified-matrix-audit.json`: reconciled request totals, conservative intact-line recovery
  counters, per-mode scheduling/pipeline measurements and production binary SHA-256 values.
- `final-builds-summary.json`, `final-unit-*.txt`, `final-build-*.txt`, `final-python.txt`: build, cached unit recheck and syntax
  evidence. The actual uncached 34-test runs are recorded in `shutdown-green-{safe,fast}.txt`.
- `setup-dev.txt`, `setup-full.txt`, `postgres.log`: fresh seed/cluster setup and shutdown evidence. Generated TSV directories
  and `pgdata/` were removed after verification.

### Reproduce the constrained-memlock check

Use binaries rebuilt with **both** the copied-send pressure fallback and shutdown-lifetime barrier, and configure
`PGHOST`, `PGPORT`, `PGUSER` and noninteractive admin authentication
for the private cluster. Select an inactive full-seed template; the examples use `conduit_seed`, as in the historical
instructions. Application processes must be **unprivileged and have no `CAP_IPC_LOCK`**, which can bypass the limit.
The inherited hard memlock limit must allow the requested soft limit.

These commands are reproduction instructions, not additional completed runs:

```sh
python3 tests/verify.py --template conduit_seed --case adaptive --memlock-bytes 2097152 --output .zig-cache/connection-eof/reproduce-fast-pressure
python3 tests/verify.py --template conduit_seed --binary zig-out/safe/bin/conduit --case adaptive --memlock-bytes 2097152 --output .zig-cache/connection-eof/reproduce-safe-pressure
```

`--memlock-bytes` changes **only child-server soft `RLIMIT_MEMLOCK`**, not the runner's or PostgreSQL's limits. With
`SEND_ZC=1`, the constrained-memlock adaptive case requires the actual pressure warning; setting a limit alone is not
proof that the kernel returned `ENOMEM`. `--fallback` sets `NO_PBUF=1 SEND_ZC=0` and skips the zero-copy pressure assertion,
so a fallback-matrix pass must not be presented as zero-copy pressure coverage.

---

## Historical report: validation leading to e0cc458

> The original pre-merge report below records work starting at `9b75e6f` that led to `e0cc458`. Its validation totals,
> local load measurements, copied-cluster environment and cleanup evidence are preserved as history, not results for the
> subsequent EOF/optimization follow-up. Its then-pending official rerun was subsequently completed and the PR merged, as recorded above.

Verified 2026-10-26, starting from `9b75e6f` on branch `zig-uring-harshit`.

**Implementation and validation:** performed by **GPT-6.1 Sol (max effort)** at the author's request, including reproduction, debugging, code changes, regression tests and local load verification.

**Historical status at this report's cutoff:** both reported review failures were reproduced on the original source and fixed; the build recorded here passed the local checks below. The official rerun was pending at that time. It subsequently scored `e0cc458` at #2 and the PR was merged; the subsequent EOF/optimization follow-up is separate.

### Review findings and root causes

The [reviewer comment addressed by this historical report](https://github.com/arjaythedev/multicore-server-challenge/pull/45#issuecomment-6414650660), before the later merged `e0cc458` run, reported 570 users held for five minutes, 151 req/s, p95 90.8 ms, p99 103.4 ms, 0.75% errors and 338 unexpected 404s. The earlier comment reported the same two symptoms. Conformance already passed, so conformance alone was not sufficient evidence of a fix.

| Finding | Root cause | Fix |
|---|---|---|
| GET tails near 100 ms while CPU was idle | Adaptive scheduling bypassed the hold for a lone read, but not for every queued batch. Statement affinity could also prefer a busy backend over an idle one. | `src/server.zig`: flush staged reads at **any queue depth** when a read backend is idle, including after an in-flight reply; never route to a busy backend instead of an available idle one. Adaptive thresholds are capped by `READ_WINDOW_US`; zero really disables holding. |
| False 404s for existing article, comments and profile lookups; incorrect empty filtered lists/counts | Inline text slices escaped loop-local `StageItem` copies. Per-kind arrays and planner key interners could therefore retain overwritten stack bytes. | `src/server.zig` and `src/plan.zig`: borrow keys from stable, owned batch/plan items. No additional allocation is needed on the production hot path. |

An archived, independently built original `9b75e6f` reproduced both symptoms against private SQL-created fixtures: successful read bursts had p95 around 105–110 ms, and a mixed burst returned false 404s and wrong filter results. The same fixture tests pass on the fixed source, including distinct and duplicate keys, different viewers/pages, missing resources, and 127/128/129-byte inline/heap boundaries. Planner ownership tests also failed against the original planner.

`TCP_NODELAY` and real write `BEGIN`/`COMMIT` boundaries were already present at the starting commit; neither was removed or presented as a new fix.

### Additional correctness and performance fixes

- **Failed write-group recovery:** an extended-protocol error skips the queued `COMMIT` until `Sync`, leaving the connection in an aborted transaction. Queue an explicit `ROLLBACK` before retries. Reserve a separate internal reply token and verify that rollback returns an idle transaction state.
- **Write isolation during group outcome:** unrelated standalone writes must not be pipelined behind an unresolved group. Otherwise they can execute in the aborted transaction before rollback, even when a rollback was subsequently queued. Submission and FIFO draining now exclude those connections. The failure path is verified by actual log evidence, not merely by setting an environment switch.
- **Bounded write queues:** group submission honors both the configured pipeline depth and the physical reply-ring capacity. If draining standalone writes fills a connection, the next group waits and resumes on a later completion, without needing a new incoming request. Regression tests cover depths 1, 4, 32 and the internal 64-slot ring boundary, including wraparound and the rollback token. The public `PG_DEPTH` maximum remains 32.
- **Zero-copy send lifetime:** retain the response until both the final send and the zero-copy release notification complete, in either order. Latch promised notifications before handling partial/error completions. Each already-submitted attempt retains its own zero-copy identity, so it can fall back independently even after support has been disabled. Capability fallback is worker-local rather than mutating shared configuration. Zero-byte sends close instead of retrying forever. Connection metadata remains within 64 bytes.
- **Large grouped writes:** heap-backed wire payloads no longer narrow their length into a 16-bit inline length. The previous path trapped for payloads above 65,535 bytes in ReleaseSafe. A 128 KiB unit case and live 6 MiB article round trips exercise this.
- **Fallback receive progress:** multishot poll notifications now drain `recvfrom()` until `EAGAIN`, retrying `EINTR`. The previous one-read-per-notification path stalled a 60,000-request pipeline after approximately 5,615 responses; the fixed path completes it.

No new runtime dependency, application schema/index change, response cache, result cache or benchmark-specific application behavior was introduced. Writes whose commit outcome is unknown after disconnection are not replayed.

### Regression tests and verifier reliability

`src/all_tests.zig` now imports the server and planner, which previously were absent from the unit-test root.

New tests:

- `tests/read_regression.py`: independent SQL-created fixtures and exact response expectations, released in 64-preconnected-client bursts. Checks identity, timestamps, counts, viewer flags, empty/nonempty threads, legitimate 404s, duplicate/mixed/filter keys and inline boundaries. Optional latency checks exclude connection setup and JSON validation. Private fixtures are cleaned up.
- `tests/streamtest.py`: a 6 MiB article create/read, three slow-reader ordered pipelines, ten abandoned large responses, and fixture cleanup.
- `tests/reconnect.py`: deliberately terminate app-role backends in a disposable database; require every outage probe to finish with a correct 200 or shaped JSON 503, reject transport failures, then require 50 successful recovery reads.
- `tests/verify.py`: bounded matrix runner, fresh database clone per case, owned server process-group cleanup, mandatory failure-injection evidence, per-check logs and `summary.json`. It can build the repository's official conformance binary or accept `--conformance`.

Existing tests were tightened:

- `tests/batchdiff.py`: reset results every round; propagate thread failures; require every response; use deterministic author ordering. A previous round's successful slots cannot hide a later incomplete round.
- `tests/writetest.py`: require all writers to finish, immediately read back article/comment/profile state, and compare persisted favorite/comment/unique-tag totals against independent read-only SQL. Existing favorites are accounted for, making repeated runs meaningful.
- `tests/httptest.py`: validate response framing, truncation and endpoint-specific status codes. The 60,000-response check parses incrementally with bounded retained memory rather than repeatedly scanning all prior output; sender errors propagate.
- `tests/sqldiff.py`: compare complete ordered rows and counts; fail on mismatches, failed dumps, malformed/missing/out-of-order results or subprocess failures. Statements have a timeout; 100-case batches print progress instead of silently waiting through the entire run.

### Original validation results (historical)

Earlier exploratory runs are not included in the totals below. **Every total in this historical table belongs to the
original pre-merge validation, not to the current EOF follow-up.**

| Check | Final result |
|---|---|
| Unit tests, safe-optimized default | **25/25 passed** |
| Unit tests, ReleaseFast/native | **25/25 passed** |
| Production `bash build.sh` and ReleaseSafe/native build | Passed |
| Exact repository `test/run.sh`, development seed | **197/197 passed** |
| Exact repository `test/run.sh`, full seed | **197/197 passed** |
| Full eight-case matrix, ReleaseFast, normal I/O | All passed |
| Full eight-case matrix, ReleaseSafe, normal I/O | All passed |
| Full eight-case matrix, ReleaseFast, forced fallback I/O | All passed |
| Full eight-case matrix, ReleaseSafe, forced fallback I/O | All passed |
| Conformance inside those 32 matrix configurations | **6,304/6,304 steps passed**; **6,698** including the two exact-wrapper runs |
| Independent fixture-backed reads in the 32 configurations | **50,176 responses checked** |
| Batched vs non-batched responses, normal and duplicate-heavy workloads | **108,000 comparisons**, zero mismatches/incomplete responses |
| SQL vs SPEC reference, full seed, random seeds 1 and 17 | **3,000 cases**, zero mismatches |
| Concurrent writers, normal and injected group failures | 200/200 in every run; exact persisted totals. **2,400 completed workers** across the matrices and four extra depth-limit runs |
| Extra forced-failure write runs at `PG_DEPTH=1` and `32` | Passed in ReleaseFast/normal and ReleaseSafe/fallback; rollback exercised, no `25P02` |
| 60,000 pipelined requests on one connection | All answered in **3.4 s fast/normal, 3.6 s safe/normal, 3.0 s fast/fallback, 2.8 s safe/fallback** |
| Large-response / slow-reader / abandoned-reader tests | Passed in all four build/I/O combinations |
| Backend termination and recovery | Passed in all four matrices; strict reconnect-only reruns also passed in all four combinations, each with 480 outage probes and 50 clean recovery reads |
| Final matrix server-log audit | No `25P02`, unexpected PostgreSQL batches, panics or assertion failures in the 64 reference/test server logs |
| Formatting, Python syntax, whitespace | Changed Zig files pass `zig fmt --check`; all eight test Python files compile; `git diff --check` passes |

The eight cases are `adaptive`, `per-kind`, `planner`, `split`, `failed-per-kind`, `failed-planner`, `failed-writes` and `threads`. Fixed-window read cases use a 20 ms hold to exercise batching rather than accidentally testing only individual statements. The threaded case uses two workers in one process. Fallback means `NO_PBUF=1 SEND_ZC=0`.

#### Deterministic scheduling regression

The runner preconnects clients, pauses only its own server to queue a burst, and then resumes it. A separate test first blocks a backend with a table lock, queues more reads, then releases the backend. These test the idle and busy-to-idle paths without interpreting Python thread dispatch spread as server delay.

| Build / I/O | Maximum idle-burst completion | Completion after blocked backend release |
|---|---:|---:|
| Fast / normal | 0.92 ms | 2.06 ms |
| Safe / normal | 1.63 ms | 1.18 ms |
| Fast / fallback | 1.14 ms | 1.56 ms |
| Safe / fallback | 1.05 ms | 1.11 ms |

All are below the regression threshold of 75 ms, rather than near the old 100 ms timer. Separate fixture latency bursts pass a 50 ms maximum-request threshold in adaptive and threaded configurations.

### Sustained local load results (historical)

Official repository load generator, full 500,000-article seed, a fresh clone for each run. Normal production `start.sh` and default application settings were used: **3 worker processes**, each with 3 read + 1 write PostgreSQL connections, default adaptive mode and **`BCRYPT_WAIT_MS=250`**. No test failure switches or reduced bcrypt wait were enabled. Ramp/tail were 10 seconds each, with `think-scale=1`.

Local environment: Linux `7.2.11-arch1-1`, x86-64, 12 logical CPUs, Zig 0.17.0, PostgreSQL 18.6, Go 1.27.3. Server, PostgreSQL and load generator shared the host without CPU pinning; the copied PostgreSQL test cluster used 256 MiB shared buffers. This is **not** the official isolated 8-vCPU target, and the two different-duration runs are not a capacity curve.

| Users | Measured hold | Requests | req/s | p50 | p95 | p99 | Errors | 404s | Loadgen verdict |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 570 | 300 s | 45,636 | 152.12 | 0.465 ms | **1.332 ms** | **3.209 ms** | **0** | **0** | PASS, not LG-limited |
| 5,000 | 60 s | 80,197 | 1,336.62 | 0.262 ms | **0.916 ms** | **1.420 ms** | **0** | **0** | PASS, not LG-limited |

Raw endpoint status counts were independently summed and matched to the merged totals: only 200, 201 and 204 occurred. Across both measured windows there were **125,833 requests**, including **119,652 GETs**, with zero 404s, 5xx responses or reported transport errors. Both `loadgen merge` commands exited successfully; a zero exit from `loadgen run` alone was not treated as a passing performance verdict.

Representative GET tails at the reviewer's 570-user load:

| Endpoint | Requests | p95 | p99 |
|---|---:|---:|---:|
| Article detail | 9,137 | 0.893 ms | 1.247 ms |
| Comments | 9,126 | 0.500 ms | 0.756 ms |
| Profile | 2,433 | 0.638 ms | 0.995 ms |
| Article list | 5,381 | 0.980 ms | 1.263 ms |
| Feed | 3,627 | 1.377 ms | 1.934 ms |

Every measured GET endpoint had p99 below 2 ms at 570 users; the highest GET maximum was 6.215 ms. At 5,000 users the highest GET p99 was 1.566 ms and the highest maximum was 17.135 ms. The recurring 100 ms read shelf did not appear in these runs.

### Reproduce the historical checks

Run from this submission directory. Configure noninteractive PostgreSQL admin access through the normal `PG*` settings, put `psql` on `PATH`, and have an inactive seeded template available. The matrix needs permission to clone/drop databases and inspect/lock its disposable clone. The application uses the seed's `conduit/conduit` role over TCP. See the README's matrix-runner requirements. In a sandbox, give Zig a writable absolute `ZIG_GLOBAL_CACHE_DIR`; this run used this checkout's `.zig-cache/global`.

```sh
zig build test --cache-dir .zig-cache --summary all
zig build test -Doptimize=ReleaseFast -Dcpu=native --cache-dir .zig-cache --summary all
bash build.sh
zig build -Doptimize=ReleaseSafe -Dcpu=native -Dstrip=false --prefix zig-out/safe --cache-dir .zig-cache --summary all
zig build sqldump -Doptimize=ReleaseSafe --cache-dir .zig-cache --summary all

PGDATABASE=conduit_seed python3 tests/sqldiff.py 1 1500
PGDATABASE=conduit_seed python3 tests/sqldiff.py 17 1500

TEMPLATE=conduit_dev bash ../../test/run.sh .
TEMPLATE=conduit_seed bash ../../test/run.sh .

python3 tests/verify.py --template conduit_seed --output zig-out/verify-fast-normal
python3 tests/verify.py --template conduit_seed --binary zig-out/safe/bin/conduit --output zig-out/verify-safe-normal
python3 tests/verify.py --template conduit_seed --fallback --output zig-out/verify-fast-fallback
python3 tests/verify.py --template conduit_seed --binary zig-out/safe/bin/conduit --fallback --output zig-out/verify-safe-fallback

zig fmt --check src/server.zig src/plan.zig src/all_tests.zig src/main.zig
python3 -c 'import pathlib; [compile(p.read_text(), str(p), "exec") for p in pathlib.Path("tests").glob("*.py")]'
git diff --check
```

The runner builds official conformance from `../../bench`; pass `--conformance` with a previously built binary to skip that build. Full-seed matrix logs here used `.zig-cache/verification/conformance`.

For a running production-default server on its own disposable full-seed clone, the measured load commands were equivalent to:

```sh
.zig-cache/verification/loadgen run -target http://127.0.0.1:3100 -users 570 -ramp 10s -measure 300s -tail 10s -articles 500000 -think-scale 1 -secret multicore-server-challenge -run-id pr45-local-570 -out zig-out/load-570.json
.zig-cache/verification/loadgen merge -o zig-out/load-570.merged.json zig-out/load-570.json

.zig-cache/verification/loadgen run -target http://127.0.0.1:3100 -users 5000 -ramp 10s -measure 60s -tail 10s -articles 500000 -think-scale 1 -secret multicore-server-challenge -run-id pr45-local-5000 -out zig-out/load-5000.json
.zig-cache/verification/loadgen merge -o zig-out/load-5000.merged.json zig-out/load-5000.json
```

Use a unique run ID if repeating on the same database. The actual recorded runs used UUID-suffixed IDs retained in the raw JSON. To build the official load generator from the repository, run `go build -o ../submissions/zig-iouring-harshitkhandelwal208/.zig-cache/verification/loadgen ./cmd/loadgen` from `../../bench`.

### Historical evidence, cleanup and limits

Local artifacts remain under ignored `.zig-cache/verification/` (not part of a Git commit):

- `baseline-confirmed/`: authentic original-build reproduction. Earlier exploratory baseline logs are not used as evidence.
- `final-fast-normal/`, `final-safe-normal/`, `final-fast-fallback/`, `final-safe-fallback/`: per-test output, reference/test server logs and machine-readable `summary.json`.
- `final-checks.txt`: complete matrix, write-depth and exact verifier-wrapper output.
- `sqldiff-seed1.txt`, `sqldiff-seed17.txt`: both 1,500-case SQL comparisons.
- `final-writes-*-depth*.txt` / `.log`: extra forced-group-failure runs.
- `strict-reconnect*.txt` / `.log`: reconnect checks after transport failures were made an explicit failure condition.
- `final-load-570.json`, `final-load-5000.json`, matching `.merged.json`, `.merge.txt` and `.server.log`: raw/merged load evidence and production-default startup logs.

**Historical cleanup (original report only):** all owned application/load-generator processes and the disposable PostgreSQL copy were stopped, and per-run databases were dropped. The approximately 15 GiB disposable PostgreSQL data-directory copy was removed after verification; the original external seed cluster was not started or modified. Useful logs and raw load results were retained. No system package was installed.

Limits and intentionally unchanged behavior:

- This original local validation was not a proof against every possible race or a replacement for an official rerun; that rerun later took place at `e0cc458`. Pathological kernel completion/disconnect orderings were covered by targeted unit cases and live large-response tests, not an exhaustive kernel fault-injection campaign.
- Busy PostgreSQL backends can still cause ordinary queuing; `READ_WINDOW_US` is a hold cap, not an end-to-end latency guarantee. Fixed-window mode remains an explicit opt-in. Queued standalone writes retain priority over subsequent groups; a permanently saturated standalone backlog can delay grouped writes.
- Default bcrypt batching still waits up to 250 ms. Login p95 was about 293 ms / 313 ms in these two runs, with zero errors; this is distinct from the fixed GET timer bug. Authentication tuning was not changed without a separate throughput/latency study.
- Python diagnostics have no errors in the changed test files, but style/annotation warnings remain. Two pre-existing type-checking errors in the untouched historical `benchmarks/parse_run.py` were not changed; that script was not used for these results.
- The older README and competitive-analysis experiment tables were marked historical/superseded. This report's pre-merge review status was later superseded by the official **merged / #2** result at `e0cc458`; the subsequent EOF/optimization follow-up is separately scoped above.

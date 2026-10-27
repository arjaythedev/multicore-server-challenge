# Competitive Analysis

Historical comparison of **`zig-iouring-harshitkhandelwal208`** against a leaderboard snapshot and competing submissions,
with current local implementation status kept separate from measured historical phases.
Data sources are labelled: **[LB]** = the official LEADERBOARD.md snapshot used for the original comparison (8-vCPU box),
**[RIG]** = our earlier local test rig (see README for setup).

> **Historical tables:** The leaderboard and local-rig tables predate the adaptive-flush, lookup-key lifetime, EOF and
> PR #79 / #82 follow-up changes. They do not measure current defaults or establish current leaderboard superiority.
> The separate official **`e0cc458` result was merged at #2: 110,000 users held for 5 minutes**, as reported in the
> [maintainer comment](https://github.com/arjaythedev/multicore-server-challenge/pull/45#issuecomment-6420772705).
> The rig's one-server-thread/one-Postgres-thread budget is not comparable to that official 8-vCPU box.

## Current local implementation and evidence boundaries

The [PR #79 / #82 comparison](PR79_PR82_ANALYSIS.md) is **pre-implementation history**. Its optimization backlog is now
implemented locally, with subsequent correctness-audit fixes; it is no longer a list of features we lack. Source-checked
mechanisms/defaults are summarized in §6 and [README.md](README.md#optimizations-and-why). The runtime now links **libc +
libdeflate**, installed via `libdeflate-dev` by `install.sh`; production PG access still uses our own wire client, not libpq.

The **current native unit suite passed 49/49 in ReleaseSafe and ReleaseFast**, and final production builds passed.
Explicit full-seed validation passed **88/88 configurations** (80 base plus eight combined-feature/failure runs on the
same production binaries), plus both exact verifiers and real-pressure checks. An earlier `final_suite.py` sweep used the **development seed, not the full seed**; it remains separate. The
**34/34 units and 32/32 full-seed configurations** below describe only the earlier EOF phase.

The final local ABBA comparison was essentially flat (**+0.28%** at the offered workload), not a demonstrated capacity
or throughput win. The final five-minute hold completed **3,175,759 measured requests with zero errors**, not LG-limited;
that is still local, not official capacity evidence. See [OPTIMIZATION_REPORT.md](OPTIMIZATION_REPORT.md) and the new
phase of [VERIFICATION.md](VERIFICATION.md) for final settings, metrics and artifacts. The [pre-audit observations in the
README](README.md#historical-pr-79--82-experiments-before-the-final-audit) and comparison tables below remain historical.

**Implementation and documentation attribution: GPT-6.1 Sol (max effort)**, at the author's request.

---

## 1. Official Leaderboard Context

The [latest PR #45 maintainer rerun](https://github.com/arjaythedev/multicore-server-challenge/pull/45#issuecomment-6420772705)
scored **`e0cc458` at #2**, held **110,000 users for 5 minutes**, and merged the submission: **28,835 req/s**,
p50 21.2 ms, **p95 162.4 ms**, **p99 476.7 ms**, **0.77% errors**. The earlier ~100 ms GET stalls and false 404s were
resolved; the server did not restart. The 120,000-user hold failed with **2.74% errors** (p95 285 ms).
The passing hold still had **66,926 `conn_closed`/EOF transport errors**, about 0.8% of reads and 0.05% of writes.

**Retained local connection EOF fix, not part of that score:** constrained-memlock testing reproduced a real `SEND_ZC`
`ENOMEM` completion closing a healthy connection in archived `e0cc458`. Copied-send fallback preserves the response buffer
and notification barrier without disabling future zero-copy sends. A second source-proven gap allowed numeric-FD retirement
before asynchronous `SHUTDOWN` completed. `Conn.shutdown_live` now holds that barrier through success or failure of the
FD/generation-tagged completion; poll-cancel completions are separately ignored. `Conn` stays 64 bytes with no additional
successful-request syscall.

**Historical EOF-phase validation:** the shutdown regression was red before the fix; that phase's combined unit suite
passed **34/34 in both Safe and Fast**, including 24 receive/send/notification/shutdown completion permutations. The
EOF-phase production fixes passed **all 32 full-seed matrix configurations**, two additional pressure-aware verifier runs,
all four actual-pressure stream modes and the exact verifier on both seeds. Two **20,000-user / 120-second local holds**
in that phase passed with **1,271,735 measured requests and zero errors**, not LG-limited. The 64 KiB pressure run's intact worker snapshots prove **at least 535,895
recovered ENOMEM completions** over process lifetime, including ramp/tail; interleaved stderr lines are excluded.
These checks do not establish capacity on the official box or a statistically controlled performance improvement.

A separate native EOF in a Safe/2 MiB HTTP run had `zc_nomem=0`; repeated HTTP/chunk and close-churn probes passed before
the shutdown fix. **Native EOF causality is not proven. Remote errno data is unavailable: neither local mechanism is
established as the cause of all 66,926 official EOFs, and no 120k capacity is claimed.** See the
[README](README.md#historical-local-connection-eof-phase) and [VERIFICATION.md](VERIFICATION.md) for phase-specific evidence.

Historical top-entry snapshot (official 8-vCPU box, 5-minute holds), not a live ranking. Consult
[LEADERBOARD.md](../../LEADERBOARD.md) for the current leaderboard:

| # | Users | Submission | PR | req/s | p95 ms | p99 ms | CPU: app / Postgres |
|--:|--:|---|---|--:|--:|--:|---|
| 1 | 100,000 | rust-tokio-Scooter1337 | #7 | 26,279 | 119 | 185 | 20% / 70% |
| 2 | 95,000 | csharp-sockets-jh-d | #22 | 24,696 | 493 | 737 | 21% / 75% |
| 3 | 84,000 | c-iouring-tigokraft | #10 | 21,262 | 339 | 421 | 18% / 80% |
| 4 | 84,000 | cobol-gnucobol-benmandrew | #15 | 21,292 | 361 | 461 | 20% / 75% |
| 5 | 84,000 | csharp-kestrel-xeonfx | #8 | 20,906 | 404 | 467 | 25% / 74% |
| 6 | 80,000 | rust-mio-foovoo | #11 | 20,710 | 474 | 752 | 18% / 75% |
| 7 | 68,000 | cpp-asio-c-hatton | #4 | 17,887 | 94 | 174 | 27% / 71% |
| 8 | 65,000 | goose-native-tbsvttr | #32 | 17,125 | 27 | 721 | 18% / 71% |


---

## 2. Historical Local Rig: CPU per Request [RIG]

All measurements on the same earlier local rig (README § Historical results), 22,000 users, two rounds each:

| Submission | Postgres µs/req | App µs/req | Total µs/req | req/s | steady p95 ms |
|---|--:|--:|--:|--:|--:|
| **historical build (100 ms window)** | **46** | **33** | **79** | 11,112 | 138 |
| #47 (WorriedArrow), default window | 55 | 37 | 92 | 11,528 | 32 |
| #59 (semyonfox) | 105 | 36 | 141 | 11,614 | 3.3 |
| #7 (Scooter1337) | 124 | 38 | 162 | 11,672 | 2.1 |
| #64 (touhidsiddiqueeraj-bit) | 124 | 39 | 163 | 11,653 | 2.1 |
| historical build, planner off | 144 | 33 | 177 | 11,666 | 1.0 |
| earlier build (`ed2e521`) | 147 | 34 | 181 | 11,658 | 1.0 |
| #53 (fourneau) | 199 | 38 | 238 | 11,591 | 1.1 |
| #10 (tigokraft) | 188 | 44 | 232 | 11,618 | 0.9 |
| #22 (jh-d) | 213 | 43 | 256 | 11,658 | 1.0 |

In this historical sample, the 100 ms build used 46 µs of Postgres CPU per request, with shared enrichment in the
two-phase planner, but its p95 was about 138 ms versus 1–3 ms for the non-batching builds. That latency/CPU trade-off
predates the current idle-backend flushing behavior and is not a current comparison or an official ranking result.

---

## 3. Historical Local Rig: Saturation Sweep [RIG]

Historical head-to-head at the knee, same rig, one server thread + one Postgres thread. Pass/fail labels use the local
comparison thresholds described in the README, not official acceptance:

| Build | Last Pass | First Fail | Knee (est.) |
|---|---|---|---|
| historical build, 100 ms window (default at the time) | 38,000 users: p95 360 ms (2/2) | 40,000 users: p95 526–567 ms (0/2) | ~39,000 |
| #47, default window | 38,000 users: p95 397 ms (1/2) | 40,000 users: p95 813 ms (0/2) | ~39,000 |
| earlier build (`ed2e521`) | 28,000 users: p95 291 ms | 32,000 users: p95 623 ms | ~29,500 |

At 38,000 users in these historical runs:

| Metric | #47 | historical build | Delta |
|---|--:|--:|---|
| req/s | 17,800 | 18,155 | +2.0% |
| steady p95 ms | 397 | 279 | −30% |
| Postgres µs/req | ~51 | 47 | −8% |
| total µs/req | ~84 | 76 | −10% |

Both tested builds held about the same number of users (~39,000) on this historical budget, with the 100 ms build
using about 10% less CPU per request. The load generator saturated around 40,000 users on this rig. These results neither
predict the current local follow-up's capacity on the 8-vCPU box nor supersede the official `e0cc458` hold.

---

## 4. Memory: Connection Overhead

Current idle keep-alive metadata costs **64 bytes per `Conn` table slot** (indexed by fd), plus the kernel socket.
Receive buffers come from a 16,384-slot shared provided-buffer ring and are not per-connection. The RSS figures below
are historical local measurements; they have not been remeasured for the current checkout:

| Connections | RSS |
|--:|--:|
| 100,000 idle | ~23 MB |
| 50,000 busy | ~11 MB per worker process |

Current API responses transfer the rendering allocation into the send lifetime rather than copying it. Per worker,
the **256 × 4 KiB fast slab cache** remains alongside **11 power-of-two response-pool classes, 4 KiB–4 MiB**. Each class
retains at most 64 buffers and 256 KiB, or one buffer for larger classes; excess/non-class allocations and sizes above
4 MiB are freed rather than pooled. These bounds cover idle retained storage, not live responses, gzip workspace,
coordinator IPC or total RSS. Buffers remain owned until partial sends and zero-copy notifications retire.

Exact per-connection memory for other submissions was not measured here; their leaderboard CPU percentages do not
establish relative connection-memory overhead.

---

## 5. Bcrypt: 4-Way SIMD Kernel

Historical timings on the rig's Ryzen 7 7445HS (one core):

| Mode | Time for 4 hashes | Effective per hash |
|---|--:|--:|
| Sequential (`std.crypto.pwhash.bcrypt`) | ~160 ms (4 × 40 ms) | 40 ms |
| 4-lane interleaved kernel (`bcrypt.zig`) | ~55 ms | ~13.7 ms |

Current defaults remain **four lanes**, a **250 ms** collection window and normal-priority hashing threads. Optional
`BCRYPT_AUTO=1` calibrates 1–4 lanes using real cost-10 hashes at startup unless `BCRYPT_LANES` is explicit. `BCRYPT_IDLE_MS=0`
disables idle-window bypass; a positive interval lets the primary hasher dispatch a partial batch after idle time, not
change its thread priority. `BCRYPT_STALE_MS` defaults to **9500 ms**, clamped **1000–9500**; stale jobs get 503 before the
load generator's 10 s timeout. Rejections are still errors, and these policies have no established official capacity gain.

---

## 6. Current Mechanisms and Configuration

### PR #79 / #82 backlog implemented locally

These are implementation facts, **not additive speedup estimates**. Optional policies are deliberately not all enabled by
default; see the [full configuration reference](README.md#configuration).

| Area | Current implementation / default |
|---|---|
| Single-statement packed reads | `PACKED_READS=0`; when enabled, eligible list/feed/article/profile/tag plans return distinct article entities and narrow request headers with ordered IDs/viewer membership; direct JSON rendering borrows the PG buffer until all dependent responses are rendered. Comments and login/user lookups remain dedicated |
| Feed count work | Batch-local followee reuse in per-kind/two-phase/packed paths; at most **8 batch-selected shared authors** get a 1,000th-article proof. Exact capped-count fallback for other viewers, including combined sparse authors; no cross-batch result cache |
| Comment overlap | `COMMENTS_SHARED_PCT=50`, capped at 100; two-phase sharing requires at least two staged comments and a distinct-slug ratio at or below that threshold. Packed plans always exclude comments |
| Service-wide read pooling | `READ_COORDINATOR=0`; when enabled, a separate coordinator owns read backends/batching via fork-shared SPSC rings and eventfd wakeups. Multi-process HTTP, local writes and bcrypt are retained; IPC copying/queueing is not free |
| Independent read depth | `READ_DEPTH` inherits `PG_DEPTH` (normally **4**), clamped **1–32**; write depth is independent when `READ_DEPTH` is set |
| Response ownership/storage | Rendering-allocation transfer plus the bounded size classes described in §4; old 4-KiB-only pooling/copy descriptions no longer apply |
| Write collection / arrays | `WRITE_GROUP_MAX=32` (**1–128**), `WRITE_WINDOW_US=0` (cap **10000 µs**), `WRITE_ARRAYS=0`. Eligible homogeneous follow/favorite/comment-create groups may use array SQL; **explicit BEGIN/COMMIT, commit-before-response and original member retry wire** remain |
| Compression | Runtime links **libc + libdeflate** even with `GZIP=0` (default); enabled gzip uses level 1. Mode `1` saves body bytes, `2` saves **estimated** TCP segments using MSS + 200-byte header allowance. `GZIP_MIN=1024`, floored at **1024**. Identity exclusion forces acceptable enabled gzip even below the threshold/without savings, otherwise **empty 406**; **204 stays bodyless** |
| ACK policy | `ACK_DELAY=0`; optional asynchronous `TCP_QUICKACK=0` retains an FD/generation/CQE barrier. `EINVAL`/`EOPNOTSUPP`/`ENOSYS` disables it for that worker; `TCP_NODELAY` stays enabled |
| Zero-copy threshold | `SEND_ZC=1`, `SEND_ZC_MIN=256` (minimum **1**); retains the one-copied-retry ENOMEM behavior, notification barrier and unsupported-operation fallback |
| Bcrypt scheduling | `BCRYPT_AUTO=0` unless enabled without explicit `BCRYPT_LANES`; max **4** lanes. `BCRYPT_IDLE_MS=0`, `BCRYPT_STALE_MS=9500` (**1000–9500**); normal priority retained |
| JSON / authentication | Fused SIMD escape/copy and digit-pair timestamps; exact-issued-payload JWT shortcut **after signature/algorithm verification**, with expiry still checked and general handling for extra/reordered claims including `nbf` |
| Startup SQL hardening | Prepare/Describe validates result column counts/OIDs against decoders on startup/reconnect; correctness protection, not a demonstrated throughput win |

**Final audit fixes are part of the current code:** failed PG sockets retain their FD and in-flight SEND/RECV buffers until
both CQEs retire; PG completions are generation-tagged and synchronous shutdown is failure-only. Gzip must not silently
send forbidden identity, including for sub-threshold bodies. Single/array favorite counts reconcile snapshot viewer
membership with the requested state, including concurrent idempotent conflicts and duplicate array targets, instead of
using changed-row counts. `tests/favorite_counts.py` adds independent SQL/conflict tests using **libpq in tests only**;
production remains driver-free. Feature/negotiation and feed-boundary tests are described in the README's [Tests](README.md#tests).

### Earlier tuning evolution, with current defaults

The performance comparisons above remain historical. The retained 100 ms `READ_WINDOW_US` is a hold cap, not an idle-read
delay or a response-time guarantee; neither this table nor the implemented backlog demonstrates a new performance win.

| Knob | Old Default | Current Default | Why |
|---|---|---|---|
| `n_bufs` | 2,048 | 16,384 | 8× provided-buffer ring headroom; eliminates `ENOBUFS` drops under burst load |
| `READ_HOLD_MIN` | 8,192 | 2,048 | Matches `PLAN_MAX`; dispatches a full batch immediately instead of waiting |
| `READ_WINDOW_US` | 150,000 µs | 100,000 µs | Caps the batching hold, including adaptive thresholds; `0` disables holding. The README window table is historical |
| `BCRYPT_STALE_MS` (formerly fixed `stale_ns`) | 15.0 s | 9500 ms, clamped 1000–9500 | Drops stale bcrypt jobs before the 10.0 s client timeout |
| `ADAPTIVE_WINDOW` | (new) | 1 (enabled) | Flushes all staged reads when any read backend is idle, as capacity permits; when all are busy, ≥1,024 staged → 10 ms, ≥512 → 25 ms, ≥256 → 35 ms, ≥128 → 50 ms, always capped by `READ_WINDOW_US`. Only `0` selects fixed-window mode |
| `SEND_ZC` | (new) | 1 (enabled) | Uses `IORING_OP_SEND_ZC` from `SEND_ZC_MIN=256` bytes; `EINVAL`/`EOPNOTSUPP` disables it for that worker. Retained `ENOMEM` fallback retries once with copied `SEND`, preserving buffer/notification lifetime and future zero-copy eligibility |
| `TCP_DEFER_ACCEPT` | 0 (disabled) | 1 (enabled) | Defers kernel accept wakeup until client payload bytes arrive |
| `response storage` | copy + heap alloc; later 4 KiB slabs only | Ownership transfer + 256 × 4 KiB fast cache + bounded 4 KiB–4 MiB size classes | Reuses empty storage without caching results; no new allocation-rate or RSS measurement is claimed |
| `request staging` | heap alloc | zero-alloc inline slabs | 128 B inline buffer for `StageItem` text, 256 B inline buffer for `Member` bytes, static `WRec` in `PgConn`, 64-entry `BatchRec` slab pool |
| `favorite SQL CTE` | 2 statements | 1 modifying CTE | Combines mutation and decoration; counts now reconcile snapshot viewer membership with the requested state for concurrent idempotent conflicts, in both single and array SQL |
| `router SWAR` | sequential `eql` | 32-bit integer switch | Dispatches route prefixes (`tags`, `user`, `prof`, `arti`) via little-endian integer matching; remaining path/method checks still apply |
| `connection affinity` | pure round-robin | hardcoded slack of 2 | May prefer a recent same-statement backend within slack of minimum depth, but never a busy backend over an available idle one; `READ_ROUTE_SLACK` is not supported configuration |
| `bcrypt sink ring` | 256 items | 1,024 items | Absorbs registration/login spikes without triggering thread backpressure nanosleep |
| `PIN_CPUS` | 0 (disabled) | 0 (configurable) | Optional CPU core affinity pinning via `sched_setaffinity` (off by default to let Linux CFS schedule dynamically) |

---

All rig numbers are historical measurements from the README's local setup. The separate official `e0cc458` result was
**merged at #2 with a 110,000-user, 5-minute hold**. EOF-only validation, PR #79 / #82 pre-audit measurements and final
post-audit validation are distinct phases. The final native unit/build, full-seed **88/88 configuration coverage**, pressure
and sustained load checks passed, but do not establish a throughput win or elimination of every scored-run EOF. One real
PostgreSQL deadlock recovered through rollback/retry with zero bad writer responses; it is documented in the current
report rather than described as an error-free log. No new official capacity is claimed. See [OPTIMIZATION_REPORT.md](OPTIMIZATION_REPORT.md) and
[VERIFICATION.md](VERIFICATION.md) for current results and phase-specific validation.

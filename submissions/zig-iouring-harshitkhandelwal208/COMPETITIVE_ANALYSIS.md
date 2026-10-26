# Competitive Analysis

Historical comparison of **`zig-iouring-harshitkhandelwal208`** against a leaderboard snapshot and competing submissions.
Data sources are labelled: **[LB]** = the official LEADERBOARD.md snapshot used for the original comparison (8-vCPU box),
**[RIG]** = our earlier local test rig (see README for setup).

> **Historical / superseded:** The leaderboard and local-rig comparison tables below predate the current adaptive-flush
> and lookup-key lifetime fixes. They do not measure current defaults or establish current leaderboard superiority.
> See [VERIFICATION.md](VERIFICATION.md) for current local reproductions, tests and results. This submission **has been
> benchmarked on the official box, but remains unranked**; the latest reviewer result for the original `9b75e6f` is below.
> The local rig's one-server-thread/one-Postgres-thread budget is not comparable to the official 8-vCPU box.

---

## 1. Official Leaderboard Context

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

The [latest PR #45 reviewer rerun](https://github.com/arjaythedev/multicore-server-challenge/pull/45#issuecomment-6414650660)
benchmarked the original `9b75e6f`: **570 users held for 5 minutes**, 151 req/s, p50 0.6 ms, p95 90.8 ms, p99 103.4 ms,
0.75% errors and 3% target CPU. It was left **unranked** because GET tails still reached about 100 ms and existing rows
returned false 404s. Both symptoms were reproduced and fixed locally: staged reads flush at any depth when a read backend
is idle, and per-kind/planner lookup keys now borrow stable stored text rather than loop-local copies. See
[VERIFICATION.md](VERIFICATION.md) for the local evidence; the fixes still need an official rerun, not a ranking inferred
from the old local tables.

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
predict the fixed checkout's capacity on the 8-vCPU box nor supersede the reviewer's unranked official result.

---

## 4. Memory: Connection Overhead

Current idle keep-alive metadata costs **64 bytes per `Conn` table slot** (indexed by fd), plus the kernel socket.
Receive buffers come from a 16,384-slot shared provided-buffer ring and are not per-connection. The RSS figures below
are historical local measurements; they have not been remeasured for the current checkout:

| Connections | RSS |
|--:|--:|
| 100,000 idle | ~23 MB |
| 50,000 busy | ~11 MB per worker process |

Exact per-connection memory for other submissions was not measured here; their leaderboard CPU percentages do not
establish relative connection-memory overhead.

---

## 5. Bcrypt: 4-Way SIMD Kernel

Historical timings on the rig's Ryzen 7 7445HS (one core):

| Mode | Time for 4 hashes | Effective per hash |
|---|--:|--:|
| Sequential (`std.crypto.pwhash.bcrypt`) | ~160 ms (4 × 40 ms) | 40 ms |
| 4-lane interleaved kernel (`bcrypt.zig`) | ~55 ms | ~13.7 ms |

The stale-job cutoff (`stale_ns`) is set at 9.5 s: jobs older than that are dropped with a 503 before the load generator's 10.0 s client timeout.

---

## 6. Tuned Configuration

Original tuning changes, with current read-scheduling and routing semantics corrected below. The performance comparisons
above remain historical; the retained 100 ms `READ_WINDOW_US` is a hold cap, not an idle-read delay or a response-time guarantee.

| Knob | Old Default | Current Default | Why |
|---|---|---|---|
| `n_bufs` | 2,048 | 16,384 | 8× provided-buffer ring headroom; eliminates `ENOBUFS` drops under burst load |
| `READ_HOLD_MIN` | 8,192 | 2,048 | Matches `PLAN_MAX`; dispatches a full batch immediately instead of waiting |
| `READ_WINDOW_US` | 150,000 µs | 100,000 µs | Caps the batching hold, including adaptive thresholds; `0` disables holding. The README window table is historical |
| `stale_ns` | 15.0 s | 9.5 s | Drops dead bcrypt jobs before the 10.0 s client timeout |
| `ADAPTIVE_WINDOW` | (new) | 1 (enabled) | Flushes all staged reads when any read backend is idle, as capacity permits; when all are busy, ≥1,024 staged → 10 ms, ≥512 → 25 ms, ≥256 → 35 ms, ≥128 → 50 ms, always capped by `READ_WINDOW_US`. Only `0` selects fixed-window mode |
| `SEND_ZC` | (new) | 1 (enabled) | Uses `IORING_OP_SEND_ZC` for responses ≥ 256 bytes; auto-fallback to `prep_send` if kernel returns `EOPNOTSUPP` |
| `TCP_DEFER_ACCEPT` | 0 (disabled) | 1 (enabled) | Defers kernel accept wakeup until client payload bytes arrive |
| `response slab pool` | heap alloc | 256 × 4 KB slabs | Recycles 4 KB response buffers per worker, eliminating heap allocations for 95%+ of outgoing responses |
| `request staging` | heap alloc | zero-alloc inline slabs | 128 B inline buffer for `StageItem` text, 256 B inline buffer for `Member` bytes, static `WRec` in `PgConn`, 64-entry `BatchRec` slab pool |
| `favorite SQL CTE` | 2 statements | 1 modifying CTE | Folds `INSERT`/`DELETE` and article decoration into a single modifying CTE with delta counters (`favCols`), halving write statement count |
| `router SWAR` | sequential `eql` | 32-bit integer switch | Dispatches route prefixes (`tags`, `user`, `prof`, `arti`) via little-endian integer matching; remaining path/method checks still apply |
| `connection affinity` | pure round-robin | hardcoded slack of 2 | May prefer a recent same-statement backend within slack of minimum depth, but never a busy backend over an available idle one; `READ_ROUTE_SLACK` is not supported configuration |
| `bcrypt sink ring` | 256 items | 1,024 items | Absorbs registration/login spikes without triggering thread backpressure nanosleep |
| `PIN_CPUS` | 0 (disabled) | 0 (configurable) | Optional CPU core affinity pinning via `sched_setaffinity` (off by default to let Linux CFS schedule dynamically) |

---

All rig numbers are historical measurements from the README's local setup. This submission was benchmarked on the
official box at the original `9b75e6f`, but remains unranked. Current local fixes and validation are documented in
[VERIFICATION.md](VERIFICATION.md); only a fresh reviewer rerun can establish their official-box result.

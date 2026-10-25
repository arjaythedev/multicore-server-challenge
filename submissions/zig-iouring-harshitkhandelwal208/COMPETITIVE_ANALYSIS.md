# Competitive Analysis

Comparison of **`zig-iouring-harshitkhandelwal208`** against the official leaderboard and competing submissions. Data sources are labelled: **[LB]** = official LEADERBOARD.md (8-vCPU box), **[RIG]** = our local test rig (see README for setup).

> **Note:** This submission has no official box measurement yet. The local rig uses one server thread and one Postgres thread on a Ryzen 7 7445HS — not comparable to the 8-vCPU benchmark box. All "rig" numbers are directional, not absolute.

---

## 1. Official Leaderboard Context

The top entries from [LEADERBOARD.md](../../LEADERBOARD.md) (official 8-vCPU box, 5-minute holds):

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

This submission has not been benchmarked on the official box.

---

## 2. Local Rig: CPU per Request [RIG]

All measurements on the same local rig (README § Results), 22,000 users, two rounds each:

| Submission | Postgres µs/req | App µs/req | Total µs/req | req/s | steady p95 ms |
|---|--:|--:|--:|--:|--:|
| **this branch (100 ms window)** | **46** | **33** | **79** | 11,112 | 138 |
| #47 (WorriedArrow), default window | 55 | 37 | 92 | 11,528 | 32 |
| #59 (semyonfox) | 105 | 36 | 141 | 11,614 | 3.3 |
| #7 (Scooter1337) | 124 | 38 | 162 | 11,672 | 2.1 |
| #64 (touhidsiddiqueeraj-bit) | 124 | 39 | 163 | 11,653 | 2.1 |
| this branch, planner off | 144 | 33 | 177 | 11,666 | 1.0 |
| previous commit (`ed2e521`) | 147 | 34 | 181 | 11,658 | 1.0 |
| #53 (fourneau) | 199 | 38 | 238 | 11,591 | 1.1 |
| #10 (tigokraft) | 188 | 44 | 232 | 11,618 | 0.9 |
| #22 (jh-d) | 213 | 43 | 256 | 11,658 | 1.0 |

At 22,000 users this branch uses 46 µs of Postgres CPU per request, the lowest of the measured submissions, because the two-phase planner shares enrichment work across requests. The trade-off is latency: a read waits up to 100 ms for its batch (p95 ~138 ms), where non-batching submissions are at 1–3 ms.

---

## 3. Local Rig: Saturation Sweep [RIG]

Head-to-head at the knee, same rig, one server thread + one Postgres thread:

| Build | Last Pass | First Fail | Knee (est.) |
|---|---|---|---|
| this branch, 100 ms window (default) | 38,000 users: p95 360 ms (2/2) | 40,000 users: p95 526–567 ms (0/2) | ~39,000 |
| #47, default window | 38,000 users: p95 397 ms (1/2) | 40,000 users: p95 813 ms (0/2) | ~39,000 |
| previous commit (`ed2e521`) | 28,000 users: p95 291 ms | 32,000 users: p95 623 ms | ~29,500 |

At 38,000 users on this rig:

| Metric | #47 | this branch | Delta |
|---|--:|--:|---|
| req/s | 17,800 | 18,155 | +2.0% |
| steady p95 ms | 397 | 279 | −30% |
| Postgres µs/req | ~51 | 47 | −8% |
| total µs/req | ~84 | 76 | −10% |

Both hold about the same number of users (~39,000) on this budget. This branch uses about 10% less CPU per request. The load generator saturates around 40,000 users on this rig, so the actual limits on the 8-vCPU box are unknown.

---

## 4. Memory: Connection Overhead

Idle keep-alive connections on this branch cost 48 bytes each (one struct slot indexed by fd). Receive buffers come from an 8,192-slot shared provided-buffer ring and are not per-connection. Measured on the rig:

| Connections | RSS |
|--:|--:|
| 100,000 idle | ~23 MB |
| 50,000 busy | ~11 MB per worker process |

For comparison, the official leaderboard shows C#/Sockets (#22) at 95k users uses 21% app CPU — its managed handles are substantially heavier. The C/io_uring (#10) entry at 84k users uses 18% app CPU with a static slot table. Exact per-connection memory for other submissions was not measured by us.

---

## 5. Bcrypt: 4-Way SIMD Kernel

Timings on the rig's Ryzen 7 7445HS (one core):

| Mode | Time for 4 hashes | Effective per hash |
|---|--:|--:|
| Sequential (`std.crypto.pwhash.bcrypt`) | ~160 ms (4 × 40 ms) | 40 ms |
| 4-lane interleaved kernel (`bcrypt.zig`) | ~55 ms | ~13.7 ms |

The stale-job cutoff (`stale_ns`) is set at 9.5 s: jobs older than that are dropped with a 503 before the load generator's 10.0 s client timeout.

---

## 6. Tuned Configuration

Parameters changed from the initial commit to the current defaults:

| Knob | Old Default | Current Default | Why |
|---|---|---|---|
| `n_bufs` | 2,048 | 8,192 | 4× provided-buffer ring headroom; eliminates `ENOBUFS` drops under burst load |
| `READ_HOLD_MIN` | 8,192 | 2,048 | Matches `PLAN_MAX`; dispatches a full batch immediately instead of waiting |
| `READ_WINDOW_US` | 150,000 µs | 100,000 µs | Better latency/efficiency balance (see README window table) |
| `stale_ns` | 15.0 s | 9.5 s | Drops dead bcrypt jobs before the 10.0 s client timeout |
| `ADAPTIVE_WINDOW` | (new) | 1 (enabled) | Contracts read window under load: ≥1,024 staged → 10 ms, ≥512 → 25 ms, ≥256 → 50 ms, idle PG backends with ≥64 staged → 15 ms |
| `SEND_ZC` | (new) | 1 (enabled) | Uses `IORING_OP_SEND_ZC` for responses ≥ 256 bytes; auto-fallback to `prep_send` if kernel returns `EOPNOTSUPP` |

---

All rig numbers are from the local test setup described in the README. Official box results will be determined by the benchmark run.

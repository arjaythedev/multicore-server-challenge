# Guarded laptop load tests — October 24–25, 2026

The highest passing five-minute measurement completed **2,760,483 requests at
9,201.61 requests/second**, with **6,000 virtual users and zero errors**. Overall
p95 was **442.111 ms** and p99 **513.023 ms**, passing the challenge's thresholds.
The unchanged load generator reported that it was not limited and did not fall
behind. This is the measured result under the laptop's current operating mode
and the resource budget below, not an unrestricted maximum or an official score.

The fastest passing one-minute probe on October 24 averaged **20,591.12 req/s**.
That short result is not a five-minute capacity claim. A higher-user five-minute
run failed the latency limit, and a subsequent attempt hit the thermal guard.

## Passing sustained measurement

| Metric | Result |
|---|---:|
| Date | October 25, 2026 |
| Virtual users | 6,000 |
| Think-scale | 0.1 |
| Ramp / measurement / tail | 60 / 300 / 15 seconds |
| Measured requests | 2,760,483 |
| Throughput | 9,201.61 req/s |
| p50 / p95 / p99 | 269.055 / 442.111 / 513.023 ms |
| Maximum request latency | 995.327 ms |
| Errors | 0 |
| Login p99 | 887.807 ms |
| Application / PostgreSQL / generator CPU | 2.06 / 4.00 / 0.95 CPU equivalents |
| Application peak sampled RSS | 33.39 MiB |
| Generator peak RSS | 217.00 MiB |
| Maximum sampled CPU temperature | 74 C |
| Minimum host available RAM | 18.79 GiB |
| Measured memory pressure / cgroup OOM events | 0 / 0 |
| Verdict | PASS; generator not limited |

The workload included reads, logins, signups and durable writes. Writes accounted
for approximately 5.03% of measured requests. This was not an empty endpoint or
a read-only microbenchmark. The server binary is the same one used by all runs
in this report; application source was not changed during these tests.

## Full run record

All durations below are measurement windows, excluding ramp and tail. Every
completed run used a new full-seed database clone. None was generator-limited.

| Date | VUs | Seconds | req/s | p95 ms | p99 ms | Errors | Verdict |
|---|---:|---:|---:|---:|---:|---:|---|
| Oct 24 | 1,000 | 60 | 2,643 | 2.6 | 4.0 | 0 | PASS |
| Oct 24 | 4,000 | 60 | 10,589 | 3.0 | 4.7 | 0 | PASS |
| Oct 24 | 8,000 | 60 | 20,115 | 51.8 | 73.0 | 0 | PASS |
| Oct 24 | 12,000 | 60 | 20,591 | 320.5 | 377.3 | 0 | PASS |
| Oct 24 | 16,000 | 60 | 20,570 | 599.0 | 682.5 | 0 | FAIL: p95 |
| Oct 24 | 14,000 | 60 | 20,223 | 475.4 | 541.7 | 0 | PASS |
| Oct 24 | 14,000 | 300 | 18,667 | 593.9 | 683.0 | 0 | FAIL: p95 |
| Oct 24 | 12,600 | interrupted | — | — | — | — | Thermal guard |
| Oct 25 | 12,000 | 300 | 8,564 | 1,546.2 | 1,819.6 | 8,145 | FAIL: p95 and p99 |
| Oct 25 | 6,000 | 300 | 9,202 | 442.1 | 513.0 | 0 | PASS |

The October 25 12,000-user run had 0.317% request timeouts. Its error percentage
was below the challenge limit, but its latency failed. The October 24
14,000-user hold completed 5,600,105 requests with no errors, but also failed
latency. Neither is presented as passing capacity.

PostgreSQL consumed essentially its entire four-core quota at the higher loads.
Adding users beyond saturation predominantly increased queueing and latency.
The six-thousand-user confirmation establishes an observed passing point; the
exact boundary between that and the failed higher loads was not exhaustively
searched under the October 25 conditions.

## Operating conditions and resource budget

- Intel Core i9-13900H, 20 logical CPUs, approximately 30 GiB RAM. Application,
  database, generator and the user's normal applications shared the laptop.
- PostgreSQL 18.6, pinned image, original challenge configuration and schema.
  The full seed contained 100,000 users and 500,000 articles before each clone.
  fsync and synchronous commit remained enabled. No database tuning, CPU
  affinity, host sysctls or power-setting changes were made.
- PostgreSQL: **4 CPU equivalents, 8 GiB memory, zero swap, 128 tasks**.
  Disk bandwidth was capped at **128 MiB/s reads and 64 MiB/s writes**.
- Application plus generator: **4 CPU equivalents, 2 GiB memory, zero swap,
  128 tasks**, with a 1.5-GiB memory-high threshold and low scheduler/I/O priority.
  The groups therefore had a combined ceiling of 8 CPU equivalents and 10 GiB.
- Application: two runtime workers, six read connections, two write connections,
  two bcrypt workers. Generator: unchanged upstream code, GOMAXPROCS=2.
- Probes: 20-second ramp, 60-second measurement, 10-second tail. Confirmations:
  60-second ramp, 300-second measurement, 15-second tail.
- Think-scale 0.1 accelerates pacing and session turnover. **Do not multiply VUs
  by ten** to infer an official user count or its connection/memory costs.

On October 25, the firmware profile was `quiet`, the CPU energy preference was
`power`, the scaling governor was `powersave`, and AC power was connected. One
read-only sample during the passing hold observed CPU frequencies between
840 and 900 MHz, averaging 896 MHz. These settings were left as configured.
The earlier run's power profile and frequencies were not recorded, so this is
not a controlled experiment establishing the cause of the between-day difference.
The large variation makes it particularly inappropriate to combine both days
into a single capacity curve or claim a code regression/improvement from them.

## Protective stops and cleanup

An independent one-second watchdog ran outside the benchmark cgroups. It enforced
an 8-GiB available-RAM floor and monitored temperature, pressure, scheduling delay
and test-group memory consumption. Kernel-enforced quotas were verified before
load began. More detailed thresholds and reproduction instructions are in
[tools/README.md](../tools/README.md).

Two initial attempts stopped at preflight temperature readings of 91 and 92 C,
before starting a database or generator. The helper was changed to wait for five
consecutive samples below 80 C. Two later setup attempts stopped during database
copying because deliberate disk throttling contributed to global I/O and
dirty-page memory pressure. These were not completed load tests. The final guard
pairs those pressure signals with actual disk utilization or reduced RAM
headroom; hard resource caps and the unconditional RAM floor remain in force.

During the October 24 12,600-user attempt, a sampled temperature reached **100 C**.
The watchdog stopped the test automatically; its immediate threshold was then
98 C. That attempt produced no complete measurement and is excluded from
capacity claims. The immediate threshold was lowered to **95 C** for the October
25 confirmations, retaining the stop after eight samples at or above 90 C.
No new higher-load escalation followed the passing six-thousand-user result.
The guards reduce risk; they do not prove a crash can never happen.

Normal runs removed their database clones and processes. The exact clone left by
the thermal interruption was separately removed before the final measurement.
Final checks found no temporary benchmark container, systemd unit or listener
on port 3110. The original PostgreSQL container remains stopped, its seed volume
is retained, and unrelated applications/services were not stopped or modified.

## Evidence

Application SHA-256:

`71f84fdd1e961ac4b045ddcd23779347282ec10240520777c6ef7e22286559e6`

[laptop-load.json](laptop-load.json) contains all nine completed run summaries,
endpoint results, generator diagnostics, CPU/memory measurements, protective
stop records and setup attempts. Raw histograms, per-second timelines, logs,
metadata and host monitoring remain in the ignored workspace directories:

- `.local/laptop-load-20261024-e/`
- `.local/laptop-load-20261025-confirm/`
- `.local/laptop-load-20261025-6000/`

The earlier source revision's unrestricted 37,379-req/s result in BENCHMARKS.md
used a different budget and operating conditions. It is not a comparison proving
the current implementation faster or slower. An official score still requires
the organizer's server and separate load generators.

# Performance-mode rerun — October 25, 2026

**No new throughput measurement completed.** The firmware profile and CPU energy
preference both reported `performance`, with AC power connected. The application
binary was unchanged from the earlier tests:

`71f84fdd1e961ac4b045ddcd23779347282ec10240520777c6ef7e22286559e6`

The intended first measurement repeated the 6,000-user, 60-second ramp,
300-second measurement and 15-second tail used by the passing quiet-mode run.
CPU/memory ceilings remained four CPU equivalents / 8 GiB for PostgreSQL and
four CPU equivalents / 2 GiB for the app plus generator, with zero swap.

| Attempt | Result |
|---|---|
| Original 128/64 MiB/s read/write caps | Stopped while cloning the database: sustained disk utilization near 100% together with elevated I/O pressure. No HTTP generator started. |
| Reduced 32/8 MiB/s caps | Refused to start: the SSD did not cool below the new preflight threshold within two minutes. Its composite temperature reached 76.85 C and its hardware temperature alarm was set. |
| Reduced caps, after SSD cooled to 68.85 C and alarm cleared | Stopped during database preparation after a CPU sample reached 96 C, exceeding the existing 95 C cutoff. No HTTP generator started. |

The NVMe drive reported a composite high threshold of 74.85 C and a critical
threshold of 79.85 C. The helper now requires a starting temperature below
70.85 C and stops at 73.85 C, using the device's reported thresholds. These
checks are additional protection; the existing CPU limit was not raised.
Individual vendor sensor temperatures were also recorded, but their labels do
not establish a physical location or a usable independent threshold.

Database shutdown was delayed by pending I/O. A stop request timed out; the
helper was hardened to attempt termination of every owned group even if another
cleanup request times out. After the queued writes drained, final checks showed
no temporary benchmark container, runner, systemd unit or listener on port 3110.
Host writeback returned to zero and available RAM was approximately 21 GiB.
Unrelated applications and services were not stopped or modified.

The original PostgreSQL container remains stopped and its seed volume is retained.
Inspection of any files left by interrupted database creation was deferred;
PostgreSQL was not restarted just to perform that inspection. The full database
copy itself produced significant I/O stalls on this Btrfs filesystem, including
with the lower bandwidth cap. Future testing should address that preparation
step as well as cooling, rather than repeatedly retrying the same copy workflow.

The earlier **9,201.61 req/s** passing result remains a quiet-mode measurement.
It is not a performance-mode result, and these attempts provide no basis for
estimating performance-mode capacity or a speedup.

## Subsequent snapshot attempt and user-requested stop

Preparation was changed to a disposable Btrfs reflink snapshot, with the original
volume mounted read-only and no fallback to a bulk copy. This preparation
succeeded and the 6,000-user HTTP load started. The user then requested that all
tests stop before the five-minute measurement completed. The recorded maximum
CPU temperature was 93 C and minimum available RAM was 18.40 GiB. This incomplete
run provides no sustained throughput result. The runner, app, generator and
temporary PostgreSQL container were stopped; the disposable snapshot volume was
removed after container shutdown finished. No local tests were run afterward.

Its raw files remain in `.local/performance-20261025-reflink-6000/`; its stop and
cleanup records are included in the machine-readable report. The submission
folder was subsequently renamed to `rust-tokio-nouredeen06` for the GitHub account;
historical absolute paths inside logs retain the name used at execution time.

[performance-mode-attempt.json](performance-mode-attempt.json) retains all
three attempts, resource limits, monitor samples, stop reasons, power settings
and hardware sensor diagnostics. Raw directories are:

- `.local/performance-20261025-6000/`
- `.local/performance-20261025-6000-slowcopy/`
- `.local/performance-20261025-6000-retry/`

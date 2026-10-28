# mc2 comparison

Both entries were built in `crdev` with Crystal 1.22.1, `--release` and
`--mcpu x86-64-v3`, and measured on October 28, 2026. The epoll source snapshot is
from repository commit `32999d72a1fa9ac58c6d50d38baabb77956611cc`.
Its source and scripts were copied into ignored `bin/reference/` before building;
the original submission was read only.

The supplied helper ran both apps inside `mc2`, sharing its three available CPUs
(cpuset 3–5) with Postgres on port 5502, against a fresh full-seed database per run.
It used 3,000 users/connections, think scale 0.1, a 30-second ramp, a 60-second
measurement and a 5-second tail. Both runs held the shared benchmark lock.
CPU seconds in the logs cover the whole traffic run, including ramp and tail;
peak memory is the entire mc2 cgroup, including Postgres and its file cache.

Commands (from the challenge worktree):

```bash
flock /home/user/experiments/crystal-challenges/bench/.lock \
  bash /home/user/experiments/crystal-challenges/bench/mcbox.sh \
  mc2 5502 "$PWD/submissions/crystal-rayo-faustinoaq/bin/reference" 3293 3000
flock /home/user/experiments/crystal-challenges/bench/.lock \
  bash /home/user/experiments/crystal-challenges/bench/mcbox.sh \
  mc2 5502 "$PWD/submissions/crystal-rayo-faustinoaq" 3292 3000
```

The helper's fixed mc2 scratch database is named `conduit`; it was dropped under
the same lock after the final run. Correctness tests used separate uniquely named
scratch databases, also dropped. No system or container settings were changed.

The first Rayo attempt, before adding `-Dwithout_mt`, crashed during warm-up and
is excluded from the comparison. The committed Rayo log uses the corrected build.
These are short local comparisons, not official capacity scores.

| Entry | req/s | p95 ms | p99 ms | Errors | PG CPU-s | App CPU-s | Result |
|---|---:|---:|---:|---:|---:|---:|---|
| [epoll](epoll-mc2.txt) | 5,614.6 | 741.9 | 1,119.2 | 0% | 72 | 56 | FAIL: latency |
| [Rayo](rayo-mc2.txt) | 5,254.9 | 346.9 | 410.1 | 0% | 187 | 71 | PASS |

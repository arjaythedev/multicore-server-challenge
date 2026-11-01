# Submission validation

## Closed-result revision — 30 October 2026

[Run 41037586892](https://github.com/Chemske/multicore-server-challenge/actions/runs/41037586892) passed all 27 unit checks, closed profiles, all five page families, disconnected-primary ownership, 256 independent feed comparisons, comment groups, favorite rollback and uncertain-commit handling, fresh cost-ten passwords with independent Go verification, 24 blocked writers and progress on four reactors. Zig and Go each passed all 197 unchanged steps. Nine recovery cases rebuilt all 48 statements across 40 database owners. The separate connection test retained 150,000 sockets and answered each; it is not a workload-user result.

The write recovery harness checks independent owners: successful tag reads establish read recovery, then distinct write probes must recover within ten seconds. Every rejected probe must leave its article absent; a successful probe must be durably present once. This avoids treating one recovered read connection as proof that all write owners have already completed their own reconnect and preparation.

The lost favorite-commit test records request identities from PostgreSQL Bind messages. Its unique viewer cohort must execute exactly once per viewer after all owners recover, including a deliberately separate first-time singleton. This detects replay directly and permits ordinary singleton dispatch under multiple reactors. Counting every single statement as a replay could falsely fail when one reactor received only one request. Native checks and [Linux run 41046946269](https://github.com/Chemske/multicore-server-challenge/actions/runs/41046946269) pass the identity test and nine recovery scenarios across 40 owners, including all 197 unchanged steps, without changing the application runtime.

The final Linux default build uses plain `build.sh` as the unprivileged challenge user. [Run 41045355459](https://github.com/Chemske/multicore-server-challenge/actions/runs/41045355459) repeats the focused matrix, then builds with the shipping defaults and checks four serving reactors, all 197 unchanged steps, mutations and 40-owner recovery. On the independent Oracle target the default build also passed 27 unit checks and all 197 unchanged full-seed checks before the database was reset and performance measurement started. Workload capacity is reported separately in [SCALING.md](SCALING.md).

## Scaling revision — 29 October 2026

The integrated Linux revision passed [run 40961667314](https://github.com/Chemske/multicore-server-challenge/actions/runs/40961667314): 22 unit checks, grouped page/comment faults, mixed bcrypt jobs with Go cross-verification, dedicated-writer isolation, two serving reactors, 150,000 actual HTTP sockets, 15 mutation cases and nine recovery cases. Zig and Go each passed the unchanged 197-step development-seed suite; the suite passed again after database recovery. The larger socket check is separate from workload capacity. Configuration, scope and evidence are recorded in [SCALING.md](SCALING.md).

## Initial submission — 25 October 2026

Checked on 25 October 2026. All commands below use the submitted source and unchanged upstream schema, seeds, test suite and reference implementation. Local helper/proxy tests use disposable database copies.

## Correctness and failure handling

- Sixteen Zig unit checks: protocol framing, routes, parameters, authentication, scheduler state and PostgreSQL array escaping.
- Focused native groups: 11 HTTP scenarios, 13 authentication scenarios, 15 profile scenarios, 15 article/feed scenarios and 15 mutation scenarios.
- All 197 unchanged conformance steps pass on the development seed. Normalized responses match the unchanged Go reference.
- All 197 unchanged steps also pass on the full 500,000-article seed. Zig and Go use successive private clones for normalized reference comparison. Both final Go attempts passed 196/197: its `offset=100000000` request exceeded the unchanged 30-second client timeout, while Zig passed that step and all 197 checks. The other 196 normalized responses match Zig exactly. Both failed reference transcripts are retained; neither is counted as a successful full-reference run. Earlier historical full-reference passes are preserved in PERFORMANCE.md.
- Tags grouping: 64 correct responses from six wire executions; 64 SQL failures from two executions; a subsequent read executes fresh SQL.
- Article grouping: 64 mixed reads from two wire executions, with independent anonymous/authenticated flags, missing rows, quoted/backslash/Unicode slugs, post-group freshness and SQL-error reuse.
- Native connection test: 8,000 actual sockets, 4,000 replacements, retained-input pressure and a non-renewable partial-request deadline. The 100,000-slot scheduler check is simulated state, not a live connection benchmark.
- Ten recovery/concurrency scenarios: independently rebuilt owners/settings/21 preparations, bounded reconnects, stalled authentication, backend loss, uncertain COMMIT without replay, blocked-write progress, rollback, project-cluster restart and another complete conformance pass.
- Shell/Python syntax and Git whitespace checks pass.

Run the native checks from the submission directory after `source dev/env.sh`, using the commands in README.md. Complete logs stay under the local workspace's `work/experiments/submission/`; generated databases, compiler output, hostnames and local absolute paths are excluded from the submission.

## Clean Ubuntu

The unchanged upstream GitHub Actions workflow installs the pinned toolchain/client library on Ubuntu 24.04 x86_64, builds as the unprivileged runner, starts the foreground server against PostgreSQL 18 and passes all 197 conformance steps. Its first successful run is [40206141704](https://github.com/Chemske/multicore-server-challenge/actions/runs/40206141704), on the preceding baseline. The same workflow runs again for the final submission commit; see the submission pull request's checks for its exact revision and current status.

This validates a real Linux/epoll runtime and the OpenSSL-enabled libpq installer, beyond the earlier Mac cross-link proof. It does not reproduce the official eight-vCPU/16 GB machine or establish large Linux connection capacity.

## Performance and scope

The article-group comparison, including its subsequently discovered VM contention, every error, binary fingerprints and worse median p99, is recorded in PERFORMANCE.md and benchmarks/results/article-groups.json. The release's latest 8,000-user native hold fails (p95 2,127.871 ms, p99 3,901.439 ms, 9.774% HTTP 503s) while two existing VM workloads and substantial swap share the Mac. The complete result is retained. Local tests never establish an official user score. The organiser's full-seed capacity search and five-minute hold with separate generators remain authoritative.

The submission adds only its own directory. It includes source, pinned dependencies, build/install/start scripts, tests and English documentation. No build products or caches are committed. Authorship uses the public Chemske identity; source attribution is preserved.

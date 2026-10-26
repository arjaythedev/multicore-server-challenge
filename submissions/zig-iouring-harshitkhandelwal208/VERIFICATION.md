# PR #45: fixes and local verification

Verified 2026-10-26, starting from `9b75e6f` on branch `zig-uring-harshit`.

**Implementation and validation:** performed by **GPT-6.1 Sol (max effort)** at the author's request, including reproduction, debugging, code changes, regression tests and local load verification.

**Status:** both reported review failures were reproduced on the original source and fixed. The final build passes the local checks below. A fresh official-box benchmark is still required; these results do not establish a leaderboard position or maximum capacity.

## Review findings and root causes

The [latest reviewer comment](https://github.com/arjaythedev/multicore-server-challenge/pull/45#issuecomment-6414650660) reported 570 users held for five minutes, 151 req/s, p95 90.8 ms, p99 103.4 ms, 0.75% errors and 338 unexpected 404s. The earlier comment reported the same two symptoms. Conformance already passed, so conformance alone was not sufficient evidence of a fix.

| Finding | Root cause | Fix |
|---|---|---|
| GET tails near 100 ms while CPU was idle | Adaptive scheduling bypassed the hold for a lone read, but not for every queued batch. Statement affinity could also prefer a busy backend over an idle one. | `src/server.zig`: flush staged reads at **any queue depth** when a read backend is idle, including after an in-flight reply; never route to a busy backend instead of an available idle one. Adaptive thresholds are capped by `READ_WINDOW_US`; zero really disables holding. |
| False 404s for existing article, comments and profile lookups; incorrect empty filtered lists/counts | Inline text slices escaped loop-local `StageItem` copies. Per-kind arrays and planner key interners could therefore retain overwritten stack bytes. | `src/server.zig` and `src/plan.zig`: borrow keys from stable, owned batch/plan items. No additional allocation is needed on the production hot path. |

An archived, independently built original `9b75e6f` reproduced both symptoms against private SQL-created fixtures: successful read bursts had p95 around 105–110 ms, and a mixed burst returned false 404s and wrong filter results. The same fixture tests pass on the fixed source, including distinct and duplicate keys, different viewers/pages, missing resources, and 127/128/129-byte inline/heap boundaries. Planner ownership tests also failed against the original planner.

`TCP_NODELAY` and real write `BEGIN`/`COMMIT` boundaries were already present at the starting commit; neither was removed or presented as a new fix.

## Additional correctness and performance fixes

- **Failed write-group recovery:** an extended-protocol error skips the queued `COMMIT` until `Sync`, leaving the connection in an aborted transaction. Queue an explicit `ROLLBACK` before retries. Reserve a separate internal reply token and verify that rollback returns an idle transaction state.
- **Write isolation during group outcome:** unrelated standalone writes must not be pipelined behind an unresolved group. Otherwise they can execute in the aborted transaction before rollback, even when a rollback was subsequently queued. Submission and FIFO draining now exclude those connections. The failure path is verified by actual log evidence, not merely by setting an environment switch.
- **Bounded write queues:** group submission honors both the configured pipeline depth and the physical reply-ring capacity. If draining standalone writes fills a connection, the next group waits and resumes on a later completion, without needing a new incoming request. Regression tests cover depths 1, 4, 32 and the internal 64-slot ring boundary, including wraparound and the rollback token. The public `PG_DEPTH` maximum remains 32.
- **Zero-copy send lifetime:** retain the response until both the final send and the zero-copy release notification complete, in either order. Latch promised notifications before handling partial/error completions. Each already-submitted attempt retains its own zero-copy identity, so it can fall back independently even after support has been disabled. Capability fallback is worker-local rather than mutating shared configuration. Zero-byte sends close instead of retrying forever. Connection metadata remains within 64 bytes.
- **Large grouped writes:** heap-backed wire payloads no longer narrow their length into a 16-bit inline length. The previous path trapped for payloads above 65,535 bytes in ReleaseSafe. A 128 KiB unit case and live 6 MiB article round trips exercise this.
- **Fallback receive progress:** multishot poll notifications now drain `recvfrom()` until `EAGAIN`, retrying `EINTR`. The previous one-read-per-notification path stalled a 60,000-request pipeline after approximately 5,615 responses; the fixed path completes it.

No new runtime dependency, application schema/index change, response cache, result cache or benchmark-specific application behavior was introduced. Writes whose commit outcome is unknown after disconnection are not replayed.

## Regression tests and verifier reliability

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

## Final validation results

Earlier exploratory runs are not included in the totals below.

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

### Deterministic scheduling regression

The runner preconnects clients, pauses only its own server to queue a burst, and then resumes it. A separate test first blocks a backend with a table lock, queues more reads, then releases the backend. These test the idle and busy-to-idle paths without interpreting Python thread dispatch spread as server delay.

| Build / I/O | Maximum idle-burst completion | Completion after blocked backend release |
|---|---:|---:|
| Fast / normal | 0.92 ms | 2.06 ms |
| Safe / normal | 1.63 ms | 1.18 ms |
| Fast / fallback | 1.14 ms | 1.56 ms |
| Safe / fallback | 1.05 ms | 1.11 ms |

All are below the regression threshold of 75 ms, rather than near the old 100 ms timer. Separate fixture latency bursts pass a 50 ms maximum-request threshold in adaptive and threaded configurations.

## Sustained local load results

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

## Reproduce the checks

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

## Evidence, cleanup and limits

Local artifacts remain under ignored `.zig-cache/verification/` (not part of a Git commit):

- `baseline-confirmed/`: authentic original-build reproduction. Earlier exploratory baseline logs are not used as evidence.
- `final-fast-normal/`, `final-safe-normal/`, `final-fast-fallback/`, `final-safe-fallback/`: per-test output, reference/test server logs and machine-readable `summary.json`.
- `final-checks.txt`: complete matrix, write-depth and exact verifier-wrapper output.
- `sqldiff-seed1.txt`, `sqldiff-seed17.txt`: both 1,500-case SQL comparisons.
- `final-writes-*-depth*.txt` / `.log`: extra forced-group-failure runs.
- `strict-reconnect*.txt` / `.log`: reconnect checks after transport failures were made an explicit failure condition.
- `final-load-570.json`, `final-load-5000.json`, matching `.merged.json`, `.merge.txt` and `.server.log`: raw/merged load evidence and production-default startup logs.

All owned application/load-generator processes and the disposable PostgreSQL copy were stopped, and per-run databases were dropped. The approximately 15 GiB disposable PostgreSQL data-directory copy was removed after verification; the original external seed cluster was not started or modified. Useful logs and raw load results were retained. No system package was installed.

Limits and intentionally unchanged behavior:

- This is extensive local validation, not a proof against every possible race or a replacement for the reviewer's official rerun. Pathological kernel completion/disconnect orderings are covered by targeted unit cases and live large-response tests, not an exhaustive kernel fault-injection campaign.
- Busy PostgreSQL backends can still cause ordinary queuing; `READ_WINDOW_US` is a hold cap, not an end-to-end latency guarantee. Fixed-window mode remains an explicit opt-in. Queued standalone writes retain priority over subsequent groups; a permanently saturated standalone backlog can delay grouped writes.
- Default bcrypt batching still waits up to 250 ms. Login p95 was about 293 ms / 313 ms in these two runs, with zero errors; this is distinct from the fixed GET timer bug. Authentication tuning was not changed without a separate throughput/latency study.
- Python diagnostics have no errors in the changed test files, but style/annotation warnings remain. Two pre-existing type-checking errors in the untouched historical `benchmarks/parse_run.py` were not changed; that script was not used for these results.
- README and competitive-analysis tables from older experiments are now explicitly marked historical/superseded, with the official **benchmarked but unranked** status kept separate from the new local results.

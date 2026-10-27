# Native Mac development and cleanup

## Workspace policy

I develop on macOS ARM64 without a VM or container platform. Tools and generated data belong in the existing project workspace rather than scattered system installations. I do not add global shell configuration, Homebrew, launch agents, database services or global Git settings for this challenge.

The checkout is one directory inside a surrounding workspace. From the workspace root:

| Location | Purpose |
|---|---|
| `multicore-server-challenge/` | Repository and source |
| `work/tools/` | Project-local Go, GitHub CLI and PostgreSQL/libpq |
| `work/cache/` | Go/Zig build and dependency caches |
| `work/runtime/` | Database cluster, socket files, logs, process metadata |
| `work/tmp/` | Temporary downloads and scratch files |
| `outputs/` | Review copies of documents and selected deliverables |

These are local workspace conventions. The eventual submission must build from its own folder on clean Ubuntu without referring to this Mac's absolute paths. Runtime configuration comes from DATABASE_URL, JWT_SECRET, HOST and PORT.

## Existing tools

Zig 0.17.0 and VS Code were already installed. Preparation added project-local Go 1.27.3 and GitHub CLI 2.103.2 from official, SHA-256-checked distributions, plus the official Zig VS Code extension 0.7.0. Milestone 1 added PostgreSQL/libpq 18.6 under work/tools, built from the official source archive with SHA-256 555610c24d53e4316da5b7d3fc25c279d96856d5e0e23ee308c328c5fa881d9f.

The VS Code extension automatically downloaded ZLS 0.17.0 when source files appeared. Its binary, README and licence were moved to work/tools/zls-0.17.0, and the workspace now uses that path and a project-local ZLS cache. This is an additional editor helper, not a separately installed application.

The VS Code workspace directs new integrated terminals to local GOCACHE, GOMODCACHE, GOPATH, ZIG_GLOBAL_CACHE_DIR, ZIG_LOCAL_CACHE_DIR and TMPDIR paths. PSQL_HISTORY is local too. GOTOOLCHAIN=local avoids silently downloading another Go compiler. Existing terminals and commands launched elsewhere do not automatically inherit this environment. Editor-managed tools need the same cache-location check before activation.

## PostgreSQL setup

Milestone 1 uses the source-built PostgreSQL 18.6 prefix at work/tools/postgresql-18.6 and data at work/runtime/postgres-18. It requires no sudo or package manager. The local build omits ICU, readline and zlib; it uses UTF-8 with C locale. The reference conformance run passed with these choices. This setup is for local correctness work, not representative benchmark tuning.

The cluster listens only on 127.0.0.1:55432 and requires SCRAM authentication. Unix-domain sockets are disabled because the workspace path exceeds macOS's socket-path length limit. No socket or database files are redirected to an external location. The local development administrator credentials in dev/env.sh are for this disposable cluster only.

conduit_dev is the checked reference seed. conduit_local is a separate copy used by the interactive server. Focused tests create and drop their own additional copies. PostgreSQL refuses to copy a template with active sessions; keeping the interactive server away from conduit_dev prevents that conflict.

Use one pinned PostgreSQL 18 distribution with both server tools and libpq, installed/extracted under work/tools if it is relocatable and meets the test requirements. Keep data, sockets and logs under work/runtime. Start and stop it explicitly with pg_ctl, bind locally on a dedicated port, and do not register an automatic service.

The native source build succeeded using existing compiler/SDK, make, flex, bison and Perl tools. No extra build packages were installed. The eventual Linux submission installer must also pin the toolchain/client requirements and meet the challenge's source-build rules.

Use development data first. Full-seed tests need extra space for template copies, generated seed files, WAL and logs. The reported database size is not the peak disk requirement. Avoid multiple full copies by default and record disk use around longer tests.

## Validation plan

1. Confirm the unmodified reference server and test harness work on the chosen PostgreSQL cluster.
2. Run the unchanged conformance suite against a fresh development-seed copy.
3. Repeat against a fresh full-seed copy once the implementation is complete.
4. Compare normalized transcripts with the development golden transcript.
5. Add targeted HTTP-framing, concurrent mutation, rollback, commit visibility, disconnect and database-recovery checks.
6. Measure local candidates against the same load with alternating A/B order. Keep raw results, commit IDs and resource conditions.

Expected future commands from the repository root, once the environment and scripts exist:

```sh
bash seed/make-seed.sh --dev
bash test/run.sh submissions/zig-reactor-Chemske
bash seed/make-seed.sh
TEMPLATE=conduit_seed bash test/run.sh submissions/zig-reactor-Chemske
```

Both development- and full-seed conformance now pass for the complete Zig API. Local full-seed comparisons are documented in PERFORMANCE.md; Clean Ubuntu x86_64 installation and conformance also pass; official capacity remains unmeasured. The milestone tests run the unchanged suite; older result files preserve their checkpoint failures. Seed creation replaces the named seed database, so it belongs in the dedicated project cluster. The dev helper preserves an existing seed instead of replacing it. Test/run creates and removes a temporary database. Load tests need separate disposable copies because they mutate data. Local development-seed load runs use 10,000 seeded articles rather than the full-data default.

The Mac's six cores and 8 GiB RAM cannot reproduce the official Linux target. Keep local load within host limits, monitor generator saturation and memory pressure, and never label local capacity as an official score. Linux CI is a required compatibility check; the organiser's benchmark determines the ranking. No remote server has been rented. BENCHMARKING.md describes an optional short-lived Oracle x86 test requested during the final optimisation round; no cloud resource is created without selecting that next step.

## Current footprint and cleanup inventory

At the research checkpoint, work used roughly 414 MiB and the checkout roughly 6.9 MiB before these documents. Download archives inside work/tools account for about 78 MiB and can be removed once their extracted tools are no longer in doubt. They have not been deleted during research.

Earlier preparation also used default cache locations outside this workspace:

| Location | Observed size | Treatment |
|---|---:|---|
| `~/.cache/zig` | 46 MiB | Review challenge-generated entries; may include pre-existing content |
| `~/Library/Caches/go-build` | 136 MiB | Review before deletion; do not assume exclusive ownership |
| `~/go/pkg/mod` | 51 MiB | Contains dependencies fetched during preparation; inspect before removal |
| `~/.vscode/extensions/ziglang.vscode-zig-0.7.0` | 1.4 MiB | Added Zig extension; removable through VS Code if no longer wanted |

I will not delete entire shared caches without confirming their contents. The pre-existing Zig installation, VS Code and GitHub credentials are not disposable challenge files. macOS and the editors can also retain normal metadata and history; a contained workspace is not a promise of zero operating-system traces.

Cleanup order: stop only the project server and database cluster; preserve or push useful source and results; remove project-generated work; optionally remove the added extension and reviewed external cache entries. Never remove a live database directory before stopping its server. Keep this inventory current as setup changes.

Milestone 1 also uses work/build for PostgreSQL source/object files, work/downloads for its checked archive, work/logs for build/test/database logs, and work/tools/reference-go for the built reference executable. These are all removable generated assets after the project processes stop. A first Zsh path-resolution error briefly created a work directory in Documents; its generated contents were moved to work/tmp/env-initial-attempt and the external directory no longer exists. The helper was corrected and verified in both Bash and Zsh.

To keep newly opened terminals consistent, source dev/env.sh before building or running tests. It sets the task-specific development paths and defaults; a manual HOST or PORT override belongs on the server command after sourcing. CHALLENGE_HOST and CHALLENGE_PORT can set helper defaults without colliding with Zsh's built-in HOST variable.

Milestone 2 adds no installed tools. Its test builds the existing upstream Go reference and conformance executable into work/tools and writes logs, normalized transcripts and JSON evidence to work/results/milestone2. Disposable test databases are removed even on an assertion failure. The interactive server still uses only conduit_local.

At the milestone 3 checkpoint, work occupies about 1.6 GiB, including the 405 MiB dedicated PostgreSQL cluster, compiler caches and source/build tools. This is contained workspace data; temporary test databases have been removed.

Milestone 3 adds no installed tools. Its test launches Zig and the unchanged Go reference against separate disposable clones, keeps the complete logs/transcripts under work/results/milestone3, and compares the reached profile responses. Failure injection adds a deferred constraint trigger only inside the private Zig test clone, then removes it. Neither the official schema file nor the seed/interactive databases are altered by that check. Both clones and test servers are removed on exit.

At milestone 4, work occupies about 1.7 GiB, including the 485 MiB database cluster and its WAL, source/build tools and compiler caches. No disposable test databases remain.

Milestone 4 adds no installed tools. Shared Python test helpers use only the existing standard library; dev/env.sh disables bytecode writes to keep imports from adding cache directories beside source. All reference executables and read-test evidence stay in work/tools and work/results/milestone4. Contract comparisons and custom fixtures use separate successive pairs of disposable clones so the reference's later writes cannot affect differential reads.

The count-failure check temporarily enables row-level security and a test-only policy/function inside its private Zig clone. It rejects only count statements after a page succeeds, then removes the policy/function and disables row-level security. The official schema file, seed and interactive database remain unchanged. This is failure injection, not part of installation, the application runtime or a capacity run.

Milestone 5 adds no software or service installation. Its complete upstream/reference transcripts, the official runner log and write-failure evidence live in work/results/milestone5. The fault-injection triggers and temporary permission changes affect only disposable test clones and are removed. A short-lived unchanged Go reference also writes to the same private clone to exercise concurrent tag creation; no external database is used. Temporary servers and databases are removed even on test failure. The footprint remains about 1.7 GiB under work, including the 485 MiB dedicated database cluster.

The first optimisation adds no dependencies or installed tools. Two saved executables, the pilot and the six-run comparison live under work/experiments/prepared-statements. Each run removes its private database and temporary server. All benchmark JSON, per-endpoint histograms and logs are disposable generated evidence; the comparison script itself is submitted source under benchmarks/. After validation, work remains about 1.7 GiB and the dedicated cluster is about 437 MiB. No test databases remain.

Milestone 6 adds a build-time database pool size and readiness-driven replacement without installing dependencies or services. Its one/two/four-connection executables and nine raw comparison runs are under work/experiments/database-concurrency. Recovery tests use a standard-library TCP proxy and private database clones; only protocol names and setup counts are retained. The optional --restart-cluster check restarts only the dedicated project cluster, brings it back in a finally path, and temporarily affects the interactive project server. All clone databases, proxy threads and temporary servers are cleaned up.

## Repository policy

All proposed submission files stay under submissions/zig-reactor-Chemske. Shared challenge files remain unchanged. Documentation is in English and distinguishes intended behaviour from verified behaviour. Reused source keeps its licence and attribution; no invented benchmark or test result belongs in the README.

The existing remote branch name zig-httpz-chemske reflects an earlier candidate and does not describe the selected reactor design. The submission folder and README identify the selected reactor stack; the historical branch name does not affect builds.

## Final optimisation round: full data and connection scheduling

The unchanged full seed is now present as `conduit_seed`: 100,000 users, 500,000 articles, 200 tags, 1,250,377 article/tag links, 4,990,637 favourites, 2,494,001 comments and 1,989,808 follows. Every official row-count/content fingerprint matched. Its reported database size is 2,314 MiB. The generator's temporary TSV files and executable were removed by the unchanged script.

To contain seed-generation outputs, I copied the unchanged `seed/make-seed.sh` and `schema.sql` into `work/full-seed/`, with its `bench` symlink pointing at the original repository bench directory. This changes neither generator nor schema. The checked log is `work/experiments/final-round/full-seed.log`. Do not rerun seed generation casually: the upstream script replaces its named seed database.

`tests/full_seed.py` runs the unchanged 197-step suite on a fresh full clone for Zig and then a separate fresh full clone for Go. All normalized responses match. The development-focused tests keep their smaller, purpose-built fixtures; they are not silently relabelled full-seed tests. Benchmarks use `--template conduit_seed --users 512 --think-scale 0.005` for the local full-data comparisons. Session/think times remain accelerated and the generator remains on the Mac.

Connection scheduling now has a configurable 131,072-slot ceiling and uses constant-time free/queue operations plus an indexed deadline heap. The native socket test is `python3 tests/connections.py`: 8,000 real sockets, 4,000 slot replacements, bounded input pressure and a fixed partial-request deadline. The 100,000-slot unit test simulates scheduler state only. No kernel setting is changed to make the Mac reach Linux connection counts.

New tests and query-plan analysis use Python's existing standard library, libpq, psql and the existing compiler. No VM, Docker, extra application or background service was installed. Saved binaries, SQL plan JSON, raw benchmark histograms and full-seed logs remain under `work/experiments/final-round/`. The Ubuntu-only installer builds its private client library on the benchmark host; it must not be run on the Mac.

For cleanup after the final review, stop the interactive server and dedicated PostgreSQL cluster first. The full seed, WAL and compiler caches are generated data under `work/`; retaining `conduit_seed` until the last check avoids regenerating it. Temporary clones are removed after each test/run. The exact end-of-round footprint is recorded in the review output, since peak disk usage during a clone is larger than the retained template.

A further cross-link proof built PostgreSQL 18.6's client library and the server for x86_64 Linux using the existing Zig compiler on macOS. The results are ELF executable/shared-library files under `work/experiments/final-round/linux-cross/`. This installs no Linux tool or application on the Mac and executes no Linux code. The proof disables TLS/optional client features and uses a private cross-build prefix; it does not validate the Ubuntu installer's OpenSSL-enabled client or runtime search paths. The Ubuntu installer still needs an actual Linux run.

At the end of this round, generated `work/` data occupies about 4.8 GiB, including about 3.2 GiB for the dedicated PostgreSQL cluster (the full seed, development/interactive databases and retained WAL). All load-test databases and temporary servers are removed after their runs. The final source remains under this submission folder; compiled executables, query plans and benchmark histograms are not committed. Keep the full template for the last Ubuntu/review step, then stop project processes before deleting generated data. No new Mac application or system service was installed in this round.

The final submission recheck still passes all 197 Zig full-seed steps. Two Go reference attempts time out on `offset=100000000`; their other 196 responses match Zig exactly. The strict optional full-reference helper keeps that failure visible. See VALIDATION.md for the final evidence and use the unchanged official runner to test the submission independently.

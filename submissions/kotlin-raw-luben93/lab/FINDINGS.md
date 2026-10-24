# Findings so far (paused 2026-10-24)

Everything we measured and learned while building the two Kotlin submissions, so work can resume anywhere.
Full research notes (verbatim SQL of the top entries, conformance checklist, every study's raw tables) are on the
branch `research-notes` (folder `research/`).

## Branches

| Branch | What | State |
|---|---|---|
| `kotlin-raw-luben93` | **Submission 1, JVM** (HotSpot JDK 27). Canonical Kotlin Multiplatform sources. | 197/197 conformance (dev + full seed), 165 JVM tests |
| `kotlin-native-luben93` | **Submission 2, Kotlin/Native** (linuxX64, epoll). Sources mirrored with `tools/sync-variant.sh`. | 197/197 conformance |
| `tune-pg` | WIP, unmeasured: GET /api/tags requests queued together share one execution ("broadcast", as the #1 entry does); app-side tag sorting when the DB collation is byte order | needs rebase onto `kotlin-raw-luben93`, review, A/B |
| `tune-native` | WIP, unmeasured (`a01e7e5`): Kotlin/Native GC heap target 512 MiB (`GC_HEAP_MB`, `GC_LOG=1`) and build-time CPU targeting via Kotlin/Native's clang `-march=native` feature list | needs compile, conformance, A/B |
| `tune-jvm`, `bcrypt-c`, `bcrypt-c-native` | merged | — |
| `lab-results` | big-machine runs from the Omarchy box (i7-13700H, CPUs 0-7 = "box", 8-19 load) | pushed by that session when ready |

## Local measurements (4-vCPU lab; server + Postgres pinned to CPUs 0-1, loadgen on 2-3)

CPU µs per request = (app or Postgres CPU time in the measure window) / requests; `/opt/tools/bench.sh`, same harness
for everything. Absolute numbers don't transfer to the box; ratios do (Ktor < Vert.x < Rust #1 reproduces the
leaderboard order).

| Server | Load | app µs | PG µs | total | p95 | result |
|---|---|--:|--:|--:|--:|---|
| kotlin-ktor-canleon (44k on box) | 3k req/s | 245 | 186 | 431 | 2 ms | pass |
| kotlin-vertx-canleon (46k) | 7.8k req/s | 121 | 129 | 250 | 176 ms | pass, ~ceiling |
| elixir-raw-foovoo (32k), best tuning | 3.9k req/s | 257 | 233 | 490 | 339 ms | ceiling |
| rust-tokio-Scooter1337 (#1, 100k) | 11.6k req/s | 46 | 107 | 153 | 16 ms | pass |
| rust-tokio-Scooter1337 | 13.4k req/s | 48 | 95 | 143 | 509 ms | **fail** |
| **ours, JVM** (first integration) | 8.4k req/s | 61 | 118 | 179 | 34 ms | pass |
| **ours, JVM** (first integration) | 13.9k req/s | 56 | 87 | 143 | 374 ms | pass (ceiling) |
| **ours, JVM** after tune-jvm round | ~14.7k req/s | 48 | 86 | 134 | ~334 ms | pass (+4.7%) |
| **ours, Native** before eventfd fix | 8.4k req/s | 124 | 109 | 233 | 22 ms | pass |
| **ours, Native** after eventfd fix | 8.4k req/s | 65 | 133 | 198 | 6 ms | pass, RSS 49 MB |

So the JVM build is level with the #1 entry on this harness; tags broadcast and other Postgres-side work are the next
lever. (The JVM per-request numbers include bcrypt: at think-scale 0.2-0.25 logins are 4-5x the scored rate.)

## What the studies concluded

- **Postgres is the lever.** At the top of the leaderboard Postgres is ~70% of the box, the app ~20%. Cutting app CPU
  10% buys ~+2% users; cutting Postgres CPU 10% buys ~+8%. #1 vs #3 differ by ~90 µs/request of Postgres, not app.
- **Batched reads** (C# #2's design): one statement per kind for everything queued (LATERAL over unnest; `r.i >= 0`
  and `OFFSET 0` fences so each request still runs its own subqueries), generic plans, binary results, group commit.
  Our SQL matches SPEC's reference on 67/67 multi-request checks; all plans are nested loops / index probes on the full
  seed. Sharing one execution across queued tags (or list) requests is what #1 does and was accepted.
- **epoll vs io_uring: no difference** (paired A/B, median ratio 1.02 / 1.005; every model saturates at ~150k req/s per
  core). The io_uring entry (84k) is not cheaper on the app side (68 vs 61 µs) and never got buffer rings working.
  SQPOLL burns a core; kernel bypass is impossible unprivileged; a proxy doubles the TCP path. Fewer, busier event
  loops are cheaper per request. (`research/io-models.md`)
- **BEAM (Erlang/Elixir): no.** 490-555 µs/request vs our 143; ~80 µs per Postgres round trip through Postgrex; no
  batching driver. Best possible BEAM entry estimated at ~60k users. (`research/beam.md`)
- **SIMD bcrypt loses**; AVX2/AVX-512 gathers cost a load slot per element. Winner: the public-domain Openwall C core
  with 8 independent hashes interleaved, gcc `-O3`: 12.6 ms/hash vs 23.4 (Kotlin JVM) / 18.7 (Kotlin/Native); JDK
  Vector API ≥ 19.3. Integrated (FFM on the JVM, cinterop on Native), 0.4 s batch window. (`research/simd-bcrypt.md`)
- **JSON rendered by Postgres: worse** (+16-28% Postgres CPU on lists/articles/comments) except GET /api/tags, where
  `'{"tags":' || array_to_json(...)::text || '}'` costs Postgres the same. (`research/placement-json-sql.md`)
- **bcrypt in SQL: not allowed** (pgcrypto needs `CREATE EXTENSION`, rule 3) and 4x the CPU of our C kernel anyway.
- **Runtime options:** JDK 27 already defaults to compact object headers, compressed oops, AVX-512, SHA intrinsics.
  Graal JIT is gone in 27 (JVMCI removed); Azul Prime can't be downloaded anonymously; Leyden in 27 only helps
  warm-up (the scorer warms up 3 min). Kept: FFM epoll HTTP loops, THP, `UseSystemMemoryBarrier`, `-UsePerfData`,
  Kotlin `-Xno-*-assertions`; ParallelGC rejected (GC-pause p95 spikes). `java.lang.LazyConstant` (StableValue's
  successor, preview) is available for hot globals if a profile shows them. Kotlin/Native: GC heap target defaults to
  10 MiB; the inliner (`-Xbinary=preCodegenInlineThreshold=40`) is off by default. (`research/runtime-options.md`)
- **The $12 contest** (`research/twelve-dollar.md`): its wall was a 65,535-fd unit limit (ours is 200k); winners
  batched wakeups; JVM entries used SerialGC + fixed heaps; java-nio went 64% -> 56% CPU with FFM syscalls.
- **Kotlin/Native bug found and fixed:** the epoll loop drained its wake eventfd with `recv()` (ENOTSOCK), so after
  the first cross-thread post it spun; fixing it halved native app CPU.

## Box and OS limits we design for

LimitNOFILE 200000 (systemd), somaxconn / syn backlog 65535, `vm.max_map_count` 65530 (not raised: no thread or
≥128 KiB buffer per connection), scorer probes 32k -> 64k -> 120k (the cap), one process holds all probes on a growing
DB. We: listen backlog 65535, SO_REUSEPORT listener per loop, no idle buffers, no idle timeout, EMFILE back-off,
RLIMIT_NOFILE raised to hard (Native), `TCP_NODELAY`. The box's CPU model is unknown (host: Synteq); detect at build.

## Next steps, by expected value

1. Postgres: finish + measure `tune-pg` (tags broadcast, tag sort), several kinds per round trip, plan audit on an
   evolved DB, connection-count sweep for 8 cores, #1's shared list enrichment.
2. Native: measure `tune-native` (GC heap target, CPU targeting), inliner threshold, epoll edge-triggered.
3. Limits audit for 64k-120k connections (task list: buffers, queues, kernel caps) and big-machine runs (lab/README.md).
4. JVM: JFR-profile-driven pass (`LazyConstant`/static finals, allocations), Leyden AOT cache A/B (warm-up only).

## Resuming the lab in a fresh container

Postgres 18 binaries (theseus-rs GitHub release) in `/opt/pg18`, data in `/var/lib/pg18/data`, JDK 27 in `/opt/jdk`,
Go 1.27 built from source in `/opt/src/go127`, loadgen/conformance in `/opt/tools`; after a container restart run
`/opt/tools/lab-up.sh` (sysctls + Postgres pinned to CPUs 0-1). Measure with `/opt/tools/bench.sh` /
`/opt/tools/capacity.sh` (copies of the generalized `lab/bench.sh` / `lab/capacity.sh` live in this folder).

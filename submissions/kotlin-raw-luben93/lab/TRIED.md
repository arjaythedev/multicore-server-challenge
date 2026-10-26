# What we tried (history, 2026-10-23/24)

Companion to FINDINGS.md: every experiment so far with its outcome, so nothing gets repeated by accident.
Numbers are from the local 4-vCPU lab (server + Postgres on CPUs 0-1) unless marked otherwise.

## Timeline

1. **Lab.** Network was GitHub-only at first: Postgres 18.4 binaries (theseus-rs release), Kotlin 2.4.21 and
   Kotlin/Native prebuilt, Temurin JDK 27, LLVM 21 came from GitHub release assets; Go 1.27.1 was built from source
   (bench/go.mod needs it). Then full network access was granted. Box sysctls mirrored (somaxconn/syn backlog 65535,
   port range 1024-65535, `vm.max_map_count` 65530). Local fd hard limit is 20000 and can't be raised.
2. **Baselines measured** on one harness: Ktor 431 µs/req, Vert.x 250-283, Rust #1 143-175, Elixir 490-600 (later).
3. **Research workflow** (7 agents): rust-tokio #1, csharp #2, other top entries, prior Kotlin entries, conformance +
   loadgen, bcrypt, SQL catalog (all statements PREPAREd and timed on the full seed).
4. **Skeleton + contracts** written by hand (platform expect/actual, ByteBuf, SHA-256/HMAC, Row/Result/Params,
   Db/HttpEngine/Exchange/Json/Auth APIs), then **4 parallel implementation tracks** in worktrees (libs, db, http+JVM
   NIO, app+SQL) and the Kotlin/Native epoll loop by hand. First integration: **197/197 conformance**, JVM and Native.
5. **Side studies** (user requests): $12-contest techniques, BEAM, runtime/compiler/kernel options, io_uring vs epoll,
   SIMD bcrypt, JSON/bcrypt placement (SQL vs app vs C).
6. **Split into two submissions** (JVM, Kotlin/Native), each its own branch/worktree/folder.
7. **Tuning round 1**: JVM track finished (8 commits); Postgres and Native tracks were cut off by a spend limit
   (their WIP is on `tune-pg`, `tune-native`). C bcrypt integrated. Native event-loop spin bug found and fixed.

## Tried and KEPT

| Change | Effect |
|---|---|
| Zero-dependency stack (own HTTP, PG wire client, JSON, JWT, bcrypt) vs frameworks | 179 vs 283 (Vert.x) / 431 (Ktor) µs/req at ~8k req/s |
| Batched reads: one statement per kind for all queued requests (C# #2 SQL, `r.i >= 0` / `OFFSET 0` fences), generic plans, binary rows | per-request PG cost falls with load: 118 -> 87 µs/req from 8.4k to 13.9k req/s |
| Group commit (BEGIN..COMMIT in one round trip, isolated writes for expected failures) | 61k writes/s with 128 clients in the db bench |
| `LIST_ALL_DEEP` kind for huge offsets | conformance's offset=100000000 on the full seed: 3.6 s -> 26 ms |
| bcrypt: Kotlin 4 interleaved lanes | 49 -> 23 ms/hash (JVM), 56 -> 18.6 (Native) |
| bcrypt: Openwall C core, 8 lanes, gcc -O3 (FFM / cinterop), 0.4 s window | 23.4 -> 12.6 ms/hash (JVM), 18.7 -> 12.9 (Native); ~0.3 core saved at 100k users |
| JWT verified in place, no per-request atomic/ThreadLocal | -34% allocated bytes; CPU within noise |
| JVM Postgres sockets as blocking SocketChannels | read syscalls/request 2.23 -> 1.60 |
| SWAR scans (JSON escaping 16+8 bytes/step, HTTP parsing 8) | JSON escape 0.305 -> 0.270 ns/byte |
| JVM HTTP loops on raw epoll through FFM (critical downcalls), NIO behind `HTTP_IO=nio` | app 66.5 -> 63.4 µs/req; loop micro-bench 202k -> 262k req/s |
| Kotlin `-Xno-param/call/receiver-assertions` (JVM) | app 63.6 -> 62.0 |
| JVM flags `-XX:+UseTransparentHugePages -XX:+UseSystemMemoryBarrier -XX:-UsePerfData` (G1) | 13k@0.2: 14,266 -> 14,735 req/s, p95 365 -> 334 ms |
| Kotlin/Native eventfd drained with `read()` (was `recv()`: ENOTSOCK, loop spun) | Native app 131 -> 65 µs/req, p95 27 -> 6 ms |

## Tried and REJECTED (measured)

| Idea | Result |
|---|---|
| io_uring (multishot accept/recv, buffer rings, DEFER_TASKRUN) vs epoll, C, JVM (FFM), K/N | paired A/B ratio 1.02 / 1.005: no gain; K/N io_uring +13% CPU |
| SQPOLL | burns ~a whole core |
| SIMD bcrypt: AVX2 / AVX-512 gathers, hybrids | 13.9-19 ms/hash vs 12.4-13 for 8-lane scalar C |
| JDK Vector API bcrypt | ≥19.3 ms/hash (slower than plain Kotlin by default) |
| One IntArray for all bcrypt lanes | no JVM gain, worse on Native (23.0 vs 18.5) |
| JSON rendered by Postgres (json_build_object, row_to_json, format, concatenation) | +16-28% Postgres CPU on lists/articles/comments; only `/api/tags` is neutral |
| bcrypt in Postgres (pgcrypto) | not allowed (CREATE EXTENSION) and 51 ms/hash (4x our C); plpgsql/SQL Blowfish 2.8-16.5 s/hash |
| Erlang/Elixir (BEAM) | 490-555 µs/req; best case est. ~60k users on the box |
| ParallelGC | p95 642 ms spike at 13k@0.2 (GC pauses) |
| THP alone | folded into the kept flag set (better together) |
| 8-byte-only JSON SWAR | bimodal; 16+8 loop kept instead |
| Elixir tunings: pool 6 + generic plans | +28% for Elixir, still 3.4x our CPU/request |

## Considered and NOT done (with the reason)

| Idea | Why not |
|---|---|
| Ktor / Vert.x / Quarkus / http4k | measured (Ktor, Vert.x) or JVM-only/framework layers; our own stack is 1.6-2.4x cheaper |
| Schema/index/view/function changes, extensions, server config, Unix socket to PG | forbidden by rules 2/3/12 (peer auth: OS user challenge != role conduit) |
| Speculative login response before bcrypt finishes | allowed only if verified before sending; saves µs vs 30-50 ms of bcrypt, no CPU gain |
| Virtual threads | our request path never blocks; coroutines resume on the I/O thread; VTs add mount/unmount + poller hops |
| Graal JIT on JDK 27 | JVMCI removed in 27; Oracle GraalVM 25 native-image PGO is a low-priority A/B |
| Azul Prime, OpenJ9 | license/anonymous download (rule 11); lower expected peak |
| Leyden AOT cache | JDK 27 only speeds warm-up; scorer warms up 3 min (cheap A/B still open) |
| Multiple server processes | smaller batches per process; COBOL's 6 processes scored 84k vs single-process Rust 100k (not measured here) |
| Kernel bypass (AF_XDP/DPDK), busy polling | unprivileged service (EPERM) / burns cores Postgres needs |
| Front proxy (nginx, Kong) | doubles the TCP path; nginx costs 11-19% of the box |
| PostgREST | needs views/functions (rule 3), per-request transaction + session setup, JSON in PG |
| SerialGC, inlining flags, TieredStopAtLevel | not run: GC ~0.05% of CPU, JIT tiers irrelevant at peak |
| HMAC midstate on the JVM | javax+SHA-NI 235 ns vs pure Kotlin 834 ns; Jwt.verify ≤1% of app |
| `LazyConstant` / static finals for hot globals | volatile read on x86 is a plain load; no profile hit yet |
| Path-as-bytes routing | ~60 ns/request, below noise |

## Open (written, not measured) and next

- `tune-pg`: tags broadcast (#1's accepted technique; ~20% of requests are GET /api/tags) + app-side tag sort.
- `tune-native`: GC heap target 512 MiB, build-time CPU targeting; plus the inliner threshold, edge-triggered epoll.
- Several kinds per round trip; plan audit on an evolved DB; DB_READ/WRITE_CONNS sweep for 8 cores; #1's shared
  list enrichment; Postgres sockets via FFM (~0.3 µs); limits audit for 64k-120k; big-machine runs (Omarchy box).
- Remaining JVM hot spots: JsonWriter (~6%), Row.parse (1.6%), coroutine resume, per-request objects (~0.3 KB).

## Process lessons (lab pitfalls)

- **One shared lock for load tests** (`/opt/tools/bench.lock`): flock is not fair; with many agents measuring,
  queues of 10+ jobs formed. Cap side studies' lock time; prefer the Omarchy box for big runs.
- **Even PORTs after a load test can fail to bind** (loadgen's TIME_WAIT sockets on even ephemeral ports): use odd ports.
- `/opt/tools/bench.sh` finds the app as the deepest child of start.sh: wrong for BEAM (picks `inet_gethost`);
  `lab/bench.sh` finds it by the listening port instead.
- think-scale 0.2-0.25 multiplies logins 4-5x, so bcrypt is 44-55% of JVM app CPU in the lab (much less when scored);
  compare non-bcrypt per-thread CPU, and run the 13k@0.2 knee 3+ times (13.7k-14.8k req/s for the same jar).
- Workflow agents' worktrees start from `main`, not the current branch: tell agents to check out the base branch first.
- Workflows run 2 agents at a time on this 4-CPU box; a spend limit can cut tracks mid-way (WIP was committed).
- The container can reboot: run `/opt/tools/lab-up.sh` (sysctls reset, Postgres stopped).
- Maven needs `~/.m2/settings.xml` proxy entries; cargo needs `no_proxy` without crates.io and `CARGO_HTTP_PROXY`.
- `stop`-style wait loops with `pgrep -f '<pattern>'` match themselves; use pid files.

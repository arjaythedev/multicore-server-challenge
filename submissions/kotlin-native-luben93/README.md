# Kotlin/Native, no framework: own HTTP/1.1 server on epoll, own Postgres client, batched reads

Front: direct

| | |
|---|---|
| Language / runtime | Kotlin 2.4.21, Kotlin/Native (LLVM) for linuxX64: a native executable, no JVM at run time |
| HTTP | own HTTP/1.1 engine on raw epoll (`platform.linux`), one SO_REUSEPORT listener per event-loop thread |
| Postgres | own wire-protocol 3.0 client (SCRAM-SHA-256, extended protocol, binary results), batched reads, group commit |
| JSON, JWT, bcrypt | own: streaming JSON writer straight from binary rows, HS256, bcrypt cost 10 with interleaved lanes |
| Coroutines | Kotlin `suspend` with stdlib intrinsics only; continuations resume on the thread that did the I/O |
| Build | Gradle 9.8.2 (checksum-verified by `install.sh`) on Temurin JDK 27, used at build time only |
| Dependencies | none besides the Kotlin stdlib |

This is the Kotlin/Native build of the same Kotlin Multiplatform code as `kotlin-raw-luben93` (the JVM build);
DESIGN.md describes the architecture and the rules it keeps (no caching, bcrypt cost 10 on every login, HS256 + exp
checked on every request, writes committed before responding).

```bash
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

Optional process settings (defaults sized from the CPU count): `HTTP_THREADS`, `DB_READ_CONNS`, `DB_WRITE_CONNS`
(8 + 4 on the box), `BCRYPT_THREADS`, `BCRYPT_BATCH_MS`, `DB_OPTIONS`, `APP_SORT_TAGS`, `DB_STATS_S`, `OVERLOAD_GUARD`
(`READ_QUEUE_MAX`, `WRITE_QUEUE_MAX`, `BCRYPT_QUEUE_MAX`), `READ_SHARE`, `READ_GATHER_MS`, `READ_MAX_BATCH`,
`READ_VIEWER_FLAGS`, `READ_FEED_MAX_BATCH` (default 192: the feed statement decorates each distinct page article once and its hub/count work is per batch, so
bigger batches are cheaper per feed; in the lab at 180k users cap 64 collapsed and 192 held; 0 = `READ_MAX_BATCH`), `READ_FEED_HEAVY`, `READ_FEED_FLOOR`, `BCRYPT_FLUSH_MIN`,
`BCRYPT_FLUSH_AGE_MS`, `BCRYPT_PRIO_LOAD`, `BCRYPT_THREADS_MAX` and `BCRYPT_EXTRA_AGE_MS` (extra bcrypt workers that only start once the oldest login has
waited that long: insurance for a login rate the base threads cannot hash), `READ_SHARED_ROWS` (default on: comments, article and the global, tag and author lists
return each distinct thread or page once; `0` = fan every row out to every request) and `READ_FEED_SHARE` (default on: the feed decorates each distinct page
article once; `0` = per page row), `SCHED_BATCH` (default on: every thread we start runs under the SCHED_BATCH policy, so a worker woken by epoll or a
futex does not preempt a running Postgres backend on a saturated box; `0` = the default policy), `HTTP_GZIP` (unset = only while the box sends more than
`GZIP_ABOVE_MBPS` (100) MB/s on a real interface with TCP retransmits; `0` never, `1` always), `BCRYPT_NICE` (bcrypt threads default to `max(2, cpus/4)` at nice 0: one thread lost most
logins to the 10 s timeout above ~130k users on the box) (defaults: gather 30 ms, `READ_MAX_BATCH` 1024, feed shortcut on, bcrypt flush at 4
waiting / 150 ms): see the JVM build's README for what they do, they
are the same code.
Native-only: `GC_HEAP_MB` (floor of the GC heap target, default 512), `GC_LOG=1` (collections per 10 s).
Build-time (read by `build.gradle.kts` from the environment, defaults are what the submission has always built):
`CONDUIT_GC` (`pmcs` | `cms` | `stwms`), `CONDUIT_ALLOCATOR` (`custom` | `std`), `CONDUIT_INLINE` (default 40),
`CONDUIT_LLVM_INLINE`, `CONDUIT_BINARY` (`key=value,...` for any other `-Xbinary` option, e.g. `gcMarkSingleThreaded=true`),
`CONDUIT_GENERIC_CPU=1` (build.sh: generic x86-64 instead of this CPU).

## Lab results (2026-10-31)

Box simulation on an i7-13700H: server + Postgres 18 on 8 of its 20 CPUs (Postgres in a container with the box's pg-conf values for 8 cores / 16 GB),
the challenge's own load generator on the other 12, full seed, 200 s measured holds. Lab numbers only; nothing here is an official result.

**156k lab users, interleaved with the previous version (merged #121), same state, 0 errors in all four runs**

| run | rps | p50 / p95 / p99 ms | Postgres us/request | app us/request | box CPU |
|---|--:|---|--:|--:|--:|
| previous (#121), a | 39,313 | 167 / 471 / 596 | 129 | 59 | 100% |
| previous (#121), b | 39,079 | 160 / 586 / 742 | 132 | 58 | 100% |
| this version, a | 40,918 | 34 / 77 / 138 | 93 | 50 | 81% |
| this version, b | 40,900 | 36 / 90 / 217 | 97 | 52 | 83% |

**180k lab users, feed batch cap** (single runs): cap 64 collapsed (p95 6,074 ms, 1.7% timeouts); cap 192 held the whole offered load (46,486 rps, steady-state p95 143 / p99 199 ms, 0 errors); cap 1,024 likewise (steady p95 130 / p99 184).

**190k lab users, same bench as three of the leaders** (steady state = the hold minus its first 15 s; all four runs 0.00% errors and 0.00% on the login endpoint)

| | verdict (window p99 ms) | steady p50 / p95 / p99 ms (worst second) | box CPU | Postgres us/request | logins + registrations |
|---|---|---|--:|--:|--:|
| this version (cap 192) | FAIL (1,538) | 62 / 153 / 206 (445) | 97% | 93 | 10,080 + 218 |
| rust-epoll-theCatWisel | FAIL (1,221) | 102 / 157 / 175 (345) | 74% | 63 | 10,120 + 201 |
| rust-epoll-WorriedArrow | FAIL (1,734) | 115 / 180 / 207 (533) | 95% | 92 | 10,138 + 224 |
| zig-iouring-nick-potts | FAIL (1,904) | 154 / 252 / 305 (608) | 84% | 70 | 10,091 + 210 |

All four fail the load generator's verdict window because the generator, on the same machine, pegs its CPUs at the end of its ramp and the first seconds of the window carry that transient;
the steady-state columns are the comparison. This version is on par with WorriedArrow at 190k and behind theCatWisel in CPU headroom (box 97% against 74%, Postgres 93 against 63 us/request).
The capacity on the benchmark box is not measured here (INFERRED only: the previous version held 156k in this lab and scored 130k officially).

What the batch does now: comments, article, the global/tag/author lists return each distinct thread or page once per batch (the per-request favorited/following flags come back as a few flag rows),
the feed decorates each distinct page article once and its batch cap is 192, and bcrypt gets extra workers that start only when the oldest login has waited its window plus 100 ms.
Same as before: batch-shared reads, 8 read + 4 write connections, the overload guard (requests whose client is gone are dropped, queue caps answer 503), adaptive gzip.

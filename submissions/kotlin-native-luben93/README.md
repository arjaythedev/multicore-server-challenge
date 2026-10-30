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
`READ_VIEWER_FLAGS`, `READ_FEED_MAX_BATCH` (default 64: feeds share nothing, so they leave in small batches and no
long feed execution holds a read connection; 0 = `READ_MAX_BATCH`), `READ_FEED_HEAVY`, `READ_FEED_FLOOR`, `BCRYPT_FLUSH_MIN`,
`BCRYPT_FLUSH_AGE_MS`, `BCRYPT_PRIO_LOAD`, `SCHED_BATCH` (default on: every thread we start runs under the SCHED_BATCH policy, so a worker woken by epoll or a
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

## Lab results (2026-10-28)

Box simulation on an i7-13700H: server + Postgres 18 on 8 of its CPUs (Postgres in a container with the box's
pg-conf values for 8 cores / 16 GB), the challenge's own load generator on the others, full seed; the scorer's search
with its start and cap scaled x1.2 (this machine's speed relative to the box), so 144,000 here ~ 120,000 on the box.

| at 120,000 users | app us/req | Postgres us/req | p95 / p99 ms | RSS |
|---|--:|--:|---|--:|
| this version | 42 | 117 | 56 / 83 | 360 MB |
| the JVM build (kotlin-raw-luben93, same code) | 42 | 128 | 67 / 103 | 3.2 GB |
| the previous Native submission | 59 | 174 | 192 / 1,601 | 1 GB |

The scorer's search held its 144,000-user cap (5-minute hold: 37,672 req/s, p95 112 ms, p99 188 ms, 0.06% errors).
Same as the JVM build: batch-shared reads, 8 read + 4 write connections, the overload guard (requests whose client is
gone are dropped, queue caps answer 503), and the feed batch cap.

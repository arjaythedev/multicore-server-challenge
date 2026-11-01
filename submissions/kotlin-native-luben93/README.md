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
(`READ_QUEUE_MAX`, `WRITE_QUEUE_MAX`, `BCRYPT_QUEUE_MAX`), `READ_SHARE`, `READ_GATHER_MS` (the gather window's floor, 30), `READ_GATHER_AUTO` (default on: while the CPUs the process may use are at least
`READ_GATHER_HIGH_PCT` (75) busy the window widens by `READ_GATHER_STEP_MS` (10) a second up to `READ_GATHER_MAX_MS` (100), back down at `READ_GATHER_LOW_PCT` (60); `0` = the fixed `READ_GATHER_MS`), `READ_MAX_BATCH`,
`PG_IO_TIMEOUT_S` (15: how long a Postgres socket may block with a reply outstanding; an idle connection waits indefinitely),
`READ_VIEWER_FLAGS`, `READ_FEED_MAX_BATCH` (default 512: the feed statement decorates each distinct page article once and its hub/count work is per batch, so
bigger batches are cheaper per feed; in the lab at 180k users cap 64 collapsed and 192 and 1,024 held; 0 = `READ_MAX_BATCH`), `READ_FEED_HEAVY`, `READ_FEED_FLOOR`, `BCRYPT_FLUSH_MIN`,
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
`READ_FEED_ROWS` (default on: the feed returns each distinct article's columns once per batch and the app fans them out to its pages), `READ_GLOBAL_WIN` (default on: overlapping global-list pages of a batch are read by one window scan) and `WRITE_IMPLICIT_TX` (default on: a write group is one implicit transaction ended by its Sync, without BEGIN/COMMIT); `0` gives the previous behaviour.

# Kotlin, no framework: own HTTP/1.1 server, own Postgres client, batched reads

Front: direct

| | |
|---|---|
| Language / runtime | Kotlin 2.4.21 (Kotlin Multiplatform), HotSpot JDK 27 (Temurin 27+35, `install.sh`) |
| HTTP | own HTTP/1.1 engine (common Kotlin) on raw epoll loops (JVM: FFM critical downcalls, java.nio with `HTTP_IO=nio`), one SO_REUSEPORT listener per loop |
| Postgres | own wire-protocol 3.0 client (SCRAM-SHA-256, extended protocol, binary results), batched reads, group commit |
| JSON, JWT | own: streaming JSON writer straight from binary rows, HS256 |
| bcrypt | cost 10, up to 8 logins per batch with their rounds interleaved (12.7 ms CPU per hash; 23.4 ms in pure Kotlin): the public-domain Openwall C core, vendored as source in `native/`, built by `build.sh` with gcc `-O3`, called through the FFM API. Pure-Kotlin lanes are the fallback |
| Coroutines | Kotlin `suspend` with stdlib intrinsics only; continuations resume on the thread that did the I/O |
| Build | Gradle 9.8.2 (checksum-verified by `install.sh`) and Temurin JDK 27, build-time only |
| Dependencies | none besides the Kotlin stdlib (and the vendored bcrypt C source, compiled on the box) |

The same sources also build a Kotlin/Native (linuxX64) binary; see DESIGN.md for the architecture and the rules
this keeps (no caching, bcrypt cost 10 on every login, HS256 + exp checked on every request, writes committed
before responding).

```bash
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

Optional process settings (defaults sized from the CPU count): `HTTP_THREADS`, `DB_READ_CONNS`, `DB_WRITE_CONNS`,
`BCRYPT_THREADS`, `BCRYPT_BATCH_MS`, `DB_OPTIONS`, `HTTP_IO` (`nio`: JVM HTTP loops on java.nio instead of epoll).
`BCRYPT_IMPL=kotlin` forces the pure-Kotlin bcrypt.
`APP_SORT_TAGS=0` leaves tag-list sorting to SQL even under a byte-order collation; `DB_STATS_S=<seconds>` logs
batching statistics. `JAVA_HEAP` sets the JVM heap in `start.sh` (default `3g`).
Overload guard: `OVERLOAD_GUARD=0` turns it off. Otherwise queued reads and bcrypt jobs whose client has given up are
dropped unrun, and a full queue answers 503 "server busy" (`READ_QUEUE_MAX` 65536, `WRITE_QUEUE_MAX` 8192,
`BCRYPT_QUEUE_MAX` 2048; 0 = no cap).
Batched reads: `READ_SHARE=0` makes every request of a batch compute its own rows (default 1: the requests of one
execution share counts, pages and article columns, see DESIGN.md "Shared reads"); `READ_GATHER_MS` (default 20) is how
long a read kind waits for more requests before it is sent (0: as soon as a connection is free); `READ_MAX_BATCH`
(default 256) caps one execution while sharing; `READ_VIEWER_FLAGS=0` makes shared lists check favorited/following
per row instead of once per viewer; `READ_FEED_MAX_BATCH` (default 32; 0 = `READ_MAX_BATCH`) caps the feeds per
execution: feeds share nothing, so small batches keep one long feed execution from holding a read connection.
Postgres connections default to three read connections per four CPUs and one write connection per two
(`DB_READ_CONNS`, `DB_WRITE_CONNS`: 6 + 4 on the box). With `DB_STATS_S` the log also gets, per interval, each read kind's
queue wait and round trip, the read and write connections' utilization, and the bcrypt queue wait.
`SQL_PRINT=1` prints every read statement and exits (diagnostics).

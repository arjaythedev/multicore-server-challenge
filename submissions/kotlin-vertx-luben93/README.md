# Kotlin on Netty + the Vert.x Postgres client: the production-style JVM stack

Front: direct

The same application code as `kotlin-raw-luben93` (handlers, SQL, JSON, JWT, bcrypt), on the libraries a maintainable
production server would use instead of our own HTTP engine and wire client. Defaults (`start.sh`): `HTTP_IO=netty-http`,
`DB_DRIVER=vertx`; `HTTP_IO=` (empty) and `DB_DRIVER=own` switch back to ours for comparison.

| | |
|---|---|
| Language / runtime | Kotlin 2.4.21 (Kotlin Multiplatform), HotSpot JDK 27 (Temurin 27+35, `install.sh`), G1 |
| HTTP | Netty 4.2.19: native epoll transport, Netty's HTTP/1.1 decoder, 2 event loops each with a SO_REUSEPORT listener, pooled allocator, no leak detection or buffer checks, one write per response |
| Postgres | Vert.x 5.2.1 reactive pg client, with our batching on top in application code: queued reads of one kind leave as ONE array statement (20 ms gather window, shared counts/pages/articles, feeds in batches of 32) on 8 pipelined read connections; writes are group-committed (up to 64 per transaction, 4 at once); rows render straight from the driver's values, timestamps fetched as float8 epoch seconds |
| JSON, JWT | own: streaming JSON writer, HS256 |
| bcrypt | cost 10, up to 8 logins per batch with their rounds interleaved: the public-domain Openwall C core, vendored in `native/`, built by `build.sh`, called through FFM; 3 threads at normal priority (`BCRYPT_THREADS`, `BCRYPT_NICE`) |
| Coroutines | Kotlin `suspend` with stdlib intrinsics only; continuations resume on the thread that did the I/O |
| Build | Gradle 9.8.2 (checksum-verified by `install.sh`) and Temurin JDK 27, build-time only |
| Dependencies | Netty 4.2.19 (`netty-transport-native-epoll`, `netty-codec-http`), Vert.x 5.2.1 (`vertx-pg-client`), the Kotlin stdlib, and the vendored bcrypt C source (compiled on the box) |

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
(default 256) caps one execution while sharing. With `DB_STATS_S` the log also gets, per interval, each read kind's
queue wait and round trip, the read and write connections' utilization, and the bcrypt queue wait.
`SQL_PRINT=1` prints every read statement and exits (diagnostics).

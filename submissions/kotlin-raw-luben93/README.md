# Kotlin, no framework: own HTTP/1.1 server, own Postgres client, batched reads

Front: direct

| | |
|---|---|
| Language / runtime | Kotlin 2.4.21 (Kotlin Multiplatform), HotSpot JDK 27 (Temurin 27+35, `install.sh`) |
| HTTP | own HTTP/1.1 engine (common Kotlin) on raw epoll loops (FFM critical downcalls; java.nio with `HTTP_IO=nio`), one SO_REUSEPORT listener per loop |
| Postgres | own wire-protocol 3.0 client (SCRAM-SHA-256, extended protocol, binary results), batched reads, group commit |
| JSON, JWT | own: streaming JSON writer straight from binary rows, HS256 |
| bcrypt | cost 10, up to 8 logins per batch with their rounds interleaved: the public-domain Openwall C core, vendored as source in `native/`, built by `build.sh` with gcc `-O3`, called through the FFM API. Pure-Kotlin lanes are the fallback |
| Coroutines | Kotlin `suspend` with stdlib intrinsics only; continuations resume on the thread that did the I/O |
| Build | Gradle 9.8.2 (checksum-verified by `install.sh`) and Temurin JDK 27 |
| Dependencies | none besides the Kotlin stdlib (and the vendored bcrypt C source, compiled on the box) |

The same sources build `kotlin-native-luben93` (Kotlin/Native). DESIGN.md describes the architecture and the rules
this keeps: no caching, bcrypt cost 10 on every login, HS256 + exp checked on every request, writes committed before
responding.

```bash
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

## Settings (all optional; defaults are what the box runs)

- Threads and connections: `HTTP_THREADS`, `DB_READ_CONNS`, `DB_WRITE_CONNS`, `BCRYPT_THREADS`, `BCRYPT_THREADS_MAX`,
  `BCRYPT_EXTRA_AGE_MS`. `JAVA_HEAP` sets the heap in `start.sh` (default `3g`). `HTTP_IO=nio`: java.nio loops.
- Postgres session: `DB_OPTIONS` (default: generic plans, no JIT, no parallel workers).
- Batched reads: `READ_SHARE` (default on: the requests of a batch share counts, pages and article columns),
  `READ_SHARED_ROWS` and `READ_FEED_SHARE` (default on: each distinct thread, page or article is returned once per
  batch), `READ_VIEWER_FLAGS`, `READ_MAX_BATCH`, `READ_FEED_MAX_BATCH`, `READ_FEED_HEAVY`, `READ_FEED_FLOOR`.
- Gather window: `READ_GATHER_MS` (floor, 30 ms). `READ_GATHER_AUTO` (default on) widens it by `READ_GATHER_STEP_MS`
  (10) a second up to `READ_GATHER_MAX_MS` (100) while the CPUs the process may use are at least `READ_GATHER_HIGH_PCT`
  (75) busy, and back at `READ_GATHER_LOW_PCT` (60): bigger batches cost Postgres less per request, and the extra wait
  is only paid when the CPUs are the bottleneck. `0` = the fixed window.
- bcrypt batching: `BCRYPT_BATCH_MS`, `BCRYPT_FLUSH_MIN`, `BCRYPT_FLUSH_AGE_MS`, `BCRYPT_PRIO_LOAD`, `BCRYPT_NICE`,
  `BCRYPT_IMPL=kotlin` (pure-Kotlin lanes).
- Overload guard: `OVERLOAD_GUARD=0` turns it off; otherwise requests whose client has gone are dropped unrun and a
  full queue answers 503 (`READ_QUEUE_MAX`, `WRITE_QUEUE_MAX`, `BCRYPT_QUEUE_MAX`).
- Other: `APP_SORT_TAGS`, `HTTP_GZIP` (unset: only while the network link is full, `GZIP_ABOVE_MBPS`), `DB_STATS_S`
  (batching statistics every N seconds; off by default).

# Scala 3 + Cats Effect + http4s Ember + doobie

Front: direct

| | |
|---|---|
| Language | Scala 3.10.0 on Temurin JDK 25.0.4.1 (official tarball, checksum-verified) |
| Build | sbt 1.13.0 (official tarball, checksum-verified) |
| Effect system / streaming | Cats Effect 3.7.1, fs2 3.14.0 |
| HTTP server | http4s 0.23.38, Ember backend (`http4s-ember-server`), routes in `http4s-dsl` |
| Database access | doobie 1.0.0-RC12 (`doobie-core`, `doobie-hikari`, `doobie-postgres`), HikariCP 7.1.0, PostgreSQL JDBC 42.7.14 |
| JSON | circe 0.14.17 (derived encoders, jawn parser) |
| bcrypt | `at.favre.lib:bcrypt` 0.10.2, cost 10 |
| JWT | HS256 by hand with the JDK's `Mac` (about 40 lines, `Jwt.scala`) |
| **Front** | **direct**: Ember serves `0.0.0.0:80` itself |

This is ordinary Typelevel code: a `HttpRoutes[IO]` with one case per endpoint, the reference SQL from
[SPEC.md](../../SPEC.md) as doobie fragments, and circe case-class encoders. There is no hand-written HTTP parser
or event loop.

## Running it

```bash
sudo bash install.sh   # JDK 25 and sbt tarballs into /opt
bash build.sh          # sbt compile, writes target/classpath.txt
DATABASE_URL=... JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

Optional knobs (env): `DB_POOL_SIZE` (default 4 per core, so 32 on the 8-core box), `BCRYPT_THREADS`
(default half the cores), `MAX_CONNECTIONS` (default 150,000).

## Layout

| File | What |
|---|---|
| `Main.scala` | Config from env, the Hikari transactor, the bcrypt pool, the Ember server |
| `ListenBacklog.scala` | Raises the listen backlog (see below) |
| `Api.scala` | The 19 routes, auth, pagination, the error mapping |
| `Sql.scala` | The reference SQL as doobie `ConnectionIO` programs |
| `Body.scala` | Request-body validation (strict JSON types, 422 on anything malformed) |
| `Model.scala` | Response types with circe encoders, timestamps, `ApiError` |
| `Jwt.scala` | HS256 sign and verify |

## Optimizations, and why

- **Direct instead of Nginx.** Nginx used about 11% of the box in the video. Ember holds every keep-alive
  connection as a fiber. It accepts up to 150,000 connections (`LimitNOFILE` is 200,000). An open connection costs
  about 35 KB of heap (fs2's 8 KB socket buffer, plus about ten fibers and twenty fs2 scopes, measured with a heap
  histogram), so the 4 GB heap holds about 100,000 of them.
- **Idle connections stay open** until the client closes them. A virtual user keeps its connection for the whole
  session and thinks for up to 70 s. With a finite idle timeout, Ember races a timer against every socket read
  (about 4% more CPU per request in a local A/B test).
- **A listen backlog of 4,096 instead of 50.** fs2 binds with Java's default backlog of 50, and neither fs2 nor Ember
  has a setting for it. When users arrive faster than the accept loop takes them, the kernel's accept queue
  overflows, and each dropped handshake comes back as a 1–3 s retransmit. On Linux, calling `listen()` again on a
  listening socket changes its backlog, so `ListenBacklog.scala` finds the socket among the process's descriptors
  and does that through the JDK's foreign function API. The kernel caps it at `net.core.somaxconn` (4,096 on Ubuntu
  24.04).
- **A small read buffer (8 KB).** Requests are small. Ember's default is 256 KB per read, which multiplied over tens
  of thousands of open connections would use too much heap.
- **Autocommit for single statements.** Most endpoints run one or two statements. The transactor for them uses
  doobie's `Strategy.void` with Hikari's `autoCommit=true`, so no `BEGIN`/`COMMIT` round trips are added. Only
  `POST /api/articles` (article + tags) runs in a real transaction, as the spec says. Each request still borrows
  one pooled connection for all of its statements (for example the page and the count of a list).
- **Server-side prepared statements from the first use** (`prepareThreshold=1`). Postgres plans each query once
  per connection, not on every call. That caches plans, not data (rule 5).
- **A bounded bcrypt pool.** bcrypt (about 60–70 ms of CPU at cost 10) runs on a fixed pool with half the cores,
  through `IO.evalOn`. A login burst cannot take every compute thread away from the other requests.
- **Pool size 32.** Postgres uses most of the box's CPU in this workload. More connections than that only add
  contention inside Postgres. 32 is well under the 95-connection limit.
- **JVM**: G1 with a fixed, pre-touched 4 GB heap (Postgres needs the rest of the 16 GB). Cats Effect fiber
  tracing is off (`cats.effect.tracing.mode=none`), because it records a frame for every `IO` step. The CPU
  starvation checker is off, because its warnings only add noise under load.
- **No caches** (rule 5). Every token's signature and `exp` are checked on every request. Every login verifies
  bcrypt against the stored hash. Every response is read from Postgres.

## Local numbers

These numbers come from a 16-thread laptop that also ran Postgres 18 (Docker) and the load generator, on the dev
seed with `-think-scale 0.2`. They are not comparable to the benchmark box. 8,000 users passed: 10,458 req/s, p95
36 ms, p99 60 ms, 0 errors. All 197 conformance steps pass.

## License

MIT, under the repo's [license](../../LICENSE).

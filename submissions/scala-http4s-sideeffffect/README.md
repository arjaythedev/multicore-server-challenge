# Scala 3 + Cats Effect + http4s Ember + skunk

Front: direct

| | |
|---|---|
| Language | Scala 3.10.0 on Temurin JDK 27 (`27+35`, the newest OpenJDK release; official tarball, checksum-verified) |
| Build | Scala CLI 1.18.0 (official release binary, checksum-verified); build definition in `project.scala`; `start.sh` runs the app through it too |
| Effect system / streaming | Cats Effect 3.7.1, fs2 3.14.0 |
| HTTP server | http4s 0.23.38, Ember backend (`http4s-ember-server`), routes in `http4s-dsl` |
| Database access | skunk 2.0.0-RC3 (`skunk-core`, the Typelevel Postgres driver on fs2 sockets; no JDBC), otel4s 1.1.0 no-op providers |
| JSON | circe 0.14.17 (derived encoders, jawn parser) |
| bcrypt | Bouncy Castle 1.86 (`bcprov-jdk18on`, `OpenBSDBCrypt`), cost 10, `$2a$` |
| JWT | HS256 by hand with the JDK's `Mac` (about 40 lines, `Jwt.scala`) |
| GC / heap | Parallel GC, 45% of RAM, pre-touched; Cats Effect compute threads = half the cores |
| **Front** | **direct**: Ember serves `0.0.0.0:80` itself |

This is ordinary Typelevel code: a `HttpRoutes[IO]` with one case per endpoint, the reference SQL from
[SPEC.md](../../SPEC.md) as skunk queries and commands, and circe case-class encoders. There is no hand-written HTTP parser
or event loop. Concurrent article-page and feed lookups are merged into one statement with a small fs2
"DataLoader" (`Batcher.scala`).

**[FINDINGS.md](FINDINGS.md)** has every decision with its measurements, and the ideas that were rejected.
**[RESEARCH.md](RESEARCH.md)** is the survey of the other submissions (merged and open PRs) it started from.

## Running it

```bash
sudo bash install.sh   # JDK 27 and Scala CLI into /opt
bash build.sh          # scala-cli compile, writes target/classpath.txt
DATABASE_URL=... JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

Optional knobs (env): `DB_READ_SESSIONS` (default 32), `DB_WRITE_SESSIONS` (default 8), `COMPUTE_THREADS` and
`BCRYPT_THREADS` (default half the cores each), `MAX_CONNECTIONS` (default 150,000).

## Layout

| File | What |
|---|---|
| `Main.scala` | Config from env, the skunk sessions, the bcrypt pool, the Ember server |
| `SessionPool.scala` | Lends long-lived skunk sessions from a Cats Effect `Queue` |
| `Batcher.scala` | Merges concurrent lookups of one kind into one statement (fs2 `Queue` → chunks → `Deferred`s) |
| `ListenBacklog.scala` | Raises the listen backlog (see below) |
| `Api.scala` | The 19 routes, auth, pagination, the error mapping |
| `Sql.scala` | The reference SQL as skunk `Query`/`Command` values |
| `Body.scala` | Request-body validation (strict JSON types, 422 on anything malformed) |
| `Model.scala` | Response types with circe encoders, timestamps, `ApiError` |
| `Jwt.scala` | HS256 sign and verify |

## Optimizations, and why

- **Direct instead of Nginx.** Nginx used about 11% of the box in the video. Ember holds every keep-alive
  connection as a fiber. It accepts up to 150,000 connections (`LimitNOFILE` is 200,000). An open connection costs
  about 35 KB of heap (fs2's 8 KB socket buffer, plus about ten fibers and twenty fs2 scopes, measured with a heap
  histogram), so the ~7 GB heap holds well over 100,000 of them.
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
- **A bounded bcrypt pool.** bcrypt (about 55 ms of CPU at cost 10) runs on a fixed pool with half the cores,
  through `IO.evalOn`. A login burst cannot take every compute thread away from the other requests.
- **Bouncy Castle's bcrypt** instead of at.favre's: faster in all of 6 alternating rounds (20 warm-up + 50 timed
  verifies of the seed hash on one core, JDK 27): median 53.6 ms vs 56.8 ms per verify (5.0–7.6% per round), 53.5
  vs 56.8 ms per hash. It verifies the seed's `$2a$10$` hashes, and a hash from either library verifies with the
  other.
- **JVM**: Parallel GC with a fixed, pre-touched heap of 45% of RAM (~7 GB; Postgres needs `shared_buffers`, its
  backends and the page cache), chosen in a sweep against G1, ZGC and Shenandoah ([FINDINGS.md](FINDINGS.md)).
  Cats Effect gets half the cores as compute threads, leaving the rest to Postgres. Fiber tracing is off
  (`cats.effect.tracing.mode=none`), because it records a frame for every `IO` step. The CPU starvation checker is
  off, because its warnings only add noise under load.
- **Article page and feed lookups batched.** `GET /api/articles/:slug`, `GET /api/articles/:slug/comments` and
  `GET /api/articles/feed` go through `Batcher`: the lookups that arrive while earlier batches run become one
  `unnest(...) WITH ORDINALITY` statement, each request still getting its own rows, for its own viewer, from a
  statement that started after it asked. The global list is not batched (it would share results between requests).
  Together they moved the local limit from 6,000 to 8,000 users
  ([FINDINGS.md](FINDINGS.md#batching-the-dataloader-pattern-with-fs2)).
- **No caches** (rule 5). Every token's signature and `exp` are checked on every request. Every login verifies
  bcrypt against the stored hash. Every response is read from Postgres.

## Postgres access

- **skunk, sessions lent from a queue.** `Session.pooled` returns every session through its "full" recycler, which
  runs `UNLISTEN *` and `RESET ALL`: two extra round trips and two extra statements for Postgres on every request,
  and the builder has no way to change it (skunk's `Pool` needs a `Telemetry`, which is `private[skunk]`).
  `SessionPool` opens a fixed set of sessions at startup (`Session.Builder...single`) and lends them from a Cats
  Effect `Queue`. A returned session only has to be healthy and outside a transaction (skunk tracks both without
  I/O); otherwise it is closed and replaced.
- **Separate read and write sessions** (32 + 8, from a sweep of 8 + 4, 16 + 4, 32 + 8 and 48 + 8). A request that
  writes runs its statement on a write session, so a burst of reads can't queue the writes. 40 connections in total,
  well under the 95 limit.
- **Prepared once per session.** Each statement is a `val`; skunk parses and describes it the first time a session
  runs it, caches that, and after that sends only Bind/Execute. That caches plans, not data (rule 5).
- **Session settings** (rule 2 allows session-level ones), sent in the startup packet and checked with
  `current_setting()`: `plan_cache_mode = force_generic_plan` (one generic plan per prepared statement instead of
  five custom plans first), `jit = off`, `max_parallel_workers_per_gather = 0` (these are short index lookups).
- **Telemetry off.** Skunk instruments every statement through otel4s. The no-op tracer and meter providers, with
  query capture and pool/protocol spans disabled, make that free.
- **One statement per request, in autocommit.** Every endpoint now runs exactly one statement (see below), so there
  is no `BEGIN`/`COMMIT` anywhere. `POST /api/articles` stays atomic because it is one statement.

## SQL

Every statement in `Sql.scala` is a named `val` with a comment saying what it replaces. Each rewrite was checked to
return the same rows as the reference SQL on the dev seed (including an offset past the end and an unknown tag), and
timed there: the median `EXPLAIN (ANALYZE, TIMING OFF)` of the generic plan, old and new alternating in one
session, 80 runs each, with the session settings above; or `pgbench` (1 client, prepared) per request where the
point is fewer statements.

| Rewrite | Replaces | Why | Measured |
|---|---|---|---|
| Page first (global and author lists) | `ARTICLE_LIST_SELECT ... ORDER_PAGE` | the reference decorates (tags, favorite count, following) every row that `OFFSET` skips too; cut the ids from `articles` alone, decorate only the page | page 1: 1.02x; page 5: 3.97x (global), 3.43x (author) |
| Constant inner `LIMIT 100` in those | `LIMIT $2` | with a parameter the generic plan guesses a big page and picks a worse plan for the author list; `limit` is at most 100, so the rows are the same | author, limit 5: 1.02x vs 0.46x with `LIMIT $2` |
| Page + capped count in one statement (all lists, feed) | the page, then the count | the count is the single outer row and the page joins it laterally, so an empty page still carries the count | Postgres: 0.99-1.02x (same work); one skunk exchange less for the app |
| Comments with the slug lookup | article-id lookup, then comments | `LEFT JOIN LATERAL` from the article: no row is 404, one row without a comment is "no comments" | one statement instead of two |
| Follow / unfollow + profile | user lookup, then insert/delete | data-modifying CTE | 1.12x |
| Favorite / unfavorite + read-back | lookup, insert/delete, `ARTICLE_FULL_SELECT` | CTE; the main query can't see the CTE's own change, so the count adds `(SELECT count(*) FROM changed)` and `favorited` is known | 1.24x |
| Create comment | article lookup, then insert | CTE | 1.21x |
| Create article + tags + read-back | `BEGIN`, article, tags, article_tags, `COMMIT`, read-back | one statement (so atomic); tags inserted sorted, so concurrent creates lock shared tag rows in the same order; `ON CONFLICT DO UPDATE ... RETURNING` returns a tag committed after the snapshot, which `DO NOTHING` would drop | 1.58x |
| Update / delete article, delete comment | owner lookup, then update/delete (+ read-back) | CTE that returns the owner: no row is 404, someone else's is 403 and nothing changed | delete: 1.09x |
| Global count | `count(*) FROM (... LIMIT 1000)` | `EXISTS (... OFFSET 999)` is one index probe; count only when there are fewer than 1,000 | 1.08x |
| Feed count | `author_id IN (SELECT followee_id ...)` | `= ANY(ARRAY(...))` reads the followees once | 1.11-1.16x |
| Feed `following = true` | the `EXISTS` on `follows` | the feed picks articles through `follows` in the same statement (same snapshot), so it is always true | 1.01-1.05x |

Measured and not adopted:

| Idea | Measured | Why not |
|---|---|---|
| Tag names by primary key (`ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) ... ORDER BY 1)`) | 0.75-0.81x (slower), stable over three parameter sets | with 200 tags the hash join reads two pages per article; a primary-key lookup per tag reads more. Same order and collation (checked on all 10,000 dev articles) |
| Page first for the tag, favorited and feed lists | 1.00-1.05x | the reference already cuts those ids first |

## Local numbers

All 197 conformance steps pass. On a laptop set up like the box (Postgres 18 with the box's pgtune settings and the
full seed; app and Postgres sharing 8 logical CPUs, i.e. 4 hyper-threaded cores; load generator on other cores;
`-think-scale 0.2`): **8,000 users pass** (9,054 req/s, p95 387 ms, p99 606 ms, 0 errors); 8,500 fail on p95. The
progression, stage by stage, is in [FINDINGS.md](FINDINGS.md#where-it-ended-up). Absolute numbers are a laptop's;
the box has 8 dedicated vCPUs.

## License

MIT, under the repo's [license](../../LICENSE).

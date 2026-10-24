# Zig / fourneau

Front: direct

| | |
|---|---|
| Language | Zig 0.17.0 (official tarball, sha256-checked in `install.sh`) |
| HTTP | [fourneau](https://github.com/Eldhus/fourneau): HTTP/1.1 on io_uring, a fiber per connection, shards |
| Postgres driver | its own: protocol 3.0, SCRAM-SHA-256, prepared statements, binary parameters and results, pipelining |
| JSON, JWT (HS256), bcrypt | in `src/`, on Zig's standard library (`std.json`, `std.crypto`) |
| Dependencies | fourneau, pinned by commit and hash in `build.zig.zon`; nothing else |

## Design

The box's CPU is shared with Postgres, which does most of the work, so the server is built to cost
little per request and, above all, to make each request cost Postgres little.

**Shards.** Two threads, each with its own io_uring, its own share of the connections
(`SO_REUSEPORT`), its own Postgres connections and its own buffers: nothing is shared between them
but the JWT key and the bcrypt workers. A connection is a fiber: handlers are plain sequential code
that waits for Postgres the way it waits for its socket. An idle connection holds ~28 KB; the
server keeps as many as its descriptor limit allows less 1,024 (198,976 under the box's 200,000),
the longest idle closed first once every slot is taken, so a new client never meets a failing
`accept`. At 120,000 users on 4 CPUs, twice what it can serve there, it kept serving 14,400
requests a second (15,100 at its limit), and was idle again 2 s after the load stopped.

**Reads in batches.** A cheap read's cost in Postgres is mostly the statement's own (Bind, executor
start and end, the transaction), not its rows. Reads of one kind waiting together are sent as one
statement: the request's query is the inner side of a `LATERAL` join over `unnest`ed arrays of the
waiting requests' parameters, and each row comes back tagged with its request's index. Measured
on the article by slug: 161 us of Postgres CPU per request sent alone, 53 us per request in batches
of 10. There is no timer: a read waits only while every read connection has a statement in flight,
and the kind whose oldest read has waited longest goes next (up to 64 requests), to the idle
connection that last ran that kind if there is one, so a backend keeps one kind's plan and index
pages warm (p50 -5%, p99 -10%). At low load every batch is one request; under load batches grow by
themselves.

**What no viewer changes is read once per statement.** In a batch, the tags, the global
`articlesCount`, each distinct page of the global, tag, author and favorited lists (its articles,
their tags, favorite counts and authors), and each distinct capped count by tag, author or user are
read once for the requests that ask for the same one, all of them already waiting before the
statement runs; the tags come back as one row that every request of the batch keeps. `favorited`
and `following` are always the request's own. Nothing outlives the statement: no result is kept for
a later request.

**Writes in groups of one commit.** Writes waiting for a write connection go out together under one
Sync: one implicit transaction, one commit, one WAL flush for all of them. Each response is sent only
after that commit (`ReadyForQuery`). If any statement fails, Postgres rolls the whole group back, and
each of its requests is sent again alone, to get its own answer (a duplicate username is a 422 for
that request only). A request whose commit is uncertain (the connection lost) is never retried.

**A lost Postgres connection connects again.** Its waiting requests fail (500), batches skip it,
and it reconnects at once, then every second until Postgres accepts. All 20 backends terminated
twice under 6,000 users: 16 requests failed.

**Lean SQL, same answers.** Pages pick their ids on the bare index first, with a constant inner
limit (100, the API's ceiling) so the generic plan expects a page, and the per-article subqueries run
only for the page's rows, not for those `OFFSET` skips. Tag names are looked up by key rather than
by a join that hashed all 200 tags per article. A request's `favorited` and `following` for a whole
page are one probe of each index (`user_id = $v AND article_id = ANY(page)`), not one per article:
half a page statement's buffer reads, p95 -10%. A feed's articles carry their tags as ids, named by
one row of the batch's tags in Postgres's own order of the names, which saves a fifth of a feed's
index descents (p95 -9%). Comments and their article's existence are one statement. Every
statement is prepared once per connection; the session sets `plan_cache_mode = force_generic_plan`,
`jit = off`, `max_parallel_workers_per_gather = 0` and `enable_memoize = off` (a generic page plan
put a Memoize node on the users join, which clears a hash table every execution). A differential test sent 40,000
concurrent reads (every list filter, deep offsets, feeds, articles, comments, profiles, anonymous
and logged in) to the Go example and to this server on the full seed: no difference.

**bcrypt four at a time.** A Blowfish round is a chain of dependent table loads, so one hash leaves
most of a core idle. A worker thread takes up to four queued hashes of the same cost and runs them
in lockstep, every round kept: 21 ms of a core per hash against 51 alone. Four lanes' rounds are
x86-64 assembly, 13 instructions a round where the compiler's spills made 15: 13% less time a hash
with both hyperthreads of a core busy, as under load. Holding fewer than four,
it waits up to 150 ms after the oldest's arrival for more (a second measured no cheaper); logins are
about a thousandth of the requests. Four workers, one gathering at a time: with Postgres taking the
CPUs, two left logins queued past their 10 s. Hashes are verified on every login, written `$2b$` at cost 10.

**Memory.** Every buffer is allocated at startup and its pages left untouched until used; transparent
huge pages are switched off for the process, so a connection's few touched pages are not 2 MiB each.
Response bodies are written into a result slot of the shard (2,048 of them, requests in flight at
most), straight from the binary rows.

Every request reads Postgres; every token's signature and `exp` are checked on every request. No
schema or server configuration is changed.

## Running it

```sh
sudo bash install.sh   # Zig 0.17.0 into /usr/local/zig-0.17.0
bash build.sh          # bin/conduit (fetches fourneau at its pinned commit)
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

`CONDUIT_SHARDS`, `CONDUIT_READS`, `CONDUIT_WRITES` and `CONDUIT_BCRYPT_WORKERS` override the
defaults (2 shards; read connections a shard 5/8 of the CPUs the process may run on, at least 2,
so 5 on the box; 2 write connections a shard; 4 bcrypt workers) for measuring; `start.sh` sets none
of them. Fewer read connections measured better for as long as they keep Postgres busy: a statement
in flight past that is contention, and batches shrink. On 4 CPUs at 58k users, 2 a shard against 8:
p95 105-148 ms against 139-234 (and on a database aged by 20 minutes of writes, 146-187 against 4
a shard's 191-267); 1 a shard left CPUs idle. One shard measured the same as two (Postgres's CPU
per request equal, p95 a little worse).

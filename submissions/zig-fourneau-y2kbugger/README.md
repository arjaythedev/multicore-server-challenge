# Zig / fourneau

Front: direct

| | |
|---|---|
| Language | Zig 0.17.0 (official tarball, sha256-checked in `install.sh`) |
| HTTP | [fourneau](https://github.com/Eldhus/fourneau), modified: its branch [`fourneau-multicore-tuned`](https://github.com/Eldhus/fourneau/tree/fourneau-multicore-tuned). HTTP/1.1 on io_uring, a fiber per connection, shards |
| Postgres driver | its own: protocol 3.0, SCRAM-SHA-256, prepared statements, binary parameters and results, pipelining |
| JSON, JWT (HS256), bcrypt | in `src/`, on Zig's standard library (`std.json`, `std.crypto`) |
| Dependencies | fourneau `fourneau-multicore-tuned`, pinned by commit and hash in `build.zig.zon`; nothing else |

In short:

- Reads of one kind waiting at the same moment are one SQL statement, up to 128 requests.
- What no viewer changes (a page, an article, a count, the tags) is read once in that statement.
- Writes waiting together are one transaction: one commit, one WAL flush, each answered after it.
- bcrypt runs four hashes at a time, the rounds in x86-64 assembly.
- A fiber per connection on io_uring, two shards that share nothing, ~28 KB an idle connection.

## fourneau, modified

[fourneau](https://github.com/Eldhus/fourneau) is an HTTP server in Zig: io_uring under a fiber per
connection (a port of `std.Io.Evented`), shards that share nothing, and a limit, deadline or
eviction on everything a client can hold. It races Go's net/http, axum and others every night it
changes on the [fourneau HTTP drag race](https://fourneau.y2kbugger.com/), a site fourneau itself
serves with nothing in front. On the race of 2026-10-21, plaintext over HTTP/1.1 on 2 dedicated
vCPUs: fourneau's Zig app 168,318 requests a second, axum 72,542, Go's net/http 39,600.

The drag race runs fourneau's `master`. This server is built on its branch
[`fourneau-multicore-tuned`](https://github.com/Eldhus/fourneau/tree/fourneau-multicore-tuned), at
[7f8733c](https://github.com/Eldhus/fourneau/tree/7f8733cecdaebc792871cba88f062f45c9d9b894)
([what it changes](https://github.com/Eldhus/fourneau/compare/master...fourneau-multicore-tuned)):
fourneau cut down to what an HTTP/1.1 application server on plain sockets needs (TLS, ACME,
HTTP/2, compression, static files and streamed responses taken out), plus what this server needed:
fibers of one thread that park and unpark each other (a request waits for its batch that way),
slabs past 4 GiB, and a full server evicting its longest idle connections a batch at a time.

## Design

The box's CPU is shared with Postgres, which does most of the work, so the server is built to cost
little per request and, above all, to make each request cost Postgres little. "4 CPUs" below are
two cores of an i7-10510U with their hyperthreads, the server and Postgres on them, the repo's load
generator on the other four.

**Shards.** Two threads, each with its own io_uring, its own share of the connections
(`SO_REUSEPORT`), its own Postgres connections and its own buffers: nothing is shared between them
but the JWT key and the bcrypt workers. A connection is a fiber: handlers are plain sequential code
that waits for Postgres the way it waits for its socket. An idle connection holds ~28 KB; the
server keeps as many as its descriptor limit allows less 1,024 (198,976 under the box's 200,000),
the longest idle closed first once every slot is taken, so a new client never meets a failing
`accept`. At 128,000 users on 4 CPUs, twice what it can serve there, it held all 128,013
connections in 4.0 GB, 36 of 693,499 requests timed out, and it was idle again 1 s after the load
stopped.

**Reads in batches.** Most of what a cheap read costs Postgres is the statement around it (Bind,
executor start and end, the transaction), not its rows: the article by slug took 161 us of
Postgres's CPU sent alone, 53 us a request ten to a statement. So the reads of one kind that are
waiting at the same moment go to Postgres together, as the leaderboard's top two entries also do
(rust-tokio-Scooter1337, and csharp-sockets-jh-d, whose README describes this same statement): the
requests' parameters as arrays, `unnest`ed into a row each, the request's own query run for each
row through `LATERAL`, and every result row led by its request's position. Nothing waits on a
timer. A kind's reads queue only while every read connection is busy; a connection that comes free
takes the kind whose oldest read has waited longest, up to 128 of them, and the kind it ran last if
that one is waiting, so its backend keeps that kind's plan and index pages warm (p50 -5%, p99 -10%).
Unloaded, a batch is one request. Loaded, the queue is the batch, and a request that misses a full
one waits a whole statement more: on a database aged by the load, one shard with the box's 5 read
and 2 write connections on 4 CPUs, a cap of 64 rather than 32 took p95 at 52k users from 160 ms to
90, and 128 rather than 64 at 56k from 215 to 195.

**What no viewer changes is read once per statement.** In a batch, the tags, the global
`articlesCount`, each distinct page of the global, tag, author and favorited lists (its articles,
their tags, favorite counts and authors), each distinct article by slug (most are clicked from the
list a user just saw), and each distinct capped count by tag, author or user are
read once for the requests that ask for the same one, all of them already waiting before the
statement runs; the tags come back as one row that every request of the batch keeps. `favorited`
and `following` are always the request's own. Nothing outlives the statement: no result is kept for
a later request. The leaderboard's #1 shares the same way, within one execution, among the requests
already waiting for it.

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
one row of every tag's id and name in Postgres's own order of the names (as `/api/tags` reads
them), which saves a fifth of a feed's
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

## Against the leaderboard's #1, on one machine

Unofficial, not the box: rust-tokio-Scooter1337 built from its folder and started as its
`start.sh` starts it, and this server at its defaults, each on the same 4 CPUs and a fresh copy of
the full seed, interleaved twice, 58,000 users (a 30 s ramp, 60 s measured):

| | requests a second | p95 | p99 | Postgres CPU a request |
|---|--:|--:|--:|--:|
| this server | 14,225 / 14,629 | 638 / 421 ms | 761 / 517 ms | 176 / 171 us |
| rust-tokio-Scooter1337 | 9,804 / 9,674 | 2,904 / 3,228 ms | 3,023 / 3,394 ms | 249 / 251 us |

1.45-1.51 times the requests on the same CPUs, each costing Postgres about 30% less CPU.

## The rules, where they bite

- 5, no caching: nothing read for one request is kept for another. Sharing happens only inside one
  statement, among the requests already waiting for it.
- 6, committed before the response: a write's response goes out after its group's `ReadyForQuery`,
  so after the commit; a request whose commit is uncertain is answered 500, never retried.
- 7, security: sign-ups and password changes are hashed with bcrypt at cost 10, every login is
  verified against the stored hash, and every token's HS256 signature and `exp` are checked on
  every request.
- 11, built from source: Zig from its official tarball, checked by sha256; fourneau fetched at a
  pinned commit and checked against its hash; nothing prebuilt.
- 12, nothing tuned on the box: no schema, server or kernel setting is changed. In the process
  only: transparent huge pages off for itself, and session settings on its own Postgres
  connections.

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

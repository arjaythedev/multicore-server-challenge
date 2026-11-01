# C + epoll + libpq pipeline mode, batched reads

Front: direct

| Piece | Version |
|---|---|
| Language | C (gnu11), GCC 13.3 from Ubuntu 24.04 |
| HTTP/1.1, JSON, JWT (HS256), routing | hand-written, in `src/` |
| Postgres driver | libpq (`libpq-dev`, 18.x from the PGDG repo that the box already has; 14+ works) in pipeline mode |
| HMAC-SHA256 | OpenSSL 3.0 SHA-256 (`libssl-dev`) |
| bcrypt | `src/bcrypt.c` (several hashes interleaved in one thread, see below), cost 10; libxcrypt 4.4.36 (`libcrypt-dev`) for salts and other hash formats |

`install.sh` installs `gcc libc6-dev libpq-dev libssl-dev libcrypt-dev` with apt. `build.sh` is one `gcc` call
(`-O2 -march=native`, no other dependencies). `start.sh` runs `bin/conduit`, configured by `DATABASE_URL`,
`JWT_SECRET`, `HOST` and `PORT`.

## Design

Postgres and the server share 8 CPUs, and Postgres is most of the work, so the design is about making each
request cost Postgres as little as possible, and costing little itself.

**Event loops.** One epoll loop per 4 CPUs (2 on the box), each with its own `SO_REUSEPORT` listener and its own
Postgres connections; nothing is shared between loops. Sockets are edge-triggered and read until drained. An idle
keep-alive connection holds no buffers (about 100 bytes plus the kernel's socket), so 150,000 connections take
about 40 MB.

**One round trip per request.** Every statement is prepared once per connection. A request's statements go out as
Bind/Execute pairs and one Sync; many requests are pipelined on a connection, and the replies are matched to
requests in order. Statements before a Sync run in one implicit transaction that commits at the Sync, and a
response is sent only after its ReadyForQuery, so writes are committed before we answer (rule 6). Dependent
statements are folded together: follow/unfollow, delete article/comment, create comment and favorite/unfavorite
are single statements with data-modifying CTEs; create article is four statements before one Sync (the tag
inserts use `currval`); update article is a lookup, then the update and the read-back.

**Batched reads.** Much of what a small statement costs Postgres is per statement: protocol messages, executor
start-up and shutdown, snapshot, transaction start and end. Reads of one kind (an article by slug, comments, the tag
list, a profile, a page of each list kind, the feed) wait in a per-loop queue. Each kind collects its requests for
up to 40 ms (or until 256 are waiting), then goes out as one statement over the unnested parameters of every
waiting request, each row carrying its request's ordinal. The window keeps batches large at any load, not only when
the connections are busy (the idea is from rust-epoll-WorriedArrow's batch clock).

**Shared within a statement.** The requests of one statement share whatever doesn't depend on who is asking: each
distinct page key (limit, offset, tag, author, ...) is paged and counted once, each article in the batch gets its
tags, favorite count and author once, each slug's comments are read once, and only `favorited` / `following` are
computed per request. A list statement looks like this:

```sql
WITH r AS MATERIALIZED (SELECT * FROM unnest($1::int8[], $2::int8[], $3::int8[]) WITH ORDINALITY AS r(v, l, o, i)),
     c AS MATERIALIZED (<capped count per distinct count key>),
     p AS MATERIALIZED (<page ids per distinct (limit, offset, key)>),
     a AS MATERIALIZED (<tags, favorite count, author per distinct article>)
SELECT r.i, c.n, a.*, <favorited by r.v>, <following by r.v>
FROM r JOIN c ON ... JOIN p ON ... LEFT JOIN a ON a.id = p.id ORDER BY r.i, p.id DESC
```

Everything a response contains was read by that statement while the request was waiting, in one snapshot, and
nothing outlives the statement: only requests that are queued when it goes out share it. Per-key lookups are
`LATERAL ... LIMIT` so generic plans probe indexes, and hash aggregation is off for the session (a generic plan
sized each `DISTINCT`'s hash table for thousands of keys). Rows are handed out by ordinal, and a batch whose rows
don't come back grouped per request in order fails with 500 instead of mixing anything up. A differential test of
20,000 random reads at concurrency 256 against `examples/go` on the same database: no differences.

At 68,000 users on the test machine (the official score of the first version), the window and the sharing took
Postgres from 2.9 to 1.6 cores and the whole box from 55% to 32% CPU for the same traffic.

**Writes on their own connections** (32), so a commit's WAL flush never holds up reads queued behind it on a
pipelined connection, and concurrent commits share flushes.

**SQL.** All answers are the same as SPEC.md's statements:

- List pages are one statement with their capped count. The page's ids are picked first from the bare index walk,
  with an inner `LIMIT 100` (the API's maximum page, so generic-plan row estimates stay small) and the request's
  `LIMIT` outside; tags, favorite count, `favorited`, author and `following` are computed for those rows only.
- The count subquery has `OFFSET 0` so Postgres can't pull it up into the outer query, where it would run once per
  article row instead of once per request. The global and tag counts, which nearly always reach the cap, step over
  999 index entries first instead of aggregating 1,000.
- Tag names by primary key per tag (`ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) ... ORDER BY 1)`)
  instead of a join that hashes every tag for every article.
- In the feed, `following` is `true`: every article in it is by an author the viewer follows, in the same snapshot.
- Favorite/unfavorite insert or delete and read the article back in one statement; the read runs in the
  statement's snapshot, which doesn't include its own write, so the count is adjusted by the rows the CTE actually
  inserted or deleted, and `favorited` is what the request just set.
- Comments are one statement (`LEFT JOIN LATERAL` from the article), so a missing article (404) and an empty thread
  are told apart without a second query.

**Session settings** on our own connections (rule 2): `plan_cache_mode = force_generic_plan`, `jit = off`,
`max_parallel_workers_per_gather = 0`, `enable_memoize = off`; and `sslmode=disable` for the local connection
(libpq's default `prefer` would have Postgres encrypt every result).

**Binary results, text parameters.** Rows are read from libpq's result as binary (int8, bool, timestamptz as
microseconds since 2000, `text[]` arrays) and written straight into the JSON response.

**bcrypt** runs on its own threads (at a lower scheduling priority than the event loops and Postgres), so a hash
never blocks a loop; the finished job comes back to its loop through a mailbox and an eventfd. A cost-10 hash is
about a million Blowfish encryptions, each a chain of dependent S-box loads, so one hash at a time leaves the core
mostly waiting on load latency. `src/bcrypt.c` computes up to 4 hashes at once in one thread, each step done for
all of them back to back, so their chains overlap: on the test machine 13 ms of CPU per hash with 4 at once
instead of libxcrypt's 37 ms (on a core shared with its hyper-thread sibling: 24 ms instead of 40 ms). Every hash
is still full bcrypt at cost 10 with a fresh salt from libxcrypt, and every login is verified against its stored
hash. The first worker lets its batch fill for up to 150 ms (at moderate load logins are too rare to fill it
otherwise: 1.2 hashes per batch on average without the wait, 3.3 with it); the other workers only start when two
full batches are waiting. `bin/conduit --bcrypt-selftest` checks the output
against libxcrypt on random passwords, salts and `$2a$`/`$2b$`/`$2y$` settings. `$2a$` with password bytes
>= 0x80 (where libxcrypt applies a countermeasure for an old bug) and other formats go to libxcrypt.

## Rules

- No caching across requests: every request reads Postgres while it's being served. Only connections and prepared
  statements are reused. Requests share rows only within one batched statement, while all of them are waiting (see above).
- Every password is hashed with bcrypt cost 10 (fresh salt from libxcrypt's `crypt_gensalt_rn`), every login
  verifies against the stored hash, and passwords over 72 bytes are rejected (422) rather than truncated. Every
  request with a token verifies its HS256 signature, `alg` and `exp`.
- Writes are committed before the response (synchronous commit, see above). Nothing in the database is created or
  altered; only session settings are used. 38 Postgres connections in total.

## Configuration (env, optional)

`THREADS` (event loops, default CPUs/4), `PG_READ_PER_LOOP` (3), `PG_WRITE_PER_LOOP` (16), `PG_DEPTH` (batches in
flight per read connection, 1), `BATCH_MAX` (256), `READ_WINDOW_US` (how long a read kind collects a batch, 40000), `BCRYPT_THREADS` (CPUs; all but one are spare capacity), `BCRYPT_LANES` (hashes computed together, 4, at most 8), `BCRYPT_WINDOW_MS` (how long the first worker waits
for its lanes to fill, 150),
`BCRYPT_NICE` (10).
`SHARE_READS` (default 1): tag-list requests that are waiting when the statement goes out share one execution
(0: one row each).

## Credits

Ideas taken from the write-ups of other submissions, implemented here from scratch:
[csharp-sockets-jh-d](../csharp-sockets-jh-d) (batched `unnest` + `LATERAL` reads tagged by ordinal, Memoize off,
separate write connections), [c-iouring-tigokraft](../c-iouring-tigokraft) (tag names by primary key, page ids
before per-article work, the bounded inner `LIMIT 100`, generic plans, no TLS on the loopback connection, few
connections), [rust-tokio-Scooter1337](../rust-tokio-Scooter1337) (sharing one execution among waiting tag-list
requests; interleaving several bcrypt hashes in one thread, also in c-iouring-tigokraft),
[rust-epoll-WorriedArrow](../rust-epoll-WorriedArrow) (a time window that fills read batches, sharing pages,
counts and per-article data within a batch, the feed count over an array of followees, waiting for bcrypt lanes to
fill).

## Local results (not official)

On a local emulation of the box (8 CPUs of a 16-thread desktop, Postgres 18 with the box's config, full seed, load
generator on the other 8 CPUs over loopback), 5-minute holds: 150,000 users at p95 74 ms, p99 107 ms (box CPU 76%)
and 160,000 users at p95 80 ms, p99 120 ms (77%); past ~170,000 users the local load generator itself stalls, for
the leader too. The first version (official score 68,000) used 55% of the box at 68,000 users there; this one
uses 32%. These numbers only compare submissions on that machine.

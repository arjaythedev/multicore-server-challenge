# C + epoll + libpq pipeline mode, batched reads

Front: direct

| Piece | Version |
|---|---|
| Language | C (gnu11), GCC 13.3 from Ubuntu 24.04 |
| HTTP/1.1, JSON, JWT (HS256), routing | hand-written, in `src/` |
| Postgres driver | libpq (`libpq-dev`, 18.x from the PGDG repo that the box already has; 14+ works) in pipeline mode |
| HMAC-SHA256 | OpenSSL 3.0 SHA-256 (`libssl-dev`) |
| bcrypt | libxcrypt 4.4.36 (`libcrypt-dev`), cost 10 |

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
list, a profile, a page of each list kind, the feed) wait in a per-loop queue. When a read connection has nothing in
flight, the kind whose oldest request has waited longest goes out as one statement: the per-request query is the
inner side of a `LATERAL` join over the unnested parameters of every waiting request, and each row carries its
request's ordinal.

```sql
SELECT r.i, x.* FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY AS r(v, k, i)
CROSS JOIN LATERAL (<the per-request query, with r.v as the viewer and r.k as the slug> LIMIT 1) x
```

Each request still gets its own execution of its own query, in the statement's snapshot, while it is being served:
the inner queries are correlated with their request row (by their parameters, or `r.i > 0` where nothing else ties
them to it), and Memoize is off for the session, so no request is ever handed a row cached from another request's
lookup. At low load a batch holds one request and nothing waits; under load the queues fill while the connections
are busy, so batches grow by themselves (100-250 requests at the limit). Six read connections in total turned out to
be the best trade between filling batches and keeping Postgres's cores busy. Rows are handed out by ordinal, and a
batch whose rows don't come back grouped per request in order fails with 500 instead of mixing anything up.

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

**bcrypt** runs on its own threads (one per CPU, at a lower scheduling priority than the event loops and Postgres),
so a ~40 ms hash never blocks a loop; the finished job comes back to its loop through a mailbox and an eventfd.

## Rules

- No caching across requests: every request reads Postgres while it's being served. Only connections and prepared
  statements are reused. Batching shares statements, never rows (see above).
- Every password is hashed with bcrypt cost 10 (fresh salt from libxcrypt's `crypt_gensalt_rn`), every login
  verifies against the stored hash, and passwords over 72 bytes are rejected (422) rather than truncated. Every
  request with a token verifies its HS256 signature, `alg` and `exp`.
- Writes are committed before the response (synchronous commit, see above). Nothing in the database is created or
  altered; only session settings are used. 38 Postgres connections in total.

## Configuration (env, optional)

`THREADS` (event loops, default CPUs/4), `PG_READ_PER_LOOP` (3), `PG_WRITE_PER_LOOP` (16), `PG_DEPTH` (batches in
flight per read connection, 1), `BATCH_MAX` (256), `BCRYPT_THREADS` (CPUs), `BCRYPT_NICE` (10).
`SHARE_READS` (default 0): if 1, tag-list requests that are all waiting when the statement goes out share one
execution (the result is never kept for later requests).

## Credits

Ideas taken from the write-ups of other submissions, implemented here from scratch:
[csharp-sockets-jh-d](../csharp-sockets-jh-d) (batched `unnest` + `LATERAL` reads tagged by ordinal, Memoize off,
separate write connections), [c-iouring-tigokraft](../c-iouring-tigokraft) (tag names by primary key, page ids
before per-article work, the bounded inner `LIMIT 100`, generic plans, no TLS on the loopback connection, few
connections), [rust-tokio-Scooter1337](../rust-tokio-Scooter1337) (sharing one execution among waiting tag-list
requests, off by default here).

## Local results (not official)

On a local emulation of the box (8 CPUs of a 16-thread desktop, Postgres 18 with the box's config, full seed, load
generator on the other 8 CPUs over loopback), 2-minute probes: 145,000 users pass (38,000 req/s, p95 ~100 ms,
p99 ~200 ms); a 5-minute hold passes at 140,000 users. Under the same setup the current leader passes about the
same number of users, so these numbers only compare submissions on that machine.

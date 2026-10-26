# Julia: raw epoll, own Postgres client, batched reads

Front: direct

| | |
|---|---|
| Language / runtime | Julia 1.13.2 (official tarball, sha256-checked in `install.sh`) |
| HTTP | own HTTP/1.1 server on raw non-blocking sockets and `epoll`, called through `ccall`: no framework, no libuv |
| Postgres | own client for wire protocol 3.0 (SCRAM-SHA-256, extended query protocol, binary parameters and results): no LibPQ |
| JSON | written straight from Postgres's binary rows; a small validating parser for request bodies |
| bcrypt, JWT | own bcrypt (cost 10, `$2a$`/`$2b$`/`$2y$`, four hashes interleaved); own SHA-256/HMAC for HS256 |
| Dependencies | none outside Julia's standard library (`Sockets`, only to resolve the database host name) |

## Design

Postgres takes most of the box's CPU, so the server aims at little work per request on both sides, and at sending
Postgres as few statements as possible.

**Shared-nothing event loops.** Two loop threads (`LOOPS`), each with its own `SO_REUSEPORT` listener, `epoll` set,
client connections, Postgres connections and request queues. Nothing on the request path is shared between threads or
locked. Every call that can block in the kernel (`epoll_wait`, a bcrypt worker's wait) is a `gc_safe` `ccall`, so a
parked thread never holds up Julia's garbage collector. The hot path allocates almost nothing: buffers, requests and
batches are pooled per loop. Under full load the process allocates about 0.2 MiB/s, and a GC runs about once a minute.

**HTTP.** Edge-triggered sockets. A connection holds a read buffer only while it has unparsed bytes: each request's
path, query, token and body strings are decoded into its own pooled request object before it is dispatched, so the
tens of thousands of idle and waiting connections hold no buffers. The response body is written into the request's
buffer after a reserved gap, and the headers go in the gap last, so each response is one `send`.

**Batched reads.** Requests of the same kind (an article by slug, a page of the global list, a feed page, ...) that
queue while the loop's read connections are busy go to Postgres as one statement. The per-request query is the inner
side of a `LATERAL` join over the unnested parameters of the waiting requests, and every row comes back tagged with its
request's index:

```sql
SELECT r.i, x.* FROM unnest($1::int4[], $2::int8[], $3::text[]) AS r(i, v, k)
CROSS JOIN LATERAL (<the per-request query, with r.v as the viewer and r.k as the slug>) x
```

Each request's data still comes from its own execution of its query, in the statement's snapshot, while the request
is being served. Nothing is shared between requests: subqueries that use no request parameter (the tag list, the
global count) are tied to the request row (`WHERE r.i >= 0`) so they run once per request, and Memoize is off for
the session. There's no timer. Whenever a read connection is free, the kind whose oldest request has waited longest
sends everything it has queued (up to 64). At low load each batch has one request and nothing waits. Under load,
batches grow while the connections are busy. Six read connections in all (three per loop) gave the best throughput:
more connections mean smaller batches and more per-statement overhead in Postgres, and fewer leave its cores idle.

**Writes on their own connections** (four per loop), so a read never queues behind a commit's WAL flush. Each write
is a single Sync group, so it's one implicit transaction and one round trip. Follow/unfollow write and read back in
one statement (a data-modifying CTE). Favorite/unfavorite run the write, then the article read as a second statement
in the same group, so the read sees a conflicting write that the insert waited for. Article creation (insert, new
tags, article tags, read-back) is also one group.

**Own Postgres client.** Every statement is prepared once per connection at startup, with generic plans
(`plan_cache_mode = force_generic_plan`), no JIT and no parallel workers, all set in the startup packet. A query is
a Bind/Execute/Sync written into the connection's send buffer. The loop flushes each connection once per `epoll`
round, so everything queued in that round goes out in one `send`. Replies are parsed in place: columns are offsets into
the receive buffer, text goes from there into the JSON output, and arrays and timestamps are decoded from their
binary form.

**SQL** (session settings only, nothing in the database changed). The read SQL follows
[csharp-sockets-jh-d](../csharp-sockets-jh-d)'s, MIT-licensed:

- A page is cut in a subquery before any join or per-row work, so `OFFSET` rows cost an index step only.
- Tag names are looked up by primary key per tag. They're sorted by the app when the database collation is code-point
  order (`C`, `C.UTF-8`, checked at startup), and by Postgres otherwise.
- `favorited` and `following` are bounded primary-key probes. In the feed, `following` is constant true. For comments,
  the viewer's followees are read once per request and each comment's author is checked against them.
- Capped counts: the global count, the tag count and the feed count first test whether a 1000th row exists
  (`OFFSET 999`), which is about 45% cheaper than counting 1000 rows. All the seed's tags and about 80% of its feeds
  hit the cap. Author and favorited counts are usually small, so they're counted directly.
- Tags are inserted only when missing, in name order, so there's no sequence burn and no deadlock between concurrent
  creates.

**bcrypt, interleaved.** A Blowfish round is a chain of dependent table loads, so one hash leaves most of a core
idle. Each bcrypt thread takes up to four queued jobs and runs them in lockstep in one loop body (`NTuple` lanes), so
the out-of-order core overlaps the four chains. That's 15.7 ms per hash with four lanes, vs. 45 ms for one lane and
47 ms for the system's libxcrypt on the same machine. Like group commit, a worker holding fewer than four jobs waits up
to 40 ms for more. Two bcrypt threads run at nice 5. Logins are about 0.1% of requests, so their latency matters far
less than the CPU they would take from Postgres. Blowfish's initial state, the hex digits of π, is computed with
`BigFloat` at precompile time, not pasted in as a table. Results are checked against libxcrypt.

## Rules

There's no caching of any kind across requests. Every request reads Postgres while it's being served, and only
connections and prepared statements are reused. Batching shares statements, never results (see above). Every login
verifies bcrypt cost 10 against the stored hash, and every registration and password change hashes with cost 10 and a
fresh salt from `getrandom`. Every request verifies the JWT's HS256 signature, `alg` and `exp`. Writes are committed
before the response is sent (synchronous commit). Nothing in the database is created or altered: only session
settings are used. The server opens 14 Postgres connections in all.

## Configuration (env, optional)

`LOOPS` (2), `DB_READ_CONNS` (3 per loop), `DB_WRITE_CONNS` (4 per loop), `BATCH_MAX` (64), `READ_DEPTH` (1 statement
in flight per read connection), `WRITE_DEPTH` (2), `BCRYPT_THREADS` (2), `BCRYPT_NICE` (5), `BCRYPT_WAIT_MS` (40),
`STATS` (seconds between allocation/GC reports on stderr; 0 = off). Nothing needs to be set.

```sh
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

## Local results

On a Ryzen 7 2700X, with the server and Postgres 18 (pgtune settings for 8 CPUs / 16 GB) sharing 4 cores / 8
threads, and the load generator on the other 4 cores. Full seed, fresh database each run, `-think-scale 0.1` (so
10,000 users make the request rate of about 100,000). These are local comparisons, not official scores. The #1
submission ran on the same setup for reference:

| | users (× think 0.1) | req/s | p95 ms | p99 ms | login p99 ms | CPU app / Postgres |
|---|--:|--:|--:|--:|--:|---|
| this | 10,000 | 25,531 | 34 | 51 | 204 | 173% / 529% |
| rust-tokio-Scooter1337 | 10,000 | 25,783 | 24 | 33 | 399 | 189% / 535% |
| this | 16,000 (saturated) | 26,321 | 304 | 330 | 504 | 211% / 523% |
| rust-tokio-Scooter1337 | 16,000 (saturated) | 25,972 | 350 | 413 | 10,002 (50% timed out) | 204% / 540% |

With 50,000 real connections (two load generators, think 0.4), it ran at 25,339 req/s with zero errors.

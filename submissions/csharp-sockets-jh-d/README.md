# C# / .NET 10: own HTTP server, own Postgres client, batched reads

Front: direct

| | |
|---|---|
| Language / runtime | C# 13, .NET 10 (SDK 10.0.402, official tarball, checksummed in `install.sh`) |
| HTTP | own HTTP/1.1 server on `System.Net.Sockets` (keep-alive, `Content-Length` bodies): no ASP.NET Core |
| Postgres | own client for the PostgreSQL wire protocol 3.0 (SCRAM-SHA-256, extended query protocol, binary results): no Npgsql |
| JSON | `System.Text.Json` `Utf8JsonWriter`, fed straight from Postgres's binary rows; `JsonDocument` for request bodies |
| bcrypt, JWT | own bcrypt (cost 10, `$2a$/$2b$/$2y$`); HS256 via a per-thread keyed `HMACSHA256` |
| Dependencies | none outside the .NET base library (`packages.lock.json` is empty) |

## Design

The server shares the box's CPUs with Postgres, so the design aims at little work per request on both sides.

**Batched reads.** Much of a cheap statement's cost in Postgres is per-statement overhead (protocol messages,
executor startup and shutdown, snapshot, transaction start and end) rather than work on rows. Reads of the same kind
(an article by slug, a page of the global list, a feed page, ...) that arrive while earlier ones of that kind are
still in Postgres are sent together as one statement: the per-request query becomes the inner side of a `LATERAL`
join over the unnested parameters of the waiting requests, and every row comes back tagged with its request's index.

```sql
SELECT r.i, x.* FROM unnest($1::int4[], $2::int8[], $3::text[]) AS r(i, v, k)
CROSS JOIN LATERAL (<the per-request query, with r.v as the viewer and r.k as the slug>) x
```

Each request's data is still read by its own execution of its query, in the statement's snapshot, while the request
is being served. Nothing is shared between requests: subqueries that don't use a request parameter (the global list
count, the tag list) are tied to the request row (`WHERE r.i >= 0`) so that Postgres runs them once per request, not
once per statement; list counts sit in an `OFFSET 0` subquery so the planner can't pull them up and run them once
per article row; and Memoize is off for the session, so no request is handed a row another request's lookup fetched.

There is no timer. Requests wait in their kind's queue until a read connection is free (one statement in Postgres per
connection); then the kind whose oldest request has waited longest sends everything it has queued (up to 64) as one
statement. At low load every batch has one request and nothing waits; under load requests stay queued until a backend
is actually free, so batches grow by themselves and nothing queues behind a long statement on a connection. A kind
can hold at most 6 connections at once.

**Writes on their own connections.** Every commit waits for its WAL flush. On a pipelined connection every read
queued behind it would wait too, so writes go to connections of their own (where concurrent commits share flushes:
Postgres's group commit), and reads to others.

**Own Postgres client.** Every statement is prepared once per connection at startup; a query is a Bind/Execute/Sync
written into the connection's send buffer, and many are pipelined per connection. A reader thread per connection
parses replies in place: rows are spans of the receive buffer, text columns are UTF-8 and go into the JSON writer as
UTF-8 (no strings), arrays are decoded from their binary form, timestamps from microseconds. JSON property names are
encoded once at startup. Sends never block a
reader thread (a blocking send there could deadlock against Postgres blocking on its own output): the socket is
written with `MSG_DONTWAIT`, and whatever it won't take goes to a flusher thread.

**Own HTTP server.** Raw sockets with two reusable `SocketAsyncEventArgs` and a small buffer per connection, a pooled
context per request, the response headers written last into space reserved in front of the JSON body (one buffer,
one send). Socket completions run inline on the epoll threads (`DOTNET_SYSTEM_NET_SOCKETS_INLINE_COMPLETIONS=1`): a
request is parsed, authenticated and queued for Postgres on the thread that received it, and its response is sent
from the Postgres reader thread that completed it. No allocations per request on the read paths.

**Postgres settings and SQL** (session settings only):

- Generic plans (`plan_cache_mode = force_generic_plan`): every statement's generic plan is as good as its custom one,
  so planning per execution is skipped.
- No JIT, no parallel workers, no Memoize; no TLS on the loopback connection.
- One statement per read; follow/unfollow write and read back in one statement (a data-modifying CTE);
  favorite/unfavorite write, then read back as a second statement of the same Sync group (it then sees concurrent
  writes the insert waited for); article creation is one Sync group (one implicit transaction).
- The page is cut in a subquery before joins and per-row work, so `OFFSET` rows cost an index step only.
- Tag names by primary key per tag, sorted by the app when the database collation is code point order (`C`,
  `C.UTF-8`, checked at startup: UTF-8 byte order is then exactly `ORDER BY name`), by Postgres otherwise.
- `favorited`/`following` are bounded per-row probes; in the feed `following` is constant true (same snapshot); for
  comments the viewer's followees are read once per request and each comment's author is checked against them.
- Capped counts read at most 1000 index entries; the global count checks whether a 1000th row exists.
- Tags are only inserted when missing, in name order (no sequence burn, no deadlock between concurrent creates).

**bcrypt, interleaved.** A Blowfish round is a chain of dependent table loads, so one hash leaves much of a core idle.
Two bcrypt threads each take up to four queued hashes and run them interleaved. Like group commit, the thread holding
one hash waits a short while for more before it starts; a queued hash whose client has gone is dropped.

**Runtime.** Workstation concurrent GC, tiered PGO, idle thread-pool workers sleep instead of spinning.

## Rules

No caching of any kind across requests: every request reads Postgres while it is served (only connections and
prepared statements are reused); batching shares statements, never results (above). Every login verifies bcrypt cost
10 against the stored hash; every registration and password change hashes with cost 10; every request verifies the
JWT signature, `alg` and `exp`. Writes are committed before responding (synchronous commit). Nothing in the database
is created or altered; only session settings are used. 28 connections in total.

## Configuration (env, optional)

`DB_CONNS` (12, reads), `DB_WRITE_CONNS` (16), `DISPATCH_DEPTH` (1), `BATCH_MAX` (64), `BATCH_INFLIGHT` (6), per kind
`BATCH_<KIND>=<max>:<in flight>` (kinds: tags, article, comments, profile, user, list, author, tag, favorited, feed),
`BCRYPT_THREADS` (2), `BCRYPT_BATCH_WAIT_MS` (300), `BCRYPT_NICE` (0), `DB_OPTIONS`. Nothing needs to be set.

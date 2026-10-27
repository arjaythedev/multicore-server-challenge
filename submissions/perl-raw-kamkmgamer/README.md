# Perl / raw prefork Conduit server

- **Language:** Perl 5.38 (Ubuntu 24.04 system Perl)
- **Framework:** none. A hand-written HTTP/1.1 server: one `fork()`ed worker per database
  slot, each an `EV` (libev/epoll) event loop with one blocking `DBI`/`DBD::Pg` connection.
- **Driver:** DBI + DBD::Pg (libpq), server-side prepared statements, one connection per worker
- **bcrypt:** Crypt::Eksblowfish, cost 10, verified against the stored hash on every login
- **JSON:** JSON::XS

**Front: direct.** The process binds `0.0.0.0:80` itself and holds every keep-alive connection; there is no Nginx in the request path.

## Deployment shape

95 worker processes (95 of the 97 non-superuser slots) each hold one Postgres connection. Every
worker has its own `SO_REUSEPORT` listening socket, so the kernel spreads new connections
across workers without a thundering herd. With 100,000 users that is about 1,053 keep-alive
sockets per worker. Idle sockets are held for 75 s.

Within a worker, `EV` (libev's epoll backend) multiplexes its client sockets in C. A request
runs its SQL on that worker's connection; the other sockets in that worker wait only for the
duration of the query (a few milliseconds), and 95 workers give 95 concurrent database
queries. This is deliberately a blocking-per-worker design: Perl has no production async
Postgres driver, and 95 blocking slots are simpler and cheaper than a pure-Perl async facade.

## Optimizations and choices

- **No framework and no Mojo.** The request parser, router, JSON shaping and response writer
  are all direct Perl. No middleware, no per-request object graph, no template layer.
- **95 processes instead of 8.** The previous Perl submission used 8 blocking workers and
  saturated at ~1,100 users. Here the database concurrency is 95, which is what the scoring
  runs are actually limited by, while each worker's epoll loop keeps its ~1,050 keep-alive
  sockets off the critical path.
- **Direct front.** Serving `:80` from the workers removes the reverse-proxy hop and its CPU.
  `EV` uses epoll, so tens of thousands of mostly-idle sockets cost no per-poll Perl work.
- **One prepared statement per SQL shape, reused forever.** DBD::Pg server-side prepares keep
  plans on the connection. Only connections and plans are cached; no data, responses, JWT
  results or bcrypt results are cached across requests.
- **Reference SQL shapes, hot-path rewrites.** Page and count semantics, `LIMIT 1000` caps and
  newest-first ordering stay as specified. The per-row tag array uses primary-key lookups instead
  of the hash join over `tags` that the generic plan picks; favorites count/favorited share one
  `LATERAL` scan; `enable_seqscan=off` keeps the tiny `tags` lookup on its primary key. These are
  query-shape changes only, not data caching.
- **Manual fast paths.** Errors are constant byte strings, the JWT header is a constant,
  timestamps are truncated with one regex, and article rows are turned into response hashes in
  one pass. Tags and boolean columns come back from DBD::Pg as native Perl arrays/0-1.
- **`SET TIME ZONE 'UTC'`** per connection (session-level, allowed) for deterministic timestamps.
- **Security is not weakened.** bcrypt cost 10 on every registration/update and a real verify on
  every login; HS256 signature and `exp` checked on every request with no verification cache;
  every write commits before the response is sent.

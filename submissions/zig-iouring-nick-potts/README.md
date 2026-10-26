# Zig / io_uring

Front: direct

Start-time flags come from one environment variable, `CONDUIT_FLAGS`: a comma-separated list of `name=on|off`, read
once at startup (unset or empty: every default; an unknown name or value stops the server). Each combination is its
own specialised build of the server, chosen at startup, so nothing on the request path tests a flag and an `off`
feature costs nothing.

- `shed`, default on, off with `CONDUIT_FLAGS=shed=off`: under CPU saturation the server refuses route classes in a
  fixed, measured cost order, heaviest first (sign-ups and sign-ins first), with an immediate `503` and
  `Retry-After: 1`. It adds one class each second the box's CPU stays below 3% idle (password hashing at idle
  priority counts as idle) and removes one each second it is above 8%, within an error budget of 0.9% of requests.
  This version has no scored result yet. It is behind a flag because it needs a maintainer ruling (rule 8).
- `ackdelay`, default on, off with `CONDUIT_FLAGS=ackdelay=off`: after each response the server turns
  `TCP_QUICKACK` off on that client socket, through the io_uring (a socket `setsockopt` command, no extra syscall), so
  the next request's ACK leaves with its response instead of in a packet of its own. Without it, after a response
  slower than the kernel's delayed-ACK timer (about 40 ms), the kernel ACKs the connection's next request at once
  when it comes after an idle gap longer than the retransmit timeout, as a keep-alive client's requests do. With it
  that ACK waits for the response, whose reads batch on the 5 ms clock. It only sets an option on the server's own
  sockets. On the 8-vCPU test box at 140,000 users it cut the server's pure ACKs from 0.81 to 0.59 a request and the
  receive CPU's softirq time by about 12%; CPU per request moved by less than the noise (-1.5 µs). Two official
  searches with it held 150,000 users where the build without it held 140,000.

Zig 0.17.0 (official tarball, pinned by SHA-256 in `install.sh`) and PostgreSQL 18. No other dependencies: the
HTTP server, the Postgres wire client, JSON, JWT, SHA-256 and the bcrypt glue are written here against raw Linux
syscalls.

- Several single-threaded worker processes, each with its own `SO_REUSEPORT` listener, io_uring (single issuer,
  deferred task work), write connection and bcrypt threads. Multishot accept, multishot recv into provided buffers,
  and requests parsed straight out of the received buffer. A response is built behind a reserved header gap and
  leaves in one send.
- One more process, the drain process, owns every read connection (5/8 of the cores, 5 at 8 CPUs; fewer backends make
  bigger drains and contend less for buffer pins and locks: 9 µs per request less on the 8-CPU test box than 6) and
  one read queue for the whole box. A worker sends each read through shared memory: per worker an ask ring and an
  answer ring, single producer and single consumer each, mapped before forking. The drain process answers with each
  read's rows in Postgres's DataRow layout, and the worker writes the JSON. Eventfds wake each side, and a worker
  writes one only while the drain process sleeps with nothing queued. With one worker there is no drain process and
  the worker keeps its own read connections.
- Postgres v3 protocol from scratch: named prepared statements with generic plans, binary parameters and results.
  Reads gather on a 5 ms batch clock: once the oldest queued read has waited 5 ms, a free read connection takes every
  queued read of every worker into one Sync group, one group in flight per connection. Requests for the same
  statement in that drain run as one execution with one array per parameter, and the rows go back by ordinal. Reads
  that take no parameters and are the same for every viewer share one execution. A drain with two or more reads of
  the kinds the mega statement covers sends those as one execution of one statement (MEGA), which returns each
  article and the tag list once beside each read's own keys and viewer flags. It shares work only among the reads
  queued before it started, within its one execution. No returned data is retained across requests. The reads it
  does not cover run beside it, one statement for one request and its batched form for more.
- Writes go to their own connection, one per worker. A lone write waits 3 ms for company; then up to 128 queued
  writes go out as one Sync group without BEGIN or COMMIT, so they commit together at the Sync and are answered after
  it (group commit). Favorites, unfavorites, follows, unfollows and comments of one group each run as one execution
  of their batched form. Register and user update, which can fail on a taken name, run alone. A failed group
  retries its requests one per group. The re-read after a favorite, unfavorite or article update goes on the read
  queue once its group has committed.
- Overload shedding (`shed`). Every 100 ms the first worker reads the box's idle and iowait time from `/proc/stat`
  and adds the CPU time of every worker's idle-priority bcrypt hashers, which record their thread ids in a page all
  processes share (`/proc/<tid>/schedstat`); the normal-priority watchdog hasher is not counted. From that it moves a
  depth it publishes in the shared page: the first class is refused as soon as idle falls below 3%, one more each
  further second below 3%, one fewer each second above 8%, and between the two the depth holds. The classes are
  routes in one fixed order, heaviest first: register, login, feed, article create, list, favorite, comments, comment
  create, article, profile, tags, then the routes measured nowhere (unfavorite, article update and delete, comment
  delete, follow, unfollow, user update, user get). Register (17.6 ms) and login (15.5 ms) are the cost per request
  an earlier version of the shed learned on this server (Postgres share plus hasher CPU), in its log lines from the
  174k and 183k user holds on Hetzner at submit 2b10541; the rest follow the Postgres time per request of each
  endpoint measured on #7 under the same workload (pg_stat_statements at 100,000 users, executor time mapped onto
  measured backend CPU). An unknown route is never refused.
  Each worker refuses the classes within the depth in full, right after routing and before
  any other work, with the connection kept open. Every request earns 0.9% of an error and every refusal spends a
  whole one, so from startup the refusals never exceed 0.9% of requests; a refusal of the class at place r (from 0)
  needs credit for r + 1 errors, so the heavier classes get the budget first, and a request the budget does not pay
  for is served. Every other response with status 400 or above spends one too, into debt of at most ten seconds'
  earnings. Unspent credit is capped at what the last second earned. Each worker logs a line every 10 s in which it
  refused anything or the box was overloaded: the depth, the share of the period overloaded, the lowest and average
  idle (hasher CPU counted as idle), and per class refused, its place in the order and route name, the refusals and
  the requests.
- At startup every statement is prepared and described against the live database, and the server refuses to start
  unless each one returns exactly the column types it was written for.
- JSON is written straight from the Postgres receive buffer. Each response shape is generated at compile time from a
  field list, so a response is a fixed sequence of constant copies and value encoders.
- JWT HS256 is verified on every request with a precomputed HMAC key schedule and SHA-NI when the CPU has it
  (chosen once at startup).
- bcrypt cost 10 runs on worker threads in batches: one kernel call hashes up to 8 passwords, their Blowfish rounds
  interleaved so the S-box lookups overlap, each password on its own lane with its own salt (identical jobs are never
  merged). Startup self-tests every kernel and picks the kernel and width that cost the least CPU on this machine.
  The hasher threads run at SCHED_IDLE, so hashing uses only CPU nothing else wants. The event loop keeps the queue
  and hands each hasher its batch through a slot of its own, so no thread ever waits on a lock a starved hasher holds.
  Since an unprivileged thread can't raise its priority again, one more hasher stays at normal priority and takes
  any job still unfinished one fill window plus two batches' CPU time after it was queued.
  Password bytes follow golang.org/x/crypto/bcrypt, the reference: every byte counts, embedded NULs included, and a
  password over 72 bytes is rejected on register and update.

No result, token or password caches; every request reads Postgres. No schema or configuration changes, no host
tuning.

```sh
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

## Credits

The SQL statements start from [#7 rust-tokio-Scooter1337](https://github.com/arjaythedev/multicore-server-challenge/pull/7)
(rank 1): list page and capped count in one statement, tag names by primary key, write CTEs that fold the slug
lookup into the mutation, and the `unnest ... CROSS JOIN LATERAL` read batching. The ideas are reimplemented here;
no code is copied.

Every statement in `src/sql/` except ARTICLE_DELETE (the server's own) is branch sql-stack's pack
stack-15-wdelay3 (ad2bf31) byte for byte, so a pack's family ports by copying its files. Its MEGA.sql is
stack-14-fcset's (38ea7d9); stack-15 adds only the 3 ms write wait. sql-stack's REPORT (`sql/stack/REPORT.md`) is
unreviewed and still changing on its branch; this server relies on it for nothing but these files, which match the
packs by SHA-256.

The read batch clock is PR #47's two-phase gather, in the shape branch sql-proto measured (3135e10). One read
queue for all workers, in the drain process, follows sql-proto's measurement that four independent queues cost
1.211x the Postgres CPU of one shared queue (ade3905), and that one shared queue on a shorter clock costs the same
CPU at lower latency (ddc29aa).

The mega statement (`src/sql/MEGA.sql`, copied verbatim) is branch sql-stack's stack-14-fcset (38ea7d9): branch
sql-proto's MEGA2 and batching contract (fcb68a5, 5ee23e4) with the edits the stack kept, each from its own branch:
the grouped tag scan (sql-proto), capped count probes on the index's own columns (sql-lists), the feed's follows
read once with feed rows followed by construction (sql-feed), its comment parts removed (sql-stack), each distinct
list request's capped count carried in its page and the feed's count proof from the drain's 10 most followed
authors (sql-proto), each list read's favorited and following flags from one probe per read (sql-proto), and
favorite counts from one grouped scan (sql-feed). The idea comes from PR #47.

The write pool and the write statements' batched forms (`src/sql/BATCH_*.sql` for the five writes, copied verbatim)
come from branch sql-writes (3eb613c, writes-1conn), and the 3 ms write wait from its writes-delay3ms (c39809b), as
branch sql-stack's stack-15-wdelay3 (ad2bf31) stacks them.

The comments statements (`src/sql/COMMENTS_LIST_SET.sql`, `src/sql/BATCH_COMMENTS_LIST_SET.sql`, copied verbatim)
and their contract come from branch sql-articlepage (0684101), as branch sql-stack's stack-15-wdelay3 (ad2bf31)
stacks them.

The bcrypt engine (`src/bcrypt/`) is branch bcrypt's (c939d52, `bcrypt/REPORT.md`), vendored as is.

# CHICKEN Scheme: Spiffy + postgresql egg

**Front: nginx**

A deliberately plain submission: CHICKEN Scheme compiled to C, the stock Spiffy web server, and off-the-shelf
eggs for everything else (Postgres, JSON, bcrypt, HMAC). It runs the reference SQL from `SPEC.md` verbatim.
There is no hand-written HTTP parser, JWT library or connection pool trickery. One file, `conduit.scm`, about
680 lines. Passes `bench/cmd/conformance` 197/197.

| Piece | Version |
|---|---|
| Language | CHICKEN Scheme 5.4.0, official release tarball (sha256-checked) built into `/opt/chicken` by `install.sh` |
| HTTP | [spiffy](https://wiki.call-cc.org/eggref/5/spiffy) 6.5.2 (with intarweb 2.1.0, uri-common 2.0) |
| Postgres | [postgresql](https://wiki.call-cc.org/eggref/5/postgresql) 4.1.6, libpq bindings that wait on the socket through CHICKEN's scheduler, so a query only blocks its own green thread |
| JSON | [medea](https://wiki.call-cc.org/eggref/5/medea) 4 for parsing request bodies; responses use a ~40-line writer in `conduit.scm` (see below) |
| bcrypt | [crypt](https://wiki.call-cc.org/eggref/5/crypt) 1.0.1 (system libcrypt `crypt()`; salts from its bundled crypt_blowfish gensalt, cost 10) |
| JWT | HS256 from [hmac](https://wiki.call-cc.org/eggref/5/hmac) 7.2.0 + [sha2](https://wiki.call-cc.org/eggref/5/sha2) 4.2.6 + [base64](https://wiki.call-cc.org/eggref/5/base64) 1.0; header `alg` must be `HS256`, `exp` is required |

`build.sh` installs the eggs at pinned versions into `./eggs` (not system-wide) and compiles `conduit.scm`
with `csc -O3`. A clean build takes about 4–5 minutes, almost all of it compiling eggs.

## Multicore model

CHICKEN has green threads, not OS threads, so one process uses one core. The parent opens the listening socket
and forks `WORKERS` processes, each running Spiffy's own accept loop on that shared socket (one green thread
per connection). `start.sh` defaults to **two workers per core** (16 on the box) because bcrypt runs on the
worker's only OS thread and stalls every other request on that worker for its ~50 ms. More processes means
fewer requests stuck behind any one login.

Each worker has its own small Postgres pool (a mutex + condition variable around a list of connections). The
workers share 80 connections between them (5 each on the box), keeping well under `max_connections`. If any
worker dies, the parent kills the rest and exits.

Behind Nginx because CHICKEN's scheduler `poll()`s every blocked thread's fd on each scheduling round, so per
request cost grows with the number of open connections. Locally, without Nginx, it was fine up to ~60
connections per worker and fell apart past ~125. Nginx's upstream keep-alive pool keeps that number small no
matter how many users are connected.

## Things that had to be fixed to make it work

Three things in the stack's defaults hurt badly under load. Fixing them was plumbing, not optimization:

- **Non-blocking listener.** CHICKEN's `tcp-listen` leaves the socket in blocking mode. With several
  processes polling it, they all wake for each new connection; one wins `accept()` and the others **block
  inside `accept()`**, which freezes every green thread in that process until the next connection shows up.
  Under a load test that's never, so whole workers hung. Setting `O_NONBLOCK` on the listener makes the losers
  get `EAGAIN`, which Spiffy's accept loop already catches and retries.
- **TCP_NODELAY + buffered output.** Spiffy writes the status line, each header and the body as separate
  `send()`s on an unbuffered port. On a keep-alive connection Nagle's algorithm then holds the tail until the
  peer's delayed ACK, adding ~40 ms to every request after the first. `tcp-buffer-size` makes each response
  one write when Spiffy flushes it, and accepted sockets get `TCP_NODELAY`.
- **Read the body before routing.** An early 401/422/404 that never read the request body left those bytes
  on the keep-alive connection, where they were then parsed as the next request.

## Performance change 1: a direct JSON writer

To find the biggest cost, I timed each part of a typical request in a compiled microbenchmark. For a
10-article list page, in the server's own CPU:

| Step | CPU |
|---|---|
| medea `json->string` (5.5 KB) | 0.99 ms |
| Postgres query + row parsing (client side) | 0.18 ms |
| intarweb request parse + response write | 0.11 ms |

Encoding the response cost about three times everything else combined. medea re-binds the current output
port for every nested value, finds each value's type by scanning a list of predicates, and copies every
string through `string-translate*` before writing it. `conduit.scm` has a small replacement that walks the
same data (alists → objects, vectors → arrays, `'null`) and writes straight to one string port, escaping
strings in runs. Its output is byte-identical to medea's (checked on list pages, full articles and an
escape/control-character/UTF-8 test), and it takes 0.26 ms for that page.

End to end, A/B behind the box's Nginx config on my 16-core machine (16 workers, load generator on the
same machine, so these numbers are only good for comparison):

| | Server CPU per request (1,200 users) | 2,500 users: req/s | p95 | p99 |
|---|---|---|---|---|
| medea writer | 1.95 ms | 2,230 | 1,270 ms | 2,148 ms |
| direct writer | 1.29 ms | 3,187 | 101 ms | 229 ms |

## Performance change 2: prepared statements

After the JSON fix, the largest remaining cost was Postgres parsing and planning every query on every
request (about 1 ms of database CPU per request; the article queries have several subqueries). Now each
connection `PREPARE`s a SQL string the first time it runs it and `EXECUTE`s it by name after that. That's
what pgx does for the Go example. The SQL stays inline in the handlers; only the `execute` /
`query-row` / `query-rows` helpers know about it. Statements hold query plans, never data, so this is
within rule 5. Plan choice is left at Postgres's default (`plan_cache_mode = auto`).

Same A/B setup as above:

| | Postgres CPU per request (1,200 users) | 3,000 users: req/s | p95 | p99 |
|---|---|---|---|---|
| unnamed statements | 1.07 ms | 2,986 | 853 ms | 1,412 ms |
| prepared statements | 0.66 ms | 3,285 | 511 ms | 904 ms |

The server's own CPU per request is unchanged (~1.3 ms), as expected.

## Other details

- Timestamps are formatted in SQL with `to_char(..., 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')` (session time zone
  UTC), which truncates to milliseconds as the spec asks.
- intarweb's `Authorization` parser only understands Basic/Digest, so the server registers a raw-string
  parser for that header to read `Token <jwt>`.
- Idle keep-alive connections time out after 120 s (Nginx's upstream keep-alive is 60 s).

## Build and run

```bash
sudo bash submissions/chicken-spiffy-wardjm/install.sh     # CHICKEN 5.4.0 -> /opt/chicken (CHICKEN_PREFIX overrides)
bash submissions/chicken-spiffy-wardjm/build.sh            # eggs -> ./eggs, binary -> bin/conduit
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=multicore-server-challenge \
  HOST=127.0.0.1 PORT=3000 bash submissions/chicken-spiffy-wardjm/start.sh
```

Environment: `DATABASE_URL`, `JWT_SECRET`, `HOST`, `PORT`, plus `WORKERS` (default `2 × nproc`) and
`DB_POOL_SIZE` (default `80 / WORKERS`).

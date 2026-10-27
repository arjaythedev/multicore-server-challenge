# Node.js + C++ (libuv, libpq pipeline, ring buffers)

**Front: direct**

Node.js runs the HTTP side (one event loop per process); a small C++ addon, built from source, runs everything
that is slow or latency-sensitive on that same libuv loop or on native threads. Zero npm dependencies.

| Piece | Version |
|---|---|
| Node.js | 24.11.0 (official tarball, sha256-checked by `install.sh`) |
| HTTP | `node:http`, hand-written router |
| Addon | C++20, raw Node-API (`node_api.h`), libuv from Node's own headers, built by `g++` in `build.sh` (no node-gyp) |
| Postgres | libpq from Ubuntu 24.04's `libpq-dev`, pipeline mode, driven by `uv_poll` |
| bcrypt | vendored `crypt_blowfish` (Solar Designer, public domain), cost 10, `$2b$` |
| JWT | HS256 in C++ on OpenSSL's HMAC-SHA256; `alg`, signature and `exp` checked on every request |

## Multicore model

* `src/main.js` pre-forks one worker per core and respawns a worker that dies. It never touches a request.
* Each worker listens on the shared port with `SO_REUSEPORT` (`reusePort: true`), so the kernel spreads the
  keep-alive connections evenly (no accept-mutex through the primary, no thundering herd).
* Each worker loads its own addon instance, which owns:
  * **Postgres lanes** (all on the worker's libuv loop, no threads): 4 read + 2 write connections, so 8 workers
    use 48 of the 95 allowed connections. Each connection is a nonblocking libpq connection in **pipeline mode**
    watched by `uv_poll`; many requests are in flight on one socket. Each request is its own pipeline segment
    (own `Sync`), i.e. its own implicit transaction, and it completes only when the `Sync` result arrives, i.e.
    after COMMIT. Writes live on their own connections so a commit's fsync never stalls the reads queued behind it.
  * **Ring buffers**: the in-flight requests of one connection are a `FifoRing` (results return in send order, so
    the head of the ring owns the next result). The bcrypt hand-off is a pair of lock-free `SpscRing`s per thread.
  * **bcrypt thread pool** (2 native threads per worker): login/register/password change never block the event
    loop; the event loop pushes a job into the thread's ring and is woken with `uv_async_send` when it is done.
* All statements are prepared once per connection at start-up.

## Optimizations

* **One round trip per request.** Postgres builds the response JSON (`json_build_object`/`json_agg`); the addon
  returns the bytes as a Buffer and JS writes them to the socket without ever materialising row objects.
  The "find the article (404), then act" pairs in the reference SQL are folded into single statements, and the
  list endpoints fetch the page of ids first and run the correlated subqueries only for those rows. The
  `articlesCount` (capped at 1000) is computed in the same statement as the page.
  Responses are identical to the reference SQL's (same ordering, slugs, counts, 3-digit UTC timestamps).
* `POST /api/articles` is three statements in one pipelined request (one transaction, committed before the
  response); tag creation is `ON CONFLICT DO NOTHING`.
* No caching of any kind: every request verifies its JWT (HMAC + `alg` + `exp`), every login runs bcrypt against
  the stored hash, every read goes to Postgres. No `synchronous_commit` change, no unlogged tables.
* Idle keep-alive connections are held for 125 s (above Nginx's 60 s and the load generator's 70 s think-time cap).
* `--max-semi-space-size=32` in each worker to cut scavenge overhead.

## Notes

* Passwords over 72 bytes (or containing a NUL) are rejected: 422 on register/update, 401 on login.
* `Front: direct` means the workers bind `HOST:PORT` themselves (the benchmark box gives `0.0.0.0:80`). The code is
  identical behind Nginx on `127.0.0.1:3000`; only this line would change.

Environment: `DATABASE_URL`, `JWT_SECRET` (required), `HOST` (127.0.0.1), `PORT` (3000), and optionally `WORKERS`,
`READ_CONNS`, `WRITE_CONNS`, `BCRYPT_THREADS`, `PG_SSLMODE` (default `disable`), `NODE_WORKER_FLAGS`,
`CONDUIT_STATS=1`.

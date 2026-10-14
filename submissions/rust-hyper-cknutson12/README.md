# Rust: hyper + tokio-postgres (pipelined), one statement per request

**Front: direct.** The server listens on `HOST:PORT` itself (`0.0.0.0:80` on the box) and holds every user's
keep-alive connection, so the ~11% of the box that Nginx used goes to Postgres instead.

## Stack (exact versions in `Cargo.lock`)

| Piece | Version |
|---|---|
| Rust | 1.99.0 (rustup, from `install.sh`) |
| HTTP | hyper 1.12.0 (`server`, `http1`), hyper-util 0.1.21, on tokio 1.53.2 (multi-thread runtime) |
| Postgres driver | tokio-postgres 0.7 (no TLS) |
| JSON | hand-written response writer; serde_json 1.0.154 for request bodies |
| JWT | HS256 with hmac 0.12 + sha2 0.10 + base64 0.22 |
| bcrypt | bcrypt 0.19.3, cost 10 |
| Allocator | mimalloc |

Release profile: opt-level 3, fat LTO, one codegen unit.

## Where the time goes, and what I did about it

On this workload the app is cheap and Postgres is the bottleneck, so almost everything here is about giving
Postgres less to do per request and using fewer of its backends.

1. **One statement per request.** The reference SQL takes 2–3 statements for most endpoints (look up the slug,
   then write, then re-read the article; or a page, then a count). Each one is a round trip, a parse/bind/execute,
   a snapshot and an implicit transaction in Postgres. Here every endpoint except the rare `PUT /api/articles/:slug`
   is a single statement:
   - lists and the feed fold the capped count into the page query (`WITH c AS (count) SELECT ... FROM c LEFT
     JOIN (page) ...`), so an empty page still returns its count;
   - comments fold the article lookup into the list (`articles LEFT JOIN LATERAL (newest 100 comments)`);
   - favorite/unfavorite, follow/unfollow, post/delete comment and delete article are data-modifying CTEs. The
     favorite response is computed in the same statement: the SELECT sees the snapshot from before the INSERT,
     so `favoritesCount` adds the row the INSERT reported (`RETURNING 1`; 0 rows if it already existed, which the
     snapshot already counts) and `favorited` is the constant `true` (and the reverse for DELETE);
   - creating an article (with its tags) is one statement and therefore one transaction. `INSERT INTO tags ...
     ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id` returns the id of every tag in the list,
     new or existing, so the `article_tags` insert in the same statement links all of them.
2. **The expensive columns only for the rows returned.** `ARTICLE_LIST_SELECT ... ORDER BY a.id DESC LIMIT n
   OFFSET k` evaluates the per-row subqueries (tags, favorites count, favorited, following) for the k skipped rows
   too. Here the page is cut in a subquery first and the subqueries run in the outer query on its rows only.
3. **The global count reads frozen pages.** `SELECT 1 FROM articles ORDER BY id LIMIT 1000` walks the primary key
   from the oldest end: those pages are all-visible, so it is an index-only scan with no heap fetches. Counting
   from the newest end (where the planner may go, and where every new article lands) hit ~90 heap fetches per call
   under load. Same answer, min(count, 1000).
4. **Pipelined, shared connections.** 2 × cores connections, shared by all requests (tokio-postgres pipelines
   concurrent queries on one connection: they go out back to back and the replies come back in order). Each
   request picks the less loaded of two random connections. Postgres gets 16 busy backends instead of 80, with
   fewer wake-ups and syscalls per query. Since every endpoint is one statement, nothing ever needs a connection to
   itself.
5. **Prepared, generic plans.** Every statement is prepared once per connection at startup, with
   `SET plan_cache_mode = force_generic_plan` and `SET jit = off` on our own sessions (session-level `SET`, allowed
   by rule 2), so Postgres never re-plans per execution.
6. **Cheap app side.** hyper's HTTP/1.1 server straight on tokio (no framework), responses written byte by byte
   into one buffer (no response structs or serde), timestamps formatted from Postgres's binary microseconds,
   mimalloc, fat LTO. bcrypt runs on the blocking pool behind a semaphore of `cores - 1`, so a burst of logins
   can't take every core from Postgres and the event loop.

What it does **not** do: no caching of any kind (every request reads Postgres), no `synchronous_commit` change,
every write is committed before the response, bcrypt cost 10 for every hash and login, and every token's HS256
signature, `alg` and `exp` are checked on every request.

## Behavior notes

- Auth runs before body validation, and body validation before the database (so an invalid body for an unknown
  article is 422, as in the conformance suite).
- Unknown paths and wrong methods are a JSON 404, as in the Go example.
- No idle keep-alive timeout: a connection stays open until the client closes it.
- Passwords over 72 bytes are 422 on sign-up and update (bcrypt would otherwise truncate them silently).

## Build and run

```bash
sudo bash install.sh   # once: build-essential + Rust 1.99.0 in /usr/local
bash build.sh          # cargo build --release --locked -> target/release/conduit
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 ./start.sh
```

Optional knobs (the defaults are what I want benchmarked): `DB_CONNS` (2 × cores), `APP_THREADS` (cores),
`BCRYPT_THREADS` (cores − 1).

## Local numbers (not the benchmark box)

Docker on an Apple-silicon laptop, full seed, Postgres 18 and the server sharing 8 vCPUs, `loadgen` on 4 others
with `-think-scale 0.1` (so each virtual user is ~10 real ones), 20 s ramp + 40 s measured. Same setup, back to back:

| | users × 0.1 think | req/s | p95 | p99 | errors |
|---|---|---|---|---|---|
| Go example (`net/http` + pgx, 80 conns) | 3,000 | 7,800 | 24 ms | 129 ms | 0 |
| this | 3,000 | 7,900 | 1.2 ms | 3.9 ms | 0 |
| Go example | 5,000 | 12,100 | 192 ms | 628 ms | 0 |
| this | 5,000 | 13,100 | 5.1 ms | 51 ms | 0 |
| this | 7,000 | 17,100 | 197 ms | 576 ms | 0 |

At 6,000 users the CPU split was about 2.7 cores for the server (about one of them bcrypt for the logins) and
3.9 for Postgres.

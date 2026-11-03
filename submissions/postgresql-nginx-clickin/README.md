# PostgreSQL + nginx: the Conduit API written in SQL

Front: direct

The app is the `.sql` files in [`sql/`](sql). nginx carries HTTP, and a small generic nginx module runs the SQL
files for each request. Postgres works out the result: it verifies and signs JWTs, validates request bodies,
picks the status code (200/201/204/401/403/404/422) and builds every JSON body. The module knows nothing about
Conduit. It has no routes, no JSON and no JWT code.

| | |
|---|---|
| Language | SQL (PostgreSQL 18), plus a generic C nginx module that runs it (~1,150 lines) |
| Server | nginx 1.28.0, built from the pinned tarball with `--with-threads` and the module |
| Driver | libpq (Ubuntu 24.04's `libpq-dev`) |
| bcrypt | libxcrypt `crypt_rn`, cost 10 (Ubuntu's `libcrypt-dev`) |

## How a request is answered

[`nginx.conf`](nginx.conf) maps a method on a location to `.sql` files and names the request values they may use:

```nginx
location ~ ^/api/articles/(?<slug>[^/]+)/favorite$ {
    sql POST auth.sql,favorite.sql,article_out.sql
        authorization=$http_authorization hmac_ipad=env:JWT_HMAC_IPAD hmac_opad=env:JWT_HMAC_OPAD
        required=1 slug=$slug ok_status=200;
}
```

The module ([`module/ngx_http_sql_module.c`](module/ngx_http_sql_module.c)) follows four rules:

1. **Values are named.** SQL writes `:slug`, and the module turns that into `$n` when it loads the file. A header
   or query argument that isn't there is `NULL`. `?limit=` is an empty string, not `NULL`.
2. **Files run in order, as one task on nginx's thread pool, on that thread's own Postgres connection** (prepared
   once per connection, generic plans).
3. **Each column of a statement's first row becomes a named value** for the files after it. `auth.sql` outputs
   `viewer` and `token`, and `favorite.sql` uses `:viewer`.
4. **The first row with a non-NULL `status` column is the response.** The `body` column becomes the JSON body;
   NULL means an empty body, as for 204.

Postgres can't run bcrypt without an extension, so two column names ask the module to do it:

- `bcrypt_password` gets hashed into the value `bcrypt_hash`, which `register_insert.sql` then stores.
- `check_password` with `check_hash` is compared with bcrypt. A mismatch is a 401.

Two SQL errors map to responses. A unique violation (23505) is a 422, and so is a data exception (22xxx, a body
that isn't JSON). `{{name}}` in a file pastes in `sql/name.sql`. The shared article JSON, for example, is
`{{_article}}`.

Every read endpoint is one statement. The token check (`{{_auth}}`) and the `?limit`/`?offset` check
(`{{_page}}`) are CTEs of the same statement, and a `CASE` answers 401 or 422 before the page query runs. Writes
still run a few statements: `auth.sql` first, then the write, then the read-back after the commit.

### Batches: many requests, one statement

The read endpoints also have a set-oriented statement, `x_batch.sql`, named by `sql_batch` next to the route:

```nginx
sql GET article_get.sql authorization=$http_authorization ... slug=$slug;
sql_batch GET article_get_batch.sql;
```

nginx's event loop is single-threaded, so a worker can gather requests without locks.

1. A request for such a route goes into that route's queue in its worker, not straight to the thread pool.
2. After the worker has handled the events from one `epoll_wait`, a posted event sends the whole queue to the
   thread pool as one task, if that route has no batch running yet. Requests that arrive while a batch runs wait
   for it, so batches grow with load and wait for nothing when it's quiet. A queue that reaches `sql_batch_max`
   (128) goes at once.
3. On the thread, every request value becomes a `text[]` with one element per request. Constants such as the
   HMAC pads stay plain values, and `:batch_size` is the count. The statement answers one row per request:
   `i` (its place in the arrays), `status` and `body`.
4. Back on the event loop, each request gets its row.

A batch of one runs the route's ordinary statement. If the batch statement fails, or leaves a request without a
row, those requests run the ordinary statement one by one, so a batch never answers differently from single
requests.

The batch statements start with `unnest(...) WITH ORDINALITY` and check every token with the same SQL as single
requests ([`sql/_jwt.sql`](sql/_jwt.sql)). Requests that ask for the same page share its ids, articles and count.
The parts of an article that don't depend on the reader (tags, timestamps, favorites count, author) are built
once per batch as JSON text ([`sql/_art_parts.sql`](sql/_art_parts.sql)). Each request then adds its own
`favorited` and `following`. Writes don't batch: they keep their few statements per request.

### JWT in SQL

[`sql/auth.sql`](sql/auth.sql) checks HS256 with the core `sha256()` function: HMAC is
`sha256(opad || sha256(ipad || msg))`. The two pads depend only on `JWT_SECRET`, so `start.sh` works them out
once and passes them in as hex. The HMAC itself runs in SQL for every token. The
signature is compared on the raw token text first. Only a token that passes gets its header and payload
base64-decoded and parsed. A malformed token therefore never reaches a cast that could raise an error, and the
session's `plan_cache_mode = force_generic_plan` keeps those `CASE` guards from being folded away at plan time.
Then it checks `alg = HS256`, that `exp` is a number in the future, and that `sub` is a string of digits.
[`sql/jwt_sign.sql`](sql/jwt_sign.sql) signs new tokens the same way.

## Rules

- Nothing is created in the database: no functions, extensions or settings. Every file is a plain statement
  against the schema. The only session settings are `plan_cache_mode` and `jit`.
- The statements follow the reference SQL in SPEC.md, wrapped in CTEs that also produce the status and the JSON.
  Article creation runs `BEGIN`, the insert, the two tag inserts and `COMMIT` as separate steps. Favorite,
  unfavorite and update read the article back in a later statement, after their write has committed.
- `GET /api/articles` folds the four filter variants into one statement: a `UNION ALL` of the four page
  queries, and a `CASE` for the count. Each branch is gated on the request's parameters alone, so in the generic
  plan the branches that don't apply are one-time filters and never scan a table.
- No caching. Each request is answered by a statement that starts after the request arrived. Requests in the same
  batch share that statement's reads, and nothing is kept after it. Prepared statements are the only thing kept.
- Writes are committed (autocommit, or the explicit `COMMIT`) before the response is sent.
- Connections: one per thread-pool thread, 3 threads per nginx worker, so 24 on the box's 8 cores. That held
  more users than 6 or 11 per worker: Postgres shares the cores, and fewer busy backends contend less.

## Local results

- `test/run.sh` passes 197/197 on Ubuntu 24.04 arm64.
- `loadgen`, in Docker on an Apple M4:
  - Server and Postgres 18 (box `pg-conf.sh` values, but `shared_buffers` 2 GB) share 8 pinned cores, as on the
    box. The load generator has 2 other cores.
  - Full seed, fresh copy per run, `-think-scale 0.25 -ramp 30s -measure 60s` (each user is 4× as busy as in
    scoring).

| | Users | req/s | p50 | p95 | p99 | Postgres / nginx cores | |
|---|---:|---:|---:|---:|---:|---|---|
| one statement per request | 24,000 | 19,953 | 250 ms | 424 ms | 526 ms | 5.6 / 2.3 | pass |
| | 27,000 | 20,011 | 391 ms | 597 ms | 754 ms | | fail (p95) |
| batches | 24,000 | 25,118 | 5.6 ms | 47 ms | 80 ms | 5.2 / 2.2 | pass |
| | 32,000 | 32,145 | 38 ms | 131 ms | 201 ms | 4.9 / 2.7 | pass |
| | 40,000 | 28,612 | 221 ms | 961 ms | 1,874 ms | 4.5 / 3.3 | fail, load generator fell behind |

Batches cut Postgres CPU per 1,000 req/s from 0.28 to 0.15 cores at 32,000 users. At that point the 8 cores are
full: nginx's share is mostly bcrypt (about 35 logins/s locally). Performance wasn't the goal: the point is to see
how much of a web app plain SQL can carry.

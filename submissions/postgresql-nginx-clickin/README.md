# PostgreSQL + nginx: the Conduit API written in SQL

Front: direct

The app is the `.sql` files in [`sql/`](sql). nginx carries HTTP, and a small generic nginx module runs the SQL
files for each request. Postgres works out the result: it verifies and signs JWTs, validates request bodies,
picks the status code (200/201/204/401/403/404/422) and builds every JSON body. The module knows nothing about
Conduit. It has no routes, no JSON and no JWT code.

| | |
|---|---|
| Language | SQL (PostgreSQL 18), plus a generic C nginx module that runs it (~800 lines) |
| Server | nginx 1.28.0, built from the pinned tarball with `--with-threads` and the module |
| Driver | libpq (Ubuntu 24.04's `libpq-dev`) |
| bcrypt | libxcrypt `crypt_rn`, cost 10 (Ubuntu's `libcrypt-dev`) |

## How a request is answered

[`nginx.conf`](nginx.conf) maps a method on a location to `.sql` files and names the request values they may use:

```nginx
location ~ ^/api/articles/(?<slug>[^/]+)/favorite$ {
    sql POST auth.sql,favorite.sql,article_out.sql
        authorization=$http_authorization secret=env:JWT_SECRET required=1 slug=$slug ok_status=200;
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
- No caching. Each request runs its files against Postgres; prepared statements are the only thing kept.
- Writes are committed (autocommit, or the explicit `COMMIT`) before the response is sent.
- Connections: one per thread-pool thread, `95 / nproc` threads per worker (11 × 8 = 88 on the box).

## Local results

These ran in Docker on a 10-core Mac, with the server, Postgres 18 and the load generator sharing the same VM:

- `test/run.sh` passes 197/197.
- `loadgen` on the dev seed (`-think-scale 0.2 -ramp 10s -measure 30s`):

| Users | req/s | p50 | p95 | p99 | errors |
|---:|---:|---:|---:|---:|---:|
| 2,000 | 2,643 | 0.6 ms | 2.2 ms | 3.8 ms | 0 |
| 8,000 | 10,453 | 4.1 ms | 27.9 ms | 48.3 ms | 0 |

Performance wasn't the goal: the point is to see how much of a web app plain SQL can carry.

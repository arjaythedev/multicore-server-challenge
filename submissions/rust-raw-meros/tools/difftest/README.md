# difftest

Differential tester: sends the same random request mix to two Conduit servers
and compares status, content type and JSON body. Python 3 standard library
only; not part of the server build.

## What is compared

- Same status code, same `application/json` content type, structurally equal
  JSON (key order ignored, types strict: `1`, `1.0` and `true` differ).
- Normalised, because correct servers differ there: error message text (the
  `{"errors":{"body":[..]}}` shape is checked); `token` (must be a valid
  HS256 JWT; on `GET/PUT /api/user` it must be the presented token, elsewhere
  only `sub` is compared); `createdAt`/`updatedAt` of rows touched during the
  run (only the 3-digit RFC 3339 format is checked).
- With `--writes`, ids that a server hands out (user id in the token, slug,
  comment id) are kept per server, and follow-up requests use each server's
  own values. Ids are compared literally, so databases that drift apart show
  up as slug/id mismatches after the first diverging write.

## Request mix

Reads: tags, article lists (tag/author/favorited filters, several at once,
`limit`/`offset` valid, boundary, invalid, repeated), feed (users following
many, some, nobody; anonymous), article/comments/profile (existing, missing,
odd path segments such as `%00`, `%FF`, `..`, double encoding), `GET /api/user`,
logins (good, wrong, malformed bodies), refused registrations, unrouted
paths/methods, and Authorization headers that are expired, wrong-secret,
`alg: none`/HS512, malformed, wrong scheme, or whose verdict the SPEC leaves
open (`exp` as string, missing `iat`, `sub` as integer, ...).
Writes (`--writes`): register, update user, create/update/delete article,
favorite/unfavorite, follow/unfollow, add/delete comment, writes with
rejected tokens, plus validation failures and wrong-owner (403) cases. Each
write queues follow-up reads of what it touched.

`--evil` adds titles with NUL and lone UTF-16 surrogates. Servers may
disagree on those (see findings below), after which their databases diverge,
so use it on a throw-away pair.

## Run

```sh
# 1. one database copy per server (as postgres; password postgres on the dev box)
export PGHOST=127.0.0.1 PGPORT=5433 PGUSER=postgres PGPASSWORD=postgres
for n in dt_a dt_b; do
  psql -c "DROP DATABASE IF EXISTS $n WITH (FORCE)" -c "CREATE DATABASE $n TEMPLATE conduit_dev OWNER conduit"
done   # psql: nix shell nixpkgs#postgresql_18 --command psql ...

# 2. reference servers (copy upstream-main/examples/{go,rust} somewhere writable first)
(cd examples/go   && GOTOOLCHAIN=auto nix shell nixpkgs#go --command bash build.sh)
(cd examples/rust && nix develop /home/meros/git/personal/12dollar/multicore --command cargo build --release)
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5433/dt_a JWT_SECRET=dev-secret HOST=127.0.0.1 PORT=3191 \
  DB_POOL_SIZE=20 examples/go/bin/conduit &
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5433/dt_b JWT_SECRET=dev-secret HOST=127.0.0.1 PORT=3192 \
  DB_POOL_SIZE=20 examples/rust/target/release/conduit &

# 3. read-only (parallel, the databases stay unchanged)
python3 -I tools/difftest/difftest.py --a http://127.0.0.1:3191 --b http://127.0.0.1:3192 \
  --secret dev-secret --articles 10000 --users 2000 --count 20000 --seed 1

# 4. with writes (sequential, lockstep): recreate both databases first, a write run changes them
python3 -I tools/difftest/difftest.py --a http://127.0.0.1:3191 --b http://127.0.0.1:3192 \
  --secret dev-secret --articles 10000 --users 2000 --count 5000 --seed 2 --writes
```

To test our server against a reference, give ours as `--b` (and a reference as `--a`),
each on its own database copy. Exit status is 1 on any mismatch. `--a` is also where
the tool learns usernames, slugs and feed sizes (it samples `--sample` users, default
400; it has no database access). Seeded passwords are `password123`. `--articles` and
`--users` should match the database; an unseeded id just yields 401/404 on both sides.
Same `--seed` gives the same request sequence (follow-ups included).

Output: per-endpoint table (requests, mismatches, status histogram of A), 5xx
list (counted even when both agree, with an example), mismatch classes with the
first differing field, and the first 10 mismatches with both bodies truncated.

Clean up: kill the two servers, `DROP DATABASE dt_a; DROP DATABASE dt_b;`.

Self-tests: `cd tools/difftest && python3 -m unittest dt.test_dt`.

## Findings: Go vs Rust reference (20000 reads, 5000+1500 writes, seeds 1 to 5)

Everything in the endpoint flows agrees: all list/filter/feed/article/comment/
profile responses, all login/register/update/create/favorite/follow/comment/
delete flows, the paging and 422 handling, tags, slugs (including odd titles).
Differences, all in edges the SPEC leaves open (A = Go, B = Rust):

| Case | Go | Rust |
|---|---|---|
| Path that Go's mux cleans (`//`, `/.`, `/..`) | 307 redirect, text body | 404 JSON |
| Invalid UTF-8 in a path segment (`%FF`) | 500 JSON | 400 plain text |
| `Authorization: Token <jwt> ` (trailing space) | accepted | 401 |
| JWT with `exp` as a string | accepted | 401 |
| `PUT /api/articles/feed` with no/empty body | validation first (401/422) | 404 first |
| Lone surrogate `\ud800` in a title (`--evil`) | 201, stored as U+FFFD | 422 |

Same in both (so the SPEC cannot be read from them, but worth knowing):
`offset` beyond int4 on `/feed` (`$3::int`) gives 500; NUL (`%00`, `\u0000`) in
a path or title gives 500; a header that is present but empty means anonymous;
`nbf` in the future, missing `exp`, `sub` as integer, `alg` in lowercase,
HS512 and `none` are all 401; missing `iat` and extra claims are accepted.

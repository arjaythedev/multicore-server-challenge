# F#: Giraffe on Kestrel + Npgsql

**Front: direct**

Implements [`SPEC.md`](../../SPEC.md) and passes `bench/cmd/conformance` (197/197 on the dev seed). Built with the
architecture of the author's production F# platform (sss8): idiomatic F#, a Giraffe route table over Kestrel, a
database layer of typed queries through Npgsql.FSharp, and one small module for each kind of cryptography.

| Piece | Version |
|---|---|
| Language | F# 10, .NET 10 (`global.json`: SDK 10.0.100+, `install.sh` installs 10.0.402) |
| HTTP | ASP.NET Core Kestrel, Giraffe 7.0.2 with endpoint routing |
| JSON | `System.Text.Json`: `Utf8JsonWriter` out, `JsonDocument` in |
| Postgres | Npgsql 10.0.3 (multiplexing, auto-prepare) through Npgsql.FSharp 5.7.0 |
| JWT | HS256 with the BCL's `HMACSHA256` and `Base64Url` (`src/Web/Jwt.fs`) |
| bcrypt | BCrypt.Net-Next 4.2.0, cost 10 |

Package versions are pinned, and `build.sh` restores the `packages.lock.json` graphs in locked mode.

## Layout

```
src/Engine/   the database side: Types, Db (pool), Commit (group commit), Reads (read batching), Passwords (bcrypt lanes), Tags, Users, Profiles, Articles, Comments
src/Web/      Jwt (the token shim), Wire (JSON in/out, query paging; pure), Handlers (Giraffe), Program (Kestrel)
src/Tests/    xUnit facts for Jwt and Wire (no database)
check.sh      the harness: build -> facts -> conformance suite (../../test/run.sh), with one verdict at the end
```

- **Engine** has no HTTP and no tokens. Each function takes typed values and returns typed records, or a small
  union (`Done | NotFound | NotYours`, `Stored | Taken | Missing`) that the handler maps to a status.
- **Wire** has no `HttpContext`, so the shape rules (422 cases, `limit`/`offset` parsing, key case-sensitivity,
  timestamp truncation) are plain unit tests.
- **Handlers** only authenticate, decode, call Engine and encode.

## Multicore model

- **One process, one Kestrel.** Kestrel serves every core with async I/O and holds each user's keep-alive
  connection directly (`Front: direct`). The keep-alive timeout is 120 s.
- **Read batching for the hot reads** (`src/Engine/Reads.fs`): tags, the four article lists, the feed, article by
  slug, comments and profiles. Every such read queues on one channel. `READ_LANES` reader lanes (default one per
  core), each with a connection of its own, take whatever queued while their previous batch was in flight (up to
  `READ_BATCH`, default 1024) and send it as one `NpgsqlBatch` with **one statement per kind of read**.
  - Each kind has two statements with the same columns. A kind with one request in the batch uses the **single**
    statement (the plain per-request query). A kind with several uses the **batched** statement, which takes the
    requests as arrays (`unnest(...) WITH ORDINALITY`) and tags every row with `k`, the request it belongs to.
  - The batched statement does the viewer-independent work **once per distinct value**, in `MATERIALIZED` CTEs: one
    capped count per list key, one page of ids per (key, limit, offset), and one card per article (columns, tag array,
    favorite count, author). Only the viewer's `favorited` and `following` flags are per request. Forty users on
    page 1 of the global feed cost one page and ten cards, plus the flags.
  - There is no timer. With no load each statement serves one request; near saturation the batches grow by
    themselves, and each request costs Postgres less. On an 8-core test box at 40,000 users this took p95 from 673 ms
    (fail) to 66 ms, at more requests per second and less Postgres CPU.
  - This is not a cache: every request is answered by a statement that started after it arrived, and nothing
    outlives its batch.
  - Lookups by a batch's keys are `CROSS JOIN LATERAL (… LIMIT 1)`: one index probe per distinct key. The planner
    cannot see how few rows a CTE holds. With a plain join it hash-joins whole tables, and the `LIMIT 1` (on unique
    keys) stops it from flattening the lateral back into that join.
  - Our sessions run with `jit=off` (a session setting; the server config is untouched). The batched statements look
    costly to the planner, and JIT compiling took ~400 ms of a 1 ms query.
- **One multiplexed Npgsql pool for the cold reads** (sign-in lookups, the read after a write), `DB_POOL_SIZE`
  connections, default cores / 2. A request does not hold a connection: its statements are pipelined onto whichever
  connection is free.
- **Group commit for writes** (`src/Engine/Commit.fs`). Every write queues on one channel. `WRITE_LANES` writer
  lanes (default 2), each with a connection of its own, take whatever queued while their previous group was in flight
  (up to `WRITE_GROUP`, default 128) and send it as one `NpgsqlBatch`. That is one round trip and one implicit
  transaction, ended by the batch's Sync, so the whole group shares one commit and one WAL flush. Each caller is
  answered only after that commit (ReadyForQuery). There is no timer: with no load a group is one write, and under
  load the groups grow by themselves.
  - If the server refuses one statement (a UNIQUE name, a deadlock between lanes), it rolls the whole group back, so
    none of it happened. Each write then runs again in its own transaction, and only the bad one fails.
  - If the connection breaks, whether the group committed is unknown, so its writes fail (500) instead of being
    applied twice.
  - At shutdown the server logs `group commit: N writes in M groups`.
- **bcrypt on dedicated threads** (`BCRYPT_THREADS`, default one per two cores) behind a queue. A burst of logins waits
  for a lane instead of parking thread-pool threads that the cheap reads need.
- **GC:** server GC, non-concurrent, DATAS off, and a 64 MB gen0 budget (`DOTNET_GCgen0size` in `start.sh`). The
  JIT runs with tiered PGO.

## SQL

The reference SQL, reshaped so that **every read and most writes take one round trip** (and a batch of reads one
statement per kind, see above):

- **Lists:** the count, the page's ids and their cards are one statement. The page is chosen by id first and the card
  columns are built only for its rows, so a huge `offset` skips index entries instead of computing tag arrays and
  counts for every skipped article. An empty page still returns the count.
- **Global count:** walks the primary key from the oldest end (`ORDER BY id LIMIT 1000`). Those pages are
  all-visible, so it is an index-only scan.
- **Comments:** the article lookup and the newest 100 comments are one statement. No row means 404.
- **Follow, unfollow, favorite, unfavorite, delete article, delete comment, update article:** the lookup, the
  ownership check and the write are one statement (a data-modifying CTE), and the outer `SELECT` reports what it
  found, so 404 and 403 are still told apart.
- **Favorite and unfavorite** return the full article from the same statement. The outer query's snapshot predates
  the CTE's write, so the count adds or subtracts the rows the write actually changed.
- **Create article** is SPEC's transaction as one group-commit write: the new tags, then the article and its tag
  links in one statement (a data-modifying CTE). Same rows, same transaction, then the read after the commit.
- **Slugs** use SPEC's `SLUGIFY` in SQL, so they are byte-identical to the reference.

## Rules

- **No caching:** every request reads Postgres. Only connections and prepared statements are reused.
- **Writes:** each one is committed before its response. Several requests' writes share a transaction (group
  commit, rule 6), and each response waits for that commit.
- **Tokens:** every token is verified each time. `alg` must be `HS256`, the HMAC is compared in constant time,
  `sub` must be a decimal string and `exp` must be present and in the future.
- **bcrypt:** cost 10 for every new password, and every login verifies against the stored hash. A password longer
  than 72 bytes is refused with a 422, never silently truncated.

## bcrypt runs once per sign-in, and never for a refused request

bcrypt is by far the most expensive thing the server does (~50-80 ms of a core), so it runs exactly once per
sign-up, password change or login, and only when that request is going to succeed:

| Request | bcrypt |
|---|---|
| `POST /api/users` | one hash, only after a cheap check that the username and email are free. A body that fails validation, or a taken name, costs none. |
| `POST /api/users/login` | one verify, only when the email exists. An unknown email or a malformed body costs none. |
| `PUT /api/user` with `password` | one hash, only after checking that the user exists and the new names are free. Without `password`, none. |
| everything else | none. Tokens are HS256 JWTs, and `GET /api/user` reads the user row. |

The pre-checks don't change the outcome: two racing sign-ups can both pass, and the UNIQUE constraint still answers
422. At shutdown the server logs its counts (`bcrypt: N hashes, M verifies`). A conformance run gives exactly
3 hashes (2 sign-ups + 1 password change) and 5 verifies (the 5 logins whose email exists).
- **Connections:** at most 95 Postgres connections (`READ_LANES` + `WRITE_LANES` + `DB_POOL_SIZE`; the pool is
  capped to fit).

## Build, run, check

```bash
sudo bash install.sh            # once: .NET SDK 10.0.402 -> /usr/local/dotnet
bash build.sh                   # -> out/Web.dll
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=multicore-server-challenge \
  HOST=0.0.0.0 PORT=80 bash start.sh
bash check.sh                   # build + facts + conformance (needs the dev seed, Go, psql, curl)
SKIP_CONFORMANCE=1 bash check.sh  # the quick gate, no database
```

Environment: `DATABASE_URL`, `JWT_SECRET` (required); `HOST` (127.0.0.1), `PORT` (3000); `READ_LANES` (cores);
`READ_BATCH` (1024); `WRITE_LANES` (2); `WRITE_GROUP` (128); `DB_POOL_SIZE` (cores / 2, capped so the total stays
at most 95); `BCRYPT_THREADS` (cores / 2).

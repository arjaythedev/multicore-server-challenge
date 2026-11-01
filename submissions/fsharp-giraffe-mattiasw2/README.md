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
src/Engine/   the database side: Types, Db (pool), Passwords (bcrypt lanes), Tags, Users, Profiles, Articles, Comments
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
- **One multiplexed Npgsql pool**, `DB_POOL_SIZE` connections, default 3 per core and capped at 95. A request does not
  hold a connection: its statements queue and are written, pipelined, to whichever connection is free. That keeps
  Postgres at a few busy backends per core instead of one per waiting request.
- **bcrypt on dedicated threads** (`BCRYPT_THREADS`, default one per two cores) behind a queue. A burst of logins waits
  for a lane instead of parking thread-pool threads that the cheap reads need.
- **GC:** server GC, non-concurrent, DATAS off, and a 64 MB gen0 budget (`DOTNET_GCgen0size` in `start.sh`). The
  JIT runs with tiered PGO.

## SQL

The reference SQL, reshaped so that **every read and most writes take one round trip**:

- **Lists:** the page and its capped count are one statement. The count is a one-row subquery and the page joins it
  `LEFT JOIN LATERAL`, so an empty page still returns the count.
- **Global count:** walks the primary key from the oldest end (`ORDER BY id LIMIT 1000`). Those pages are
  all-visible, so it is an index-only scan.
- **Comments:** the article lookup and the newest 100 comments are one statement. No row means 404.
- **Follow, unfollow, favorite, unfavorite, delete article, delete comment, update article:** the lookup, the
  ownership check and the write are one statement (a data-modifying CTE), and the outer `SELECT` reports what it
  found, so 404 and 403 are still told apart.
- **Favorite and unfavorite** return the full article from the same statement. The outer query's snapshot predates
  the CTE's write, so the count adds or subtracts the rows the write actually changed.
- **Create article** is the reference transaction: the article, then its tags, then its tag links, then the read
  after the commit.
- **Slugs** use SPEC's `SLUGIFY` in SQL, so they are byte-identical to the reference.

## Rules

- **No caching:** every request reads Postgres. Only connections and prepared statements are reused.
- **Writes:** each one is committed before its response.
- **Tokens:** every token is verified each time. `alg` must be `HS256`, the HMAC is compared in constant time,
  `sub` must be a decimal string and `exp` must be present and in the future.
- **bcrypt:** cost 10 for every new password, and every login verifies against the stored hash. A password longer
  than 72 bytes is refused with a 422, never silently truncated.
- **Connections:** at most 95 Postgres connections (`DB_POOL_SIZE` is capped).

## Build, run, check

```bash
sudo bash install.sh            # once: .NET SDK 10.0.402 -> /usr/local/dotnet
bash build.sh                   # -> out/Web.dll
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=multicore-server-challenge \
  HOST=0.0.0.0 PORT=80 bash start.sh
bash check.sh                   # build + facts + conformance (needs the dev seed, Go, psql, curl)
SKIP_CONFORMANCE=1 bash check.sh  # the quick gate, no database
```

Environment: `DATABASE_URL`, `JWT_SECRET` (required); `HOST` (127.0.0.1), `PORT` (3000); `DB_POOL_SIZE`
(3 × cores, at most 95); `BCRYPT_THREADS` (cores / 2).

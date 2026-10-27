# Conduit: C++20 / Drogon (libpq)

**Front: direct** — the server itself listens on `HOST:PORT` (the box uses `0.0.0.0:80`) and holds every user's keep-alive connection; no Nginx CPU.

C++20, Drogon built from git (libpq backend), jsoncpp for JSON, jwt-cpp (HS256), an own bcrypt implementation (`bcrypt.hpp`/`bcrypt_tables.cpp`, cost 10, `$2b$`) and jemalloc. Built with `-O3 -march=native -flto` plus section gc and `-fno-plt`; LTO and `--gc-sections` shrink the binary and keep hot code inline.

- Two libpq pools: `"default"` for reads (`DB_READ_CONNS`, default 12) and `"write"` for writes (`DB_WRITE_CONNS`, default 16). Handlers are C++20 coroutines (`execSqlCoro`), so no thread blocks while Postgres works; single-statement writes auto-commit before the response is sent.
- Pages paginate by id first: the `LIMIT/OFFSET` window is computed on bare article ids before joins and decorations run, so skipped `OFFSET` rows never pay for tag arrays, counts or flags. List totals are capped count subqueries (`LIMIT 1000`), which bounds the worst case for huge databases.
- Per-page metadata (tag lists, favorite counts, viewer favorited, viewer following) is loaded with batched `= ANY($1::bigint[])` queries and joined back through flat maps (`robin_hood`), instead of repeating correlated subqueries per row.
- One round trip per mutation via CTE statements: article creation computes `nextval`, the slug (`title-<id>`) and inserts/links its tags in a single statement; favorite/unfavorite, comment create/delete, article update/delete and follow/unfollow all do the slug/username lookup and the write in one statement.
- JWT (`Authorization: Token <jwt>`, HS256, `exp` checked) is verified by two middlewares (required/optional routes) on every request; the viewer id is passed to handlers via request attributes. Timestamps are formatted to RFC 3339 in the app.
- No caching: every request reads Postgres. Every login runs bcrypt against the stored hash. No schema or config changes, no CPU affinity or host tuning; `config.json` sets 6 event-loop threads, unlimited keep-alive and pipelining, WARN-level logging.

```sh
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

## Results

Local benchmark numbers: TBD.

Front: direct

# Python raw socket submission

from the previous challenge, i wondered whether sockets could remove all the overhead

## Software

- Python 3 (system `python3` on Ubuntu 24.04)
- `psycopg` 3.3.4 + `psycopg_pool` 3.3.3 (bounded pool, 5–30 connections of Postgres's 100)
- `bcrypt` 5.0.0 (pure — no wheel compilation)
- `PyJWT` 2.15.1

All pins live in `constraints.txt` (transitives included); `build.sh` installs against it and `start.sh` runs the project `.venv`.

## Architecture (hexagonal / ports & adapters)

```
conduit_server/
├── domain/            pure business logic: frozen dataclasses + validation/slug/paging rules. No I/O deps.
│   ├── models.py      response shapes (User, Profile, Article, Comment…)
│   └── services.py    slugify (byte-identical to SQL SLUGIFY), strict limit/offset, tagList checks
├── ports/             Protocol contracts — inbound (transport) & outbound (db, crypto)
├── adapters/
│   ├── inbound/       raw socket server (epoll via selectors), path-param router, controllers
│   └── outbound/      psycopg PostgreSQL repository + bcrypt/JWT adapter
├── main.py            composition root: wires pool → repository → crypto → controllers
└── scripts/check.py   static wiring check (used by `just check`)
```

## How it works

- **Transport** — one process, blocking free: a non-blocking TCP listener on `HOST:PORT` with a
  `selectors` (epoll) event loop. Per-connection byte buffers accumulate until a full HTTP/1.1
  request head + `Content-Length` body arrives; requests are parsed into an `HttpRequest`
  (params / query / headers / body) and dispatched to the decorator router. Keep-alive is honored
  byte-exactly: after a response, only the consumed bytes are dropped and the socket stays open
  (per the challenge: idle > 65 s so Nginx never reuses a dead socket). `TCP_NODELAY` is set on
  every accepted connection; responses are written with a brief blocking flip (fast paths don't
  block in practice).

- **Routing** — 19 endpoints registered via decorators (`@router.get/post/put/delete`). Routes
  are compiled regexes, so `/api/articles/:slug/favorite` captures params. Handlers return
  `(status, dataclass-or-dict)`; the router serializes dataclasses and emits JSON with a correct
  `Content-Length`, mapping `ApiError` to `{"errors": {"body": [...]}}` for 401/403/404/422/500.

- **Data layer** — a single `psycopg_pool` `ConnectionPool` (5 min / 30 max). All queries mirror
  the challenge's reference SQL: shared `ARTICLE_LIST_SELECT` fragment (tag list array,
  favorites count, `favorited`/`following` EXISTS probes for the viewer — note the viewer binds
  twice), capped 1,000 counts, newest-first by id paging, feed via lateral join, article insert +
  tag upsert in one transaction, slug computed in Python from `nextval` id. List rows omit
  `body`; timestamps are RFC 3339 UTC with truncated 3 fractional digits.

- **Security** — no caching, no shortcuts: every login does a fresh bcrypt verify (cost 10,
  over-72-byte passwords rejected as 422), every request re-verifies the JWT signature
  (HS256-only, `exp` required), and anonymous viewers pass `0` as the viewer id.

## Justfile guide

| Command        | What it does                                                                                     |
|----------------|--------------------------------------------------------------------------------------------------|
| `just`         | list all recipes                                                                                  |
| `just test`    | full conformance suite: builds, starts on a fresh `conduit_dev` copy, runs `test/run.sh` (197 steps) |
| `just venv`    | create/recreate `.venv` with pinned deps                                                          |
| `just lint`    | syntax gate (`py_compile` over all sources)                                                        |
| `just check`   | lint + composition-root wiring check: asserts all 19 routes register cleanly (`scripts/check.py`)   |
| `just paths`   | echo resolved CWD / submissions / repo-root paths                                                  |

Typical flow from a clean checkout:

```
just venv    # only if needed; `just test` builds anyway
just check   # fast static gate
just test    # the real 197-step conformance run
```


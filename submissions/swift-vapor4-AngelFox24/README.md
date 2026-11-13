# RealWorld (Conduit) API — Vapor 4 + Fluent

**Front: direct** — the server serves clients itself on `HOST:PORT`, with no reverse proxy.

A straight port of the RealWorld/Conduit backend to **Vapor 4** and **Fluent**, backed by
PostgreSQL. It implements the same behavior and 19 endpoints as the Hummingbird reference in
`swift-hummingbird-denizakya`, following the
[multicore-server-challenge](https://github.com/arjaythedev/multicore-server-challenge) `SPEC.md`.

This is intentionally a plain, out-of-the-box baseline: Fluent models, migrations, and the Fluent
query builder. There is no cross-request caching, prepared-statement tuning, or hand-written
JSON/SQL optimization.

## Requirements

- Swift 6.x (developed against Swift 6.4.2)
- PostgreSQL (challenge benchmark uses PostgreSQL 18)

## Build and run

```bash
swift build
swift run
```

The server listens on Vapor's defaults unless `HOST`/`PORT` are set. `swift run` starts the
`serve` command; no extra arguments are required.

For a release build:

```bash
swift build -c release
.build/release/SwiftVaporAngelfox serve
```

The challenge submission scripts do the same on Linux:

```bash
./install.sh   # once, as root: installs the Swift toolchain
./build.sh     # swift build -c release
./start.sh     # runs .build/release/SwiftVaporAngelfox in the foreground
```

## Configuration

`SPEC.md`'s runtime contract uses exactly four variables: `DATABASE_URL`, `JWT_SECRET`, `HOST`,
and `PORT`. Those are the ones the benchmark sets.

| Variable | Purpose | Default |
| --- | --- | --- |
| `DATABASE_URL` | Full PostgreSQL URL, e.g. `postgres://user:pass@host:5432/db`. This is the challenge variable; when present it wins over the individual `DATABASE_*` variables. | unset |
| `DATABASE_HOST` | Local-development fallback, only read when `DATABASE_URL` is absent | `localhost` |
| `DATABASE_PORT` | Local-development fallback | `5432` |
| `DATABASE_USERNAME` | Local-development fallback | `vapor_username` |
| `DATABASE_PASSWORD` | Local-development fallback | `vapor_password` |
| `DATABASE_NAME` | Local-development fallback | `vapor_database` |
| `JWT_SECRET` | Raw HS256 secret used to sign `Authorization: Token <jwt>` tokens | `conduit-dev-secret` |
| `HOST` | Listen address | Vapor default (`127.0.0.1`) |
| `PORT` | Listen port | `8080` |

The `DATABASE_*` fallbacks do not affect conformance: the benchmark does not set them, and
`DATABASE_URL` is always checked first. They exist only so the app can run against a local
database without building a URL by hand.

TLS is disabled for `DATABASE_URL` connections because the benchmark database runs on the same
host.

### JSON and auth contract

- `POST /api/users` and `POST /api/users/login` return a token with exactly the claims
  `sub`, `iat`, and `exp`.
- `iat` and `exp` are integer Unix timestamps; `exp = iat + 30 days`.
- Tokens are HS256-signed with the raw `JWT_SECRET` value, not a derivied key.
- Passwords use bcrypt with cost **10**.
- Timestamps in responses use RFC 3339 with millisecond precision.
- Errors use the RealWorld shape `{"errors":{"body":["message"]}}` with 422 for validation
  failures, 401 for authentication failures, 403 for ownership failures, and 404 for missing
  resources.

> `Package.swift` pins `vapor/jwt` to 4.x. JWTKit 5 refuses HMAC keys shorter than 32 bytes, and
> the challenge secret (`multicore-server-challenge`, 26 bytes) would be rejected.

## Endpoints

All routes are prefixed with `/api`.

| Method | Path | Auth | Description |
| --- | --- | --- | --- |
| `POST` | `/users` | — | Register a user |
| `POST` | `/users/login` | — | Log in |
| `GET` | `/user` | required | Current user |
| `PUT` | `/user` | required | Update current user |
| `GET` | `/profiles/:username` | optional | Get a profile |
| `POST` | `/profiles/:username/follow` | required | Follow a user |
| `DELETE` | `/profiles/:username/follow` | required | Unfollow a user |
| `GET` | `/articles` | optional | List articles (`tag`, `author`, `favorited`, `limit`, `offset`) |
| `GET` | `/articles/feed` | required | Articles from followed users (`limit`, `offset`) |
| `POST` | `/articles` | required | Create an article |
| `GET` | `/articles/:slug` | optional | Get an article |
| `PUT` | `/articles/:slug` | required | Update an article (author only) |
| `DELETE` | `/articles/:slug` | required | Delete an article (author only) |
| `POST` | `/articles/:slug/favorite` | required | Favorite an article |
| `DELETE` | `/articles/:slug/favorite` | required | Unfavorite an article |
| `GET` | `/articles/:slug/comments` | optional | List comments on an article |
| `POST` | `/articles/:slug/comments` | required | Add a comment |
| `DELETE` | `/articles/:slug/comments/:id` | required | Delete a comment (author only) |
| `GET` | `/tags` | — | List all tags |

Authentication uses `Authorization: Token <jwt>`. On optional-auth endpoints an absent header is
fine; an invalid header is always `401`.

## Database and migrations

Migrations are registered in `configure` and create seven tables:

`users`, `tags`, `articles`, `follows`, `article_tags`, `favorites`, `comments`.

For local development:

```bash
swift run SwiftVaporAngelfox migrate --yes
```

**Challenge note:** the benchmark database is pre-seeded with the fixed challenge schema. Do not
run migrations against it; they are for local development only. The app never calls
`autoMigrate()` at startup, so running the binary with no arguments leaves the existing schema
untouched.

## Tests

The endpoint tests use Vapor's testing harness and run migrations against a real PostgreSQL
database, then revert them. Point them at a disposable database, not at the challenge seed:

```bash
DATABASE_HOST=192.168.117.2 DATABASE_PORT=5432 swift test
```

`localhost:5432` commonly resolves to a different local PostgreSQL instance with a different
password; set `DATABASE_HOST`/`DATABASE_PORT` explicitly when needed.

## Capacity: an honest baseline

**There is no measured users-per-second number for this repo yet.** It has not been run through
the official 8-core challenge benchmark, and any specific concurrency figure without that run
would be a guess.

What can be said from the implementation:

- **It is the unoptimized baseline.** Each list/feed response issues separate queries for the
  article page, tags, favorites, follows, and an `articlesCount` query capped at 1,000. Detail
  pages similarly perform several small queries rather than one joined query.
- **Auth endpoints are CPU-bound on bcrypt at cost 10.** Register, login, and password updates
  will be the slowest operations and will bottleneck mixed workloads before the database does.
- **Database connections are a hard ceiling.** The benchmark's PostgreSQL allows 100
  connections, so throughput plateaus once the pool is saturated regardless of available CPU.
- **No caching or connection tuning.** Every request recomputes favorited/following state from
  the database.

To produce a defensible number, run the official challenge load test against a release build on
the target 8 vCPU / 16 GB box and report the measured requests per second and latency
percentiles. Until then, treat this as a correctness-focused baseline rather than a performance
claim.

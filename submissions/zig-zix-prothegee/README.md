# Zig: ZIX

Multicore server challenge submission built on zix, a Zig network library.

Front: direct

## Stack

| Part | Choice |
| :- | :- |
| Language | Zig 0.17.0 |
| HTTP engine | zix `Http1`, `.URING` dispatch, one worker per CPU |
| HTTP style | HTTP/1.1 with keep-alive, comptime router |
| Database driver | zix `postgrez`, one connection per worker on the `.URING` dispatch, TLS off, named prepared statements |
| Database | PostgreSQL 18, `max_connections = 100` |
| Auth | HS256 JWT through zix `zwte.jwt`, key minimum 26 bytes |
| Password hashing | bcrypt cost 10 through `std.crypto.pwhash.bcrypt` |
| JSON | zix `jzon`, generated serializer |
| zix pin | `0.6.0-rc0`, commit `fc1da77e` |
| Front | direct |

## Endpoints

Implemented:

| Endpoint | State |
| :- | :- |
| `POST /api/users` | done |
| `POST /api/users/login` | done |
| `GET /api/user` | done |
| `PUT /api/user` | done |
| `GET /api/profiles/:username` | done |
| `POST /api/profiles/:username/follow` | done |
| `DELETE /api/profiles/:username/follow` | done |
| `GET /api/articles` | done |
| `GET /api/articles/feed` | done |
| `GET /api/articles/:slug` | done |
| `POST /api/articles` | done |
| `PUT /api/articles/:slug` | done |
| `DELETE /api/articles/:slug` | done |
| `POST /api/articles/:slug/favorite` | done |
| `DELETE /api/articles/:slug/favorite` | done |
| `GET /api/articles/:slug/comments` | done |
| `POST /api/articles/:slug/comments` | done |
| `DELETE /api/articles/:slug/comments/:id` | done |
| `GET /api/tags` | done, also the health check |

## Architecture

- One zix worker per CPU. Each worker owns its io_uring loop and touches no shared request state.
- One PostgreSQL connection per worker on the `.URING` dispatch with TLS off, opened on first use. No shared pool and no cross-thread handoff.
- `JWT_SECRET` is read at startup and passed to every sign and verify call with the 26-byte minimum.
- Every new password is hashed with bcrypt cost 10. Login verifies against the stored hash.
- Profile reads are auth optional: a missing token is viewer 0, while a present invalid token is 401. Follow and unfollow require a token.
- Article timestamps are formatted in SQL with `to_char`, UTC, exactly 3 fractional digits.
- Article tag lists are assembled as `jsonb` in SQL and parsed into the response model.
- The hot reads use named prepared statements prepared once per worker connection, so each request skips the parse and describe round-trip.
- Article lists and the feed queue the page and the capped count in one batched round-trip, newest first.
- The comments list joins the article and filters by slug, so the common case is one query. An empty list runs the id check to keep the 404 and empty 200 apart.
- Favorites are an insert or delete edge, and the article response reports the viewer's favorited state and the total count.
- Comments are listed newest first, capped at 100, and each comment embeds the author profile.
- Responses are rendered with jzon's generated serializer, which writes the same bytes as the std path with less code.
- `GET /api/tags` reads the tags table on every request, so a new tag is visible on the next request.

## Optimizations

| Change | Why |
| :- | :- |
| `.URING` dispatch | one ring per worker, no shared event loop |
| per-worker PostgreSQL connection | on the `.URING` dispatch with TLS off, no locks and no cross-core handoff |
| named prepared statements | the plan is prepared once per worker connection, so each request skips parse and describe |
| batched page and count | one send and one receive burst for the article list and the feed |
| comments by slug | one query for the comment list, the id check only when the list is empty |
| generated JSON | jzon writes the response with type-generated code |
| keep-alive responses | matches the load generator's long-lived connections |
| direct tag query | a new tag must be visible on the next request, and rule 5 forbids cross-request caches |
| no response cache | every request reads its data from Postgres, so there is no data cache to invalidate |
| no per-request access log | the file logger is at WARN in release, so only warnings and errors are written |
| busy poll 50 us | the worker spins briefly on a socket before sleeping, trading idle CPU for tail latency |
| comptime router | path dispatch is resolved at compile time |
| release default `0.0.0.0:80` | direct front, while `HOST` and `PORT` always override it |

## Tuning

| Setting | Value |
| :- | :- |
| workers | 0 (one per CPU) |
| dispatch | `.URING`, `reuseport_cbpf` |
| recv / send buffer | 6 KiB / 6 KiB |
| request body cap | 4 KiB |
| idle pool | floor 4, ceiling 64 |
| process queue | 512 per worker |
| busy poll | 50 us |
| response headers | 4 custom slots, no Date header |
| kernel backlog | 4096 |
| Postgres connection | `.URING` dispatch, TLS off |

## Build

Run the build, run, and test commands from this submission directory.

```bash
zig build -Doptimize=ReleaseFast
```

The binary is `zig-out/bin/conduit`.

## Scripts

| Script | What it does |
| :- | :- |
| `install.sh` | installs Zig 0.17.0 from the official sha256-checked tarball into `/usr/local/zig`, plus `git`, `curl`, `jq`, `xz-utils`, and CA certificates |
| `build.sh` | builds `zig-out/bin/conduit` with `ReleaseFast`, keeping the build cache in `.zig-global` |
| `start.sh` | runs the server in the foreground with the runtime environment |

The root `test/run.sh` runs `build.sh` and `start.sh` and passes all 197 conformance checks.

## Run

The database named in `DATABASE_URL` must already hold the schema and seed.

```bash
DATABASE_URL='postgres://conduit:conduit@127.0.0.1:5432/conduit' \
JWT_SECRET='multicore-server-challenge' \
HOST=0.0.0.0 PORT=80 \
./zig-out/bin/conduit
```

A debug build binds `127.0.0.1:3000` by default and writes console records plus file records under `logs/`. A release build writes warnings and errors to the file only.

## Local database

These commands run from this submission directory.

```bash
make postgres-primary-up
make sync-seed-dev
make sync-app
```

`make sync-seed-dev` runs the seed script in the challenge repository root and creates `conduit_dev` with 100,000 users and 10,000 articles. `make sync-app` then refreshes `conduit`, the database `DATABASE_URL` names, from that seed. Stop the server before `sync-app`, because the drop terminates its connections. For the full seed, use `make sync-seed-full` and `make sync-app SEED_TEMPLATE=conduit_seed` (about 2.4 GB, 5 to 10 minutes).

The benchmark and `test/run.sh` create their own fresh copy, so this copy is only for a manual run.

## Tests

```bash
zig build test            # unit, edge, behaviour, integration
zig build unit-test
zig build edge-test
zig build behaviour-test
zig build integration-test
```

The integration suite needs the local database. It skips when the database is down.

## Status

The real conformance suite passes all 197 checks against the seeded database.

## Notes

- Debug builds enable the console logger. Release builds write warnings and errors to `logs/<date>/conduit-000000.log` only. The per-request access record is off because `save_min_level = .WARN`.
- `GET /api/tags` reads PostgreSQL on every request to satisfy the rule that forbids response caches across requests.

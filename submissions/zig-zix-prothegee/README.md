# Zig: ZIX

Multicore server challenge submission built on zix, a Zig network library.

Front: direct

## Stack

| Part | Choice |
| :- | :- |
| Language | Zig 0.17.0 |
| HTTP engine | zix `Http1`, `.URING` dispatch, one worker per CPU |
| HTTP style | HTTP/1.1 with keep-alive, comptime router |
| Database driver | zix `postgrez`, one connection per worker |
| Database | PostgreSQL 18, `max_connections = 100` |
| Auth | HS256 JWT through zix `zwte.jwt`, key minimum 26 bytes |
| Password hashing | bcrypt cost 10 through `std.crypto.pwhash.bcrypt` |
| JSON | zix `jzon` |
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
| `GET /api/tags` | done, also the health check |

Pending:

- Articles: list, feed, detail, create, update, delete.
- Favorites: favorite and unfavorite.
- Comments: list, create, delete.

## Architecture

- One zix worker per CPU. Each worker owns its io_uring loop and touches no shared request state.
- One PostgreSQL connection per worker, opened on first use. No shared pool and no cross-thread handoff.
- `JWT_SECRET` is read at startup and passed to every sign and verify call with the 26-byte minimum.
- Every new password is hashed with bcrypt cost 10. Login verifies against the stored hash.
- Profile reads are auth optional: a missing token is viewer 0, while a present invalid token is 401. Follow and unfollow require a token.
- `GET /api/tags` is served through the zix L1 response cache with a 2 second TTL.

## Optimizations

| Change | Why |
| :- | :- |
| `.URING` dispatch | one ring per worker, no shared event loop |
| per-worker PostgreSQL connection | no locks and no cross-core handoff |
| keep-alive responses | matches the load generator's long-lived connections |
| L1 cache on `GET /api/tags` | the tag list is viewer-independent and changes only when an article adds a tag |
| no cache on per-viewer responses | the user row and the `following` flag are viewer-dependent |
| comptime router | path dispatch is resolved at compile time |
| release default `0.0.0.0:80` | direct front, while `HOST` and `PORT` always override it |

## Build

Run the build, run, and test commands from this submission directory.

```bash
zig build -Doptimize=ReleaseFast
```

The binary is `zig-out/bin/conduit`.

`install.sh`, `build.sh` and `start.sh` are the CI wrappers and are the next step.

## Run

The database named in `DATABASE_URL` must already hold the schema and seed.

```bash
DATABASE_URL='postgres://conduit:conduit@127.0.0.1:5432/conduit' \
JWT_SECRET='multicore-server-challenge' \
HOST=0.0.0.0 PORT=80 \
./zig-out/bin/conduit
```

A debug build binds `127.0.0.1:3000` by default and writes console records plus file records under `logs/`. A release build writes file records only.

## Local database

Both commands run from this submission directory.

```bash
make postgres-primary-up
make sync-seed-dev
```

`make sync-seed-dev` runs the seed script in the challenge repository root. `make sync-seed-full` builds the full seed instead (about 2.4 GB, 5 to 10 minutes). The dev seed creates `conduit_dev` with 100,000 users and 10,000 articles. The container also creates an empty `conduit` database from the schema at first start. Either point `DATABASE_URL` at `conduit_dev`, or copy the seed into `conduit` (stop the server first):

```bash
PGPASSWORD=conduit psql -h 127.0.0.1 -U conduit -d postgres \
  -c "DROP DATABASE IF EXISTS conduit WITH (FORCE)" \
  -c "CREATE DATABASE conduit TEMPLATE conduit_dev"
```

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

The conformance suite has not been run against all 197 checks. Users, auth, profiles, and tags are implemented, so the remaining endpoints still answer 404.

## Notes

- Debug builds enable the console logger. Release builds write the access log to `logs/<date>/conduit-000000.log` only.
- The L1 tag cache conflicts with the challenge rule that forbids response caches across requests. Removing the `sendFromCache` and `sendCached` calls in `src/handlers/api_tags.zig` makes the submission rule-compliant.

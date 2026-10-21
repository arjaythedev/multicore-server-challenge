# Bun: Bun.serve + Bun.SQL

**Front: direct**

## Stack

| Piece | Version |
|---|---|
| Runtime | Bun 1.4.3 |
| Language | TypeScript |
| HTTP server | Bun.serve (built-in) |
| PostgreSQL driver | Bun.SQL (built-in) |
| JWT | jose 6.2.12 (HS256) |
| Password hashing | Bun.password, bcrypt cost 10 |

The submission uses Bun's built-in HTTP server and PostgreSQL client without an additional web framework or
database-driver dependency. The database pool is capped at 10 connections. The server listens directly on the
configured `HOST` and `PORT`.

## Optimizations and why

- **Front: direct.** Avoids the reverse-proxy hop and its CPU cost. Bun keeps idle HTTP connections open for 75
  seconds, longer than the workload's maximum 70-second think time.
- **Built-in HTTP and SQL.** Avoids extra framework and driver layers for this JSON API.
- **Bounded PostgreSQL pool.** Uses at most 10 database connections for this process, keeping well below the
  challenge-wide maximum of 95.
- **Bounded, indexed queries.** Article lists use the fixed schema's indexes, requested page limits/offsets, and
  capped counts. Request values are passed as SQL parameters.
- **Transactional article creation.** Creates an article and links its tags in one transaction so the write is
  committed before returning a response.
- **No application cache.** Request data is read from PostgreSQL while serving the request; JWTs are verified on
  every request.

## Configuration

Required: `DATABASE_URL`, `JWT_SECRET`. Optional: `HOST` (default `0.0.0.0`) and `PORT` (default `80`).

`install.sh` installs Bun 1.4.3. `build.sh` installs dependencies from the lockfile. `start.sh` starts the server
in the foreground.

## Tests and local measurements

The challenge conformance suite passes **197/197** on the development seed.

Local load tests used a MacBook Air, Docker PostgreSQL 18, and the full seed (`conduit_full`, 500,000 seeded
articles). These are exploratory results, not the official 8-core Ubuntu benchmark score:

| Virtual users | Think scale | Overall p95 | Overall p99 | Errors | Result |
|---:|---:|---:|---:|---:|---|
| 1,000 | 0.2 | 2.3 ms | 17.7 ms | 0% | Pass |
| 3,000 | 0.2 | 4.6 ms | 62.0 ms | 0% | Pass |
| 10,000 | 1.0 | 4.1 ms | 40.4 ms | 0% | Pass |

The 40,000-user local run did not pass: macOS reported connection resets/closures and `too_many_files`, so it does
not establish server capacity. The local host cannot provide the benchmark box's comparable CPU measurements.

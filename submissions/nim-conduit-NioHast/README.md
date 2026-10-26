# Nim / async HTTP / PostgreSQL

Front: direct

Nim 2.2.12, `std/asynchttpserver`, PostgreSQL 18 through a small libpq binding,
libxcrypt bcrypt cost 10, and OpenSSL HMAC-SHA256.

## Architecture

- Four worker processes per vCPU, selected by `WORKERS` (defaults to
  `4 * nproc`). Four processes per vCPU gives PostgreSQL enough independent
  blocking queries without approaching the 95-connection application limit.
- Every process binds `HOST:PORT` with `SO_REUSEPORT` and runs one async HTTP
  event loop. The kernel spreads keep-alive connections across processes.
- Every process owns one PostgreSQL connection, so the total stays below the
  95-connection application limit.
- Requests are handled in `src/api.nim`; no transport code is mixed into the API.
- SQL is executed live through libpq on every request. No response, query,
  JWT-verification or password-hash cache is used. Statement text is prepared
  once per process; only query plans are cached, which the rules allow.
- The global and author article lists materialize the requested page before
  computing per-article tags, favorite counts and viewer flags.
- bcrypt uses the system libxcrypt implementation at cost 10.
- JWT is HS256 with `sub`, `iat`, `exp`; the signature and expiry are checked on
  every request.
- `src/pg.nim` contains the libpq binding and a small result wrapper.
- `src/auth.nim` contains JWT/base64url/HMAC.
- `src/password.nim` contains bcrypt.
- `src/main.nim` only parses environment configuration and starts workers.

On an 8-vCPU box the defaults are 32 worker processes / 32 PostgreSQL
connections. All requests are served directly on port 80; Nginx is not used.

## Scripts

- `install.sh`: installs Nim 2.2.12 and the C libraries (`libpq`, `libcrypt`,
  `libssl`).
- `build.sh`: builds `bin/conduit` as a normal user.
- `start.sh`: launches `WORKERS` foreground child processes and waits.

## Build and run

```bash
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit \
JWT_SECRET=multicore-server-challenge HOST=0.0.0.0 PORT=80 bash start.sh
```

## Validation

- `197/197` conformance checks on the 2% dev seed and on the full 2.35 GB seed.
- A small local load smoke (2,000 users, 4-vCPU machine, load generator on the
  same host) completed with zero errors and p95/p99 comfortably below the
  limits; the local generator itself was CPU-limited, so this is not an
  official capacity claim.
- The official 8-vCPU box has not been available for this submission.

## Known trade-offs

The request path uses synchronous libpq calls; concurrency comes from multiple
worker processes (32 PostgreSQL connections on the 8-vCPU box) rather than an
async PostgreSQL pipeline. bcrypt runs synchronously inside a worker, so a
login can delay only that worker. These are deliberate correctness-first
choices and the main areas for future optimization.

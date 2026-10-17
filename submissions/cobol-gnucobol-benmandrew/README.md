# GnuCOBOL

Front: direct

## Toolchain and libraries

- Language: GnuCOBOL 3.2, built from the GNU release tarball by `install.sh` (Ubuntu 24.04 ships 3.1.2), with GMP.
- Framework: none; the server has its own epoll loop.
- Build: `cobc -O2 -fnotrunc`, then gcc -O2.
- Postgres driver: written for this server (`src/pd-pg.cpy`, `src/pd-pgconn.cpy`), protocol 3.0, SCRAM-SHA-256 login.
- libcrypto: OpenSSL from Ubuntu 24.04.
- bcrypt: Solar Designer's crypt_blowfish 1.3 (public domain), with a four-lane lockstep function `_crypt_blowfish_lanes` added.

## Optimisations

- **Native arithmetic on the request path.** The request path uses only operations that GnuCOBOL compiles to plain C, because COMPUTE and 64-bit arithmetic call slow decimal routines.
- **Pipelined Postgres driver.** Many requests share a connection, and each request sends its statements without waiting for earlier ones to finish.
- **Shared Sync for reads.** Read-only requests that are queued together run in one Postgres transaction.
- **Session settings.** Each connection sets `jit = off`, `plan_cache_mode = force_generic_plan` and `enable_memoize = off`.
- **Lean SQL.** Each list endpoint runs one statement, which gets tags, favourite counts and flags only for the rows on the page.
- **Tag list built by Postgres.** Postgres builds the tag list response body with `json_agg`.
- **Rendering from the read buffer.** Rows are written as JSON straight from the Postgres read buffer, without copying them first.
- **Batched bcrypt.** One process hashes up to four passwords at once in lockstep, and waits up to 100 ms after the first so that more can join the batch.

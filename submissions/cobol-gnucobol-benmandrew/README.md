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
- **Batched bcrypt.** One process hashes up to four passwords at once in lockstep, and waits up to 500 ms after the oldest queued password so that more can join the batch.

The last bullet is most of the language-agnostic novelty. `bcrypt` relies on a chain of table lookups, leading to pipeline stalls because of data dependencies between instructions. Overlapping multiple password hashes at once fills the pipeline better. However, logins are relatively rare, so the batch is not often filled before dispatch. By *delaying* the hash of the first password we see, we allow time for more logins to fill the batch. Each session starts with a bcrypt call 25% of the time (24.5% logins, 0.5% sign-ups), and sessions start at N / 900 s for N users, so hashes arrive as a Poisson process with a mean of $\lambda = N / 7{,}200$ per 500 ms window. Once the first login is received, the batch holds that login plus the arrivals in the next 500 ms, up to four in total. A full batch goes out at once, so the first login's mean wait is shorter than the window:

| Users (N) | $\lambda$ | 1 login | 2 logins | 3 logins | ≥4 logins | Expected batch size | Mean wait |
|---|---|---|---|---|---|---|---|
| 12,000 | 1.67 | 18.9% | 31.5% | 26.2% | 23.4% | 2.54 | 462 ms |
| 24,000 | 3.33 | 3.6% | 11.9% | 19.8% | 64.7% | 3.46 | 369 ms |
| 36,000 | 5.00 | 0.7% | 3.4% | 8.4% | 87.5% | 3.83 | 283 ms |
| 48,000 | 6.67 | 0.1% | 0.8% | 2.8% | 96.2% | 3.95 | 221 ms |

The wait applies only when a hasher is idle. The deadline is the oldest queued password's arrival plus 500 ms, so a password that has already queued behind busy hashers goes out as soon as one is free. The delay does not put the pass criteria at risk: logins and sign-ups are 1 request in 900 (0.11%), so they cannot move p95, and they can use at most 0.11 of the 1 percentage point of requests that p99 allows over 1 s. A 500 ms wait is far from the 10 s timeout that counts as an error.

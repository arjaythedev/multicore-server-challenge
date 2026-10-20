# Perl / Mojolicious Conduit server

- **Language:** Perl 5.38 (Ubuntu 24.04 system Perl)
- **Framework:** Mojolicious 9.38 (apt: `libmojolicious-perl`), served by Hypnotoad, its preforking supervisor
- **Driver:** DBI + DBD::Pg (libpq), one connection per worker process, server-side prepared statements
- **bcrypt:** Crypt::Eksblowfish (C), cost 10, verified against the stored hash on every login

Front: nginx

## Deployment shape

Hypnotoad forks one worker per core (8 on the box), each a single-threaded event loop holding one Postgres
connection — 8 connections in total against the 95-connection budget. Accepts and keep-alive requests are
unlimited per worker and idle keep-alives are held for 75 s, so Nginx never reuses a socket the server just
closed. JWT verification is hand-rolled HS256 (Digest::SHA) with an `alg` check and `exp` enforcement on every
request; nothing is cached across requests.

## Install/build

`install.sh` installs everything from the Ubuntu archive via apt — no CPAN compilation, so the build is fast
and reproducible for the pinned distro. `build.sh` verifies the dependency versions and syntax-checks all
sources. `start.sh` execs Hypnotoad in the foreground, configured only by `DATABASE_URL`, `JWT_SECRET`,
`HOST` and `PORT`.

## Optimizations and choices

- **Blocking DBI per worker, not async.** Perl has no non-blocking Postgres driver; instead of a pure-Perl
  event loop pretending to be async, each worker serves one request's SQL at a time and Hypnotoad spreads
  connections across 8 cores. This keeps per-request latency low and predictable.
- **Reference SQL verbatim.** Every endpoint runs the statements from SPEC.md unchanged, including the
  newest-first `ORDER_PAGE` walks and the `LIMIT 1000` capped counts, so list queries stay index-bound.
- **`SET TIME ZONE 'UTC'`** (session-level, as permitted) makes timestamp formatting deterministic; timestamps
  are truncated to 3 fractional digits in Perl.
- **No response or query caching of any kind**; connection + prepared-statement reuse only.
- `before_render` hook gives every error (including router 404/405) the RealWorld `errors.body` shape.

# Rust: urus + smarm

Front: direct

The Conduit API on [urus](https://git.kalsbeek.dev/Markk116/urus) (HTTP/1.1, an actor per connection) and
[smarm](https://git.kalsbeek.dev/Markk116/smarm) (a preemptive green-thread actor runtime, no async/await).
Handlers are plain synchronous functions; a request waiting on Postgres parks its actor on epoll.

This is the readable one: idiomatic code first, then speed where it costs no clarity. Its sibling
`rust-urus-turbo-markk116` is the same server optimized without that constraint.

## Stack

| Piece | Version |
|---|---|
| Rust | 1.99.0 (install.sh) |
| smarm | 0.8.1 |
| urus | 0.3.1 |
| Postgres driver | [smarm-pg](https://git.kalsbeek.dev/Markk116/smarm-pg) 0.1.0 (own, on smarm fd readiness; `postgres-protocol` 0.6 for startup/SCRAM only) |
| bcrypt | cost-10 core vendored from `bcrypt` 0.17 on `blowfish` 0.9, preemptible |
| JWT | own HS256 on `hmac` 0.12 + `sha2` 0.10, claims via `serde` |
| JSON | `serde` + `serde_json`; timestamps with `time` 0.3 |

## Shape

```
root OneForOne
├── database            OneForOne
│   ├── read pool       OneForOne of db.read.<i>: one actor per connection
│   └── write pool      OneForOne of db.write.<i>: one actor per connection
└── urus endpoint       listener pool + one actor per HTTP connection
```

The database starts first, so the reverse-order shutdown stops it last, after the endpoint has drained.
Handlers reach the pools through a `Db` handle held in the shared `App`; nothing is global.

| Module | |
|---|---|
| `main.rs` | settings from the environment, the supervision tree |
| `api/` | routes, the request context (`Req`: auth, body, params), one file per resource |
| `model.rs` | `User`, `Profile`, `Article`, `Comment`: read from rows, serialized as response JSON |
| `sql.rs` | every statement, each a `static` marked read or write |
| `db/` | `Db` (query and batch, routed to a pool) and the pools, over the smarm-pg client |
| `http.rs` | query strings, percent-decoding, `NonEmpty` |
| `auth.rs`, `pwhash.rs` | JWT, bcrypt |

A handler, in full:

```rust
pub fn get(req: &Req) -> Result<Reply, AppError> {
    let viewer = req.viewer()?;
    let slug = req.param("slug");
    article_response(200, &req.db().query(&ARTICLE_BY_SLUG, &[&viewer, &slug])?)
}
```

## Configuration

`DATABASE_URL`, `JWT_SECRET`, `HOST`, `PORT` as in SPEC.md. Optional:

| Variable | Default | |
|---|---|---|
| `SCHEDULERS` | cores | smarm scheduler threads |
| `DB_READ_CONNS` | 4 × cores, 2–72 | Postgres connections for reads |
| `DB_WRITE_CONNS` | cores, 2–24 | Postgres connections for writes |

## Optimizations

- **Own Postgres client** ([smarm-pg](https://git.kalsbeek.dev/Markk116/smarm-pg)). No async driver fits smarm, so this is a small blocking client: extended protocol,
  named prepared statements parsed lazily per connection (the Parse rides in the same write as the first
  Bind/Execute), binary params and results. Reads and writes are attempted first and only park on epoll on
  `EAGAIN`.
- **Batches.** `Db::batch` sends several statements behind one Sync: one round trip, one implicit
  transaction. List page + capped count, favorite/follow write + the read that answers, and article create
  (insert, tags, links, read-back) each go as one batch. Writes are keyed by slug/username so they don't need
  a prior lookup.
- **Separate read and write connections.** A commit waits for its WAL flush. On the benchmark box a flush
  occasionally took 1–2 s; with shared connections every connection soon had a commit stuck behind it and
  all traffic froze (whole seconds with no request completing, enough to fail the p99 budget). Reads now go
  to connections that never commit, so a slow flush only delays writes.
- **Tag lists by primary key.** Both article selects build `tagList` with a per-tag `tags_pkey` lookup instead
  of a join that the planner turns into a seq scan of `tags` per article row. Same rows and order; list pages
  cost ~65% less in Postgres.
- **Generic plans, no JIT** (session settings in the startup message). With the default
  `plan_cache_mode = auto` the global and tag lists were re-planned on every execute (0.5–0.7 ms each, a quarter
  of all statement time): a generic plan can't see `LIMIT $2`, is costed for the whole table, and loses to
  the custom plans. Forced generic plans are just as good, but that same inflated cost crosses
  `jit_above_cost` and JIT-compiles on every execute (~250 ms), hence `jit = off` with it. Postgres CPU per
  request −30% (full seed, 2 vCPU); no statement got slower.
- **Preemptible bcrypt.** smarm preempts on allocation counts and bcrypt's cost loop never allocates, so the
  `bcrypt` crate pins a scheduler thread for a whole ~60 ms verify (measured: a 1 ms ticker actor saw a 556 ms gap
  during 8 verifies). The same algorithm with `smarm::check!()` in each of the 1,024 key-expansion rounds runs
  inline in the request actor (worst ticker gap 19 ms) and is byte-compatible with the crate's hashes (tested).
- **No nginx in front.** The server takes the clients' connections itself (an actor per connection costs a
  64–256 KiB demand-paged stack). Behind nginx, nginx used ~13% of the 8 CPUs and added a hop to every request;
  served directly, the same build holds the same load at +31% req/s and roughly half the p95 (see Results).
  No gzip (optional in SPEC.md): the JSON goes out uncompressed.
- Keep-alive idle timeout 75 s, well above a user's think time between pages.

Every request still reads from Postgres, every token is HS256-verified with `exp` checked, and every login runs
a cost-10 bcrypt verify.

## Failure behaviour

A Postgres connection that breaks mid-request fails the requests queued on it with a 500; its actor
exits and the supervisor starts a replacement that connects and registers under the same name.
Terminating every backend under load costs the in-flight requests and nothing more. A request actor that
dies while waiting only drops its reply channel; the connection is never shared with it.

Actor panics are logged (`[panic] file:line: message`): smarm silences panic output inside actors and urus
answers a panicking handler with an empty 500, so without the hook a handler bug is invisible.

## Results

8 CPUs (Ryzen 9 5900X, 4 cores × 2 threads pinned for Postgres 18, nginx if used, and the server; loadgen
on the other 16), full seed, think time ×0.1, scored like the challenge (5-minute hold, p95 < 500 ms,
p99 < 1 s, < 1 % errors). Users are equivalent users (users ÷ think scale).

| | Best probe passed | Hold passes at |
|---|---|---|
| this server, direct | not probed | **101,080** (17.5k req/s, p95 251 ms, p99 278 ms, 0 errors) |
| this server behind nginx | 112,000 (14.0k req/s, p95 497 ms) | 101,080 (13.3k req/s, p95 456 ms, p99 578 ms, 0 errors) |
| this server with shared read/write connections | 112,000 (14.7k req/s, p95 443 ms) | none from 112,000 down to 101,080 (p99 ~1.9 s) |
| `examples/rust` (axum + sqlx), earlier run | 64,000 | 64,000 (p95 456 ms) |

Behind nginx, Postgres takes 40–45% of the 8 CPUs and nginx ~13%; direct, at the same 101,080 users, the app
takes 33% and Postgres 51% (more requests per second).

**Equivalent users overstate the real score.** Scaling think time by ×0.1 stands in for 10× the users only while
latency is small next to the shortened think time; near saturation it isn't. At think ×1 (one connection per
user, loadgen split over six loopback addresses to get past the ephemeral-port range), direct:

| Users (think ×1) | req/s | p95 / p99 | Open connections | Server RSS |
|---|---|---|---|---|
| 101,080 | 17.9k | 2.2 / 2.3 s (fail) | 100k | 1.9 GB |
| 128,000 | 16.0k | 5.9 / 6.5 s (fail) | 127k | 2.4 GB |

So the server tops out around 18k req/s, which at ~0.28 req/s per user is roughly 60k real users. 0 errors and
no crash at 127k connections; that run is also what found smarm's default actor cap (see `main.rs`). With shared connections the probes are
slightly faster, but every 5-minute hold fails on whole-second freezes behind slow WAL flushes (see
Optimizations); with separate read connections the holds see none.

## Tests

`cargo test` (bcrypt compatibility, Postgres client against `TEST_DATABASE_URL` if set). Conformance:
`bash test/run.sh submissions/<this folder>` from the challenge repo.

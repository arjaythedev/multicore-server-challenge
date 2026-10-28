# Design: rust-raw-meros

A Conduit (RealWorld) server for the multicore challenge. Rust, **std only**: no third-party crate, no vendored
code. Everything the server needs is written for this one job: HTTP/1.1, JSON, the Postgres wire protocol (with
SCRAM-SHA-256), SHA-256/HMAC/PBKDF2, HS256 JWT, bcrypt, the epoll loop. Shortcuts are taken wherever the challenge
makes them safe (documented where taken); nothing is general-purpose.

## Why this shape

Postgres burns 60-75% of the box's CPU for every entry on the leaderboard; the app burns 20-28%. A request costs
Postgres roughly 50 us if it runs in a big batch and 120+ us if it runs alone (measured, see RESULTS.md). So the
design is: **make batches big and cheap**, and keep the app side lean enough that it never competes with Postgres.
Latency budget is generous (p95 < 500 ms), so reads wait up to a collection window (default 30 ms) to share a statement.

## Threads

| Thread | Count (8 vCPU) | Job |
|---|---|---|
| `io` | 2 (`cpus/4`) | epoll loop, own `SO_REUSEPORT` listener, connection table, HTTP parse, JWT check, routing. Never blocks. |
| `read-lane` | 6 | one blocking Postgres connection each; takes a **batch** from the shared read queue, runs it, renders JSON |
| `write-lane` | 2 | one Postgres connection each; **group commit**: many writes, one transaction, responses after COMMIT |
| `bcrypt` | 1 | gathers up to 6 hashes (4-6 independent states interleaved), runs them, hands results on |
| main | 1 | parks |

Total Postgres connections = read-lanes + write-lanes (8), far below the 95 allowed.

Request flow: `io` thread parses a request, verifies the JWT, builds a `Job`, and either answers at once (validation
error, 401, 404 for an unknown route) or pushes the job to the queue that matches its kind. A lane thread renders the
finished HTTP response into a `Vec<u8>` and posts a `Completion{conn, bytes}` to the owning `io` thread (a mutexed
vector plus an `eventfd` wake-up). The `io` thread writes it to the socket.

## Rules compliance (README.md of the challenge)

- Every request reads Postgres while it is served. Data shared between requests lives only inside one batch: every
  recipient was queued before the batch's statements were sent, and the rows are dropped when its responses are
  written (the user's batch-sharing ruling). Nothing survives a batch: no response, row, token or hash caches.
- Writes are committed before the response (`synchronous_commit` untouched, no unlogged tables). Group commit only.
- bcrypt cost 10 on every register / password change and every login, full rounds. JWT signature and `exp`
  checked on every request, `alg` must be HS256.
- No DDL, no server-wide settings (session `SET`s via the startup `options` only), no CPU pinning, no kernel tuning.

## Module map and contracts

```
src/lib.rs            module tree (everything is a library so unit tests are plain `cargo test`)
src/main.rs           reads config, starts threads, parks
src/config.rs         env (DATABASE_URL, JWT_SECRET, HOST, PORT) + tuning knobs (thread/connection counts, windows)
src/sys.rs            the only `unsafe` FFI: epoll, eventfd, setsockopt, nice. Safe wrappers, SAFETY comments.
src/crypto/           sha256, hmac, pbkdf2, base64 (std + url-safe), hex
src/jwt.rs            HS256 sign / verify (fast path for our own token layout, general fallback)
src/bcrypt/           eksblowfish with N interleaved lanes, `$2a$` encode/decode, tables
src/json/             writer (escaping, SSE2 fast path) and a small reader (DOM of borrowed slices)
src/http/             request parser, response header writer, status table
src/pg/               Postgres client: startup + SCRAM, pipelined extended protocol, binary codecs
src/net/              io threads: reactor, connection table, completion mailbox
src/app/              routes, request validation, handlers, response rendering
src/read/             read queue, batcher, batched SQL text, row -> JSON rendering
src/write/            write queue, group commit, SQL text
```

Each module has a doc comment that states what it is, what it assumes, and what it does not handle on purpose.
Unit tests live next to the code (`#[cfg(test)] mod tests`).

### Code standards (for every module)

- Readable first, then fast where the profile says so. A hot path is allowed to be clever only with a comment that
  says what it buys (a number, a link to RESULTS.md) and a test that pins the behaviour.
- Small files (< 600 lines), small functions, named constants instead of magic numbers, `enum`s for states.
- `unsafe` only in `sys.rs` and in documented hot loops, each block with a `// SAFETY:` comment.
- No `unwrap`/`expect` on data that comes from the network or Postgres. Errors are values (`Result`, enums).
- No allocation per request on the steady-state path where a reusable buffer works.
- `cargo test`, `cargo clippy -- -D warnings`, `cargo fmt --check` must pass.

## Zero-copy rules (user requirement: minimise memory traffic, borrow instead of copy)

1. **A request is read once.** The io thread reads the socket straight into a pooled buffer. The parsed `Request`
   borrows from it. If the request is answered at once the buffer goes back to the pool; if it becomes a job, the
   buffer itself moves into the job (a move, not a copy) and the job keeps `Field` ranges into it. Lane threads hand
   `&str` slices of that buffer to Postgres as parameters. Only a JSON string with escape sequences needs its own
   decoded copy (`Cow`).
2. **A response is rendered once.** A lane renders JSON straight from the borrowed Postgres row bytes into a pooled
   response buffer that reserves room for the headers in front (`http::ResponseBuf`). The same `Vec` travels through
   the mailbox to the io thread, which writes it with a single `write` and returns it to the pool. No intermediate
   `String`, no per-field `to_owned`.
3. **Rows are not materialised.** `pg::Results` is one reusable arena; a `Row` is a view into it. Decoding a value
   (`i64`, `&str`, timestamp, array) reads the wire bytes in place. Article rows are decoded once per batch and
   shared by borrow between the responses of that batch (the batch-sharing ruling).
4. **Queues carry ownership, not clones.** Jobs and replies are moved between threads. Buffers are recycled through
   per-thread pools with a hard cap, so memory stays bounded and `malloc` stays off the steady-state path.
5. **Idle connections own nothing**: no buffer, no pending response (only a ~100 byte table entry).

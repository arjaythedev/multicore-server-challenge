# Gleam: a hand-rolled HTTP server and Postgres client on the BEAM

**Front: direct**

No web framework, no database driver library: the HTTP/1.1 server, the PostgreSQL wire-protocol client, the
JSON writer and the JWT code are all written in Gleam, with a thin Erlang module underneath for sockets, crypto
and a few process tricks, and two small C libraries: bcrypt as a dirty-CPU NIF, and the per-request leaf work
(JSON string escaping, timestamp formatting, row decoding, the HTTP request head, HS256 verification) as plain
NIFs. One BEAM process per keep-alive connection, one BEAM process per Postgres connection.

## Stack

| Piece | Version |
|---|---|
| Erlang/OTP | 28.5.0.8 (hex.pm's official Ubuntu 24.04 build, sha256-pinned in `install.sh`; amd64 and arm64) |
| Gleam | 1.19.2 (official release tarball, sha256-pinned) |
| gleam_stdlib / gleam_erlang / gleam_json | 1.0.5 / 1.3.0 / 3.1.0 (pinned in `manifest.toml`; gleam_json is used for request bodies only) |
| bcrypt | the OpenBSD `bcrypt.c`/`blowfish.c` as packaged by erlang-bcrypt, vendored in `native/` with its licence, plus a lane-interleaved variant (`native/bcrypt_lanes.c`) and a small NIF (`native/bcrypt_nif.c`), all built by `build.sh`; cost 10 |
| C helpers | `native/conduit_nif.c`: JSON string escaping and string arrays, RFC 3339 timestamps, DataRow and `text[]` splitting, the HTTP request head, HS256 JWT verification with its own SHA-256 (about 650 lines, no dependencies; the Gleam and Erlang versions stay as the tests' reference) |

`build.sh` compiles the NIFs with the system C compiler, downloads the three pinned Gleam packages and runs
`gleam export erlang-shipment`. `start.sh` runs `erl` on the shipment in the foreground.

## Design

- **Front: direct.** Nginx would cost ~11% of the box and gzip nearly every response.
- **HTTP** (`src/conduit/http.gleam`): `gen_tcp` in active mode. 16 acceptor processes block in `accept`; the one
  that gets a connection spawns its replacement and *becomes* the connection process, so there is no socket
  hand-off. The request head (method, path segments, query, `Authorization`, `Content-Length`, `Connection`)
  is parsed by one NIF call into sub-binaries of the buffer, with the leniency of the `erlang:decode_packet`
  parser it replaced (kept as the tests' reference), and the handler runs inline: it parses,
  authenticates, validates, picks the statement and hands the Postgres connection process the parameters, the
  client socket and a rendering function (`conn.Render`). That process decodes the rows, renders the JSON and
  writes the response, framed with its `Content-Length`, straight to the client socket, then tells the
  connection process it is done. So the rows and the JSON never cross a process boundary, the connection
  process's heap holds only the request, and the Postgres side's long-lived heaps absorb the garbage with cheap
  generational collections. The connection process writes a response itself when no query was needed (errors,
  bad tokens), for the few flows that need the rows for a follow-up statement (login, ownership probes, article
  creation), and when the Postgres side found an earlier response still unread in the socket and handed the bytes
  back rather than wait on a client: the shared process only ever writes into an empty socket queue, which the
  driver answers at once, so a client that stops reading blocks its own connection process and nothing else, as
  before. Pipelined requests are served from the same buffer. A connection process is spawned with a 1598-word
  heap (`MIN_HEAP`), enough for a request without growing in collected steps, and hibernates only after a request
  that grew it past `HIB_WORDS` (2500, i.e. after any growth: with the C request parser a heap rarely grows, and
  4500 left heaps sitting at their grown size for 40 % more memory at the same CPU): about 27 KB per idle
  connection all told. Connections are never closed by
  the server (keep-alive forever).
- **Postgres** (`src/conduit/pg/`): a minimal protocol 3.0 client. Startup with session options
  (`jit=off`, `max_parallel_workers_per_gather=0`, `enable_memoize=off`, `plan_cache_mode=force_generic_plan`;
  the generic plan of every statement has the same shape as its custom plan, checked with `EXPLAIN` for all 35,
  while without the setting the global list was re-planned on every execution, 0.19 ms of planning on top of
  0.15 ms of execution, because the planner prices an unknown `OFFSET` pessimistically), SCRAM-SHA-256 (also md5/cleartext),
  every statement prepared once per connection at startup (`Parse`), then one `Bind`/`Execute` per statement and
  one `Sync` per request. Results come back in binary format; a DataRow and a `text[]` are split into
  sub-binaries of the socket buffer by two small NIFs (never copied), and the scalar columns (int8, bool,
  timestamptz as microseconds) are read with bit-array patterns. Two pools: `DB_READ_CONNS` (12) and `DB_WRITE_CONNS` (8) connection processes. The read
  connections are split into five groups by statement kind (tags; an article, a profile, a user; comments; the
  list pages; the feed and the reads without a batched form) with weights 1/2/1/4/4, each group chosen
  round-robin through its own `atomics` counter, so that what waits on one connection is mostly of one kind. A connection serves one Sync group at a time; a lost connection is reopened and
  the requests waiting in the process mailbox are served after the reconnect. A request carries its deadline; a
  response is never written after it, so the connection process's own 503 can't be followed by a late one.
- **Batched reads.** When a read connection becomes free it drains its mailbox; requests of the same kind as the
  oldest one (an article by slug, a comments list, a page of the global list, ...) are sent as one statement:
  the per-request query becomes the inner side of a `LATERAL` join over the unnested parameter arrays, and every
  row comes back tagged with its request's ordinal (`WITH ORDINALITY`). Each request's rows are still produced by
  its own execution of its own query, in that statement's snapshot; nothing is shared between requests, and
  subqueries that use no request parameter are tied to the request row (`WHERE r.i >= 0`) so they run once per
  request. When requests are arriving fast (the previous one came within two windows), a connection holds the
  batch open for up to `BATCH_WAIT_MS` (2 ms) or until eight are waiting; at low load nothing waits and every
  batch has one request. Batches are capped at 64. Most of a cheap statement's backend cost is per-statement
  overhead: measured through psql on the stand-in, eight batched tags, article-by-slug or comments requests cost
  Postgres 50 %, 70 % and 80 % less than eight single statements, and on a full box without the window only
  1–9 % of requests were batched. The personal feed is not batched (its batched plan was no cheaper).
- **SQL** (`src/conduit/sql.gleam`): same results as SPEC.md's reference SQL in fewer statements. A list page and
  its capped count are one statement; slug lookups fold into the statement that needs them; follow/unfollow and
  favorite/unfavorite are single data-modifying CTE statements that return the response row; ownership-checked
  `UPDATE`/`DELETE` run a 403/404 probe only when no row matched. Page ids are cut in a subquery with a constant
  `LIMIT 100` (the API maximum) before any join or per-row work, so the planner's estimate stays small for
  custom, generic and batched plans alike. Tag names are read by primary key per tag (a correlated scalar
  subquery) instead of a hash join over the tags table on every article. Feed rows return `following` as the
  constant `true`: the statement reached each author through the viewer's own follows row in the same snapshot.
  Article creation with tags is two statements in one Sync group (one implicit transaction, one commit): missing
  tags are inserted first in name order (no deadlocks, no sequence burn for existing tags), then the article is
  inserted, linked and read back; a deadlock/serialization failure is retried once.
- **JSON output** is iodata built directly from the decoded columns (`src/conduit/jsonw.gleam`). A string
  literal is one NIF call that scans the binary and returns `[$", Bin, $"]` around the original sub-binary when
  nothing needs escaping (the common case: no copy), otherwise one escaped copy. A timestamp is one NIF call that
  writes the quoted RFC 3339 string (truncated to milliseconds); the Gleam formatter it replaced stays as the
  test oracle. The two together were about a tenth of the BEAM's time per request as Erlang pattern matching.
  A string array (`tagList`, and the 200-name `/api/tags` answer) is one NIF call that returns one binary, so
  the tags response is one term for the socket writer to walk instead of 600.
- **JWT**: a token in the shape every issuer here produces (the standard header, a flat
  `{"sub","iat","exp"}` payload, a 43-character signature) is verified by one NIF call: HMAC-SHA256 over the
  signed part with a SHA-256 written out in C (no OpenSSL round trip per request), the expected signature
  encoded and compared in constant time, and only then the payload decoded and read; the HMAC is held to
  `crypto:mac/4` on random inputs by the tests. Any other shape goes to the Gleam path (`crypto:mac`, the JSON
  parser), which accepts the same tokens more slowly. `exp` (and `nbf` if present) are checked on every
  request. Nothing is remembered between requests.
- **bcrypt, four at a time.** A Blowfish round is a chain of dependent S-box loads, so one hash leaves much of
  a core idle. A collector process gathers the hash jobs that arrive within `BCRYPT_BATCH_MS` (250 ms, or
  sooner when four are waiting) and hands them to one dirty-CPU NIF call that computes them in lockstep,
  round by round (`native/bcrypt_lanes.c`): every lane runs the full cost-10 schedule and produces the
  reference output (checked against the OpenBSD routine on random inputs and the seed's hashes,
  `native/test_lanes.c`), only the instruction interleaving differs. On an M-series core a batch of four
  takes 48 ms against 44 ms for a single reference hash, so hashing throughput is about 3.5× higher and the
  login tail grows by the collection window. The window is sized to fill the lanes at a full box's login rate
  (about 20 a second); logins are 0.1 % of requests, so it moves only their own latency. Lanes whose salts disagree on the cost fall back to one-by-one.
  A login verifies the first 72 bytes of the password against the stored hash; registration and password
  changes reject longer passwords with 422.
- **Overload behaviour.** A handler waits at most 10 s for its database result and answers 503 after that;
  the request carries that deadline, and a connection process that reaches a queued request past its deadline
  drops it (503) instead of running it for a client that has already given up, so a backlog clears instead
  of feeding on itself. Reads waiting on a connection that turns out to be dead are retried on the reopened
  one; writes are not (their commit state would be unknown).
- **VM flags** (`start.sh`, sized from `nproc`): normal schedulers on ~5/8 of the cores (`+S 5:5` on 8), because
  Postgres needs about as much CPU per request as the BEAM does; `+sbwt none` and friends so idle schedulers sleep
  instead of spinning on cores Postgres needs; `+P 2000000 +Q 1000000` for one process and one port per
  connection.

## Rules

- Every request reads Postgres while it is served: no response, query-result, token or bcrypt caches; only
  connections and prepared statements (query plans) are reused. Batching shares statements, never results.
- Writes are committed before the response: every response is built from the result of the statement or Sync
  group that committed it (`synchronous_commit` untouched).
- bcrypt cost 10 on every registration, login and password change; signature, `alg` and `exp` checked on every
  token.
- No DDL, no server-wide settings; 20 Postgres connections by default (the server refuses to start above 95).

## Configuration

`DATABASE_URL`, `JWT_SECRET` (required), `HOST`, `PORT`. Optional: `SCHEDULERS`, `DIRTY_CPU`, `DB_READ_CONNS`
(12), `DB_WRITE_CONNS` (8), `ACCEPTORS` (16), `MIN_HEAP` (1598 words: a connection process's starting heap),
`HIB_WORDS` (2500: a connection process hibernates after a request that grew its heap past this),
`BCRYPT_BATCH_MS` (250), `BATCH_WAIT_MS` (2: how long a read connection holds a batch open under load), `STATS=1` (log request/batch/expired counters every 10 s).

## Tests

`gleam test` runs unit tests (no database): timestamp formatting, row/array decoding, HMAC-SHA256 and the
request-head parser (the C versions against the Gleam, OTP and `decode_packet` ones, the parser on 35 request
shapes), JSON escaping, JWT issue/verify (fast and general paths, tampering, what the fast path leaves to the general one), query and page validation, percent-decoding, Postgres message encoding/decoding, bcrypt hash/verify through the
collector. `test/run.sh` passes 197/197 and the normalized transcript is byte-identical to
`bench/cmd/conformance/golden-dev.jsonl`, also when replayed on a clean Ubuntu 24.04 container
(`install.sh`, then `test/run.sh`, OTP 28).

## Local evidence

Not a challenge score. The closest local stand-in for the box: a Docker container on an Apple M-series
laptop with a CPU quota of 8, Ubuntu 24.04, PostgreSQL 18 from PGDG with the box's pgtune settings
(`box/pg-conf.sh` values for 8 cores / 16 GB), the full seed, this server on `0.0.0.0:80`, and the load
generator in two other containers on the same Docker network (40,000 users each, `loadgen merge`). Runs are
60 s ramp + 60 s measured. "Cores" is CPU time over the measured window divided by its length: the BEAM
process, and the Postgres client backends.

| Users | req/s | p50 / p95 / p99 ms | BEAM cores | Postgres cores | BEAM RSS |
|---:|---:|---|---:|---:|---:|
| 40,000 | 10,583 | 2.1 / 5.3 / 7.4 | 1.15 | 0.85 | 1.0 GB |
| 60,000 | 15,866 | 1.8 / 6.4 / 9.0 | 1.73 | 1.49 | 1.6 GB |
| 80,000 | 21,210 | 1.7 / 6.8 / 9.0 | 2.28 | 2.56 | 2.2 GB |

The latencies carry the 2 ms batch window (p50 was 0.3 ms without it); 77–85 % of the requests ran in a
batched statement. The same runs earlier the same day, before the connection groups and the window, the
request-head, JWT and array NIFs and the lower hibernation threshold, took 1.64 / 1.26 cores at 40,000 and
2.89 / 2.91 at 80,000 with 2.6 GB; a day before that, 3.59 / 4.08 cores and 3.7 GB at 80,000. In the stand-in
about 40 % of the BEAM's CPU is kernel time (the container's virtual network), and Postgres's is dominated by
the personal feed (per-followee index probes and the capped count, about a third) and the list pages.
Measured through psql on the stand-in, a cheap statement's backend cost is mostly per-statement overhead
(about 40 µs): eight batched tags, article-by-slug or comments requests cost 50 %, 70 % and 80 % less than
eight single ones, the list pages 14–21 % less. Load runs also make the database dirtier (favorites and
comments on hot articles land on pages the visibility map does not cover, so counting them fetches heap
tuples), which is why the 80,000 run, third in the sequence, gains less than the first. 80,000 users leaves
about three of the 8 cores idle; at 100,000 users the two load generators saturate the laptop itself (load
average near 50), so the stand-in cannot say where this server's ceiling is. An M-series core is faster than
the box's x86 vCPU, so expect less on the box.

The same laptop running Postgres.app 17 natively does about 0.13 ms of BEAM CPU per request at 5,300 req/s
(0.155 ms before the rendering moved into the connection process). macOS caps native runs at ~15k connections
(ephemeral ports).

## Credits

The single-statement SQL shapes follow FooVoo's MIT-licensed `elixir-raw-foovoo` submission to this challenge;
the batched-read idea follows jh-d's `csharp-sockets-jh-d`. The bcrypt core is OpenBSD's, via erlang-bcrypt
(`native/LICENSE.bcrypt`).

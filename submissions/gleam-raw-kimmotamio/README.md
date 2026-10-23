# Gleam: a hand-rolled HTTP server and Postgres client on the BEAM

**Front: direct**

No web framework, no database driver library: the HTTP/1.1 server, the PostgreSQL wire-protocol client, the
JSON writer and the JWT code are all written in Gleam, with a thin Erlang module underneath for sockets,
`erlang:decode_packet`, crypto and a few process tricks. One BEAM process per keep-alive connection, one BEAM
process per Postgres connection, bcrypt as a dirty-CPU NIF.

## Stack

| Piece | Version |
|---|---|
| Erlang/OTP | 28.5.0.8 (hex.pm's official Ubuntu 24.04 build, sha256-pinned in `install.sh`; amd64 and arm64) |
| Gleam | 1.19.2 (official release tarball, sha256-pinned) |
| gleam_stdlib / gleam_erlang / gleam_json | 1.0.5 / 1.3.0 / 3.1.0 (pinned in `manifest.toml`; gleam_json is used for request bodies only) |
| bcrypt | the OpenBSD `bcrypt.c`/`blowfish.c` as packaged by erlang-bcrypt, vendored in `native/` with its licence, plus a lane-interleaved variant (`native/bcrypt_lanes.c`) and a small NIF (`native/bcrypt_nif.c`), all built by `build.sh`; cost 10 |

`build.sh` compiles the NIF with the system C compiler, downloads the three pinned Gleam packages and runs
`gleam export erlang-shipment`. `start.sh` runs `erl` on the shipment in the foreground.

## Design

- **Front: direct.** Nginx would cost ~11% of the box and gzip nearly every response.
- **HTTP** (`src/conduit/http.gleam`): `gen_tcp` in active mode. 16 acceptor processes block in `accept`; the one
  that gets a connection spawns its replacement and *becomes* the connection process, so there is no socket
  hand-off. Requests are parsed with `erlang:decode_packet` (a C BIF), the handler runs inline, the response is
  written as one iodata with its `Content-Length`. Pipelined requests are served from the same buffer. Between
  requests a connection process hibernates when its heap has grown past `HIB_WORDS` (2048 words), so an idle
  keep-alive connection costs about 20 KB; connections are never closed by the server (keep-alive forever).
- **Postgres** (`src/conduit/pg/`): a minimal protocol 3.0 client. Startup with session options
  (`jit=off`, `max_parallel_workers_per_gather=0`, `enable_memoize=off`), SCRAM-SHA-256 (also md5/cleartext),
  every statement prepared once per connection at startup (`Parse`), then one `Bind`/`Execute` per statement and
  one `Sync` per request. Results come back in binary format and are decoded with bit-array pattern matching
  (int8, bool, timestamptz as microseconds, `text[]`); text columns are sub-binaries of the socket buffer, never
  copied. Two pools: `DB_READ_CONNS` (12) and `DB_WRITE_CONNS` (8) connection processes, chosen round-robin
  through an `atomics` counter. A connection serves one Sync group at a time; a lost connection is reopened and
  the requests waiting in the process mailbox are served after the reconnect.
- **Batched reads.** When a read connection becomes free it drains its mailbox; requests of the same kind as the
  oldest one (an article by slug, a comments list, a page of the global list, ...) are sent as one statement:
  the per-request query becomes the inner side of a `LATERAL` join over the unnested parameter arrays, and every
  row comes back tagged with its request's ordinal (`WITH ORDINALITY`). Each request's rows are still produced by
  its own execution of its own query, in that statement's snapshot; nothing is shared between requests, and
  subqueries that use no request parameter are tied to the request row (`WHERE r.i >= 0`) so they run once per
  request. There is no timer: at low load every batch has one request. Batches are capped at 64. The personal
  feed is not batched (its batched plan was no cheaper).
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
- **JSON output** is iodata built directly from the decoded columns (`src/conduit/jsonw.gleam`); strings go
  through one `binary:match` for the common case of nothing to escape, otherwise they are copied in chunks
  between the special bytes. Timestamps are formatted with integer arithmetic straight into a binary
  (truncated to milliseconds).
- **JWT**: `crypto:mac(hmac, sha256, …)` and `crypto:hash_equals`; the standard header is recognised by equality
  (any other header is decoded and must say HS256); the flat `{"sub","iat","exp"}` payload is scanned with
  bit-array patterns, anything else goes through the JSON parser so both agree. `exp` (and `nbf` if present) are
  checked on every request. Nothing is remembered between requests.
- **bcrypt, four at a time.** A Blowfish round is a chain of dependent S-box loads, so one hash leaves much of
  a core idle. A collector process gathers the hash jobs that arrive within `BCRYPT_BATCH_MS` (120 ms, or
  sooner when four are waiting) and hands them to one dirty-CPU NIF call that computes them in lockstep,
  round by round (`native/bcrypt_lanes.c`): every lane runs the full cost-10 schedule and produces the
  reference output (checked against the OpenBSD routine on random inputs and the seed's hashes,
  `native/test_lanes.c`), only the instruction interleaving differs. On an M-series core a batch of four
  takes 48 ms against 44 ms for a single reference hash, so hashing throughput is about 3.5× higher and the
  login tail grows by the collection window. Lanes whose salts disagree on the cost fall back to one-by-one.
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
(12), `DB_WRITE_CONNS` (8), `ACCEPTORS` (16), `HIB_WORDS` (2048), `BCRYPT_BATCH_MS` (120), `STATS=1` (log
request/batch/expired counters every 10 s).

## Tests

`gleam test` runs unit tests (no database): timestamp formatting, JSON escaping, JWT issue/verify, query and
page validation, percent-decoding, Postgres message encoding/decoding, bcrypt hash/verify through the
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
| 40,000 | 10,608 | 0.2 / 0.6 / 0.7 | 2.15 | 1.47 | 1.2 GB |
| 60,000 | 15,910 | 0.3 / 0.7 / 0.9 | 3.28 | 2.66 | 2.3 GB |
| 80,000 | 21,178 | 0.5 / 2.5 / 4.8 | 3.59 | 4.08 | 3.7 GB |

80,000 users leaves about 0.3 of the 8 cores idle, so the ceiling here is near 85,000; an M-series core is
faster than the box's x86 vCPU, so expect less on the box. Before the lane-interleaved bcrypt the BEAM took
4.14 cores at 80,000 users (about one core of it hashing ~21 logins/s). Under `pg_stat_statements` at 40,000
users the personal feed was 32% of Postgres time (0.58 ms, ~380 buffers: the page ids per followee, the
capped count, and ten rendered articles), comments 15%, the global list 13%, an article by slug 12%.

The same laptop running Postgres.app 17 natively does about 0.16 ms of BEAM CPU and 0.15 ms of Postgres CPU per
request at 5,300 req/s, with p99 around 1 ms. macOS caps native runs at ~15k connections (ephemeral ports).

## Credits

The single-statement SQL shapes follow FooVoo's MIT-licensed `elixir-raw-foovoo` submission to this challenge;
the batched-read idea follows jh-d's `csharp-sockets-jh-d`. The bcrypt core is OpenBSD's, via erlang-bcrypt
(`native/LICENSE.bcrypt`).

# Elixir: a minimal HTTP server on `:gen_tcp` + an own pipelining Postgres client

Front: direct

Based on [elixir-raw-foovoo](../elixir-raw-foovoo) by @FooVoo (MIT), moved to OTP 29 / Elixir 1.20, with Postgrex
replaced by a small pipelining client.

No Phoenix, Plug, Bandit or Cowboy. One BEAM process per keep-alive connection, `:erlang.decode_packet` for HTTP
parsing, hand-built iodata responses, an own PostgreSQL wire-protocol client, and an own bcrypt NIF that computes up
to 4 hashes interleaved.

## Stack

| Piece | Version |
|---|---|
| Erlang/OTP | 29.1.2 (hex.pm's official Ubuntu 24.04 build, sha256-pinned in `install.sh`; amd64 and arm64) |
| Elixir | 1.20.4 (official release zip, sha256-pinned) |
| bcrypt | `native/`: Openwall crypt_blowfish (libxcrypt 4.4.36) + rust-tokio-Scooter1337's interleaving, cost 10 |
| elixir_make | 0.10.0 (builds the NIF); bcrypt_elixir 3.3.2 only in tests, as the reference implementation |

All dependency versions and hashes are in `mix.lock`; `build.sh` runs `mix release` with `MIX_ENV=prod`.
`.tool-versions` is only for local development with asdf.

## Design (inherited from elixir-raw-foovoo)

- **Front: direct.** Nginx would cost ~11% of the box.
- **HTTP**: `ACCEPTORS` (16) processes block in `accept`. Each one that gets a connection spawns its replacement and
  becomes the connection process. Sockets are `active: true`, `decode_packet(:http_bin)` parses, and a connection
  hibernates as soon as it is idle (see "Tuning": this keeps the app at ~0.7 GB for 150k connections).
- **One statement per request**: a list page and its capped count are one statement, slug lookups fold into the
  statement that needs them, and writes return the response row themselves (data-modifying CTEs).
- **Hand-built JSON iodata**, and **JWT** through `:crypto.mac` with a fast path for the standard header and flat
  payload. JSON strings go through OTP's `:json.encode_binary` (33 vs 81 ns per short string against the previous
  compiled-pattern scan; ~2% of app CPU, below what a load probe resolves).
- **VM flags** sized from `nproc`: normal schedulers on ~5/8 of the cores, `+sbwt none` (idle schedulers sleep
  instead of spinning on cores Postgres needs), and `+P`/`+Q` raised for tens of thousands of connections.

## Postgres client (`lib/conduit/pg*`)

- **One process per connection**, owning its socket. At startup it authenticates (SCRAM-SHA-256) and prepares every
  statement in `Conduit.Sql`, recording parameter and result types. Parameters and results are binary.
- **Pipelining**: a request's Bind/Execute/Sync is written as soon as it arrives, without waiting for earlier ones,
  and requests are answered in order as their ReadyForQuery comes back. Requests already waiting in the mailbox
  go out in one socket write.
- **No pool checkout**: the caller picks the connection with the fewest requests in flight (an `:atomics` counter
  per connection), sends it the request and waits on a monitor alias. Postgrex goes through DBConnection's pool for
  every query, and a connection serves one query at a time: with 12 connections that capped throughput while the
  CPU was 17% idle.
- **Separate read and write connections** (`DB_READ` and `DB_WRITE`, 5 and 16 on 8 cores; see "Tuning"): every
  commit waits for its WAL flush, and reads pipelined behind it would wait too.
- **Batched reads** (the pattern of rust-tokio-Scooter1337 and csharp-sockets-jh-d, which Postgrex's one statement per
  checkout can't do): each connection has one round in flight (`DB_DEPTH`). Requests that arrive meanwhile wait, and
  go out together as the next round, where single-statement requests for the same hot read become one execution
  of its batched variant: `SELECT r.i, x.* FROM unnest($1::int8[], ...) WITH ORDINALITY AS r(p1, ..., i) CROSS JOIN
  LATERAL (<the statement, $k -> r.pk>) x`. These are generated at startup from the statements and the parameter
  types Postgres reports. Rows are routed back by `r.i`. Batches form only under load and grow with it (no timer),
  and Postgres computes request-independent subqueries (the global count, the tag list) once per execution. A failed
  batch is retried request by request. Measured at 80k users: Postgres CPU per request -35% with 2 connections
  (0.153 -> 0.099 ms), but too few connections cap the backends reads can use (see "Tuning").
- **Read routing with bounded affinity** (`DB_ROUTE_SLACK`, 8; after rust-tokio-Scooter1337): a single-statement
  read goes to its statement's preferred connection unless that one has more than 8 requests in flight above the
  least loaded, so same-statement reads meet and batch. About a third of Postgres's CPU is per-statement overhead
  (statement execution is ~66% of it), which a batch pays once. At 80k users: 15.6% -> 30.7% of reads batched,
  Postgres CPU per request -11%; at 120k p99 100 -> 57 ms.
- **Rows are decoded by the requesting process**, not the connection process, which only frames messages and
  routes rows: one process decoding for a whole connection becomes a bottleneck under batching.
- **Multi-statement transactions without BEGIN/COMMIT**: the statements of one request share one Sync, which makes
  them one implicit transaction in one round trip (article creation with tags).
- **Raw timestamps**: `timestamptz` stays integer microseconds and is formatted by hand.
- Session settings in the startup packet: `jit=off` (LLVM compilation takes milliseconds per execution, as it
  isn't kept between executions, against statements of 0.1-1 ms; generic plans' estimates can cross its threshold) and
  `max_parallel_workers_per_gather=0` (`PG_PARAMS` adds more).

## SQL (`lib/conduit/sql.ex`)

Measured locally per statement (Postgres execution time per request, from pg_stat_statements under load), each
change against the run before it; responses checked byte-identical to the previous version on both seeds.

- **Generic plans** (`plan_cache_mode = force_generic_plan` in the startup packet): the plan cache kept re-planning
  the list statements on every execution, which cost as much as running them. Postgres CPU per request -23%.
- **Tag names by primary key** (`ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) ...)`): a join lets
  the planner hash all 200 tags for every article row. -7.5% (also done by rust-tokio-Scooter1337 and
  csharp-sockets-jh-d).
- **"Is there a 1000th row?"** for the capped counts of lists that usually have 1000+ rows (global, tag): `EXISTS
  (... OFFSET 999)` walks the same index entries as counting them but skips aggregating them, with an exact capped
  count only below that (after rust-tokio-Scooter1337 / csharp-sockets-jh-d). Global list -9%, tag list -6.8%.
- **Shared enrichment in batched global and tag lists** (hand-written batched variants, `Conduit.Sql.batched/1`;
  after rust-tokio-Scooter1337): each request's page of ids first, then tags, favorite count and author once per
  distinct article in the batch, then each request's viewer flags from one hashed read of all the batch's viewers'
  favorites and follows. Most global-list requests ask for page 1, so a batch shares most of its articles. Global list
  -11% at 80k users, -19% at 120k; tag lists (spread over many tags) unchanged; p99 at 120k 57 -> 20 ms. Two planner
  traps on the way, both fenced with `OFFSET 0`: flattened, the enrichment was computed for all 500k articles before
  the join (2.5 s), and the tag count ran once per page row instead of once per request. Pages are cut at a constant
  `LIMIT 100` (the API maximum) before the request's limit, so generic plans expect 100 rows per request rather than
  a tenth of the table (a 4 MB hash table for 30 rows). The same bound in the single (unbatched) global, tag and
  favorited lists: -2 to -4%; not in the author list, whose direct index scan is 7% cheaper than through `IN (...)`.

## JSON rendering NIF (`native/conduit_render_nif.c`, `lib/conduit/render/nif.ex`)

The hot reads (the five lists, an article, comments, profile, tags) render their whole response body in one NIF
call, straight from Postgres's binary-format rows: no decoded Erlang terms, no iolists. The connection processes
already hand rows over raw (`Conduit.Pg.query_raw/2`). The output is byte-identical to the Erlang renderer it
replaces (kept behind `RENDER_NIF=0`): strings escaped exactly as OTP's `:json.encode_binary`, timestamps as
`Conduit.Json.ts/1`. Every read is bounds-checked and a row must consume exactly its columns, otherwise `badarg`;
responses are a few KB, so it runs on normal schedulers.

Checks: `test/render_test.exs` (random rows of every shape against JSON built with `Conduit.Json`, every ASCII byte,
multi-byte UTF-8, NULLs, empty arrays and pages, malformed rows), the whole test suite under AddressSanitizer, and
responses byte-identical to the Erlang renderer's on the dev and full seeds, with and without forced batching.

Measured (same build, `RENDER_NIF` on vs off): app CPU per request 0.166 -> 0.155 ms at 80k users (-6.6%), 0.113 ->
0.104 ms at 120k (-8%); box CPU 89% -> 86% and p99 24 -> 13 ms at 120k. App memory grew (1.7 -> 4.0 GB at 120k):
with less garbage, idle connection processes collected less often and held their last response longer, until
connections hibernated whenever idle (see "Tuning").

## bcrypt (`native/`, `lib/conduit/bcrypt*`)

A Blowfish round is a chain of dependent table loads, so one hash leaves most of a core idle. The NIF runs up to 4
independent hashes interleaved (code and credits in [native/README.md](native/README.md)). Concurrent registrations,
logins and password changes meet in one collector process: a batch leaves when 4 are waiting or the oldest has
waited `BCRYPT_WINDOW_MS` (150), at most `BCRYPT_WORKERS` (1) batches at a time, each on a dirty CPU scheduler. Every
hash runs all its iterations with its own salt; every login verifies against the stored hash.

Measured: one core does 30 hashes/s with bcrypt_elixir and 107/s with 4 lanes. At 80k users, bcrypt went from 0.71
to 0.25 cores and app CPU per request from 0.179 to 0.164 ms; logins wait for their batch (p50 97 ms, p99 198 ms),
which leaves overall p95/p99 unchanged since they are 0.1% of requests.

## Tuning

Measured locally (app + Postgres on 8 CPUs, full seed, real think times), one setting at a time against the best so
far; `ms/req` is CPU per request in ms of one core. p99 near the limit varies by up to ~300 ms between identical runs,
so settings were compared on CPU per request below the limit and on pass/fail at it.

- **Write connections were the limit.** A write is its own commit and waits for its WAL flush, so one connection
  does one commit per flush, while commits on separate connections share flushes. With 4 write connections, writes
  topped out at ~1,800/s: at 140k users every write endpoint had p99 2.1 s while reads stayed at 30-55 ms and the box
  at 87%. 8 connections: p99 34 ms at 140k; 16: 27 ms at 150k and the limit moved past 160k. 32 measured the same as
  16.
- **Read connections: 5.** More connections give Postgres more backends for reads but smaller batches. At 160k users,
  Postgres ms/req 0.093 with 5, 0.096 with 6, 0.100 with 8; at 170k p99 66 ms with 5 vs 144 with 6. 4 capped reads at
  4 backends (box stuck at 88%).
- **Hibernate whenever idle.** Before, a connection hibernated only once its heap passed 2048 words, and a response
  copy stays below that, so 140k idle connections each kept their last response until their next request. At 150k
  users the VM held 2.1 GB but RSS was 5.7 GB: the heap allocator's carriers (4.1 GB for 1.2 GB of heaps) stayed
  pinned by those long-lived heaps (measured with each request in a process of its own, see below; without, RSS
  was 6.6 GB at 160k). Hibernating every idle connection (a collection of a small heap): RSS 4.7-5.7 -> 0.6-0.8 GB,
  CPU per request unchanged (0.082 -> 0.081 ms). This also matters for overload: memory no longer
  climbs with every waiting request's leftovers.
- **No change** (within noise): 4, 6 or 8 normal schedulers instead of 5; `DB_ROUTE_SLACK` 4 or 16 instead of 8;
  `+MHas ageffcbf`, `+Muacul de`, `+spp true`, `+sub true`, `+sbwt short` (app 0.067-0.069 vs 0.066-0.067 ms/req).
  **Worse**: `DB_DEPTH=2` (Postgres 0.089 -> 0.094 ms/req: rounds overlap, so batches shrink), `+MBas ageffcbf`.

Together: the local limit moved from ~130k to ~180k users.

## Local results (not the official box)

Ryzen 9850X3D under WSL2: app + Postgres pinned to 8 logical CPUs (4 cores x 2 SMT, like an 8-vCPU box), the load
generator on the other 8, loopback, full seed, real think times, the box's `LimitNOFILE=200000`, and the official
search procedure (warm-up, probes doubling from 4k, bisect to 5%, 5-minute hold). elixir-raw-foovoo scores ~1.66x
its board score on this machine.

| Phase | Users | req/s | p95 / p99 ms | Errors | Box CPU (app / Postgres) | App RSS |
|---|--:|--:|--:|--:|---|--:|
| probe | 128,000 | 33,925 | 8 / 12 | 0 | 87% (38% / 48%) | 526 MB |
| probe | 160,000 | 42,255 | 32 / 63 | 0 | 90% (36% / 54%) | 727 MB |
| probe | 180,000 | 46,843 | 423 / 679 | 0 | 93% (37% / 55%) | 825 MB |
| probe (fail) | 190,000 | 48,335 | 696 / 1,411 | 0 | 94% (37% / 56%) | 975 MB |
| probe (fail) | 200,000 | 47,221 | 1,426 / 2,413 | 0.002% | 94% (40% / 54%) | 1,126 MB |
| **hold** | **180,000** | **46,970** | **143 / 660** | **0** | 93% (36% / 57%) | 825 MB |

Past the limit the server degrades only in latency: throughput keeps rising to ~48k req/s, memory stays around 1 GB,
and every user connects. At 200,000 users the ~60 users beyond the open-file limit (the server's other descriptors:
listening socket, Postgres connections, the VM's own) wait in the accept queue until their requests time out.

## Tried and rejected

Measured locally (app + Postgres on 8 CPUs, full seed), each against the run just before it:

- **`gen_tcp` with `inet_backend: :socket`** (the socket NIF instead of the inet port driver), for the HTTP listener
  and the Postgres connections: at 80k users app CPU per request +4% (0.179 -> 0.186 ms) and app memory 1.1 -> 7.9 GB
  (a gen_statem process and buffers per socket). The port driver's time is mostly the send/recv syscalls themselves.
- **`favorited`/`following` as per-row probes** (`(SELECT true FROM ... ) IS NOT NULL`, as csharp-sockets-jh-d does)
  instead of `EXISTS`, which the planner turns into one hashed read of the viewer's favorites/follows per request:
  Postgres time per request +2-10% for every statement using them (comments +10%, global list +4.5%). A hashed
  read of ~50-75 index entries beats ~10 separate index descents.
- **Shared lookups in batched article and comments reads** (each distinct slug once per batch, viewer flags from
  one hashed read of all the batch's viewers, like the shared lists): Postgres time per request +27% / +15% at 80k
  users, +33% / +26% at 120k, p99 at 120k 20 -> 72 ms. For single-row reads, the generated batched form (one
  lookup per request) is already cheap, and the CTEs, de-duplication and batch-wide viewer reads cost more than
  the shared lookups save; lists differ because they enrich 10 articles per request.
- **One Sync per round on read connections** (one implicit transaction for all the requests of a round, the rest
  of the round re-sent after an error): pgbench showed 3.4x the throughput for 10 pipelined small reads under one
  Sync instead of ten, but under the real load Postgres CPU per request didn't move (0.119 -> 0.119 ms at 80k users,
  0.108 -> 0.106 at 120k): with routing affinity and batching, a round holds few separate requests.
- **Responses flattened to one binary before sending** (`IO.iodata_to_binary`, to skip walking the iolist for its
  size and again for the send's iovec, ~3% of user CPU in perf): app CPU per request unchanged (0.167 -> 0.166 ms
  at 80k users, 0.113 -> 0.113 at 120k); the copy costs about what the walks did.
- **"Is there a 1000th row?" for the feed count** (82.6% of feeds reach the cap): -1% at 80k users, +3.8% at
  120k; the other 17% walk their feed twice.
- **Each request in a process of its own** (spawned with a large `min_heap_size`, so a request rarely collects and
  its heap is freed in one piece): perf showed GC falling from 9.8% to 1.3% of app CPU, but allocation, message
  copying and scheduling grew, for -1-3% app CPU and +0.5-1.7 GB. With connections hibernating whenever idle it
  gained nothing (150k users: 0.079 ms and 591 MB inline vs 0.081 ms and 739 MB with a 4185-word heap); removed.
- **The feed count over `author_id = ANY (ARRAY(followees))`** instead of `IN (SELECT ...)`: no measurable change
  (-0.6%); kept, as it is no more complex.

## Rules

- Every request reads Postgres while it is served; nothing is cached across requests (statement plans aside).
- Writes are committed before the response.
- Every token's signature, `alg` and `exp` are checked on every request; bcrypt cost 10 on every register, login and
  password change.
- No DDL, no server-wide settings.

## Configuration

`DATABASE_URL` and `JWT_SECRET` are required, `HOST` and `PORT` default to `0.0.0.0` and 3000. Everything else is
optional; the defaults are what was measured best (see "Tuning").

| Variable | Default | Meaning |
|---|---|---|
| `SCHEDULERS` | ~5/8 of the cores (`5:5` on 8) | normal schedulers, `total:online` (`+S`) |
| `DIRTY_CPU` | cores / 4, at least 2 | dirty CPU schedulers (bcrypt batches run there) |
| `DB_READ` | ~5/8 of the cores (5 on 8) | read connections |
| `DB_WRITE` | 2 x cores (16 on 8) | write connections |
| `DB_DEPTH` | 1 | rounds in flight per connection |
| `DB_BATCH` | 1 | 0: no batched reads |
| `DB_ROUTE_SLACK` | 8 | how much busier a read's preferred connection may be than the least loaded; `off` |
| `PG_PARAMS` | | more session settings, `name=value,name=value` |
| `BCRYPT_WORKERS` | 1 | bcrypt batches computed at once |
| `BCRYPT_WINDOW_MS` | 150 | how long a hash may wait for its batch to fill |
| `ACCEPTORS` | 16 | processes waiting in `accept` |
| `HIB_WORDS` | 0 | an idle connection hibernates when its heap is above this many words; `off` |
| `RENDER_NIF` | 1 | 0: render JSON in Erlang (the reference the NIF is tested against) |
| `ERL_AFLAGS` | | more VM flags, after ours |

## Tests

`mix test` (ExUnit, no database needed): JWT, query-parameter validation, JSON escaping, timestamp formatting,
HTTP header/body limits, fragmented and pipelined keep-alive requests, the bcrypt NIF against bcrypt_elixir
(both directions, random passwords), the seed's hashes and every batch size, and the JSON NIF against the Erlang
renderer (see above). Also checked locally: ~800 reads of every
kind give byte-identical responses sequentially and from 256 concurrent clients with batching forced (1 read connection,
1 round in flight), and the conformance suite on the dev and full seeds.
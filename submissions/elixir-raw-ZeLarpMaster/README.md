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
- **Separate read and write connections** (`DB_READ` and `DB_WRITE`, 5 and 4 on 8 cores; see "Tuning"): every
  commit waits for its WAL flush, and reads pipelined behind it would wait too.
- **Group commit** (`DB_WRITE_GROUP`, `DB_WRITE_GATHER_MS` 20; all of the top entries do it): a write round waits
  until its oldest write has waited 20 ms, and the favorites, unfavorites, follows, unfollows and new comments in
  it go out under one Sync: one transaction, one commit, one WAL flush. Each is answered with its own results once
  that commit is done. These statements raise no errors of their own (conflicts are `DO NOTHING`, a missing row is
  no row), and each locks only its own user's rows, whose requests come one at a time. If a group fails anyway,
  nothing of it committed, and its writes are retried each on its own Sync. Postgres already shares WAL flushes
  between connections that commit at the same time, so the group alone changed little (WAL fsyncs per write 0.45 ->
  0.47 at 175k users); the window is what makes groups big. Measured with 4 write connections at 175k users: WAL
  fsyncs per write 0.45 -> 0.21, app / Postgres CPU per request 0.066 / 0.063 -> 0.065 / 0.056 ms (120k: 0.079 /
  0.054 -> 0.073 / 0.047). With 16 connections each gets smaller groups: 0.067 / 0.060 (0.35 fsyncs per write).
  Checked with concurrent writes and users whose writes fail (foreign keys), which make their groups fail: every
  response and the final database match what each user's requests imply.
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

## Read plans (`lib/conduit/plan.ex`, the `plan_*` statements in `lib/conduit/sql.ex`)

The design of the top entries (zig-iouring-nick-potts, rust-epoll-theCatWisel, rust-epoll-WorriedArrow,
java-raw-stohirov, nish-std-amritk): the article reads of every connection (the four lists, the feed, an article
and its comments) wait together for the next plan, which answers all of them in two phases.

- **Gathering**: one process collects the reads; a plan leaves once its oldest read has waited `PLAN_WINDOW_MS`
  (30) or `PLAN_MAX` (2048) are waiting, with at most `PLAN_DEPTH` (8) plans running, each in a process of its own.
  Under a backlog the oldest has already waited, so nothing waits on the timer.
- **Phase A**, one statement per kind over its distinct keys: each page's ids and capped count (the same pages and
  counts as the single statements), each slug's id and body, each thread's comments. Identical pages of different
  viewers are read once (most global-list reads are page 1). Statements go out in chunks of `PLAN_CHUNK` (128) keys
  (feeds: 16) to the least loaded read connections, so a plan's work runs on several backends at once: with one
  statement per kind, a backlog made each plan bigger and slower until everything timed out.
- **Feeds' heavy followees** (after rust-epoll-theCatWisel's and zig-iouring-nick-potts's hubs): before its feed
  statements, a plan finds which followees shared by 3+ of its feed viewers have 1000+ articles; a viewer following
  one has a capped count of 1000 without counting. 28 authors have 1000+ articles and 78% of following users follow
  one. Feed statement 2.75 -> 1.73 ms per execution for 3.4 ms per plan of checks (with 2+ followers the check cost
  5.0 ms for no more coverage): about -3.4% of Postgres time at 175k users.
- **Phase B**: each distinct article's columns once (tags, favorite count, author), the viewers' favorites among
  the plan's articles (one primary-key range scan per viewer through a hash of the plan's ids), then their follows
  among its authors.
- **Rendering**: a plan context in the render NIF (a resource used only by the plan's process) takes each chunk's
  raw rows as they arrive: page ids and counts, slug bodies, comments and articles, each article and comment rendered
  to JSON once per plan in pieces around the viewer's `favorited` / `following`, and the viewers' favorites and
  follows as hash sets. It also hands back phase B's parameters already encoded (the plan's distinct article ids,
  its authors). Then each request's finished body comes out as one binary (64 requests per NIF call, so no call
  runs long), inside the message that answers it: the plan process only routes. `PLAN_NIF=0` keeps the Erlang path
  (rows decoded into maps, responses as iolists of NIF pieces) as the reference. Measured against it at 175k users:
  app CPU per request 0.079 -> 0.075 ms (120k: 0.107 -> 0.101), p99 763 -> 504 ms.
- **Small reads** (after java-raw-stohirov and csharp-epoll-aot-gichamba, which batch them too): tags and profiles
  wait for plans as well. A plan reads the tag list once for all of its tags requests and renders it once, and its
  profiles go out together (`plan_profile`, chunks of `PLAN_CHUNK`), in a process of their own, so they answer
  while the article reads are still in phase A. They were ~450k separate executions per minute at 175k users
  (tags 4.4% and profiles 1.1% of Postgres time, plus per-statement overhead and the rounds' messages). Measured:
  app / Postgres CPU per request 0.101 / 0.065 -> 0.079 / 0.054 ms at 120k users (box 68% -> 53%), 0.074 / 0.071 ->
  0.067 / 0.064 at 175k (box 84% -> 76%, p99 579 -> 287 ms). `PLAN_SMALL=0` sends them their own statements.
- **Count lane** (after nish-std-amritk's count lane, `lib/conduit/plan_counts.ex`): a favorite count walks the
  article's index entries (and the heap pages writes touched), so unlike the rest of an article it costs by the row,
  and popular articles are on the pages of plan after plan. Plans read their articles with a placeholder count
  (`plan_articles_nc`) and ask one lane process for the counts beside it; the lane runs one `plan_counts` at a time
  over the union of the ids of every plan that asked, each distinct article counted once, and waits
  `PLAN_COUNTS_GATHER_MS` (65) after a run's first ask so that the next plans join it. The NIF's plan context puts
  each count into its article before rendering it. Not a cache: a run's ids are fixed when it is sent, after the
  reads it answers arrived, and nothing is kept once its plans have their rows. Measured at 175k users (paired runs;
  control app / Postgres 0.065 / 0.058-0.059 ms per request, box 72-73%, p95 65-68 ms):

  | Gather | Plans per run | Counts' share of Postgres | app / Postgres ms/req | Box | p95 / p99 ms | App RSS |
  |--:|--:|--:|---|--:|--:|--:|
  | 0 | 1.0 | 11.6% | 0.066 / 0.058-0.059 | 72% | 76 / 94 | 830 MB |
  | 35 ms | 1.9 | 9.0% | 0.066 / 0.056-0.057 | 70-71% | 117 / 137-189 | 840 MB |
  | 65 ms | 2.9 | 7.3% | 0.066-0.067 / 0.054 | 69% | 148 / 186 | 990 MB |

  Without a window each run took one plan (6.6 ms per run, one plan per 30 ms), so it only moved the cost. With 65
  ms: total CPU per request -2.6% (0.124 -> 0.120 ms), box -4% at the same users; at 120k total 0.128 -> 0.125.
  `PLAN_COUNTS=0` reads the counts in `plan_articles` again.
- **Rules**: nothing outlives its plan: a plan takes only reads already waiting, and every value is read from
  Postgres while they wait. Any failure (a failed statement, an article deleted between the phases) answers that
  read from its single statement instead.

Checks: byte-identical responses to the previous build (without plans) on the dev and full seeds, sequential and
concurrent, also with 2-key chunks; conformance suite.

Measured (app / Postgres CPU per request, ms; same seed and load, against the previous build): 120k users 0.101 /
0.112 -> 0.109 / 0.070 (box 86% -> 72%); 175k 0.064 / 0.094 -> 0.083 / 0.065 (box 92% -> 85%, p99 152 ms). Planner
traps on the way: the viewers' favorites as `user_id = ANY(viewers) AND article_id = ANY(ids)` walked viewers x ids
in the index (60% of Postgres time at 175k), and `article_id = ANY($2)` as a filter searches the array linearly per
row (a parameter array isn't hashed): 30 ms vs 0.9 ms as `IN (SELECT unnest($2))` for 128 viewers x 3000 ids.
Plan windows: 10 ms 0.078 / 0.075, 30 ms 0.083 / 0.065, 60 ms 0.084 / 0.064 (p99 152 -> 221 ms).

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

A Blowfish round is a chain of dependent table loads, so one hash leaves most of a core idle. The NIF runs up to 6
independent hashes interleaved (code and credits in [native/README.md](native/README.md)). Concurrent registrations,
logins and password changes meet in one collector process: a batch leaves when `BCRYPT_LANES` (6) are waiting or the oldest has
waited `BCRYPT_WINDOW_MS` (150), one batch per dirty CPU scheduler at a time (`BCRYPT_WORKERS`, 2 on 8 cores).
Every hash runs all its iterations with its own salt; every login verifies against the stored hash. `BCRYPT_IDLE=n`
runs batches on n threads the NIF starts under `SCHED_IDLE` instead (after zig-iouring-nick-potts), falling back to a
dirty CPU scheduler after `BCRYPT_IDLE_WAIT_MS` (1000); off by default, as they starve on a saturated box (see
"Tuning").

Measured: one core does 30 hashes/s with bcrypt_elixir and 107/s with 4 lanes. At 80k users, bcrypt went from 0.71
to 0.25 cores and app CPU per request from 0.179 to 0.164 ms; logins wait for their batch (p50 97 ms, p99 198 ms),
which leaves overall p95/p99 unchanged since they are 0.1% of requests. Later, with read plans, perf put bcrypt at
19% of the app's user-space CPU at 175k users (~0.57 cores for ~45 logins/s): 6 lanes instead of 4 took a login
from 12.6 to 11.6 ms of CPU under load (-8%; 7.7 vs 9.8 ms on an idle core), login p50 83 -> 117 ms.

## Tuning

Measured locally (app + Postgres on 8 CPUs, full seed, real think times), one setting at a time against the best so
far; `ms/req` is CPU per request in ms of one core. p99 near the limit varies by up to ~300 ms between identical runs,
so settings were compared on CPU per request below the limit and on pass/fail at it.

- **Write connections were the limit.** A write is its own commit and waits for its WAL flush, so one connection
  does one commit per flush, while commits on separate connections share flushes. With 4 write connections, writes
  topped out at ~1,800/s: at 140k users every write endpoint had p99 2.1 s while reads stayed at 30-55 ms and the box
  at 87%. 8 connections: p99 34 ms at 140k; 16: 27 ms at 150k and the limit moved past 160k. 32 measured the same as
  16. (Before group commit. With it, fewer connections make bigger groups: 4 by default since the saturated pass
  below.)
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
- **`SCHED_BATCH`** (after zig-iouring-nick-potts): start.sh runs the VM under `chrt --batch 0` (no privileges
  needed, inherited by every thread), so the scheduler stops letting our wakeups preempt Postgres backends. At 175k
  users, three control / batch pairs (in both orders): total 0.127 / 0.123, 0.128 / 0.127, 0.131 / 0.126 ms/req
  (-2.6% on average, lower in every pair); no change at 120k. p99 at the knee was noise in both arms.
- **bcrypt on `SCHED_IDLE` threads** (`BCRYPT_IDLE`, after zig-iouring-nick-potts) instead of a dirty CPU scheduler:
  two idle / dirty pairs (idle, dirty, dirty, idle): 175k app / Postgres 0.065 / 0.054 and 0.065 / 0.055 against
  0.067 / 0.055 twice (total -2%, lower in each pair), box 69% vs 70-71%; 120k app 0.076 vs 0.077-0.078. Logins wait
  longer for a core (175k p50 135 vs 112 ms, max 368 ms: the 1 s fallback never fired). **Reverted at saturation**
  (below): off by default.

Together: the local limit moved from ~130k to ~180k users.

### Final pass, saturated on an aged database

The board scores with the box saturated (#56's hold: box 96%), and its holds failed below the probes that passed, on
a database aged by the search. Every sweep above ran below saturation, where the box is never the limit. So the last
pass ran at 250k users with the open-file limit raised past 200,000 (only to saturate the box: these cores are faster
than the box's; 290k ran out of memory locally), box 88-90%, on a copy of a database aged by ~6 minutes at 230k-290k
users (+14% articles, +9% comments, +6% favorites). Screens are 60 s probes; two identical controls gave 61.4k /
62.1k req/s, p95 496 / 466 ms.

- **bcrypt's `SCHED_IDLE` threads starve.** At 250k, 55-61% of logins and registrations timed out (10 s): one idle
  thread got no CPU, so each batch of 6 waited out the 1 s fallback before running on a dirty scheduler, ~6 hashes/s
  against ~65 asked. Batches on the dirty CPU schedulers, 2 at once: 0 errors, login p99 258 ms; 2 idle threads, 4
  batches at once and a 200 ms fallback: also 0 errors, login p99 424 ms. Both cost ~3.6% req/s, the CPU of the
  hashes that now run. Dirty schedulers are the default again.
- **Write connections 4 instead of 16** (with the bcrypt change, 5-minute holds): 60.9k vs 59.1k req/s, p95 594 vs
  759 ms, app / Postgres 0.056 / 0.060 vs 0.058 / 0.062 ms per request. In the probe screen it tied (61.8k, p95 438).
- **Worse than the defaults**: 4 or 6 normal schedulers (58.9k / 59.7k req/s, p95 718 / 620 ms), `PLAN_WINDOW_MS` 60
  or 20 (59.9k / 60.4k, p95 585 / 549), 4 read connections (57.8k, p95 760). **No change**: `DB_WRITE_GATHER_MS` 40.
- **The aged database costs Postgres 13%**: the same build held on a fresh copy of the seed did 63.5k req/s, p95 340
  ms, Postgres 0.055 ms per request against 0.062 on the aged copy.

## Local results (not the official box)

Ryzen 9850X3D under WSL2: app + Postgres pinned to 8 logical CPUs (4 cores x 2 SMT, like an 8-vCPU box), the load
generator on the other 8, loopback, full seed, real think times, the box's `LimitNOFILE=200000`, and the official
search procedure (warm-up, probes doubling from 4k, bisect to 5%, 5-minute hold). elixir-raw-foovoo scores ~1.66x
its board score on this machine.

This build passes a probe at 200,000 users, the box's open-file limit, so locally the limit is file descriptors, not
CPU: 51,933 req/s, p95 146 / p99 161 ms, box 71% (app 40% / Postgres 30%), app / Postgres 0.061 / 0.047 ms per
request, app RSS 918 MB, logins p99 210 ms. The 40 timeouts are the users beyond the open-file limit (the server's
other descriptors: listening socket, Postgres connections, the VM's own), waiting in the accept queue. Saturated
holds past that limit, on an aged database: "Final pass, saturated on an aged database" above.

The build before read plans (#56's design) held 180,000 users in a full local search here (46,970 req/s, p95 143 /
p99 660 ms, box 93%) and failed probes at 190,000 and 200,000.

## Tried and rejected

Measured locally (app + Postgres on 8 CPUs, full seed), each against the run just before it:

- **`gen_tcp` with `inet_backend: :socket`** (the socket NIF instead of the inet port driver), for the HTTP listener
  and the Postgres connections: at 80k users app CPU per request +4% (0.179 -> 0.186 ms) and app memory 1.1 -> 7.9 GB
  (a gen_statem process and buffers per socket). The port driver's time is mostly the send/recv syscalls themselves.
- **A few socket-owning loops instead of a process per connection** (the JVM / C# selector shape: one loop per
  scheduler owning thousands of sockets in `active: once`, no per-connection state on its heap, database replies
  as messages). Prototype on GET /api/tags + /api/user only, 150k users at ~43k req/s: app CPU per request 0.093
  -> 0.092 ms (-1%), app memory 0.55 -> 3.5 GB. GC fell from 5.8% to 3.7% of the VM's samples, but the allocator
  (~20%) is mostly binaries and driver buffers, which don't depend on the process model, and the per-request
  `active: once` re-arm costs about what GC saved.
- **Plans writing their responses to the clients' sockets themselves** (`gen_tcp.send` from the plan process, the
  connection process told only that it was sent): app CPU per request +12% at 120k users (0.101 -> 0.113 ms), +5%
  at 175k (0.074 -> 0.078). One process then makes up to 2048 socket writes in a row, and the connection process
  still wakes up for the notice; message passing a body (a reference to a shared binary) was not the cost.
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
- **A gather window for read rounds** (`DB_GATHER_MS`, after the 20-100 ms windows of the top entries): a free
  connection waits until its oldest request has waited the window, so rounds batch more. Batches grew 3-4x and at
  120k users Postgres CPU per request fell from 0.112 to 0.092 / 0.085 / 0.080 ms with 5 / 10 / 20 ms, but at 175k
  (the knee) it stayed at 0.094-0.095: there rounds already run back to back and are large, and only statements that
  share work across a batch (the shared lists) get cheaper with size. Kept as a knob, off.
- **A shared batched feed** (each distinct followee's newest ids once per batch, pages merged from them, each
  distinct article enriched once): 60% fewer buffers at 100 viewers, but twice the time, as generic plans estimate
  every CTE at about one row and join them by nested loops. Sharing only the capped counts ("hub" followees with
  1000+ articles checked once per batch, after rust-epoll-theCatWisel and zig-iouring-nick-potts): 79 of 100 viewers
  skipped their count, but the count is the small part of a feed (its articles' favorite counts dominate): EXPLAIN
  -3-6%, under load Postgres CPU per request unchanged (0.111 vs 0.112 ms at 120k, 0.095 at 175k).
- **The feed count over `author_id = ANY (ARRAY(followees))`** instead of `IN (SELECT ...)`: no measurable change
  (-0.6%); kept, as it is no more complex.
- **A plan's feed counts off its first phase**: a plan's feed chunks wait for its heavy-followee check, so the feed
  answers last in ~92% of plans at 175k users, 2-4 ms after the next kind (phase A ~13-18 ms, phase B ~11-16 ms).
  Feed pages as their own statement (sent with the rest of phase A; phase B needs only the ids), the counts as
  another, sent when the check answers and awaited after phase B. CPU per request unchanged and latency the same
  within noise (steady-state p50 at 175k 41.5 / 42.8 vs 44.4 / 42.5 ms; at 190k, paired both orders, 37.6 / 38.3
  vs 38.1 / 39.3 ms, p95 58.2-58.7 for all): a few ms per plan are small next to the 30 ms gathering window, and
  what fails probes at the knee are short stalls that hit every endpoint, writes included.

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
| `DIRTY_CPU` | cores / 4, at least 2 | dirty CPU schedulers (bcrypt batches) |
| `DB_READ` | ~5/8 of the cores (5 on 8) | read connections |
| `DB_WRITE` | cores / 2, at least 4 (4 on 8) | write connections |
| `DB_WRITE_GROUP` | 1 | 0: every write is its own commit (no group commit) |
| `DB_WRITE_GATHER_MS` | 20 | a write round waits until its oldest write has waited this long (0: sends at once) |
| `DB_DEPTH` | 1 | rounds in flight per connection |
| `DB_BATCH` | 1 | 0: no batched reads |
| `DB_ROUTE_SLACK` | 8 | how much busier a read's preferred connection may be than the least loaded; `off` |
| `DB_GATHER_MS` | 0 | a read round waits until its oldest request has waited this long (0: sends at once; see "Tried and rejected") |
| `DB_GATHER_MAX` | 1024 | ... or until this many requests wait |
| `PLAN` | 1 | 0: article reads run their single statements (no read plans; also off with `RENDER_NIF=0`) |
| `PLAN_WINDOW_MS` | 30 | a plan leaves once its oldest read has waited this long |
| `PLAN_MAX` | 2048 | ... or this many wait (and a plan takes at most this many) |
| `PLAN_DEPTH` | 8 | plans running at once |
| `PLAN_CHUNK` | 128 | keys per statement execution (feeds: an eighth) |
| `PLAN_NIF` | 1 | 0: plans build their responses in Erlang (the reference the NIF's plan context is tested against) |
| `PLAN_SMALL` | 1 | 0: tags and profiles run their own statements instead of going through plans |
| `PLAN_COUNTS` | 1 | 0: plans read their favorite counts with their articles instead of from the count lane |
| `PLAN_COUNTS_GATHER_MS` | 65 | a count lane run waits this long after its first plan asked, so that more plans join it |
| `PG_PARAMS` | | more session settings, `name=value,name=value` |
| `BCRYPT_WORKERS` | dirty CPU schedulers (2 on 8) | bcrypt batches computed at once |
| `BCRYPT_WINDOW_MS` | 150 | how long a hash may wait for its batch to fill |
| `BCRYPT_LANES` | 6 | hashes per batch (1 to 6) |
| `BCRYPT_IDLE` | 0 | `SCHED_IDLE` hashing threads (0: batches run on dirty CPU schedulers; see "Tuning") |
| `BCRYPT_IDLE_WAIT_MS` | 1000 | a batch the idle threads haven't answered by then is computed on a dirty CPU scheduler |
| `ACCEPTORS` | 16 | processes waiting in `accept` |
| `HIB_WORDS` | 0 | an idle connection hibernates when its heap is above this many words; `off` |
| `RENDER_NIF` | 1 | 0: render JSON in Erlang (the reference the NIF is tested against) |
| `SCHED_BATCH` | 1 | 0: the VM runs under the normal policy instead of `SCHED_BATCH` (`chrt --batch 0`, read by start.sh) |
| `ERL_AFLAGS` | | more VM flags, after ours |

## Tests

`mix test` (ExUnit, no database needed): JWT, query-parameter validation, JSON escaping, timestamp formatting,
HTTP header/body limits, fragmented and pipelined keep-alive requests, the bcrypt NIF against bcrypt_elixir
(both directions, random passwords), the seed's hashes and every batch size, the JSON NIF against the Erlang
renderer (see above), and read plans run end to end both ways (`test/plan_test.exs`: the NIF's plan context against
the Erlang path on a stand-in for Postgres answering from a random model, with small chunks, missing articles and
failing statements; tags and profiles in plans against their single statements' renderers). Also checked locally: ~800 reads of every
kind give byte-identical responses sequentially and from 256 concurrent clients with batching forced (1 read connection,
1 round in flight), and the conformance suite on the dev and full seeds.
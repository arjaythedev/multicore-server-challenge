# Elixir: Phoenix + Ecto

**Front: direct**

## Goal

A well-optimized Elixir + Phoenix + Ecto baseline: the `mix phx.new` skeleton, contexts, Ecto schemas and
changesets, composable Ecto queries, JSON view modules and an ExUnit suite (89 tests). The tuning is configuration,
VM flags and how a few queries are written. The queries are Ecto throughout, apart from two `array_agg` fragments
and a `nextval`. Bandit and Elixir's built-in `JSON` handle HTTP and JSON, and the only hand-written formatter is
the one for timestamps. Nothing is cached between requests, every login runs bcrypt at cost 10, and every request
that sends a token has it verified. We measured every change below and dropped the ones that didn't help.

## Stack

| Piece | Version |
|---|---|
| Erlang/OTP | 29.1.2 (hex.pm's official Ubuntu 24.04 build, sha256-pinned in `install.sh`) |
| Elixir | 1.20.4 (official release zip, sha256-pinned) |
| HTTP | Phoenix 1.8 on Bandit 1.13 |
| Database | Ecto SQL 3.14 + Postgrex 0.22, phoenix_ecto 4.7 |
| JSON | Elixir's built-in `JSON` (OTP's `:json`) |
| JWT | Joken 2.7 (HS256) |
| bcrypt | bcrypt_elixir 3.3, cost 10 |
| Telemetry | telemetry_poller 1.3 + telemetry_metrics 1.2 (the generator's `ConduitWeb.Telemetry`, no reporter) |

Exact versions and hashes are in `mix.lock`. `install.sh` is the same toolchain installer as
[`elixir-raw-foovoo`](../elixir-raw-foovoo).

```bash
sudo bash install.sh
bash build.sh    # mix release -> _build/prod/rel/conduit
bash start.sh    # DATABASE_URL, JWT_SECRET; HOST (127.0.0.1), PORT (3000), DB_POOL_SIZE (4 per core, ≤ 90)
```

## Results

Measured on a workstation set up to stand in for the box (see [How we measured](#how-we-measured)), at the
workload's real pacing, following the scoring procedure: 2-minute probes, then 5-minute holds stepping down 5%.

| Run | Users | req/s | p95 | p99 | Errors | |
|---|---:|---:|---:|---:|---:|---|
| probe | 41,000 | 10,829 | 64 ms | 118 ms | 0% | pass |
| probe | 45,000 | 10,550 | 841 ms | 970 ms | 26.7% | fail |
| probe | 43,000 | 10,962 | 326 ms | 379 ms | 0% | pass |
| **5-minute hold** | **43,000** | **10,774** | **497 ms** | **572 ms** | **0%** | **pass** |
| 5-minute hold, repeated | 43,000 | 10,749 | 497 ms | 566 ms | 0% | pass |

Both holds passed with only 3 ms to spare, so 43,000 is right at the limit. Beyond it the server tops out near
11,000 req/s. At 45,000 users, p95 went over 500 ms within seconds of reaching full load, and half a minute later
the connection pool started returning 500s for requests that had waited more than 400 ms for a connection
(`queue_target`). Before the write round trips were cut, the same search held 41,000 (p95 175 ms) and its 43,000
hold failed by 6 ms.

The most useful comparison is [`elixir-raw-foovoo`](../elixir-raw-foovoo), the same language with no framework
(its own HTTP server on `:gen_tcp`, Postgrex directly), run earlier on the same workstation (built with OTP 29)
through the same search:

| | This (Phoenix + Ecto) | elixir-raw-foovoo |
|---|---:|---:|
| Held for 5 minutes on the workstation | 43,000 | 41,100 |
| App CPU per request | 0.41 ms | 0.24 ms |
| Postgres CPU per request | 0.28 ms | 0.33 ms |
| On the box | about 32,000 (estimate) | 32,000 |

A single search can move by several percent between runs, so this isn't a ranking. The framework stack (Bandit,
Plug, Phoenix, Ecto) costs about 0.17 ms more app CPU per request, while our queries spend about 0.05 ms less in
Postgres. For the box estimate we scaled 41,000, the most users held with room to spare (p95 175 ms), rather than
the 43,000 that passed by 3 ms. The 0.78 factor is the box-to-workstation ratio `elixir-raw-foovoo` measured, so it
rests on a single data point.

## Code layout

| | |
|---|---|
| `Conduit.Accounts` | Sign-up, login, the current user, tokens (`Accounts.User`, `Accounts.Token`) |
| `Conduit.Profiles` | Profiles and follows (`Profiles.Follow`) |
| `Conduit.Blog` | Articles, the feed, favorites, comments, tags (`Blog.Article`, `Comment`, `Tag`, `Favorite`) |
| `ConduitWeb.*Controller` | One per resource; they call a context and hand `{:error, reason}` to `FallbackController` |
| `ConduitWeb.*JSON` | The response shapes (`UserJSON`, `ProfileJSON`, `ArticleJSON`, `CommentJSON`, ...) |
| `ConduitWeb.Plugs` | `Authenticate` (required/optional token) and `Parsers` (`Plug.Parsers`, but bad JSON is a 422) |
| `ConduitWeb.Telemetry` | The generator's telemetry supervisor and metric definitions, ready for a reporter |
| `rel/` | The release's VM flags: `vm.args.eex` (`+Q`, allocators) and `env.sh.eex` (`+S`, no distribution) |

The skeleton is `mix phx.new --no-html --no-assets --no-live --no-dashboard --no-mailer --no-gettext` minus what a
JSON API doesn't use (static files, sessions, method override, form parsers, PubSub, DNS clustering), and without
migrations: the schema is fixed, so tests load `schema.sql` instead. `Phoenix.Ecto.CheckRepoStatus` is left out of
the dev endpoint for the same reason (its pending-migration check creates a `schema_migrations` table).

## What we changed and why

The app and Postgres share the box's 8 cores, so the work was about cutting CPU per request on both sides.

### Postgres: fewer and cheaper statements

- Tag names are looked up by primary key through a lateral join to a one-row subquery
  (`inner_lateral_join: t in subquery(tag_name)`, whose `limit: 1` keeps Postgres from flattening it). With a plain
  join, as in the reference SQL, Postgres hashed a scan of all 200 tags once per article, which was 70% of a list
  page's article statement. Postgres CPU per request went down 16%, and p95 at 38,000 users from 104 to 11 ms.
- Every connection uses generic plans (`plan_cache_mode = force_generic_plan`, a session setting passed through
  Postgrex's `parameters:`). By default Postgres re-planned the global and tag lists' id queries on every call,
  because their `LIMIT` parameter makes the generic plan look worse than it is. It's the same index scan, and no
  statement's generic plan scans a big table. Postgres CPU per request went down 5.7%, and late-hold p95 at 41,000
  users from 369 to 185 ms.
- Lists pick a page of ids, then load those articles by id. The ids come from the narrowest index for the filter
  (`article_tags` and `favorites` are walked directly, as in the reference SQL), and the capped `articlesCount`
  comes back in the same statement as an uncorrelated scalar subquery. The articles are a second statement,
  `where: a.id in ^ids`, which Postgres plans once per connection. Walking the join tables cut Postgres CPU per
  request by 21%, and loading by id list instead of re-planning the whole article query on every call cut another
  13%.
- An article's comments are one statement: the article by slug, left-lateral-joined to its newest 100 comments, so
  an unknown slug returns no row. Lists, articles and comments select only the columns the JSON sends.
- Writes make fewer round trips. A favorite looks its article up inside the insert (`insert_all` from a query),
  and an unfavorite does the same inside the delete (a subquery). A comment reads the article's id and the
  commenter's profile in one statement instead of preloading the author after the insert. A new article links its
  tags with one `insert_all` from a query, as the reference SQL does, instead of one insert per tag through
  `put_assoc`. The gain is small and close to the noise: Postgres CPU per request went down 1.1%, app CPU didn't
  change, and p95 in 30 s windows at 41,000 users went from 26 to 17 ms.
- The viewer's `favorited` and `following` come from left joins on `favorites` and `follows` by primary key rather
  than `exists(subquery(...))`, because Ecto plans every subquery again on each call before its cache lookup. App
  CPU went down 2-3%.
- The tag list is one row, with the names aggregated by Postgres (`array_agg(name ORDER BY name)`). That costs
  about 25% less app CPU per call than 200 rows, and it's on every home page.
- The pool has 4 connections per core (32 on the box). More backends make each statement slower, and fewer leave
  requests queueing. Going from 24 to 32 connections lowered late-hold p95 at 41,000 users from 488 to 374 ms in one
  batch and from 516 to 489 ms in another.
- `queue_target` is 200 ms (DBConnection's default is 50), so at saturation a query waits longer for a connection
  before the pool sheds it as a 500. The error limit punishes shed requests sooner than the latency limit punishes
  slow ones.

### BEAM

- Normal schedulers run on 5/8 of the cores (`+S 5:5` on the box, computed in `rel/env.sh.eex`). Postgres needs the
  rest, and extra runnable scheduler threads only preempt it. App CPU per request went down 3-8% in three batches.
- Heaps and binaries use the "good fit" allocator strategy (`+MHas gf +MBas gf`), after perf put a tenth of the CPU
  in the allocators. App CPU went down 3%, and peak memory at 37,000 users from 2,474 to 2,237 MB.
- Timestamps are formatted digit by digit for the API's one format (`ConduitWeb.Timestamps`). That's 6.7× faster
  than `DateTime.truncate/2` + `DateTime.to_iso8601/1`, and a test checks the two agree on 10,000 random times. A
  100-comment list formats 200 timestamps. Together with the tag-list change, p95 at the end of a hold went from
  497 to 390 ms and app CPU down 2.8%.
- Responses use Elixir's built-in `JSON` instead of Jason, for 4% less app CPU per request.
- Each connection is garbage-collected after every keep-alive request, so an idle connection holds about 14 KB
  instead of 80 KB. Connections also start with a 4,181-word heap, and Postgrex decodes text by reference
  (`decode_binary: :reference`, safe because of that GC). Together these cut app CPU by 6% for about 35 KB more per
  connection.

### Serving tens of thousands of keep-alive connections directly

- `+Q 1000000`, because every socket is a port and the default of 65,536 would cap the users. Bandit's
  `read_timeout` is 75 s, longer than the 70 s maximum think time. The listen backlog is 8,192, and responses aren't
  compressed: gzip is optional, and CPU is scarcer than bandwidth here (1,816 to 2,026 req/s in an early local
  test).

### Tried and dropped

No measurable gain, or worse:
- VM: `+sbwt none`, `+sbt db`, `+S 6:6` and `7:7`, `+IOt 2`, `+spp true`, `+sub true`, `+SDcpu 2:2`.
- Allocators: larger multiblock carriers, a 4 GB super carrier.
- Connections: ThousandIsland's `inet_backend: :socket` (app CPU +3.7%).
- Memory: connection heaps of 2,584 / 6,765 / 10,946 words (the largest: −2% app CPU for 1.8 GB more
  memory); GC every 2 or 3 requests.
- Ecto: `pool_count: 2`; 16, 20 or 28 connections; `exists` or lateral one-row forms of the viewer flags; maps
  instead of schema structs for comments (−2-5% of that call); Ecto and Phoenix logging off.
- Auth: building Joken's claims and signer once (−0.2%).
- Postgres: `force_generic_plan` *before* the list was split into ids and articles: the old single statement's
  generic plan scanned every article (7,326 → 1,418 req/s).

## Where the CPU goes now

At 41,000 users Postgres is ~40% of the CPU per request (0.28 of 0.69 ms). The app's share, from a perf profile of
the BEAM (JIT symbols on, user space only):

| | Share of app CPU |
|---|---:|
| Article lists, the feed and article pages (`ArticleController`) | 35% |
| Bandit and Plug outside the controllers (parsing, sending) | 16% |
| The runtime between requests (GC, schedulers, the pool) | 15% |
| Comment lists | 10% |
| bcrypt (logins, on the dirty schedulers) | 9% |
| Token checks | 6% |
| The tag list | 6% |

By layer, Ecto (query planning, its cache lookup, loading rows) appears in about 38% of the app's samples, garbage
collection and the allocators in about 15%, and socket I/O in 6%. In Postgres (`pg_stat_statements`, measured before
the generic-plans change), the list pages' article statement was ~40% of statement time, the feed's ids ~14% and
the comment lists ~12%.

A 5-minute hold gets heavier as it runs: the most-read articles gather comments (up to hundreds) and favorites, and
logins climb as sessions restart, so app CPU per request rises ~4% and Postgres ~12% over the window. New favorites
also sit on pages autovacuum hasn't marked all-visible yet, so the favorite counts' index-only scans visit the heap
for them. That's why a 2-minute probe passes at more users than a 5-minute hold: in an earlier search the probe at
45,000 passed while the hold at 43,000 failed.

## How we measured

A podman container on a 12-core / 24-thread workstation: the app and Postgres 18 (configured by `box/pg-conf.sh` for
16 GB) pinned to 8 threads of one CPU complex, the challenge's load generator on other cores, the full seed. Changes
were compared interleaved (each configuration in turn, then again in reverse, so drift on the machine hits them
alike), first on 30-second windows and at the end on 5-minute holds compared on their last minute, which is where a
hold passes or fails. The earliest changes were measured on a 4-core VM with think times scaled down. The scripts,
every result line and the profiles (perf of the BEAM and of Postgres, `pg_stat_statements`) are on the
[`elixir-phoenix-gerbal-tuning`](https://github.com/gerbal/multicore-server-challenge/tree/elixir-phoenix-gerbal-tuning/submissions/elixir-phoenix-gerbal/tuning)
branch of my fork.

## Behaviour notes

- Input is validated by changesets: required, non-empty strings (a value of only whitespace counts as non-empty, as
  in SPEC.md), passwords of at most 72 bytes (bcrypt ignores the rest), unique usernames and emails through
  `unique_constraint`, and list paging through a schemaless changeset. `limit`, `offset` and comment ids must be
  plain digits (`Conduit.Types.PlainInteger`; Ecto's `:integer` would also take `+5`).
- Errors use RealWorld's `{"errors": {"body": [...]}}`, e.g. `"email has already been taken"`.
- A write that loses a race with a delete returns what it would have returned a moment later, instead of a 500. A
  comment or edit on an article deleted meanwhile is a 404 (`foreign_key_constraint`, `stale_error_field`), and a
  delete that finds its row already gone is the 204 SPEC.md gives it (`allow_stale`). A favorite reads its article
  with the lock that its foreign key check takes anyway (`lock: "FOR KEY SHARE"`), so a concurrent delete either
  waits for it or leaves nothing to favorite.
- Anything that still raises goes through phoenix_ecto: a slug or username that isn't UTF-8, which Postgres rejects,
  is a 400, like a query string that isn't.
- An `offset` too large for the feed's `limit + offset` to fit in a bigint (over 2^63 − 101) is a 422. The reference
  has no such limit.

## Tests

```bash
bash test/run.sh submissions/elixir-phoenix-gerbal          # conformance suite, from the repo root
TEST_DATABASE_URL=postgres://postgres:postgres@localhost/conduit_test mix test
```

`mix test` drops and recreates its own database, loads [`schema.sql`](../../schema.sql) into it and runs each test
in a rolled-back sandbox transaction, except the favorite's locking test, which needs two real connections and
deletes its rows afterwards. It needs a role that can create databases, and hashes at cost 4 to stay fast.
`mix precommit` (as in `mix phx.new`) compiles with warnings as errors, drops unused locked deps, formats with
Styler and runs the tests.

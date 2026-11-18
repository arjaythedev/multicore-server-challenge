# nelua-epoll-tbsvttr

Front: direct

The Conduit API in [Nelua](https://nelua.io) (Lua's syntax, statically typed, compiled to C by gcc), pinned to
commit `a58450563e2d` (Nelua has no releases). No framework. Libraries:

- **libpq**, only to log in and prepare the statements. After that the database process speaks the Postgres wire
  protocol itself on the socket: Bind/Execute/Sync, binary parameters and results, pipelined.
- **OpenSSL**, for HMAC-SHA256 (JWT).
- **ISA-L**, for gzip. It is off by default (`GZIP=1` turns it on).

bcrypt is in-tree, in Nelua.

## Shape

- **HTTP worker processes, one per 2 CPUs.** Each has an epoll loop and an `SO_REUSEPORT` listening socket. A
  worker parses requests, checks tokens and bodies, and answers what needs no database itself.
- **One database process.** It holds all 48 Postgres connections (a quarter of them take the writes, so reads
  never wait behind a commit) and runs every worker's database jobs.
  - A worker sends it a job (its client as a tag, the job, viewer, parameters).
  - The database process makes a stand-in client of it, runs it through the same code a single process would,
    and sends back the finished HTTP response, which the worker writes to its socket.
  - Both directions go over one stream socket pair per worker, a loop pass's messages in one `send()`.
  - So all workers' reads share the same batches, and HTTP's syscalls (two thirds of a worker's time) spread
    over several cores.
- **bcrypt helper processes, one per CPU.** They run at nice 10 and all processes share them.
- **The parent** starts the helpers, the database process and the workers, in that order (so none holds
  another's sockets).

## Reads: one statement per batch, whatever asked

Reads wait in their kind's batch. A batch goes to Postgres once its first request has waited `BATCH_MS` (20 ms)
and no batch of its kind is in flight, so it holds what came in while the last one ran. The busier the server,
the bigger the batches and the more each page, count and article is shared, without a fixed wait. When a batch
has been in flight for `BATCH_SLOW_MS` (100 ms), another may go alongside (up to 3), so one kind isn't limited to
one Postgres backend.

A batch is one statement: each parameter is an array of the requests' values, and every row carries `k`, the
request's place in the batch. There are three kinds of batch statement:

- **PAGES** covers all lists (global, by tag, author or favoriting user, feed) and article pages, in one
  statement.
  - Each distinct page and capped count is computed once, and so is each article, author and tag, however
    many requests show it.
  - Per request it returns the count, the page's article ids, the ones the viewer favorited (one
    `= ANY(page ids)` index scan per request, not one probe per article) and the authors the viewer follows.
  - The worker joins the requests to the article, author and tag rows through hash tables. Tag lists come as
    ids plus each tag's rank by name in Postgres's own collation, so the order is exactly `ORDER BY name`.
- **COMMENTS** reads each article's newest 100 comments once. Per request it returns the article id and the
  viewer's follows.
- **TAGS, USER_GET, LOGIN and PROFILE** are small `unnest(...) WITH ORDINALITY` lookups.

Feed: authors that two or more of the batch's viewers follow are *hubs* (at most 16).
- A hub with 1000 or more articles caps its followers' counts at 1000 without counting.
- A hub's n-th newest article is a floor for its followers' pages, so the other followed authors are only read
  down to there.

This is rust-epoll-theCatWisel's idea.

### Generic plans and batches

Generic plans (`plan_cache_mode = force_generic_plan`, plus `jit = off`, no parallel workers) don't know how many
requests a batch holds. Three things had to be written around that:

- **Table access.** Every table is read from a `LATERAL` or correlated subquery keyed on an index, fenced with
  `LIMIT 1` or `OFFSET 0`. Otherwise the planner flattens it into a join and may hash a whole table (300 ms
  for one global-list batch).
- **Page sizes.** A page is `LIMIT g.lim` inside a constant `LIMIT 100`. A generic plan takes a non-constant
  `LIMIT` for a tenth of the table and allocates hash tables of that size up front: 16 MB, 3 ms, for 10 rows.
- **No join from requests back to groups.** Requests are grouped by what they ask for (`array_agg` of their k
  and viewers) and unnested from the group. Joining the requests back to the groups becomes a nested loop that
  rescans the groups for every request. At 1000 requests per batch that doubled a feed batch's cost.

## Writes

One statement per request (CTEs, the reference statements of SPEC.md folded together), Bind/Execute/Sync,
pipelined up to 8 deep per write connection.

## bcrypt

`src/bcrypt.nelua` is OpenBSD's bcrypt computed for up to 6 passwords at once. The lanes' Blowfish states are
interleaved round by round, so one lane's S-box loads overlap another's. The preprocessor generates an unrolled
function per lane count. Checked against libxcrypt on random 8-bit passwords.

- **Speed (aarch64):** 66 ms per hash with one lane, 18 ms per hash with five.
- **Lane count:** chosen at start by measuring.
- **Helper pool:** the helpers share one datagram socket that every worker sends to. One helper at a time
  collects requests (a token in a pipe), for at most `BCRYPT_WAIT_MS` (150 ms) or until its lanes are full,
  then hands the token on and computes them all. So logins from every worker fill the lanes.

The multi-lane idea is rust-epoll-theCatWisel's.

## Measured locally

Setup:
- Docker on a 4-core aarch64 VM (2 HTTP workers by default).
- Postgres 18 with the box's config, the full seed, the repo's load generator.
- CPU is the box cgroup's.
- The two servers were run within the same hour; none of the runs had the load generator falling behind.
- The comparison is rust-epoll-theCatWisel as merged in #143 (190,000 on the leaderboard). Its #154 (210,000)
  came after these runs and wasn't measured here.

| Users | Server | req/s | p50 / p99 | Box CPU | Postgres | App + bcrypt |
|---|---|---|---|---|---|---|
| 60,000 | this | 15,783 | 26 / 44 ms | 1.40 cores | 0.74 | 0.66 |
| 60,000 | rust-epoll-theCatWisel #143 | 15,851 | 12 / 22 ms | 1.30 cores | 0.68 | 0.62 |
| 138,000 | this | 35,707 | 84 / 203 ms | 2.77 cores | 1.40 | 1.37 |
| 138,000 | rust-epoll-theCatWisel #143 | 36,181 | 33 / 179 ms | 2.74 cores | 1.49 | 1.25 |

Near the box's capacity this and #143 are even. Postgres does a little less work for this one, the app a little
more (the hop between processes). At lower load the batches are smaller, which costs some CPU and keeps latency low.
On this box both fail at 145,000, where the load generator also starts to fall behind.

Run to run, the CPU figures vary by about 5–10%.

## Settings

All optional, documented in `start.sh`: `DB_POOL`, `WORKERS`, `BATCH_MS`, `BATCH_INFLIGHT`, `BATCH_SLOW_MS`,
`BATCH_MAX`, `BATCH_US`, `GZIP`, `BCRYPT_HELPERS`, `BCRYPT_LANES`, `BCRYPT_WAIT_MS`.

# Go: own epoll HTTP front, batched Postgres pipelines

**Front: direct.**

A Go server where every database access is batched across requests. It implements [`SPEC.md`](../../SPEC.md) and
serves HTTP itself (no nginx). The idea: the box has 8 cores shared with Postgres, so CPU per request is what counts.
Postgres spends far less per request when many requests arrive as one set-based statement, so the server collects
requests for a few milliseconds and sends them in one pipelined round trip.

Local score: 260,000 users at the 5-minute hold (63.9k req/s, p95 388 ms, p99 442 ms, 0 errors), 2026-10-26, with
the challenge's own `loadgen search` from 500 users on one database for the whole search. Box: an Ubuntu 24.04
container limited to 8 threads of an i9-14900K with 16 GB, Postgres 18 with the challenge config; load generators on
other cores of the same host. That machine is much faster than the official box, so expect a lower official number.
The local run raised the server's file limit to 1,048,576; under the official `LimitNOFILE=200000` one process tops
out near 200,000 connections.

| Piece | Version |
|---|---|
| Go | 1.27.2 (`install.sh`: official tarball, sha256 pinned) |
| HTTP | own epoll server, `third_party/http` (HTTP/1.1, keep-alive, zero-allocation parsing and JSON encoding) |
| Routing, JWT, validation | `third_party/http/conduit`: follows the reference's behavior, including its unstated corners |
| Postgres | `github.com/jackc/pgx/v5/pgconn` v5.11.0: one `pgconn.PgConn` per worker, extended protocol, pipelined statements, binary parameters and results, typed row decoding (no `pgx.Conn`, no reflection) |
| JWT | HS256 verified on every request (signature and `exp`), no verification cache |
| bcrypt | `third_party/fastbc`: Go assembly (no cgo), 4 hashes interleaved per core; cost 10 on every login and sign-up |

Dependencies are pinned in `go.mod` / `go.sum`; nothing prebuilt is committed.

## How a request is served

1. **Front.** An epoll event loop parses the request, checks the token and validates it. Errors that need no database
   (401, 404 for unknown routes, 422) are answered right there.
2. **Queues.** Any other request is queued for a Postgres worker, each of which owns one connection. A write goes to
   one of 4 writers, chosen by a hash of the key it contends on, so writes on the same article or user share a
   connection. A read goes to a read group (below).
3. **Batches.** When its connection is free, a worker takes everything queued (up to 512 requests; a reader waits up
   to 10 ms for 256) and serves it in at most two round trips. Writes run first, together in **one transaction**
   (group commit: every response waits for the commit). Then all reads are pipelined with one Sync. Lookups of users,
   profiles and comments are one `unnest(...)` join for all requests of the batch; article lists, the feed and
   article views fetch the ids of all pages first, then the rows, tags, favorite counts and the viewers' flags of the
   union of those ids, one statement each.
4. **Failures.** Writes are single statements that carry their own existence and ownership checks, so a group never
   fails over a 404 or 403. If Postgres rejects a group (unique violation, deadlock), nothing of it was committed,
   and each request is run again alone, so only the guilty one fails.
5. **bcrypt.** Login looks the user up, then waits for the hash. A dispatcher fills batches of 4 (or releases a batch
   whose oldest request has waited 100 ms) for 3 bcrypt workers. Registration and password changes hash first, then
   write.

Session settings: prepared statements, `plan_cache_mode = force_generic_plan`, `jit = off`, no TLS. 12 connections.

## Read groups

`CONDUIT_READ_PLAN` assigns request families to groups of readers; each group has its own queue, so a slow kind of
request cannot hold up the others, and requests that share work meet in the same batches. The default is
`global=2;feed=2;comments=2;article,profile,user,tags=1;taglist,author,favorited,login=1` (8 readers; the writers are
4 more). The format is groups separated by `;`, each `families=readers`; the families are `global`, `taglist`,
`author`, `favorited`, `feed`, `article`, `comments`, `profile`, `user`, `tags`, `login`, and a family left out joins
the last group. A reader with nothing in its own queue takes work from another group's. Set but empty, the variable
restores one shared read queue. The plan only changes which connection serves a request.

## Sharing identical queries in a batch (disclosure)

`CONDUIT_BATCH_SHARING` (default `1`; `0` turns it off). Requests of one batch that would run the *same* query with the
*same* parameters (the tag list, say, or the first page of the global list for an anonymous reader) run it once, and
each request gets its own response encoded from that one result. The sharing is only within a batch: nothing read from
the database is kept after the responses of that batch are encoded. With the switch off, every request has its own
entry in the batched statement.

## Read snapshot

Each read batch runs inside one `BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY` ... `COMMIT`, sent in the same
pipelined round trips (no extra round trip). Under Read Committed each statement takes its own snapshot, so a favorite
committed between a batch's count statement and its viewer-flag statement could answer `favorited: true` with the old
count. With one snapshot the counts, flags and rows of a batch's responses agree. A failure rolls back and fails only
that batch's reads.

## Tag order

An article's tags are listed alphabetically. The server reads the tag dictionary (`SELECT id, name FROM tags ORDER BY
name`) once per batch that needs it, takes each article's tag ids from `article_tags` and orders them by their
position in the dictionary, which is the database's own order under any collation. The same dictionary answers the
batch's `GET /api/tags` requests.

## Favorites

A favorite or unfavorite writes inside the batch's transaction and is answered after the commit with a count read
once per article for the whole batch. When a batch holds several of them for one viewer and article, or also updates
or deletes an article, they count inside the transaction instead, so each response matches sequential execution.

## How the rules are respected

- **Rule 5 (no caching).** Nothing derived from the database outlives the batch that read it: result buffers, the
  tag dictionary, counts and the per-batch arrays are reset or cleared when the batch ends, and the only sharing is of
  identical queries inside one batch, as described above. Prepared statements and connections are reused, which the
  rule allows. JWTs are verified on every request; bcrypt results are not kept.
- **Rule 6 (commit before responding).** A write response is built only after the transaction that contains the
  write has committed (or, for a retried request, after its own transaction has). Responses of a group are held until
  the group's COMMIT returns.
- **Rule 7 (bcrypt cost 10).** Every login and registration, and every password change, runs a full cost-10 bcrypt
  in `third_party/fastbc`. There is no cache of hashes, results or verified passwords.
- **Postgres.** Only session settings are changed; no schema or index is touched; the application role needs only
  SELECT, INSERT, UPDATE and DELETE.

## Build and run

```bash
sudo bash install.sh     # Go toolchain
bash build.sh            # -> bin/conduit
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=multicore-server-challenge PORT=3000 bash start.sh
```

`GOGC=800` and `GOMEMLIMIT=5GiB` unless set in the environment.

**GOAMD64.** `build.sh` builds with `GOAMD64=v3` when a trivial program built for v3 runs on the build machine (the Go
runtime checks every v3 feature at startup), and with `v1` otherwise, and prints which. The build host is the run
host. `CONDUIT_GOAMD64=v1|v2|v3` overrides it.

**No PGO.** The build uses no profile-guided optimization and ships no `default.pgo`; a profile measured neutral.

**Tunables (environment).** `CONDUIT_BATCH_SHARING`, `CONDUIT_READ_PLAN`, `CONDUIT_READ_GROUPS` (without a plan: G
read queues keyed by what requests share), `CONDUIT_DB_WORKERS` (12), `CONDUIT_DB_WRITERS` (4),
`CONDUIT_READ_WAIT_US` (10000) and `CONDUIT_READ_FILL` (256), `CONDUIT_WRITE_WAIT_US` (0) and `CONDUIT_WRITE_FILL` (16),
`CONDUIT_FLUSH_CAP` (512), `CONDUIT_HTTP_LOOPS` (1), `CONDUIT_HTTP_SLOTS` (4096 requests in flight per loop),
`CONDUIT_HTTP_WAIT` (`epoll`|`netpoll`). The submission build carries no instrumentation; `go build -tags lab` adds
counters, a periodic SAMPLE/BATCH/GROUPS log (`CONDUIT_SAMPLE_SECS`), `SIGUSR1` (logs the counters) and
`CONDUIT_PPROF=addr` (a pprof server). The `arenapoison` tag is a debugging build that overwrites row text after each
batch to catch any use past its lifetime.

`third_party/http` is the event-loop HTTP layer and Conduit front written for this challenge; `third_party/fastbc` is
the bcrypt kernel (Go assembly). Both are original code under the repository's MIT license.

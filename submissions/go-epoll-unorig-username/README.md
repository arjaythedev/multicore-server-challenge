# Go: hand-written epoll loops + pgx/pgconn, batched reads, group-committed writes

Front: direct

| Piece | Version |
|---|---|
| Go | 1.27.3 (official tarball, sha256 pinned in `install.sh`; `go.mod`: `go 1.27`) |
| HTTP | own HTTP/1.1 server on raw `epoll` (`golang.org/x/sys/unix` v0.49.0), no `net/http`, no framework |
| Postgres driver | `github.com/jackc/pgx/v5` v5.11.0, `pgconn` only: prepared statements, binary results, batches |
| bcrypt | own EksBlowfish (`bcrypt.go`), cost 10, up to 4 hashes interleaved; tested against `golang.org/x/crypto/bcrypt` v0.58.0 (test-only) |

All module versions are pinned in `go.mod` / `go.sum`. Build output goes to `bin/` (ignored).

## Why direct

Every virtual user keeps its own keep-alive connection, so a direct server holds ~100k mostly idle sockets.
With epoll loops an idle connection is a small struct and a socket: no goroutine, no stack, no buffer
(buffers exist only while bytes are in flight). That makes holding them cheap, and going direct saves the
CPU Nginx would spend proxying every request (about 11% of the box in the video).

## Design

The box is shared with Postgres, and in every top submission Postgres uses most of it, so the main goal is
less Postgres work per request.

**Event loops.** `LOOPS` (4) goroutines, each with its own `SO_REUSEPORT` listening socket and epoll
instance (edge-triggered connections). A loop reads, frames HTTP/1.1 requests (Content-Length bodies,
pipelining kept in order: the next request is parsed only after the previous response is queued), and
starts each request on its own goroutine, so the loop itself never waits for Postgres or bcrypt. The
handler hands the finished response back through the loop's eventfd; the loop writes it (EPOLLOUT resumes
partial writes). Each response is one `write`. Idle connections are never closed by the server.

**Batched reads, every kind in one statement.** Reads that are waiting at the same time (tags, article by
slug, comments, profile, current user, login lookup, and the global / tag / author / favorited / feed pages)
run as **one** statement, whatever their kinds. Each kind passes its requests' parameters as arrays; the
statement turns every list page and article page into article ids, then reads each distinct article's
viewer-independent data (tag names, favorite count, author) once, however many requests and endpoints show
it (page 1 of the global list and the newest articles are on most pages), and each distinct article's comment
thread once. Per request it returns only its page of ids, its capped count, and the ids among them that the
viewer favorited or whose author the viewer follows: one primary-key range scan (`= ANY`) per request
instead of a probe per row. The responses are assembled in the server from those rows. A read connection
takes everything that is waiting once the oldest request has waited `READ_WAIT_US` (20 ms) or 1,024 are
queued. Against one statement per kind, this cut Postgres CPU per request by about 12% (0.064 against
0.073 ms at 26,400 req/s, back to back), for about 25 ms more p95 (the statement now carries every kind, so
it takes about 10 ms). Waiting 20 ms instead of 10 ms saved about 4% more (0.058 against 0.060, two runs
each), for 5 ms more p95. `READ_CROSS=0` goes back to one statement per kind. If a batch fails, each request
is retried alone, so one request can never fail another; a lost connection is reconnected and the reads
retried.

**Group commit.** Six write connections each take every waiting write (up to 128) and send them as one
pipelined implicit transaction (one Sync, so one commit and one WAL flush). Responses are released only
after Postgres confirms the commit. If any statement fails, Postgres rolls the group back and each write is
retried in its own transaction, which is also where a unique violation becomes 422. A connection lost
during a group fails those writes with 500 (the commit is uncertain, so nothing is retried). Each mutation
is a single statement whose CTEs fold the lookup, the ownership check and the response row together;
creating an article is four statements (article, tags, links, response) chained through the session's
`currval` of the sequence.

**SQL.** The reference SQL, restructured:
- lists cut the page of ids first (`... ORDER BY id DESC LIMIT/OFFSET` on an index) and only then join
  articles and authors and compute tags / counts / flags, so offset rows cost one index step;
- a list statement computes the viewer-independent article data (tag names, favorite count, author) once
  per distinct article on its pages, however many of its requests show that article; `favorited` and
  `following` stay per request;
- tag names are read by primary key per article tag instead of joining the tags table;
- `favorited` / `following` are skipped for anonymous viewers, and in the feed `following` is the
  constant `true` (every feed author is followed by the viewer in the same snapshot);
- a duplicate registration inserts nothing (`ON CONFLICT DO NOTHING`) instead of aborting its group;
- favorite / unfavorite adjust the count by the statement's own insert / delete, since a statement does
  not see its own changes.
Session settings only: `plan_cache_mode = force_generic_plan`, `jit = off`,
`max_parallel_workers_per_gather = 0`, `enable_memoize = off`. 16 Postgres connections in total.

**bcrypt** runs on `BCRYPT_THREADS` (2) dedicated OS threads, never on a loop or a request goroutine: a
login or signup queues its job and waits on a channel, and two threads leave the other cores to Postgres. A
Blowfish round is a chain of dependent S-box loads, so a single hash leaves the core mostly waiting. A thread
that takes a job waits up to `BCRYPT_WAIT_MS` (250) for up to three more and runs the four in lockstep: each
lane is a complete EksBlowfish with all 1,024 cost-10 key-schedule rounds, interleaved round by round so the
lanes fill each other's load stalls. Fewer than four jobs still run four lanes (the spare ones repeat a job),
so a lone hash costs a whole group; that only happens when logins are rare. New hashes are `$2a$10$` with
16 salt bytes from `crypto/rand`; `$2a$`, `$2b$` and `$2y$` verify (constant-time compare). Passwords over
72 bytes are refused at signup and password change (422), as before, since bcrypt ignores the rest.
`go test` checks the lanes both ways against `x/crypto/bcrypt` and the seed's hash of `password123`.

**JSON** is written straight from Postgres binary values (timestamps, `text[]`, int8, bool) into the response
buffer; request bodies use `encoding/json` into typed structs, so a wrong type is a 422.

**JWT**: HS256 verified on every request (signature first, then `alg` must be HS256, `exp` must be in the
future, `sub` a decimal string); nothing is remembered between requests.

## Rules

No caching across requests: every request reads Postgres while it is served; only connections and prepared
statements are reused. A batch shares one statement among requests that are all already waiting when it
starts; the only values computed once for a whole statement are ones that depend on no viewer (the tag
list, the global count, a listed article's tags, favorite count and author), evaluated in that statement's
snapshot and discarded with it. Writes are committed (synchronous commit) before their responses are sent. bcrypt cost 10 for every new password; every login
verifies against the stored hash. No database objects are created or changed; only session-level settings.

## Settings (env, all optional)

`LOOPS` (4), `DB_READ_CONNS` (10), `DB_WRITE_CONNS` (6), `READ_WAIT_US` (20000), `READ_CROSS` (1), `READ_BATCH_MAX` (1024, or 64 per kind), `BCRYPT_THREADS` (2), `BCRYPT_WAIT_MS` (250),
`GOGC` (400).

## Local results

`test/run.sh` passes 197/197 in a clean Ubuntu 24.04 amd64 container that ran `install.sh`.

Load tests: Postgres 18 (box config from `box/pg-conf.sh` for 8 CPUs / 16 GB) and the server in one container
limited to 8 CPUs and 16 GB, full seed, `bench/cmd/loadgen` in a separate container, all on a shared
12-CPU arm64 VM that other benchmarks were using at the same time. Rough numbers, not comparable to the
benchmark box. `-think-scale 0.1` makes N virtual users produce the request rate of 10 N real users.

| run | req/s | p50 | p95 | p99 | errors | CPU app / Postgres (of 8) | app RSS |
|---|--:|--:|--:|--:|--:|---|--:|
| 8,000 VUs x 0.1 (rate of 80k users) | 20,032 | 3.7 ms | 77 ms | 360 ms | 0 | 25% / 25% | 44 MB |
| 10,000 VUs x 0.1 (rate of 100k users) | 22,843 | 36 ms | 148 ms | 276 ms | 0.08% (logins) | 22% / 24% | 100 MB |
| 100,000 idle keep-alive connections | | | | | 0 | | 81 MB |
| same 100k idle + 6,000 VUs x 0.1 | 14,322 | 26 ms | 116 ms | 198 ms | 0 | 17% / 17% | 178 MB peak |

Those runs used `x/crypto/bcrypt` (4 at once); the 0.08% at the 100k rate were logins timing out while the
shared VM gave the container about three cores, and a profile had bcrypt at ~58% of the app's CPU. A 1 ms read
batching window cut Postgres CPU per request by about 20% against no window in back-to-back runs.

Later, same setup, 100,000 real-rate users (26,400 req/s), Postgres CPU per request: a 10 ms window instead
of 1 ms, 0.075 against 0.095 ms (p95 3 -> 17 ms); then the per-distinct-article list data, 0.070-0.073
against 0.075 ms (two runs each).

**Own bcrypt.** CPU per cost-10 hash, `go test -bench .` on one core:

| | arm64 (native) | amd64 (Rosetta) |
|---|--:|--:|
| `x/crypto/bcrypt` | 53 ms | 65 ms |
| own, 1 job (4 lanes, 3 spare) | 74 ms | 90 ms |
| own, 4 jobs in lockstep | 19 ms | 21 ms |

Before / after in one session, same setup as above, alternating binaries, 30 s ramp + 60 s measured:

| run | req/s | login p50 / p99 | errors | CPU app / Postgres (of 8) |
|---|--:|--:|--:|---|
| 10,000 VUs x 0.1, x/crypto (2 runs) | 26,133 / 25,375 | 68 / 192 ms, 92 / 844 ms | 0 | 34% / 35%, 33% / 33% |
| 10,000 VUs x 0.1, own (2 runs) | 25,845 / 25,373 | 136 / 460 ms, 133 / 1016 ms | 0 | 26% / 37%, 25% / 35% |
| 16,000 VUs x 0.1, x/crypto | 32,931 | 10 s (timeouts) | 0.10% (77% of logins) | 34% / 38% |
| 16,000 VUs x 0.1, own (2 runs) | 35,540 / 38,889 | 1277 / 2417 ms, 266 / 783 ms | 0 | 26% / 43%, 28% / 48% |

The app uses about a quarter less CPU at the same rate, and at the 160k-user rate logins no longer time out.
A login now waits for its group (up to 250 ms; with 50 ms most groups ran one or two real hashes in four lanes, and the app used 17% more CPU at 100,000 users) and a four-lane pass (~75 ms on one core), so its median is
higher at moderate rates.

`blowfish_consts.go` (Blowfish's initial P-array and S-boxes, the hex digits of pi) is copied from
`golang.org/x/crypto` v0.58.0 `blowfish/const.go`, Copyright 2009 The Go Authors, BSD 3-Clause license (the
full text is in that file's header).

## Build and run

```bash
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

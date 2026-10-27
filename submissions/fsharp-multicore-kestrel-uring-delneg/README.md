# F# multicore: own io_uring loops + own Postgres client (delneg)

Front: direct

| | |
|---|---|
| Language | F# on .NET 11 RC 3 (SDK pinned and SHA-512 checked in `install.sh`), ReadyToRun, tiered PGO |
| HTTP | Own HTTP/1.1 on raw io_uring: one ring per I/O thread (2), multishot accept and recv with provided buffers |
| Host | Kestrel's host with a custom transport whose accept never yields: the rings own the sockets, and requests never go through Kestrel's pipeline |
| Postgres driver | Own v3 wire-protocol client (extended protocol, binary rows, SCRAM-SHA-256), no pool library |
| bcrypt | C core from c-iouring-tigokraft (#10, MIT), built from source by `build.sh`, cost 10, 5 interleaved lanes |

```bash
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

## Design

**I/O.** Two I/O threads, each with its own io_uring and its own `SO_REUSEPORT` listener. Accept and receive are
multishot; receive buffers come from a provided-buffer group. Each thread parses requests, checks the JWT (HS256,
`alg` and `exp`), and writes the response from its own thread once the data is there.

**One Postgres thread.** A single thread owns every Postgres connection (6 read, 8 write) through its own ring,
so batching needs no locks. Each kind of read (article, comments, global list, tag list, author list, feed,
profile, ...) has one queue for the whole box.

**Batch clock.** A kind sends its queued requests as ONE statement when its oldest request has waited 20 ms
(`BATCH_WAIT_US`) or 64 are queued, and a read connection is free. Batches stay large at any load, and Postgres
pays its per-statement cost once per batch, not once per request (the clock is from #79, the batching policy
from #22). Every statement takes the requests as arrays (`unnest(...)`), and nothing outlives its statement.

**Batch planner (#47).** Every waiting GET of an article, its comments, a profile or an article list (global,
tag, author, favorited, feed) goes into one batch, answered in two pipelined round trips on one read connection.
Phase A runs one statement per kind present, over the DISTINCT keys: one page per (key, limit, offset), one count
per tag, author or viewer, one row per slug or username. Phase B enriches the union of every article phase A
returned once (tag names, favorite count, author), and reads the viewer flags with one primary-key scan per
viewer (`= ANY`). Each article's JSON is written once per batch; each response is put together from those pieces
and its own flags. `PLANNER=0` falls back to the per-kind statements below.

**Packed lists (#82)** (planner off). For lists above a small batch size, each distinct page is read once and each distinct
article once (tags, favorite count, author); then each request gets one row with its page ids and its
`favorited` and `following` flags. `GET /api/tags` is one execution for everyone queued (#48).

**Feed counts.** Most feeds hit the 1000 cap. In each feed batch, the followees that at least two viewers share
(up to 8) are probed once for a 1000th article, in the same statement. A viewer who follows one gets the capped
count 1000 without walking its own followees' articles (the idea is from #100). Everyone else gets the exact
capped count.

**Group commit.** Favorite, unfavorite, follow, unfollow and new comments are batched like reads: each batch is
one write statement plus the batched read of the responses, in one transaction on a write connection. Responses
go out only after `COMMIT`. If a batch fails, each request is retried alone. New comments are matched back to
their requests by (author, article, body) and their rank among identical ones.

**bcrypt.** One hasher thread runs up to 5 hashes in lockstep (the core interleaves independent Blowfish
chains); a second thread joins when 4 or more are waiting. Every hash does all 2^10 rounds, and logins always
verify against the stored hash.

**Postgres session settings** (on its own connections only): `plan_cache_mode = force_generic_plan`, `jit = off`,
`max_parallel_workers_per_gather = 0`, `enable_memoize = off`.

## Settings

All optional; the defaults suit the 8-vCPU box.

| Variable | Default | |
|---|---|---|
| `LOOPS` | 2 | I/O threads |
| `DB_CONNS`, `DB_WRITE_CONNS` | 6, 8 | read and write connections |
| `BATCH_WAIT_US` | 20000 | batch clock |
| `BATCH_MAX`, `BATCH_INFLIGHT` | 64, 6 | batch cap, statements in flight per kind |
| `BCRYPT_LANES`, `BCRYPT_THREADS` | 5, 2 | hashes in lockstep, hasher threads |
| `PLANNER`, `PLANNER_MAX` | on, 2048 | `0` turns the batch planner off; requests per planner batch |
| `FEED_PROOF` | on | `0` turns the shared feed count probe off |
| `MC_STATS` | off | `1` logs batch sizes every 5 s |

## Correctness

- `test/run.sh`: 197/197 on the dev and the full seed.
- SQL changes were replayed against the statement they replace on the full seed over fixed inputs, comparing
  the rows (`experiments/scripts/`).

## Local results (NOT official)

Synteq box, 8 shared vCPUs, Postgres and the load generator on the same box (the load generator pinned to 2 of
them), `-think-scale 0.1`, fresh database per run:

| Users | req/s | box CPU per request | app | Postgres | p95 |
|--:|--:|--:|--:|--:|--:|
| 14,000 | ~29,600 | 158-162 us | 64-65 us | 95-99 us | 183-210 ms |
| 12,000 | ~26,400 | 160-173 us | 64-66 us | 96-107 us | ~150 ms |
| 12,000, `PLANNER=0` | ~29,700 | 163-168 us | 55-57 us | 110-112 us | 64-77 ms |
| 14,000, `PLANNER=0` | ~32,500 | 167-174 us | 57-60 us | 111-116 us | 130-158 ms |

12,000 users at `-think-scale 0.1` is about the request rate of 120,000 real users. The load generator's users
are closed-loop, so the planner's longer waits (two round trips after the 20 ms clock) lower its req/s at a fixed
user count. Measured the same way:
rust-epoll-WorriedArrow (#47) 184-191 us/req, go-epoll-MegaPanchamZ (#61) 217-226. About half of the app's CPU
is bcrypt. Holds at real think time with tens of thousands of users are limited by the load generator on this
box, so they say nothing about the server here.

Every experiment, kept or not, with its numbers: `experiments/worklog.md` and `experiments/autoresearch.jsonl`.

## Credits

- csharp-sockets-jh-d (#22): the SQL, routing and JSON this started from, and the batching policy.
- rust-tokio-Scooter1337 (#7): shared list SQL; c-iouring-tigokraft (#10): the bcrypt core (MIT).
- rust-epoll-WorriedArrow (#47): the two-phase batch planner and its flags statement.
- #82: packed list results; #79: the 20 ms batch clock; #48: tags broadcast; #100: the feed count probe.
- rust-epoll-WorriedArrow (#47), go-epoll-MegaPanchamZ (#61), c-epoll-umitaltintas (#91) and others: ideas
  measured here (see the worklog), most of them as references on the same box.

Built with Claude (Anthropic).

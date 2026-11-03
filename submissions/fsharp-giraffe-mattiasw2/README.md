# F#: Giraffe on Kestrel + Npgsql

**Front: direct**

Implements [`SPEC.md`](../../SPEC.md) and passes `bench/cmd/conformance` (197/197 on the dev seed). Built with the
architecture of the author's production F# platform (sss8): idiomatic F#, a Giraffe route table over Kestrel, a
database layer of typed queries through Npgsql.FSharp, and one small module for each kind of cryptography.

| Piece | Version |
|---|---|
| Language | F# 10, .NET 10 (`global.json`: SDK 10.0.100+, `install.sh` installs 10.0.402) |
| HTTP | ASP.NET Core Kestrel, Giraffe 7.0.2 with endpoint routing |
| JSON | `System.Text.Json`: `Utf8JsonWriter` out, `JsonDocument` in |
| Postgres | Npgsql 10.0.3 (multiplexing, auto-prepare) through Npgsql.FSharp 5.7.0 |
| JWT | HS256 with the BCL's `HMACSHA256` and `Base64Url` (`src/Web/Jwt.fs`) |
| bcrypt | our own, four hashes in lockstep (`src/Engine/Bcrypt.fs`), cost 10; BCrypt.Net-Next 4.2.0 is the test reference and the fallback for unusual hashes |

Package versions are pinned, and `build.sh` restores the `packages.lock.json` graphs in locked mode.

## Layout

```
src/Engine/   the database side: Types, Db (pool), Commit (group commit), Reads (read batching), Bcrypt (lockstep bcrypt), Passwords (bcrypt threads), Tags, Users, Profiles, Articles, Comments
src/Web/      Jwt (the token shim), Wire (JSON in/out, query paging; pure), Handlers (Giraffe), Program (Kestrel)
src/Tests/    xUnit facts for Jwt and Wire, BcryptTests against BCrypt.Net-Next (no database); BatchTests, the read-batching property (FsCheck)
check.sh      the harness: build -> facts -> conformance suite (../../test/run.sh) -> batch property, one verdict
```

- **Engine** has no HTTP and no tokens. Each function takes typed values and returns typed records, or a small
  union (`Done | NotFound | NotYours`, `Stored | Taken | Missing`) that the handler maps to a status.
- **Wire** has no `HttpContext`, so the shape rules (422 cases, `limit`/`offset` parsing, key case-sensitivity,
  timestamp truncation) are plain unit tests.
- **Handlers** only authenticate, decode, call Engine and encode.

## What is different here

Most fast entries share the same big ideas: batch the reads, group the commits, hash passwords several at a time. Two
parts of this one are done differently.

**The read batch is planned in F#, and SQL only looks rows up.** Every hot read is a value (`Read`, in
`src/Engine/Reads.fs`), not a query. A batch of them goes through plain functions: `planA` turns the requests into
distinct keys per kind (forty readers of page 1 are one page, an article page and its comments one slug), two
round trips fetch what those keys need, `planB` derives the second round's keys from the first round's rows, and
`assemble` builds every answer from the rows. Postgres never deduplicates or joins whole tables: each statement
unnests arrays of keys F# has already made distinct and probes an index once per key (`CROSS JOIN LATERAL (...
LIMIT 1)`). Both rounds run in one `REPEATABLE READ READ ONLY` snapshot. Because plan and assembly are pure, the
whole design has a property test (`src/Tests/BatchTests.fs`, FsCheck): for random batches of real keys, every
request's answer inside the batch equals its answer alone, byte for byte as the JSON goes out. A planted bug (one
viewer's favorite leaking to another viewer of the same article) shrank to exactly that batch: two viewers, one
article.

**bcrypt is F#, not C.** Several fast entries call C for bcrypt. Ours is managed F# with raw pointers
(`src/Engine/Bcrypt.fs`): four logins' hashes step through their Blowfish rounds together,
so four independent chains of S-box lookups keep the core busy. Blowfish's 1,042 initial words are computed from
pi (Machin's formula on big integers), not pasted. The JIT's code was tuned by reading its assembly (see
"Where the app's CPU goes" below): one quad of hashes is now 12.9 ms per hash on one Zen 5 core, against 11.1 ms for Openwall's C
with the same interleaving. Every hash is checked bit for bit against BCrypt.Net-Next by a property test on random
passwords (UTF-8 up to 72 bytes) and salts. bcrypt runs only for a request that will succeed (cheap checks first)
and never inside SQL, a transaction or a commit group.

## Multicore model

- **One process, one Kestrel.** Kestrel serves every core with async I/O and holds each user's keep-alive
  connection directly (`Front: direct`). The keep-alive timeout is 120 s. The listen backlog is 65535 instead of
  Kestrel's 512: users arrive thousands a second, and during a GC pause 512 fills and the kernel drops the rest,
  each a 1-3 s TCP retry for its user. At 115,000 users on 6 vCPUs that was 216 dropped connections and p99 405 ms;
  with the larger backlog none, and p99 354 ms.
- **Read batching for the hot reads** (`src/Engine/Reads.fs`): tags, the four article lists, the feed, article by
  slug, comments and profiles. Each such request is a value (`Read`) on one channel. `READ_LANES` reader lanes
  (default one per core), each with a connection of its own, answer the queue in batches:
  - **Gather.** One lane gathers at a time: it takes requests as they arrive until the first is `READ_GATHER_MS`
    old, or until it holds `READ_BATCH`, whichever comes first. The latency budget is 500 ms at p95, and a bigger
    batch shares more work. The lane never peeks at the queue: a `TryPeek` stops the `ConcurrentQueue` under the
    channel from clearing dequeued slots and reusing segments, and the dead segments then kept every answer alive
    through gen0 collections (~400 MB promoted per gen0 at 140k users, found with a heap dump).
  - **Batch size.** A batch's statements run one after another on one backend, so a huge batch is slow for every
    request in it: while all lanes are busy the queue grows, the next lane takes it all, and that batch is slower
    still. At 85,000 users a cap of 512 beat 1,024 on p95 and p99 in two paired runs (227 vs 427 ms and 255 vs
    295 ms at p95), with no more Postgres work. At 128 too little is shared: Postgres used more, the lanes saturated
    and p95 rose to 659 ms. The shutdown line `read timings` gives p50/p95/p99 of a request's wait for its batch,
    a batch's execution and a request's whole time in the read path.
  - **Plan (F#).** The batch's distinct needs: forty requests for page 1 of the global feed are one page, and an
    article page and its comments are one slug lookup.
  - **Phase A (one round trip).** Ids: the tag list, one capped count per distinct list key, the ids of each distinct
    page, slug → article id, username → user, and each distinct comment thread, so phase B knows who wrote the
    comments.
  - **Phase B (one round trip).** Everything shown, once per **batch** and across every kind of request: each
    distinct article's card (columns, tags, favorite count, author), whether a list or an article page shows it; and
    the viewers' flags as two sets, (viewer, article) favorited and (viewer, user) following. The flags are one
    statement: each article's author is looked up once, and each viewer's pairs are one index range scan
    (`= ANY`), not one probe per pair.
  - **Assemble (pure).** Each request's answer is built from those maps. Requests that show the same article share one
    `Card` object.
  - Both phases run in one `REPEATABLE READ READ ONLY` transaction: one snapshot, so the phases agree, and it is
    cheaper than a snapshot per statement.
  - The SQL only looks rows up by keys that F# has already made distinct: unnest the arrays, then one
    `CROSS JOIN LATERAL (… LIMIT 1)` index probe per key. The planner cannot see how few keys there are. With a plain
    join it may hash-join whole tables, and the `LIMIT 1` (the keys are unique) stops it from flattening the lateral
    back into that join.
  - Our sessions run with `jit=off` (a session setting; the server config is untouched). The batched statements
    look costly to the planner, and JIT compiling took ~400 ms of a 1 ms query. Prepared statements do not help:
    Postgres does not cache JIT code.
  - **Proof.** `src/Tests/BatchTests.fs` is an FsCheck property: for random batches of real keys (with many
    duplicates, unknown keys, anonymous viewers and huge offsets), every request's answer in the batch equals its
    answer alone, byte for byte as Wire encodes it. A failure shrinks to the smallest batch that still fails. A bug
    planted to check it (one viewer's favorite leaking to another viewer of the same article) shrank to exactly
    that: two viewers, one article.
  - This is not a cache: every request is answered from a snapshot taken after it arrived, and nothing outlives
    its batch.
  - **Measured** on an 8-thread test box (server and Postgres pinned to the same 8 hardware threads, the load generator
    on the others; in these runs those were each core's sibling hyperthread, so absolute numbers are pessimistic):

    | Users | Build | p95 | Postgres cores | Result |
    |--:|---|--:|--:|---|
    | 40,000 | one statement per request | 673 ms | 5.44 | fail |
    | 40,000 | batched, no gather window | 30 ms | 4.32 | pass |
    | 40,000 | batched, 25 ms window (72 requests per batch) | 84 ms | 1.91 | pass |
    | 80,000 | batched, 25 ms window | 434 ms | 3.65 | pass |
    | 90,000 | batched, 25 or 50 ms window | ~900 ms | 3.6 | fail: the app's CPU (4.1 cores) is now the limit |
- **One multiplexed Npgsql pool for the cold reads** (sign-in lookups, the read after a write), `DB_POOL_SIZE`
  connections, default cores / 2. A request does not hold a connection: its statements are pipelined onto whichever
  connection is free.
- **Group commit for writes** (`src/Engine/Commit.fs`). Every write queues on one channel. `WRITE_LANES` writer
  lanes (default 2), each with a connection of its own, take whatever queued while their previous group was in flight
  (up to `WRITE_GROUP`, default 128) and send it as one `NpgsqlBatch`. That is one round trip and one implicit
  transaction, ended by the batch's Sync, so the whole group shares one commit and one WAL flush. Each caller is
  answered only after that commit (ReadyForQuery). There is no timer: with no load a group is one write, and under
  load the groups grow by themselves.
  - If the server refuses one statement (a UNIQUE name, a deadlock between lanes), it rolls the whole group back, so
    none of it happened. Each write then runs again in its own transaction, and only the bad one fails.
  - If the connection breaks, whether the group committed is unknown, so its writes fail (500) instead of being
    applied twice.
  - At shutdown the server logs `group commit: N writes in M groups`.
- **bcrypt on dedicated threads** (`BCRYPT_THREADS`, default 2) behind a queue, each computing up to `BCRYPT_WIDTH`
  (4) hashes in lockstep (see below). A thread that takes a login waits up to `BCRYPT_GATHER_MS` (150) for
  batch-mates. Logins are ~0.1% of the requests, so that wait barely touches p95 or p99. At 100,000 users on
  6 threads 150 ms instead of 50 filled the batches to 3.3-3.4 hashes instead of 2.4 and saved 0.12-0.16 of the
  app's ~2.8 threads in two paired runs, with the same p95. A burst of logins waits for a thread instead of
  parking thread-pool threads that the cheap reads need.
- **GC:** server GC, non-concurrent, DATAS off, and a 64 MB gen0 budget (`DOTNET_GCgen0size` in `start.sh`). The
  JIT runs with tiered PGO.

## SQL

The reference SQL, reshaped so that **every read and most writes take one round trip** (and a batch of reads one
statement per kind, see above):

- **Lists:** the count, the page's ids and their cards are one statement. The page is chosen by id first and the card
  columns are built only for its rows, so a huge `offset` skips index entries instead of computing tag arrays and
  counts for every skipped article. An empty page still returns the count.
- **Tag names:** each is one `tags` primary-key probe, sorted in SQL. Written as a join, the planner may hash the
  whole tags table once per article shown.
- **Global count:** walks the primary key from the oldest end (`ORDER BY id LIMIT 1000`). Those pages are
  all-visible, so it is an index-only scan.
- **Feed count:** a viewer who follows an author with 1,000 or more articles has a feed of at least 1,000. Each batch
  checks that once for the 8 followees its viewers share most, and those viewers' counts need no scan. On the full
  seed 78% of the viewers who follow anyone follow such an author. (Idea from `csharp-epoll-aot-gichamba`.)
- **Comments:** the article lookup and the newest 100 comments are one statement. No row means 404.
- **Follow, unfollow, favorite, unfavorite, delete article, delete comment, update article:** the lookup, the
  ownership check and the write are one statement (a data-modifying CTE), and the outer `SELECT` reports what it
  found, so 404 and 403 are still told apart.
- **Favorite and unfavorite** return the full article from the same statement. The outer query's snapshot predates
  the CTE's write, so the count adds or subtracts the rows the write actually changed.
- **Create article** is SPEC's transaction as one group-commit write: the new tags, then the article and its tag
  links in one statement (a data-modifying CTE). Same rows, same transaction, then the read after the commit.
- **Slugs** use SPEC's `SLUGIFY` in SQL, so they are byte-identical to the reference.

## Rules

- **No caching:** every request reads Postgres. Only connections and prepared statements are reused.
- **Writes:** each one is committed before its response. Several requests' writes share a transaction (group
  commit, rule 6), and each response waits for that commit.
- **Tokens:** every token is verified each time. `alg` must be `HS256`, the HMAC is compared in constant time,
  `sub` must be a decimal string and `exp` must be present and in the future.
- **bcrypt:** cost 10 for every new password, and every login verifies against the stored hash. A password longer
  than 72 bytes is refused with a 422, never silently truncated.
- **Connections:** at most 95 Postgres connections (`READ_LANES` + `WRITE_LANES` + `DB_POOL_SIZE`; the pool is
  capped to fit).

## bcrypt runs once per sign-in, and never for a refused request

bcrypt is by far the most expensive thing the server does (~50-80 ms of a core), so it runs exactly once per
sign-up, password change or login, and only when that request is going to succeed:

| Request | bcrypt |
|---|---|
| `POST /api/users` | one hash, only after a cheap check that the username and email are free. A body that fails validation, or a taken name, costs none. |
| `POST /api/users/login` | one verify, only when the email exists. An unknown email or a malformed body costs none. |
| `PUT /api/user` with `password` | one hash, only after checking that the user exists and the new names are free. Without `password`, none. |
| everything else | none. Tokens are HS256 JWTs, and `GET /api/user` reads the user row. |

The pre-checks don't change the outcome: two racing sign-ups can both pass, and the UNIQUE constraint still answers
422. At shutdown the server logs its counts (`bcrypt: N hashes, M verifies`). A conformance run gives exactly
3 hashes (2 sign-ups + 1 password change) and 5 verifies (the 5 logins whose email exists).

## Capacity

Measured on one laptop, not on the benchmark box:

| | |
|---|---|
| Machine | Lenovo ThinkPad T14s Gen 6, AMD Ryzen AI 7 PRO 350: 8 cores / 16 threads, 4 Zen 5 (up to 5.1 GHz) and 4 Zen 5c (up to 3.5 GHz), 16 MB L3; 64 GB RAM |
| Software | Ubuntu 24.04.5, kernel 6.17 (OEM), .NET 10.0.14, PostgreSQL 18.6 in Docker with the box's settings for 16 GB (`box/pg-conf.sh`: shared_buffers 4 GB) |
| Pinning | server and Postgres on Zen 5 cores with both of their hyperthreads; the load generator on the cores they do not touch |

A cloud vCPU is one hyperthread, so the benchmark's 8 vCPUs are 4 physical cores x 2. Each run follows the
benchmark's search: a fresh copy of the seed (`CREATE DATABASE ... TEMPLATE`), one server start, the benchmark's
warm-up (500 users, 60 s ramp + 120 s), then a 60 s ramp and 60 s measured.

**8 vCPUs** (4 Zen 5 cores x 2; load generator on the 8 Zen 5c threads; commit 570771b):

| Users | requests/s | p95 | p99 | Postgres threads | app threads | |
|--:|--:|--:|--:|--:|--:|---|
| 130,000 | 33,800 | 215 ms | 434 ms | 3.4 | 3.1 | pass |
| 140,000 | 35,900 | 576 ms | 1,278 ms | 3.85 | 3.4 | fail |
| 150,000 | 37,400 | 1,124 ms | 2,041 ms | 4.2 | 3.6 | fail |

At 140,000 users the failure is the five seconds of the window right where the ramp ends: p50 is 1.0-1.6 s, yet the
server is waiting, not working (1.9-3.0 threads busy, the read queue near empty, most read lanes idle), while the
load generator, on the same laptop, runs at 74-99% and its timers wake up to 0.7 s late. From then on the p99 of
single seconds is 80-250 ms, apart from one 0.5 s blocking gen2 collection as the heap settles. At 150,000 the same
stall lasts twice as long, and even after it the 8 read lanes are often all busy with thousands of requests queued.

**6 vCPUs** (3 Zen 5 cores x 2; load generator on the other 10 threads; commit 570771b):

| Users | requests/s | p95 | p99 | Postgres threads | app threads | |
|--:|--:|--:|--:|--:|--:|---|
| 100,000 | 26,000 | 94 ms | 157 ms | 2.45 | 2.4 | pass |
| 110,000 | 28,700 | 147 ms | 281 ms | 2.8 | 2.5 | pass |
| 115,000 | 29,700 | 199 ms | 352 ms | 3.0 | 2.7 | pass |
| 120,000 | 29,000 | 719 ms | 1,120 ms | 3.15 | 2.75 | fail: the 6 threads are full |

Before the read batcher stopped peeking at its queue (commits 3f7cc19 to d67ba2f), 100,000 users gave p95 186-197 ms
in 4 runs and 110,000 gave 291-449 ms in 3. A 5-minute hold at 105,000 users from then passed with p95 194 ms and
p99 283 ms over 8.16 M requests; the server's memory stayed at 2.5-2.9 GB, and the database grew by 36,000 articles
(7%), which raised the p95 of single seconds from ~80 ms to ~185 ms. These Zen 5 cores are faster than a typical
cloud core, so the benchmark box will hold fewer users per vCPU.

Three things in the method moved the numbers more than most code changes, and are worth knowing for any local
rig: without the warm-up, 100,000 users gave p95 361 ms instead of 196 (the JIT had not finished optimizing); a
database that had grown through earlier runs (850,000 articles instead of 500,000) made Postgres do ~60% more work
for the same load; and a 30 s ramp instead of the benchmark's 60 s left a seconds-long transient in the measured
window. Above ~113,000 users one load generator also needs more than 4 target addresses: each gives it only ~28,000
local ports. Comparisons elsewhere in this README are paired runs under the same conditions; their absolute numbers
come from different stages of the rig.

## Where the app's CPU goes: half of it was bcrypt

`perf` on the server process (before the lockstep bcrypt below; 60,000 users, ~15,600 requests/s, Release build, 20 s at 499 Hz, JIT frames named via
`DOTNET_PerfMapEnabled=1` and `DOTNET_EnableWriteXorExecute=0`):

| Where | Share of the app's ~2.8 cores |
|---|--:|
| `BCrypt.Net.BCrypt.Encipher` + `Key` (Blowfish) | **51%** (~1.4 cores) |
| kernel (sockets, epoll, conntrack, AppArmor) | 12% |
| the .NET runtime (GC, write barriers, stubs) | 8% |
| everything else (JSON, Kestrel, Npgsql, our F#) | the rest, no function above 0.8% |

That is half the CPU for **0.1% of the requests**: ~15 logins and sign-ups per second, against 15,600 requests per
second. A cost-10 bcrypt takes 51 ms on an idle core, but ~92 ms of CPU under load, on cores shared with Postgres and
with busy hyperthread siblings. The rules make every login pay it (cost 10, verified against the stored hash, no
cache), so the only lever is a faster bcrypt. The system's native one (libxcrypt `crypt_r`, the Openwall C code)
is only 22% faster than BCrypt.Net-Next.

**So bcrypt is our own, four hashes in lockstep** (`src/Engine/Bcrypt.fs`). One bcrypt is ~1 M Blowfish encryptions,
each feeding the next: a chain of dependent S-box lookups that leaves the CPU waiting on memory latency. Four
logins' hashes are independent, so their rounds are interleaved inside each encryption (`encipher4`). That is four
chains in flight at once, all in registers, which the CPU's out-of-order engine overlaps.

| bcrypt cost 10, one thread | ms per hash | vs BCrypt.Net-Next |
|---|--:|--:|
| BCrypt.Net-Next | 64-79 | 1x |
| ours, one at a time | ~58 | ~1.2x |
| ours, two in lockstep | ~33 | ~2.2x |
| ours, four in lockstep | **~19-20** | **~3.2-4x** |

(A batch of three runs as four, the copy's result dropped: one quad costs less than a pair plus a single.)

**Then the JIT's code got the same treatment as C's.** Against Openwall's crypt_blowfish in C with interleaved
lanes (the code `csharp-epoll-aot-gichamba` calls; `gcc -O2`), on one idle Zen 5 core, fully optimized JIT:

| bcrypt cost 10, one thread | ours before | ours now | C | C faster by |
|---|--:|--:|--:|--:|
| one at a time | 46.2 ms | 39.7 ms | 36.2 ms | 1.10x |
| two in lockstep | 23.8 ms | 20.2 ms | 18.9 ms | 1.07x |
| four in lockstep | 16.9 ms | **12.9 ms** | 11.1 ms | 1.16x |

The JIT's assembly showed two costs gcc does not have. Each S-box lookup added the S-box's offset to the byte index
as an `int`, which then needed a sign extension before the load; now each S-box is its own constant offset from the
lane's pointer, indexed by a `byte`, and the offset folds into the load (`[p + 4*idx + 1096]`). And with eight chain
words and four lane pointers live, the round counter spilled to the stack every round; the four-lane rounds are now
written out, so each P word is a constant offset and there is no counter. (Unrolling the one- and two-lane rounds
too changed nothing: they have registers to spare.) At 110,000 users on 6 threads bcrypt fell from 35% to 28% of the
app's samples, about 1.04 to 0.78 threads, for the same number of hashes.

At 85,000 users on the test box this cut the app's CPU from 3.81 to 3.00 cores, with more requests per second
(21,400 against 21,000) and p95 from 647 ms to 515 ms. Postgres took the freed cores (3.88 to 4.30) and is now the
larger consumer, and the lockstep batches averaged ~2.5 logins.

- **Bit for bit.** `Tests/BcryptTests.fs` is an FsCheck property: for random batches (1 to 6) of random passwords
  (ASCII and 2-, 3- and 4-byte UTF-8, up to the 72-byte limit) and random salts, every hash equals
  BCrypt.Net-Next's. Our hashes also verify in BCrypt.Net-Next, and its `$2a$` and `$2b$` hashes verify in ours.
- **Constants derived, not pasted.** Blowfish's 1,042 initial words are the hexadecimal digits of pi. `Bcrypt.fs`
  computes them with Machin's formula on big integers, and the tests check them against the published tables.
- Stored hashes we do not compute ourselves (another revision, a malformed string) go to BCrypt.Net-Next, and a
  malformed one verifies as false. Comparisons are constant-time.

Allocation is not where the time goes. Pooled response buffers, UTF-8 timestamps from a stack buffer and no boxed
struct comparisons halved the allocation rate (300 → 145 MB/s), and GC pauses stayed at 2-3% of wall time. The other
runtime setting that measurably helped is `DOTNET_ThreadPool_UnfairSemaphoreSpinLimit=0` (in `start.sh`): idle
thread-pool workers sleep at once instead of spinning on cores that Postgres needs. At 85,000 users it cut p99 from
1,155 ms to 823 ms.

### The profile now

`perf` on the server process at 110,000 users (commit 3f7cc19; fresh copy of the seed, the benchmark's warm-up,
server and Postgres on 3 cores with both hyperthreads, ~28,000 requests/s, p95 291 ms; 20 s at 499 Hz):

| Where | Share of the app's 2.86 threads | Threads |
|---|--:|--:|
| bcrypt (`Bcrypt.expand4`, the key schedule) | **36%** | **1.04** |
| kernel: TCP, epoll, AppArmor, scheduling | 15% | 0.43 |
| Kestrel, pipelines, sockets | 10% | 0.29 |
| the .NET runtime (GC, write barriers, stubs) | 8% | 0.24 |
| JSON and text encoding | 7% | 0.19 |
| libc, vdso, loader | 4% | 0.13 |
| Npgsql | 3% | 0.07 |
| date and number formatting | 2% | 0.06 |
| our read engine (without bcrypt) | 2% | 0.05 |
| kernel conntrack | 1% | 0.04 |
| HMAC for the JWTs | 1% | 0.03 |
| our web layer, Giraffe included | 1% | 0.03 |
| everything else (CoreLib, async machinery, unresolved) | 6% | 0.16 |

bcrypt is still a third of the app's CPU for 0.1% of the requests: ~37 ms of CPU per hash, twice an idle core's
quad, because its threads share cores with Postgres and the app. Below it the profile is flat; Giraffe costs
under 1%.

## Built on others' ideas

Ideas taken from other entries; the code here is our own.

- `csharp-epoll-aot-gichamba` / `csharp-epoll-jit-gichamba` (PR #103 / #104), compared line by line:
  - the feed count's shortcut: a viewer who follows an author with 1,000+ articles counts 1,000, proved once per
    batch for the followees the batch's viewers share most (they credit `go-epoll-MegaPanchamZ` and
    `zig-iouring-harshitkhandelwal208`);
  - comment threads in the first round trip, so the second one knows the comment authors, and the favorited and
    following flags as one statement with one `= ANY` range scan per viewer (their two-phase planner, which they
    credit to `rust-epoll-WorriedArrow`);
  - tag names by a primary-key probe per tag instead of a join;
  - letting a login wait 150 ms for bcrypt batch-mates;
  - their Openwall crypt_blowfish with interleaved lanes, as the yardstick our F# bcrypt was tuned against.

Read batching and group commit themselves come from an earlier presentation (rule 6 allows several requests'
writes in one transaction).

## Build, run, check

```bash
sudo bash install.sh            # once: .NET SDK 10.0.402 -> /usr/local/dotnet
bash build.sh                   # -> out/Web.dll
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=multicore-server-challenge \
  HOST=0.0.0.0 PORT=80 bash start.sh
bash check.sh                   # build + facts + conformance + batch property (needs the dev seed, Go, psql, curl)
SKIP_CONFORMANCE=1 bash check.sh  # the quick gate, no database
```

Environment: `DATABASE_URL`, `JWT_SECRET` (required); `HOST` (127.0.0.1), `PORT` (3000); `READ_LANES` (cores);
`READ_BATCH` (512); `READ_GATHER_MS` (25); `WRITE_LANES` (2); `WRITE_GROUP` (128); `DB_POOL_SIZE` (cores / 2, capped so the total stays
at most 95); `BCRYPT_THREADS` (2); `BCRYPT_WIDTH` (4); `BCRYPT_GATHER_MS` (150); `STATS_SECONDS` (0, off).

`STATS_SECONDS=1` prints one diagnostic line a second on stderr (`src/Web/Stats.fs`), to line up against the load
generator's seconds (`t=` is unix seconds):

| Field | Meaning |
|---|---|
| `dt` | the interval as measured; above `STATS_SECONDS`, the process (or this thread) was stalled |
| `conn`, `new` | Kestrel connections open, and opened in the interval |
| `gc0`, `gc1`, `gc2`, `pause` | collections of exactly that generation, and the total GC pause in the interval |
| `alloc` | MB allocated in the interval |
| `eph`, `full`, `bg` | the latest ephemeral, full blocking and background GC, if one ran in the interval: generation, MB promoted, pause |
| `heap`, `gen2`, `loh`, `poh` | sizes after the latest GC (0 before the first) |
| `cpu`, `pool`, `pending` | the process's cores busy, thread-pool threads, queued work items |
| `reads q`, `busy`, `batches`, `per`, `worst` | read requests queued, lanes running a batch, batches finished, requests per batch, the longest arrival-to-answer |
| `writes q` | writes queued for group commit |

A seconds-long stall that shows up in `pause` (and `dt`) is GC. If `pause` stays small while `reads q` and `worst`
grow, requests are queueing for the database.

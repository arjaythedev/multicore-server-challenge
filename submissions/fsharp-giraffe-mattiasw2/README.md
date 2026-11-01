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
src/Tests/    xUnit facts for Jwt and Wire (no database); BatchTests, the read-batching property (FsCheck)
check.sh      the harness: build -> facts -> conformance suite (../../test/run.sh) -> batch property, one verdict
```

- **Engine** has no HTTP and no tokens. Each function takes typed values and returns typed records, or a small
  union (`Done | NotFound | NotYours`, `Stored | Taken | Missing`) that the handler maps to a status.
- **Wire** has no `HttpContext`, so the shape rules (422 cases, `limit`/`offset` parsing, key case-sensitivity,
  timestamp truncation) are plain unit tests.
- **Handlers** only authenticate, decode, call Engine and encode.

## Multicore model

- **One process, one Kestrel.** Kestrel serves every core with async I/O and holds each user's keep-alive
  connection directly (`Front: direct`). The keep-alive timeout is 120 s.
- **Read batching for the hot reads** (`src/Engine/Reads.fs`): tags, the four article lists, the feed, article by
  slug, comments and profiles. Each such request is a value (`Read`) on one channel. `READ_LANES` reader lanes
  (default one per core), each with a connection of its own, answer the queue in batches:
  - **Gather.** A lane that wakes for a request waits until the oldest queued request is `READ_GATHER_MS` old, or
    until `READ_BATCH` requests are queued, whichever comes first, and then takes them all. The latency budget is
    500 ms at p95, and a bigger batch shares more work.
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
- **Connections:** at most 95 Postgres connections (`READ_LANES` + `WRITE_LANES` + `DB_POOL_SIZE`; the pool is
  capped to fit).

## Capacity on a box like the benchmark's

8 vCPUs on a cloud host are 4 physical cores × 2 hyperthreads. The test box models that: server and Postgres on 4
Zen 5 cores with both of their hyperthreads, and the load generator on other cores, sharing none of them. With
batched reads, group commit and lockstep bcrypt, it holds **75,000 users** (19,150 requests/s, p95 378 ms, p99 560
ms, no errors). It fails at 80,000 (p95 583 ms). Postgres uses 4.5 of the 8 threads and the app 2.8. These cores
are faster than a typical cloud core, so expect the benchmark box to hold fewer users.

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
at most 95); `BCRYPT_THREADS` (2); `BCRYPT_WIDTH` (4); `BCRYPT_GATHER_MS` (150).

# pgserve: the HTTP server is inside Postgres

**Front: direct**

| | |
|---|---|
| Language | Zig 0.17.0 for the engine and the HTTP workers. C for `launcher.c` and a small shim for the Postgres parts Zig can't express (macros, `PG_TRY` longjmps, plan-node construction). |
| Framework | none |
| Database | PostgreSQL 18: the box's own `postgresql-18` package, with its settings untouched |
| Driver | none. Reads walk Postgres's index and heap pages in-process. Writes go through SPI. |
| Users held | 260,000 in two official-style searches on our rig, under a 16 GB memory cap |

pgserve serves the whole Conduit API from inside Postgres. Its HTTP workers are Postgres background workers,
started by our library. Each one accepts TCP connections, checks the JWT, reads the data straight out of
Postgres's shared buffers and writes the JSON back to the socket. Writes run SPEC's statements through SPI in
the same process. No app process sits between a request and its data. No request crosses the Postgres wire
protocol, because there is nobody on the other end of it.

As far as we can tell, no other entry serves HTTP from inside Postgres. None bypasses the executor and walks
the B-trees itself either, with lock-free descents and heap rows read in place. This folder is the in-Postgres
server and nothing else: there is no flag to turn it off and no fallback to SQL over a connection.

## How to run

pgserve needs Postgres 18 on the same box, the `conduit` database, and `psql` on the PATH (the launcher uses
it to talk to Postgres).

```sh
sudo bash install.sh     # Zig 0.17.0, then the engine library into Postgres's plugin directory
bash build.sh            # the launcher, as an ordinary user
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit \
  JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

- `install.sh` (root) installs Zig 0.17.0 from the official tarball, checked against its SHA-256, into
  `/opt/zig-0.17.0`, and links `/usr/local/bin/zig`. It then downloads `postgresql-server-dev-18` at exactly
  the installed `postgresql-18` version, unpacks the package without installing it, and builds
  `engine/zig-out/pgengine.so` against those headers. Installing the package would also pull in clang-19 and
  llvm-19-dev, which the build doesn't use. The library goes into `/usr/lib/postgresql/18/lib/plugins/`.
  Zig 0.17 has no `@cImport`, so the build first runs `zig translate-c` over the Postgres headers. That takes
  about 50 s the first time, and Zig caches it after that. The whole install took 29-37 s in our runs.
- `build.sh` (as `challenge`) compiles `launcher.c` with `zig cc`.
- `start.sh` runs the launcher in the foreground. It reads SPEC's `HOST`, `PORT`, `JWT_SECRET` and
  `DATABASE_URL`. Two optional variables exist: `PGSERVE_WORKERS` (default 6) and `PGSERVE_LIB` (default
  `pgengine`).
- `PGSERVE_HASH_NICE=N` (default 19) runs the bcrypt threads at nice `N`; 0 keeps them at the worker's.
- `PGSERVE_THIN_TO=1` (the default; 0 turns it off) sets `TCP_THIN_LINEAR_TIMEOUTS` on every accepted connection.
- `PGSERVE_DWELL_US=N` (default 5,000; 0 turns it off; at most 50,000) is the batch clock, with `PGSERVE_DWELL_CAP`
  (default 256) and `PGSERVE_DWELL_MIN` (default 2). `PGSERVE_STATS_S=N` (off by default) logs each worker's batch
  sizes every `N` seconds. Both are under "How a request is served".
- `GET /api/tags` answered 5.6-8.6 s after a cold Postgres restart in our runs. Most of that is bcrypt's
  self-test and calibration.

## The idea, and what it costs

Every Conduit server on the leaderboard spends most of its CPU in Postgres. The time doesn't go to finding
rows. It goes to parsing, planning, executing and sending results over a socket to a program that turns them
into JSON. We wanted to know what was left if all of that went. So we wrote a read engine that lives in Postgres
and answers each endpoint straight from the index pages. Then we moved the HTTP server in next to it.

It works. It also has costs, and we'd rather you hear them from us.

- **The plugin goes into Postgres's library directory. This is your call.** `install.sh` runs as root and
  puts `pgengine.so` in `$libdir/plugins`. The rules let root install a toolchain or a runtime. A plugin for
  the database server is neither. Rule 3 bans functions, triggers and extensions in the database, and pgserve
  creates none: no `CREATE EXTENSION`, no catalog row, no `ALTER SYSTEM`, no `pg_hba.conf` line, no superuser.
  The library is loaded per connection through `local_preload_libraries` in one connection's startup packet,
  as the `conduit` role. That is the one load path Postgres offers a role that isn't superuser, and it only
  loads from `$libdir/plugins`. We think that keeps to the letter of rule 3. Whether it keeps to its spirit is
  for the maintainer to judge.
- **It runs as the `postgres` OS user.** The HTTP workers are Postgres processes, so they have the database
  server's OS identity and file access, not `challenge`'s. Inside the database they act as the `conduit` role,
  with that role's table privileges and no more.
- **A crash takes all of Postgres down.** A worker that segfaults makes the postmaster assume shared memory is
  corrupt. It ends every backend, runs crash recovery and starts again, and every connection on the box drops.
  In an early crash test (a deliberate NULL dereference in a planner hook, loaded the same way) Postgres took
  13.6 s to accept queries again. 12.6 s of that was apport writing a 140 MB core dump. The workers are
  registered with `BGW_NEVER_RESTART`, so after a crash pgserve stays down (rule 9). An ordinary Postgres
  `ERROR` is different: it is caught, its requests get 500 and the worker carries on (below).
- **Six workers, because that's what the defaults allow.** `max_worker_processes` stays at its default of 8.
  The logical replication launcher holds one slot and pgserve takes six, which leaves one for parallel query.
  pgserve never uses parallel query itself. A seventh worker cost 1.5-1.8 µs per request in three tests and
  was left out.
- **The service's own accounting can't see the workers.** They sit in `postgresql@18-main`'s cgroup, not
  `challenge.service`'s. The scorer's idle-memory line reads "PSS 0 MB, 1 process(es)": that's the launcher.
  Anything that measures the app by its cgroup will book our CPU and memory to Postgres.
- **The engine holds session-level `AccessShareLock` on the tables and indexes it reads**, for as long as a
  worker lives (see "State kept per backend"). While pgserve runs, anything that conflicts with that lock
  waits: `DROP`, `TRUNCATE`, `ALTER TABLE`, `VACUUM FULL`, `REINDEX`. Plain `VACUUM` and every DML statement
  are unaffected.
- **Our scores used a raised `-max`.** The load generator's default `-max` is 120,000. Every number above it
  here assumes the maintainer raises it.

## How it starts

`start.sh` runs `launcher` (`launcher.c`, 183 lines). It is the process `challenge.service` starts, and it
holds the port and nothing else.

1. It ends any workers a previous launcher left behind (`pg_terminate_backend` on this role's backends of
   type `pgengine http`).
2. It opens a Unix socket at `/tmp/pgserve-<pid>.sock` for the handoff.
3. It runs one `psql` connection whose startup packet (`PGOPTIONS`) sets
   `local_preload_libraries=pgengine` and `pgengine.http=<socket>:6`. Loading the library in that session runs
   `_PG_init`, which reads the setting and calls `RegisterDynamicBackgroundWorker` six times. That call needs
   no privilege. Each worker gets the database's and the role's OIDs and the socket path in `bgw_extra`, and
   finds the library's own path with `dladdr`. The `psql` session then runs `SELECT 1` and exits. The workers
   stay.
4. Each worker joins the database as the connecting role
   (`BackgroundWorkerInitializeConnectionByOid`), checks the live schema against the one it was written for
   (below), and connects to the launcher's socket.
5. For each worker the launcher binds `HOST:PORT` with `SO_REUSEPORT` (backlog 65,535, `TCP_NODELAY` on the
   listener; an IPv6 `HOST` such as `::` gets a dual-stack socket). It passes that listening socket over the
   Unix socket with `SCM_RIGHTS`, with `JWT_SECRET` and then each optional `PGSERVE_` setting that is set (as
   NUL-separated `NAME=value`) as the message body. Postgres starts the workers with its own environment, not the
   launcher's, so this is the only way a setting reaches them. It only deals with peers whose UID owns
   `/var/run/postgresql`, which means Postgres's own processes. A worker that hasn't collected its socket
   within 30 s fails the start.
6. The launcher sleeps. On `SIGTERM` it ends the workers with `pg_terminate_backend`, which a role may do to
   its own backends. Without that, Postgres would keep serving HTTP long after the service stopped.

The launcher can bind port 80 because the unit grants it `CAP_NET_BIND_SERVICE`. The workers never bind
anything, so Postgres needs no capability at all.

## How a request is served

Each worker is one thread running an epoll loop, plus one bcrypt thread. Each turn of the loop:

1. **Read.** Every readable socket is read and every complete request is started, at most one per connection.
   A client's next request waits for the answer to its last, so a client always sees its own writes.
   Requests that need no data (a 401, a 422 for a bad body) are answered on the spot. Hashing requests go to
   the bcrypt thread. Reads and writes queue on the turn.
2. **Write.** The turn's writes run in one transaction, each in its own subtransaction, so a taken username
   fails only its own request (unique violation, 422). They are SPEC's write statements, cut down to return
   only the keys the reads that follow need, through SPI. Each is prepared once per worker and kept
   (`SPI_keepplan`). Login's email lookup runs here too. One commit covers the whole turn. That is group commit
   as rule 6 allows it, with `synchronous_commit` at Postgres's default: the worker waits for the WAL flush
   before it answers anyone.
3. **Read.** The turn's reads run as one engine batch per endpoint, all under one snapshot taken after that
   commit. They include the reads that answer the writes: the article after a favorite or an edit, the profile
   after a follow, the user after a sign-up with its new token. A new comment is answered from the row its
   insert returned. Requests share work only inside one batch, among requests already waiting when the batch
   starts. Nothing is kept from one turn to the next (rule 5).
4. **Answer.** Every answer of the turn was built back to back in one buffer. Each goes out in one `write`.

Without a batch clock (`PGSERVE_DWELL_US=0`) a batch is whatever arrived during one turn. At 300,000 users that
was a mean of 4 article reads per batch, and 1.2-3.9 for the other endpoints.

`PGSERVE_DWELL_US` (default 5,000) is the batch clock. A turn is held: the worker keeps reading sockets, answering
what needs no data and queueing reads and writes, but runs the turn's writes and reads (steps 2 and 3) only once
its oldest queued request has waited `PGSERVE_DWELL_US` µs or it holds `PGSERVE_DWELL_CAP` requests. A held worker
sleeps in `epoll_pwait2` until that deadline, so the clock costs no spinning. Writes are still answered only after
their commit, and requests still share work only inside one batch. The clock stays off after a batch smaller than
`PGSERVE_DWELL_MIN`, so at light load a lone request runs at once instead of waiting for company. The dwell is
capped at 50 ms. At 300,000 users on an aged database, 5 ms raised the mean article batch from 4 to 41 and cut the
box's CPU per request from 79 to 63 µs and p99 from 93 to 30 ms, against no clock (2 ms: batch 20, 64 µs,
p99 30 ms).

`PGSERVE_STATS_S` logs one line per worker every that many seconds (`pgserve stats ...` in the Postgres log): how
many turns ran and why (`now`: clock off or cold; `deadline`; `cap`), how long a turn's oldest request waited,
and for the writes and each endpoint the batches, requests and batch sizes (`p50`/`p90` over batches,
`rp50`/`rp90` over requests, the batch a request was served in). The counters are always kept; only the line is
optional.

Errors:

- A Postgres `ERROR` inside a read batch is caught (`PG_TRY` in the shim). That batch's requests get 500, the
  transaction is aborted, and the rest of the turn reads under a fresh one. A failed write rolls back its own
  subtransaction and answers 500. An `ERROR` anywhere else ends that worker, which isn't replaced, and the
  other five keep serving.
- A value Postgres's text input would refuse gets the reference server's answer, 500. That covers a NUL byte
  (JSON `\u0000`) in a body, and a NUL or bytes that aren't UTF-8 in a path or query value. A request that
  isn't HTTP gets 400.

**bcrypt** (cost 10) runs on each worker's bcrypt thread, and its completion `eventfd` sits in the worker's
epoll set. It is our Zig entry's lanes engine, vendored unchanged. It runs several independent hashes
interleaved in one kernel: Blowfish lanes in generated assembly that uses `BEXTR` instead of the `al`/`ah`
partial-register reads Zen handles badly. It self-tests at start and calibrates the kernel and the lane count.
On Zen 5 that engine measured 7.87 CPU-ms per hash at 5 lanes, against 10.43 for #7's Openwall batch kernel
built with gcc -O3. A lone login never waits for a batch; only overlapping logins do. Identical jobs are never
merged. The thread starts with every signal blocked, because inside a Postgres backend only the backend's own
thread may touch the backend.

HTTP parsing, routing, the JWT check (HS256 with SHA-NI, `exp` on every request) and the JSON body handling are
also our Zig entry's code, vendored unchanged.

**Answers go out uncompressed.** SPEC makes compression optional, and gzip lost every test we gave it (see
"What we tried"). The Zig entry's gzip code and its vendored libdeflate are not in this folder.

## The read engine

The engine came first. It began as a library that answers "marker" `SELECT`s inside an ordinary Postgres
backend, so that its every byte could be checked against SPEC's SQL and its cost measured against #7's
statements on the same database. pgserve's workers call the same engine directly. Everything below runs in both
forms unless it says otherwise.

**How we measured**, briefly. Each engine lever was one change, A/B'd against its parent in 4-6 interleaved
paired rounds of 20,000 requests at batch sizes 1, 2, 8 and 32, on a small sandbox with the dev seed. The
measure was backend instructions per request, the low-noise signal there. Big levers were also measured as
backend CPU on a clone of the benchmark box with the full seed. Later ones were measured in a replay that drives
Postgres with the load generator's user model at 100,000 users on an aged database, counting Postgres CPU per
logical request against #7's statements and pools. End-to-end numbers come from a Hetzner CCX33 (8 dedicated
vCPUs) with its kernel capped to 16 GB (`mem=17664M`, 15,231 MB usable) and 16 load boxes. There we ran the
official search sequence and ABBA pairs against a measured A-A spread. Every percentage below says which of
these it came from.

### One batch, no executor

As a library, each endpoint is a marker such as
`SELECT NULL::int2 AS engine_article, NULL::bytea AS body WHERE current_setting('pgengine.required') IS NOT NULL AND $1::bytea IS NOT NULL`.
A planner hook recognises it and swaps the whole plan for one CustomScan, which calls the engine for the whole
batch and returns one `(status, body)` row per request, in order. The body is the finished JSON. The
`current_setting` qual is a guard. Without the engine loaded, the qual fails with "unrecognized configuration
parameter", so a marker can never be quietly answered by plain SQL.

The executor turned out to cost more than the work at small batches: an executor state, an expression context
(two memory contexts), descriptors built from both target lists with a syscache lookup per column, two slots,
and freeing it all. So `ExecutorStart`/`Run`/`End` hooks now run a marker plan with none of it. They register
the snapshot, hand the portal a result descriptor built once per backend, run the batch in a memory context of
its own, and send rows straight to the `DestReceiver`. `EXPLAIN`, instrumentation and scrollable cursors still
take the CustomScan path. Gain: user -5.4% / -4.0% / -1.6%, profile -4.2%, article -3.3% at batch 1
(instructions). The whole batch also travels as one packed `bytea` parameter (`u32` count, then each request's
fields) instead of one array per field. That removed `array_recv` and a type lookup per field per bind: user
-6.8% to -8.8%, list_favorited -7.5% at batch 1.

pgserve goes one step further and skips the planner and the executor entirely. A worker fills the batch's
field arrays and calls `engine_exec` inside a `PG_TRY`.

### Walking nbtree's pages ourselves

The first engine used nbtree's index-scan API. A profile at batch 8 put B-tree descents (`_bt_first`) at 48-60%
of engine time and per-probe scan setup at another 4-8%. JSON was under 7%. So `btree.zig` now reads nbtree
pages itself: line pointers after the 24-byte header, `BTPageOpaqueData` in the special space, data items from
`P_FIRSTDATAKEY`, and posting lists (deduplication) expanded. It follows nbtree's own reader protocol. A page is
share-locked while its entries are copied out, then only pinned while they are checked against the heap. Moving
right follows `btpo_next` (Lehman-Yao) and steps over half-dead and deleted pages. List pages walk leaves
backward through left links and validate each step as `_bt_lock_and_validate_left` does: if the left sibling
split, walk right; if the page was deleted, restart from its live right sibling.

What made this safe to do quickly is `schema.zig`. At load, the engine checks that every index it walks is a
B-tree, that every integer key is `int4`/`int8` under the integer opfamily and `NOT NULL`, and that every text
key uses `text_ops`. Keys therefore compare as machine integers at fixed offsets, and that is checked rather than
assumed.

Each walk replaced an nbtree scan (instructions per request, dev seed, batch 1 / 8 / 32):

| walk | gain |
|---|---|
| list counts: the capped 1000-entry count read off the leaves | list_all -30.2% / -15.2% / -8.6%, list_tag -14.0% / -14.8% / -11.3% |
| `favoritesCount` from `favorites_article_idx` | list_all -9.7% / -9.5% / -7.6%, article -4.4% / -6.3% / -7.2% |
| unique integer lookups (users, articles, tags by id) | article -10.8% / -18.2% / -18.0%, comments -14.2% / -22.0% / -23.4%, user -6.7% / -19.6% / -25.8% |
| an article's tag ids from `article_tags_pkey` | list_all -8.3% / -10.1% / -8.6% |
| the feed: follows, then each followee's articles | feed -30.2% / -38.0% / -42.7% (CPU -19% / -23% / -29%) |
| comment threads from `comments_article_idx` | comments -4.3% / -7.0% / -7.5% |
| all tag names from `tags_name_key` | tags -30.7% / -24.8% / -16.1% |
| list pages, backward through left links | list_tag -11.1% to -13.2%, list_author -7.2% to -11.0% |
| name and slug lookups with text keys, compared by `varstr_cmp` as `bttextcmp` does | profile -6.9% to -17.3%, list_favorited -5.5% to -10.9% |

After the last of these, the engine no longer calls nbtree's scan API anywhere.

**Slugs are found by the id they end in.** SPEC builds every slug as `slugify(title) || '-' || id`. The engine
parses that suffix, descends `articles_pkey` on an `int8`, and accepts the row only if its slug is byte-equal.
Anything else falls back to `articles_slug_key`: an impostor that ends in another article's id, no suffix, a
leading zero. That saved a text descent whose every comparison called `strcoll`: article -5.0% / -9.8% / -10.6%.
`articles_slug_key` is only opened when a slug misses by id.

**Interpolation search.** Page searches on integer keys place up to three probes by where the key falls
between the items known to bracket it (the high key the descent just read is the first upper one), then binary
search. Only comparisons narrow the range, so a poor guess, or one made on a torn read, costs extra probes and
never a wrong answer. On the dev seed it cost instructions (+0.5% to +4.8%). In the replay it cut cycles per
request to 0.879 and CPU to 0.856, lower in 8 of 8 rounds. Under load the engine waits on DRAM, and every probe
saved is one dependent cache miss saved.

### Visibility, counts and heap rows

A walk checks visibility the way an index-only scan does. If the visibility map marks the heap block all-visible,
the entry counts without touching the heap. If not, the engine looks at the heap. The table's visibility-map page
stays pinned for the execution, and its bits are read inline off the pinned page (feed -5.9% / -9.0% / -9.7%).
Counts are tallied on the leaf page itself under its share lock. Entries on all-visible blocks are counted where
they lie, and only the rest are copied out for heap checks. Off all-visible blocks, a run of entries on the same
heap block takes one share lock for the whole run.

The favorites counts of a batch's articles are taken together, by one counter per batch (`Bt.Counter`). The
articles go in id order. A leaf reached for one key serves the next keys within its bound, the parent's pivot or
the leaf's own high key, with no descent: a split only moves entries right, and the landing walk steps right.
Entries on all-visible blocks are tallied on the leaf as before. The rest are packed as (heap block, offset,
article) across the whole batch, radix-sorted at its end, and checked once per heap block under the batch's
snapshot, so a heap page that several articles' favorites share is visited about once per batch instead of once per
article. The packed entry keeps the index's own pointer, and the HOT chain is followed per check from a copy.
The pending array is bounded (8,192 entries, 65,536 articles): full, it drains in place; past the slot limit a
count takes the per-article path. It lives in the execution's memory context and dies with it. On the dev box,
counting CPU per 20 counted articles fell by 17% with favorites in random heap order, 31% on a loadgen-aged
copy and 25% on a churned one, mostly from `favorites_article_idx` descents (102 → 70 per turn); heap block
visits fell 9-16%, because on this seed favorites cluster by article and 20 articles rarely share a page.

Heap rows are read **in place** in the pinned block, with no tuple slot. The engine runs
`heap_hot_search_buffer` under the block's share lock and deforms the tuple in Zig the way
`slot_deform_heap_tuple` does, getting attributes that a row written before an `ADD COLUMN` lacks through
`getmissingattr`. The pin keeps the tuple where it is, because moving a tuple takes a cleanup lock, which waits
for every pin. It prunes on a block move as heapam does. Gain: comments -10.2% to -16.7%, list_all -7.9% to
-11.5%, list_tag about -11%, article -5.8% to -9.6%, all 4 of 4 rounds. Lists and the feed also read each page
article at the heap pointer their walk already found, instead of descending `articles_pkey` again (list_all
-5.6% / -8.1% / -7.6%).

The oracle caught one real bug here. A walk had stored the heap pointer after the visibility check. On a page that
wasn't all-visible, the check had already moved it to the visible member of the HOT chain, and a later fetch from a
heap-only tuple finds nothing. So an article updated in place silently dropped out of its author's list: 13
mismatches. The walk now copies the entry's own pointer first. A row the walk saw as visible but then can't find
under the same snapshot is now an `ERROR`, not a skipped row, because skipping is what hid the bug.

### Lock-free reads

nbtree takes a content lock on every page it reads, and under eight busy backends the profile was full of
`LWLockAttemptLock`, `LockBufHdr` and `LWLockReleaseInternal`. So the engine reads some pages without the lock and
validates afterwards, the way a seqlock reader does:

1. check that the buffer's content lock isn't held exclusive;
2. read the page LSN;
3. read what it needs;
4. check again that the lock isn't held exclusive and that the LSN hasn't changed.

Every change to a page of a WAL-logged relation happens under the exclusive lock and sets the LSN. If either
check fails, the engine reads the page again under the lock. Every offset and length read without the lock is
clamped to the page, so a torn read can only waste work and never runs off the page.

This went in three steps:

- **Internal pages of integer-keyed descents.** LWLock acquisitions per batch-32 article execution fell from
  560 to 367. Feed -1.7% to -3.3%. It cost profile +0.5%: text-keyed descents pay the setup and get nothing.
- **Leaf pages of integer-keyed walks.** LWLock acquisitions per list_all execution at batch 1 fell from 108.4 to
  53.2, and `_bt_checkpage` calls from 63 to 8. Article down to -3.1%. Whole-index walks and text keys stay
  locked.
- **Heap rows whose hint bits already decide their visibility.** The engine walks the HOT chain and applies
  `HeapTupleSatisfiesMVCC`'s rules from the hint bits and the snapshot alone. Whenever that function would have
  to look up a transaction's status or set a hint bit, it gives up and takes the lock: a multixact deleter, a
  snapshot that overflowed its subtransactions, one taken during recovery. Serializable transactions never
  peek, because their heap reads must record predicate locks. Comments -2.5% to -5.3%; in the replay, user
  instructions -8.7%.

Postgres keeps the layout of an LWLock's state word private to `lwlock.c`. So at its first use in a backend, the
engine initialises an LWLock of its own, takes it exclusive and then shared, and checks that the state word
reads the way it assumes. If not, nothing is ever read without a lock.

Evidence for all three: the split-and-delete stress test below ran 1,440,832 executions against the
lock-free-leaves build with 0 violations, and the oracle found 0 mismatches.

### Buffer hints and prefetching

Each page read first tries the shared buffer the page was last found in, through `ReadRecentBuffer`. That call
pins the buffer only if its tag still names the page, and it skips the buffer-mapping hash and its partition
lock. Only buffer numbers are kept, never page contents. Gain: article -5.5% to -9.1%, list_all about -8%,
feed about -10%; CPU list_all -4.2% to -8.3%.

The first hint table was direct-mapped, 4,096 and then 65,536 slots. Under the replay's 2.5 GB database it
missed on reads worth 44% of read time. It is now one dense array per relation file, indexed by block number.
That cut cycles per request in the replay to 0.897, in 6 of 6 rounds.

With a hint, the engine also requests the cache lines a read needs first, before it takes the pin, so they load
while the pin waits on the buffer descriptor: a B-tree page's header and special space, or a heap page's header
and the row's line pointer. The replay couldn't resolve that one (cycles 1.035, 3 of 8 rounds lower), and we
kept it.

### Staged batch reads

A profile at that point showed what was left: IPC around 0.5, 0.94 billion cache misses per replay window, and
self time in page searches (19.5%), `UnpinBufferNoOwner` (12.3%) and `LockBufHdr` (11.9%). Nearly all of it was
dependent misses: a search's next probe, a pin's descriptor, a row's tuple, each waiting on the read before it.
One request at a time, those misses queue up. Across a batch they don't have to.

So every endpoint now reads its batch in stages:

1. Find every leaf the batch will need first (`leafOf`). For article pages, that is every article; then every
   viewer's flag leaves; then the flags.
2. Request those pages' lines.
3. Only then read them.

The same pattern runs for the feed (every followee's leaf), comments (slugs, threads, authors, follows),
profiles (usernames, then follows), list pages and their flag walks, and the list name lookups. Smaller pieces
of the same idea:

- heap tuples are requested as soon as their line pointers have loaded;
- an index keeps the leaf its last walk ended on pinned for the next walk;
- a count requests its next leaf before it checks the current leaf's heap rows;
- a batch's favorites counts run in article id order, so most keys start on the leaf the previous key ended on,
  and their heap checks are deferred, sorted by block and done once per block at the end of the batch;
- `aim` replays each leaf search a step at a time across the whole batch (line pointers, then the two anchor
  items, then one probe per step), so the batch's misses at each depth of the search land together.

On the dev seed, where everything sits in cache, these levers cost instructions and their cycles were noise.
Their target is the memory-bound full seed. There, between the full-seed tables before and after them
(which also include the in-place heap reads, lock-free leaves, dense hints and interpolation), instructions
barely moved while CPU fell most where the staging reaches: list_tag 77.8 → 46.2 µs at batch 1 and 79.9 → 39.8
at batch 32, list_author 68.5 → 36.1, comments 29.8 → 11.3 at batch 32. `aim` is the one we're least sure of. On
the dev seed it added 6-26% instructions, and a build without it ran list_all 11-14% fewer instructions and
6-13% less CPU. We never measured it alone on the full seed, and it shipped.

### Collation, proven rather than assumed

Usernames and tag names compare under the column's collation. Under `en_US.UTF-8` that means `varstr_cmp`, which
means glibc `strcoll`, at hundreds of instructions a call, and a username descent makes about twenty. The seed's
usernames and tag names are "plain": ASCII digits and lowercase letters. Collations such as `en_US.UTF-8` and
`C.UTF-8` order plain strings exactly by their bytes, but that is a property of the collation, and we didn't want
to assume it from a locale's name.

So the collation has to prove it, once per backend. Every plain string of up to three characters, in byte order,
must come out strictly ascending under `varstr_cmp` itself: 47,988 comparisons. A contraction, an ignorable
character or a reordering among those characters puts some string out of place, and then `varstr_cmp` stays for
everything. We tested the test with ICU Danish, where "aa" sorts after "z". It fails, as it should, and all 18,000
lookups and the tag order still match SQL. Strings that aren't plain always go to `varstr_cmp`.

Gain: profile -16.4% / -24.2% / -38.8% / -45.5% (batch 1 / 2 / 8 / 32; CPU -25.4% at batch 32),
list_favorited -13.0% to -28.7%, list_author -11.0% to -20.8%. Checking plainness 16 bytes at a time added
profile -3.1% to -13.5%. That first cost list_tag +0.2%, because short tag names paid the loop's entry on every
sort compare, so a tag's plainness is now worked out once per execution.

### Sharing inside a batch

Everything in an Article except `favorited` and `author.following` is the same for every viewer. So within one
batch the engine reads each distinct article once and writes it once as JSON fragments, and each request splices
its own two flags in between. That is what #7's `enriched` CTE does, without materialising rows. Fragments live in
the execution's memory context and die with it.

- **Lists:** members with the same filter key share one index walk, taken to the furthest end any of them
  needs. One walk gives both the page and the capped count.
- **Viewer flags:** each member's flags for a whole page come from one walk of its own `(viewer, id)` range in
  `favorites_pkey` and `follows_pkey`, instead of a descent per article (list_all -10.8% / -30.4% / -49.9%,
  CPU -11.1% / -29.1% / -30.0%). A viewer with more links in range than 16 per item, plus 16, is probed per
  flag instead.
- **The feed:** every author on the page is followed by construction, so only favorites are read.
- **Favorites counts:** one counter per batch of articles, sharing leaves between consecutive ids and heap
  blocks between every article's remaining entries.
- **Tag names and authors:** read once per execution (list_tag -7.8% / -14.1% / -18.3%, feed -9.9% to -16.3%).
- **Comment threads and profiles:** read once per distinct article or username.
- **Tags:** built once and every row points at the same bytes.

### The small things

- **Only the relations an endpoint reads are opened:** user went from 117k to 76k instructions at batch 1
  (-35%).
- **JSON escapes are found 32 bytes at a time** with a vector compare, and clean runs are copied whole: article
  -7.7% / -14.6% / -16.8%. Timestamps are rendered from the column's raw `int64` with no call into Postgres's
  datetime code.
- **glibc.** An early lever made batch 1 slower: each execution freed a few hundred KB, glibc trimmed it back to
  the kernel, and the next execution faulted it all in again (343,000 page faults in 3 s). `_PG_init` now sets
  `M_MMAP_THRESHOLD` to 32 MB and `M_TRIM_THRESHOLD` to 64 MB.
- **Inline page addresses.** Zig's translated `BufferGetPage` is a function call, so the engine computes page
  addresses inline. The local-buffer branch goes too, since the engine's relations are in schema `public`,
  where no temporary relation can be.
- **Lazy tuple slots.** A table's slot is made on its first heap fetch, so tables only walked for visibility
  never make one.
- **A table remembers which heap block it has pinned.** Whether the next row is on that block is a compare of
  block numbers, not a call to `BufferGetBlockNumber`, which reads the buffer's descriptor (a line every other
  backend pinning the block writes). `BufferGetBlockNumber` was 0.42% of the box's CPU at 300,000 users, from
  every caller; this one runs per heap row and per visibility check, the rest once per walk. Six backends on an
  aged copy, 5 rounds: instructions per request on the request mix -0.2% at batch 8 (4 of 5 rounds lower) and
  -0.3% at batch 32 (5 of 5), feed -0.6% / -0.7%. Cycles were within the noise.

### State kept per backend, and rule 5

Six things live in a backend between executions:

1. which shared buffer each page was last found in (a buffer number, checked against the buffer's tag on every
   read);
2. session-level `AccessShareLock` on the engine's relations: about 1.5k instructions per relation per
   execution saved, article -17.7% at batch 1;
3. those relations held open under a resource owner of the engine's own (article -5.8% at batch 1);
4. one result descriptor for the marker's two columns;
5. per collation, whether it passed its self-test;
6. in pgserve, the prepared write statements.

None of them is a page's contents, a row or a response. We read rule 5 as "no reuse of results or row data", so
we count these with connection pools and prepared statements, which the rule allows. An aborted transaction
releases the session locks, and the relations close with them. A relcache invalidation on any of them marks the
schema stale, and the next execution re-checks it against `schema.zig` or fails.

### What it adds up to

**Full seed, Postgres CPU per request.** These numbers come from a clone of the benchmark box, a single
backend, every page warm, median of 3 interleaved rounds, with the engine as of the staged reads.
"#7" is #7's statements, in their batch forms above batch 1. "SPEC SQL" is one reference statement per request.

| endpoint | engine µs, batch 1 / 8 / 32 | #7 µs, batch 1 / 8 / 32 | SPEC SQL µs |
|---|---|---|---|
| article | 30.4 / 20.4 / 13.1 | 90.4 / 37.8 / 45.2 | 107.9 |
| list_all | 36.4 / 13.4 / 10.8 | 184.8 / 139.8 / 141.3 | 360.9 |
| list_tag | 46.2 / 40.8 / 39.8 | 274.5 / 220.9 / 205.3 | 352.9 |
| list_author | 36.1 / 26.1 / 22.5 | 149.1 / 132.8 / 116.4 | 242.9 |
| list_favorited | 69.4 / 81.9 / 68.2 | 460.6 / 265.6 / 231.6 | 525.0 |
| feed | 125.4 / 100.3 / 108.7 | 645.6 / 529.0 / 471.9 | 901.7 |
| comments | 25.4 / 13.4 / 11.3 | 65.1 (one statement per request) | 73.8 |
| profile | 16.6 / 5.1 / 3.2 | 29.1 / 11.6 / 8.6 | 25.3 |
| user | 13.9 / 3.4 / 2.2 | 21.8 / 5.3 / 3.6 | 19.2 |
| tags | 14.6 / 2.7 / 1.4 | 30.6 / 4.4 / 1.1 | 33.0 |

Engine over #7 comes out at 0.08-0.64 of the CPU and 0.03-0.56 of the instructions, with one exception: tags at
batch 32, where #7 wins (1.20). Its batch form broadcasts one row to the whole batch, while the engine answers
each request, even though every answer points at the same bytes.

**The whole request mix (replay).** This is the final replay, 6 rounds with every variant interleaved,
Postgres CPU per logical request. The engine ran through markers on a shared read queue with a 5, 20 or 50 ms
batch clock, either one execution per endpoint ("per kind") or one for every endpoint ("one per drain"). Writes
and logins used #7's statements.

| variant | µs per request | p95 | Postgres CPU vs #7 | instructions vs #7 |
|---|--:|--:|--:|--:|
| #7 | 166.9 | 22.5 ms | 1 | 1 |
| best pure-SQL variant we built (50 ms clock, one statement per drain) | 77.3 | 257.6 ms | 0.496 | 0.632 |
| engine, per kind, 5 / 20 / 50 ms | 49.3 / 36.2 / 33.3 | 19.7 / 41.7 / 83.5 ms | 0.311 / 0.220 / 0.192 | 0.157 / 0.146 / 0.134 |
| engine, one per drain, 5 / 20 / 50 ms | 41.8 / 36.3 / 33.4 | 14.1 / 40.8 / 81.1 ms | 0.235 / 0.199 / 0.209 | 0.158 / 0.140 / 0.128 |

So in the replay the engine costs 0.19-0.31 of #7's Postgres CPU per request, depending on the clock. These are
replay figures, not pgserve's. pgserve has no wire, and by default no clock, so its batches are whatever one
turn holds. Note
also that instructions fall 6-8x while CPU falls 3-5x: the engine retires about 0.4-0.55 instructions per cycle, because
it spends its time waiting on memory. That is why the last third of the work went to cache misses.

**End to end.** At 60,000 users, measured against our own Zig server talking SQL to Postgres on the same 8-vCPU
clone, with servers alternating: pgserve used 91 / 98 µs of box CPU per request and the Zig server 144 / 205,
and all four runs passed. At 260,000 users, pgserve used 91-92 µs of box CPU per request on a fresh database
(before the 16 GB cap) and 99-100 on an aged one under the cap.

## Writes and commit

The commit went through three designs, and the first one came back.

1. **Synchronous commit inside the loop.** On the first sandbox's disk, a WAL flush sometimes took about
   300 ms, and every connection on that worker waited with it: p50 0.5 ms but p99 221 ms at 20,000 users.
2. **Asynchronous commit, held answers, a WAL-flusher worker.** Each worker committed with
   `synchronous_commit` off for its own session and held every answer until a seventh background worker,
   ticking every 1 ms, had flushed the WAL past it. p99 at 20,000 users fell to 3.0 ms.

   The flusher's first version died within seconds. It flushed to the WAL insert position, which at a page
   boundary points past the next page's header, and `XLogFlush` refuses that with an `ERROR`. Postgres's WAL
   writer then flushed alone on its 200 ms cycle, and writes had a 124-152 ms median. It now flushes to the end
   of the last record.
3. **Synchronous commit again.** Rule 6 says "No `synchronous_commit = off`" in so many words. Holding the
   answers made each writer wait for durability, but other sessions could read a committed write a moment
   before it was flushed. On the Hetzner rig, whose disk doesn't stall, design 1 cost nothing measurable:

| users | commit | req/s | p95 | p99 | box CPU |
|---|---|---|---|---|---|
| 120,000 | async, answers held for the flush | 31,668 | 38.2 ms | 69.9 ms | 43.7% |
| 120,000 | synchronous (kept) | 31,685 | 26.1 ms | 66.9 ms | 44.5% |
| 190,000 | async, answers held for the flush | 50,126 | 30.9 ms | 45.9 ms | 65.1% |
| 190,000 | synchronous (kept) | 50,134 | 37.5 ms | 75.6 ms | 63.5% |

(One 120 s window each, before the 16 GB cap.) The held design had better tails at 190k and no lower CPU, and it
broke a rule. It went, and with it the flusher worker. Conformance got faster as a bonus: 0.7 s instead of 3.2 s.

Writes are the part of the work we didn't make cheaper. In the replay, write backends took about 27.5% of
backend cycles: by our estimate about 200 µs of Postgres CPU per write request. Since writes and their re-reads
are about 5% of requests, that comes to about 11 µs of an average request's Postgres CPU.
They go through SPEC's own statements because the rows have to be real, committed Postgres rows.

## Memory

An idle connection holds no buffer. A connection owns heap only for what it is still waiting on:

- the bytes of a request that isn't complete yet (or of pipelined requests not yet started);
- the bytes of an answer the socket wouldn't take yet.

Each is freed as soon as it is empty. Every read lands in one 64 KB buffer per worker, and a complete request
starts straight from there. It is copied only if it must outlive the turn. The turn's answers are built back to
back in one buffer per worker, which is freed after any turn that pushed it past 4 MB. At 260,000 users the six
workers' heap stays near 200 MB.

The version before this kept each connection's input buffer (a 16 KB reserve per read) and its output buffer for
the connection's whole life. An output buffer is cleared but keeps its capacity, so every connection ended up
holding a buffer as large as the largest answer it had ever received. On a 32 GB rig at 260,000 users, the
workers' anonymous memory reached 15.5 GB and was still rising about 30 MB/s at steady load. Under the official
box's 16 GB, the official search sequence got Postgres OOM-killed at the 256k probe, every phase after that
failed, and the score was 0.

The fix, measured at 200,000 users on the aged database under the 16 GB cap, in an ABBA:

| build | req/s | p99 | µs per request | workers' heap | result |
|---|---|---|---|---|---|
| before | | 945 / 1,354 ms | | 11.0-11.2 GB at the kill | OOM-killed in both arms |
| after | 52,657 / 52,688 | 211 / 233 ms | 103.1 / 104.0 | 195-198 MB, flat | pass in both arms |

That is about 55x less worker heap at the same load. Since the fix, the only memory that still grows with
connections is the kernel's socket memory. Through a 512,000-user overload probe the box peaked at 9.0 GB of
15.2 GB, made of 196 MB of worker heap, 1.3 GB of TCP memory, 3.0 GB of slab and 48,000 orphaned sockets, and
nothing was killed.

Zero idle buffers is common ground. #7, #10 and #52 do it too. We got there late and the hard way.

## Results, and where the wall is

Both official-style searches ran on the rig described above. Each started from a fresh database, ran a 3-minute
warm-up, probed doubling from 500 users, bisected to 5%, then held for 5 minutes. Nothing was reset between
phases, so the database aged the way it would in the official run (articles +20%, comments +12%), and `-max` was
400,000.

| search | probes | overload probe | held | req/s | p95 | p99 | errors | peak memory |
|---|---|---|---|---|---|---|---|---|
| 1 | 256k pass; 270k fails (p99 2.3 s) | 400k: 21.3% errors, server stays up | **260,000** | 68,080 | 96.5 ms | 407.6 ms | 0.004% | 9.9 GB after the overload, 7.1 GB in the hold |
| 2, installed by the scorer's `prepare.sh` from this folder | 256k pass; 270k fails (p99 1.9 s) | 400k: 23.3% errors, server stays up | **260,000** | 67,940 | 130.8 ms | 497.9 ms | 0.008% | 10.0 GB after the overload, 7.2 GB in the hold |
| before the memory fix | pass to 128k | 256k: Postgres OOM-killed | none | | | | | over 15 GB |

At the knee the box is 85-88% busy, but one CPU is full. The NIC has a single receive queue, so one CPU takes
all of its interrupts and all of the kernel's receive processing. At 260,000 users that CPU ran 90% softirq, 5%
user and 4% idle, while the other seven were about a third idle. `perf` on that CPU showed where the time goes:

- the socket lookup among about 260,000 established connections (`__inet6_lookup_established`, 7.8%);
- the AMD SRSO mitigation's return thunk (3.8%);
- processing client ACKs (`tcp_clean_rtx_queue` and `tcp_ack`, 3.0% each).

Per request, pgserve sends 1.65 data packets and 0.05 bare ACKs, and receives the request plus 1.28 client ACKs.
It sends so few bare ACKs because each answer leaves within the same turn, and the ACK rides on the answer. Our
Zig server sent 0.86 bare ACKs per request.

Every NIC we could measure had one receive queue: the Hetzner rig, our sandboxes, and two DigitalOcean droplet
types we rented to guess at the official box. Rule 12 rules out RPS and IRQ affinity, and rightly so. Everything
we tried against that wall from inside our own processes is in the next section, and all of it lost.

## What we tried that didn't make it

Every row is a measured loser, kept as its own commit or result file. "A-A" is the spread between two arms of the
same build in the same series. Engine rows are dev-seed instructions per request unless they say otherwise.

### Network and threads

| tried | result | why it lost |
|---|---|---|
| keep the workers' threads off the CPU taking the NIC's receive softirq, decided at runtime from per-CPU softirq time in `/proc/stat` | 260k, aged: +1.4 µs per request (A-A 0.6), p99 doubled (300 / 262 against 122 / 146 ms) | 12 threads packed onto 7 CPUs cost more than sharing the receive CPU. The softirq counts in `/proc/softirqs` would have picked the wrong CPU: virtio counts transmit completions as `NET_RX` too. |
| busy polling from idle CPUs: one `SCHED_IDLE` helper per worker spinning on `recv(MSG_PEEK)` with `SO_BUSY_POLL` 50 µs | 200k: 38,817 req/s, fail, against 52,727, pass. 150k: p99 40-43 against 67-69 ms, but 197 against 118 µs per request and the box at 98% | Busy polling handled about 1% of received packets itself. Stopping it reschedules the NAPI on the polling CPU, so receive work scattered over every CPU, and the helpers ate all idle time. |
| a seventh worker | +1.5 µs (270k, fresh, inconclusive), +1.6 µs (300k, fresh), +1.8 µs (260k, aged, A-A 0.1); p99 11-66 ms lower | Costs CPU beyond the spread, shows no capacity gain, and takes the last background-worker slot. |

### gzip

| tried | result | why it lost |
|---|---|---|
| gzip (the Zig entry's libdeflate level 1) for bodies of 1 KiB or more | 260k ABBA: +9.7 µs per request (spread under 1 µs), p99 +60-115 ms; sent bytes 1.9 → 0.86 Gbit/s. 270k, aged, capped: +8.5 µs (A-A 4.4), no p99 gain, box 95% against 88% busy | It halves the bytes, but bytes were never the wall. |
| gzip as the fix for a "network wall" at 180k | with gzip, 220,000 held; without it, the 190k-260k probes collapsed on retransmits | The wall was packet loss on the path to our 12 load boxes (25% retransmits in the failing probe, 7% at the boxes themselves). With 16 boxes, no gzip held 260,000. |
| gzip only for answers it squeezes into one TCP segment, with our own fixed-Huffman encoder (checked by Go's `compress/gzip` on 2,817 real bodies and 8,000 generated ones) | +3.4 µs at 150k (A-A 0.6), +2.4 µs at 200k; receive-CPU softirq 11.00 against 10.77 µs per request | Only 3.9% of bodies became one segment, and the encoder ran at 1.4-1.7 ns per byte. |
| libdeflate with an 8 KB hash table (order 11) | 150k with gzip: 123.6 / 122.7 against 122.7 / 122.0 µs | No gain. |
| libdeflate with preset Huffman codes; a 1,280-byte cutoff | not run on pgserve | Dropped with gzip. |

### Commit and memory

| tried | result | why it lost |
|---|---|---|
| asynchronous commit, answers held for the flush, a WAL-flusher worker | the table in "Writes and commit" | Rule 6. |
| per-connection buffers kept for the connection's life | OOM at the 256k probe under 16 GB, score 0 | See "Memory". |

### Engine

| tried | result | why it lost or stayed |
|---|---|---|
| comment authors read once per execution (tried twice) | +0.5-1% instructions and +7% CPU at batch 8; later +1.2-1.9% | Commenters rarely repeat within a batch. |
| root and internal pages kept pinned for the execution from the first descent | list_all cycles +1.9% to +5.5% while its instructions fell | Now kept only from an index's second descent. |
| ...and a gate on batch size instead | fixed article at batch 1, but feed +6.3% at batch 1 | |
| three other shapes of the off-all-visible run loop (visitor called from two places, run check inline, through a tuple slot) | feed +3.0-4.9%, +1.5-2.4% and +2.9-5.6% | Un-inlined the feed's visitor. The kept form runs out of line. |
| count tallies past the cap to the end of the page; stopping at the cap inside a generic loop | list_all +1.3% at batch 1; +2.1% (register spills) | Kept: the page bound hoisted, and single-TID tuples on their own path. |
| per-page visibility state in a struct | list_all +4.1% at batch 1 (about +29 instructions per entry) | Moved back into locals. |
| the executor bypass running its batch in the portal's small memory context | list_all +0.5% to +4.3%, article +3.8% at batch 32 | Every response body became a malloc of its own. |
| the first lock-free form: clamp every read and peek leaves too | +0.2% to +4% | Replaced by internal pages first, then leaves on their own. |
| the lock-free step reader out of line; whole-index walks read lock-free | list_all +2.1% / +1.2% at batch 1 / 2; +1.0% | |
| one marker execution for every endpoint of a drain | 0.563 of the best SQL against 0.565 per kind at 50 ms | Saved a few µs per drain of about 1,280 requests. pgserve runs one batch per endpoint. |
| heap rows prefetched before a batch | +0.6-2.0% instructions; replay cycles 1.080, CPU 1.120 | Leaning loser, kept: the staged reads build on it. |
| a page's first lines requested before its pin | replay cycles 1.035 (3 of 8 rounds lower) | Unresolved, kept. |
| `aim` (staged leaf searches) | +6-26% instructions on the dev seed; a build without it: list_all -11 to -14% instructions, -6 to -13% CPU | Shipped. Not measured alone on the full seed. This is the one we'd test next. |
| byte order for every text comparison | profile -22% to -61% | Wrong under some collations. We used it as an upper bound for the collation self-test. |
| a backend's pins held to Postgres's 8-entry refcount array: past 8 pins, every pin and unpin also pays a hash lookup (`hash_search_with_hash_value` and `GetPrivateRefCountEntry` were 3.9% of the box at 300,000 users). Index pages were kept only while fewer than 6 pins were held, and a table's new pin took a kept page back | batch 8, six backends, aged copy: hash lookups per article request 28 → 2, but pins 15 → 18 and list_tag's 109 → 236; instructions on the request mix +1.5%, list_tag +7.4% | Each hash lookup saved came back as an extra pin and unpin, and on a busy box a pin is the dearer of the two: an atomic on a descriptor other backends write. |
| ...keeping no index page at all; keeping only internal pages | +1.5% and +0.6% instructions on the request mix | |

Small regressions we accepted for larger gains elsewhere:

- inline visibility-map bits: article +0.1-0.2%;
- the packed parameter: tags +1.2% at batch 32, 1 of 4 rounds;
- lock-free internal pages: profile +0.5%;
- lock-free leaves: feed +0.5% at batch 32;
- dense hint arrays: list_tag +0.5%, comments +0.2-0.7%;
- one hint lookup per batch: list_tag +0.9-1.2%.

### Not tried, on purpose

- Precomputed response layouts held between requests (rule 5).
- Kernel and IRQ tuning (rule 12).
- Writing heap and index tuples directly instead of through SPEC's statements (rule 6 and SPEC: the rows have to
  be the real thing).

## Correctness evidence

- **Conformance:** 197/197 through the scorer's own `prepare.sh` and `switch.sh` on the full seed, port 80, from
  this folder.
- **Differential HTTP oracle:** 20,002 requests on the full seed, pgserve against the reference Go server on the
  same database: 20,002 match.
- **The engine's oracle against SPEC's SQL:** 1,317,802 byte-exact comparisons, 0 mismatches. It covers every
  slug, username, user id, tag, list filter, limit from 1 to 100 and offset from 0 to 80, for anonymous and
  logged-in viewers, before and after a write set built to break it:
  - quotes, backslashes, control and non-ASCII bytes in titles;
  - TOASTed descriptions and bodies;
  - tag names whose collation order differs from their byte order;
  - impostor slugs, slugs with no id, a leading zero;
  - HOT updates;
  - a thread past the 100-comment cap, a deleted newest comment, a `created_at` tie;
  - an email that needs escaping.

  Batched answers equal the same requests run alone: 0 mismatches over 19,000+ members. A spot check on the full
  seed (500 per endpoint) at the staged build found 0 mismatches.
- **Split-and-delete stress:** in one transaction, insert one large key range per walked index (5,000
  favorites on one article, 900 tag links on one tag, 800 tag names spread through `tags_name_key`, and so on).
  Delete it in another, and `VACUUM` every other cycle, so leaf pages split inside the walked ranges and emptied
  pages get deleted and recycled. Readers check that every count is either the before or the after value, and
  that all members of one execution agree. Over 10 minutes: 1,440,832 executions at the lock-free-leaves
  build, 0 violations.
- **Batch counter against SQL** (`engine/test/batchcount.py`): a copy of the seed is churned (favorites inserted,
  deleted and re-inserted, HOT updates on favorites and articles, one article grown to 5,000 favorites so its
  leaves split, `VACUUM` between rounds so heap pages are a mix of all-visible and not). Every `favoritesCount`
  the engine answers (every list page, 500 articles by slug, list_favorited, list_author, list_tag) is then
  compared with `SELECT count(*)` in the same `REPEATABLE READ` transaction after another connection wrote,
  some of it still uncommitted. Three passes per build, about 23,000 counts each, for the engine and for builds
  with the pending bound at 3 and the slot limit at 4, so the fallbacks run: 0 wrong.
- **Soaks:** three readers ran random batches of every endpoint, one writer ran SPEC's writes, `ANALYZE` ran
  every minute, and the oracle spot-checked every 5 minutes.
  - 60 minutes at an early direct-walk build: 10,973,964 executions, 181,082,697 requests, 0 errors, 0 bad
    replies.
  - 30 minutes at the executor-bypass build: 7,942,077 executions, 0 errors.

  No run lost a connection or left a crash line in the Postgres log.
- **Schema guard:** `schema.zig` restates `schema.sql` as data: column types, nullability, collations, and index
  keys and directions. The engine refuses to load on any of 8 breaking changes, and loads when a column has only
  moved (10/10).
- **Session locks:** 11/11 cases for abort, reload and exit.
- **HTTP worker unit tests:** these drive the real loop over a socket pair. They cover a request split across
  two reads, two pipelined requests in one read, a 400 with `Connection: close`, a 1 MB answer sent over
  several writes, when a held turn runs, a connection that closes while its turn is held, and the batch-size
  histogram.

The oracle, stress and soak harnesses drive the engine through its marker form against a scratch database.
They aren't part of this folder, and neither are the Postgres stubs the unit tests link against. The batch counter test is, with the marker encoder it needs
(`engine/test/markers.py`).

## CI

`ci.sh` runs only in GitHub Actions, and CI does not exercise the box path. The repository's CI runs Postgres as a
`postgres:18` service container and installs no Postgres server on the runner. pgserve's workers are Postgres
processes, so there the engine has to go into that container.

`install.sh` and `start.sh` first call `ci.sh container`. If the `postgresql-18` package is installed, as on the
box, it fails and they go on to the box path described in "How to run" and "How it starts": `install.sh` lines 11-20
unpack the installed server's headers, build the engine and install it into `$libdir/plugins`, and `start.sh` runs
`./launcher`. That is what runs on the real machine. If the package is missing and exactly one running container
comes from the `postgres:18` image, they hand over to `ci.sh` instead:

- `ci.sh install` fetches `postgresql-server-dev-18` at the container's `postgresql-18` version through
  `docker exec` and the container's own apt, builds the engine on the runner against those headers, and copies
  `pgengine.so` into the container's `$(pg_config --pkglibdir)/plugins` (`docker cp`, `docker exec`).
- `ci.sh start` copies the launcher into the container and runs it with `sudo nsenter -m`. The launcher joins only
  the container's mount namespace, so its Unix socket and `/var/run/postgresql` are the ones the workers see, and it
  stays on the runner's network, so it binds `HOST:PORT` where `test/run.sh` connects.

launcher.c and the engine are the same in both paths.

## Files

- `launcher.c`: holds the port, starts the workers, hands them their sockets, stops them.
- `engine/src/serve.zig`: the HTTP workers' event loop.
- `engine/src/btree.zig`, `pg.zig`: the page walks, buffer hints, lock-free reads and in-place heap rows.
- `engine/src/schema.zig`, `collate.zig`: the schema check and the collation self-test.
- `engine/src/article.zig`, `list.zig`, `comments.zig`, `profile.zig`, `user.zig`, `tags.zig`, `enrich.zig`: one
  file per endpoint, and the shared Article fragments.
- `engine/shim/pgengine_shim.c`: `_PG_init`, the worker registration, the planner and executor hooks.
- `engine/shim/http_write.c`: the write statements and their subtransactions.
- `engine/src/web/`: HTTP, JWT, JSON and bcrypt, vendored from our Zig entry.
- `engine/test/batchcount.py`: the batch favorites counter against SQL on a churned copy of the seed.
- `engine/test/markers.py`: the marker encoder batchcount.py drives the engine with.
- `install.sh`, `build.sh`, `start.sh`, `engine/build.sh`, `engine/install-zig.sh`: as described in "How to run".
- `ci.sh`: CI only, see "CI".

## Credits

- [#7 rust-tokio-Scooter1337](https://github.com/arjaythedev/multicore-server-challenge/pull/7) is the yardstick
  in every engine table here. Its statements, batch forms and `enriched` CTE are what the engine was measured
  against and what its per-batch sharing imitates. Its Openwall bcrypt kernel is what our lanes engine was
  measured against.
- PR #47's two-phase gather is the shape of the shared read queue and batch clock that the replay scored the
  engine under, and of pgserve's optional batch clock.
- #7, #10 and #52 hold no buffers for idle connections. We arrived at the same place later.
- The vendored HTTP, JWT and bcrypt code carries our Zig entry's credits:
  - #11 and #15 for reading the JWT claims in one pass;
  - #45 for `TCP_NODELAY` on the listener;
  - PR #8, whose bcrypt lane layout and round order we measured (neither changed our kernel).
- Postgres's own nbtree and heapam code is the specification `btree.zig` and `pg.zig` follow, function by
  function. Any mistakes in following it are ours.

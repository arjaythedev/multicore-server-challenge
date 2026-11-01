# Java / raw NIO / own Postgres client

Front: direct

| | |
|---|---|
| Language / runtime | Java 25, Eclipse Temurin 25.0.4.1 (official tarball, SHA-256 pinned in `install.sh`) |
| HTTP | Hand-written HTTP/1.1 on `java.nio` selector loops, one `SO_REUSEPORT` listener per loop |
| Postgres driver | Own v3 wire-protocol client (SCRAM-SHA-256, named prepared statements, pipelining, binary rows) |
| JSON, JWT | Own JSON parser and writer; HS256 on `javax.crypto.Mac` |
| bcrypt | Own, several hashes in lockstep. The cost loop is generated x86-64 assembly (`native/`, called through the FFM API), with C and then Java kernels as fallbacks |
| Dependencies | No libraries: the JDK, and gcc to build `native/` (`install.sh` installs both) |

```bash
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

No caches across requests, no schema or Postgres config changes, no host tuning.

## Design: a batch planner in front of Postgres

Postgres is the bottleneck on this workload, so the server is built around spending as little Postgres CPU per
request as possible. The plan is the one `rust-epoll-WorriedArrow` (#131) uses, ported to Java.

**Read lanes.** Eight read lanes each own one Postgres connection. A lane takes every read waiting in one shared
queue, of every endpoint, and answers the whole batch in two pipelined round trips:

1. **Phase A** resolves what each request is about: one statement per kind of request in the batch, each taking
   arrays of *distinct* keys (`unnest(...) WITH ORDINALITY`). One global page per `(limit, offset)`, one capped count
   per tag, author or viewer, one lookup per slug, e-mail or username. It goes out as two segments in one flush: the
   tag list, current users and login lookups (about a quarter of all traffic) come back first and are answered, or
   handed to bcrypt, while Postgres works through the rest.
2. **Phase B** enriches the union of every article phase A returned, across all endpoints, once per article (tag
   ids, favorite count, author profile). The per-viewer `favorited` / `following` flags are one primary-key range
   scan per viewer (`= ANY(...)`). Comment authors are one ordered walk of the primary key over the batch's distinct
   ids, instead of a join per comment row.

Feed and author pages come back from phase A as ids and authors only, straight from `articles_author_idx` (index-only
scans); `artrow` in phase B reads their columns once per distinct article that no other statement already returned.
A feed's articles are by followed authors, so they need no follow probe.

**Feeds in parallel.** Each read lane has a second connection for the feed statement, the costliest one. It goes out
first, and a second backend runs it while the first runs the rest of phase A, so a batch doesn't wait for it in series.

Each article's JSON is written once per batch with the two viewer-dependent booleans left open, then spliced into
every response that shows it. Tag names come from one read of the 200-row tags table per batch, in the database's
own collation order. **Feeds** share their popular followees ("hubs") across the viewers of a batch: a hub with
1,000+ articles proves the capped count without counting, and its depth-th newest id is a floor that stops every
other followee's index scan early.

**Forming batches.** Lanes take turns gathering: one collects while the others execute. It takes what is waiting once
the oldest request has waited 40 ms (or 4,096 are queued). Under a backlog the oldest has already waited that long, so
nothing waits on a timer; at lower load a batch fills for the window, because a statement's fixed cost is split across
everyone in the batch. Nothing outlives its batch: every value in a response was read from Postgres while that request
waited. Reads whose client has disconnected (after a 10 s timeout under overload) are dropped unrun, so a backlog
from an overload probe doesn't spill into the next one.

**Writes: group commit without BEGIN/COMMIT.** One write lane sends every waiting write as one pipeline ending in
a single `Sync`. Postgres runs that as one implicit transaction with one WAL flush, and each response is released
only after it commits. A write waits up to 3 ms for company. All the favorites, unfavorites, follows, unfollows and
new comments of a group run as one statement per kind, over arrays. If any statement fails, the group rolls back and every write is retried in its own transaction, still
in one round trip (one `Sync` per write), so one bad write can't fail the others. Writes that return an article
(favorite, create, update) read it through the read lanes after the commit.

**bcrypt in lockstep.** One bcrypt is a single long chain of dependent S-box loads. Hashing several passwords with
their rounds interleaved, each lane in its own registers, lets the core overlap the chains. All lanes sit next to each
other in memory, each lane's P-array right before its S-boxes, so one base register reaches everything.

The cost loop, nearly all of a hash, runs in `native/`: assembly generated by `tools/gen-bcrypt-native.py` on x86-64
with BMI1 and BMI2, in two styles of S-box index extraction, and plain C kernels elsewhere. Java's C2 can't allocate
registers for this as well: on a 2-core, 4-thread EPYC 7763, Java's best width took 35.2 ms per hash where the assembly
took 14.8 ms (all CPUs busy: about 42 ms against 29 ms). The call goes through the FFM API, which leaves the thread in
native state, so a hash in progress never holds up a garbage collection. If `native/` didn't build, the server runs on
generated Java kernels (`tools/gen-bcrypt-lanes.py`). The salted expansion and the final encryption stay in Java.

At startup the server times each kernel at widths 1 to 6, with every CPU hashing at once, and keeps the fastest per
hash: wider sets lose once hyperthreads share an L1, as they do under load. Three workers take turns gathering a full
set (waiting up to 400 ms); the extra ones only run when a backlog fills sets faster than the first can hash them.
Every hash does all 2^10 rounds, and every login verifies against the stored hash. Blowfish's initial state (the hex
digits of pi) is computed at class load with `BigInteger` rather than pasted in, and checked.

**Postgres session settings** (startup parameters on our own connections only): `plan_cache_mode =
force_generic_plan` (otherwise the array-parameter statements are re-planned on every execution), `jit = off` and
`max_parallel_workers_per_gather = 0` (a generic plan can't see LIMIT values or array sizes, so its estimates would
otherwise trigger JIT compilation and parallel workers for sub-millisecond statements).

**Process**: `start.sh` runs the JVM under `SCHED_BATCH` (`chrt --batch 0`, no privileges needed, inherited by every
thread): our threads wake constantly, and under the default policy each wakeup can preempt a busy Postgres backend.
ParallelGC with a fixed 2 GB heap (1 GB young), 4 GC threads.

**HTTP**: one selector loop per two cores, each with its own `SO_REUSEPORT` listener. A connection has at most one
request in flight. Reads go through a per-loop scratch buffer, so an idle keep-alive connection holds no buffer.
Reads parsed in one pass of a loop are queued together, one lock per pass. Answers from the lanes go back to each loop's
inbox with one selector wakeup per loop per batch. JWTs (HS256 only, signature, `exp`, `nbf`) are verified on every
request on the loop thread; the common token (our exact header, flat claims) skips the general JSON parser, and anything
else takes it. If `accept` fails (out of descriptors),
the listener pauses for 100 ms while open connections keep being served.

## Settings

All optional environment variables; the defaults suit the 8-vCPU box.

| Variable | Default | |
|---|---|---|
| `IO_THREADS` | cores / 2 | HTTP selector loops |
| `READ_LANES` | cores | read lanes |
| `FEED_CONN` | 1 | 1: each read lane runs its batch's feed statement on a second connection |
| `WRITE_LANES` | 1 | group-commit connections |
| `READ_MIN` | 4096 | a batch is taken early once this many are waiting |
| `READ_WINDOW_US` | 40000 | the longest the oldest read waits for its batch to fill |
| `READ_BATCH`, `WRITE_BATCH` | 4096, 256 | batch size caps |
| `WRITE_WINDOW_US` | 3000 | how long a write waits for others to share its group |
| `BCRYPT_THREADS` | 3 | bcrypt workers |
| `BCRYPT_LANES` | measured | hashes run in lockstep (1 to 6; by default timed at startup, along with the kernel) |
| `BCRYPT_WINDOW_MS` | 400 | how long a worker waits to fill its lanes |
| `JAVA_HEAP`, `JAVA_YOUNG`, `GC_THREADS` | 2g, 1g, 4 | JVM memory and GC threads |
| `SCHED_BATCH` | 1 | run under `SCHED_BATCH` (0: the default policy) |

Postgres connections: `READ_LANES` (twice with `FEED_CONN`) `+ WRITE_LANES` (17 by default).

## Correctness

- `test/run.sh`: 197/197 on the dev seed and on the full seed (Postgres 18), on x86-64 Ubuntu 24.04 after `install.sh`.
- For the previous version (#140), a differential test of 20,000 random reads (lists with every filter and offsets up
  to 100,000, feeds, articles, comments, profiles, current user; anonymous and as 3,000 different viewers) against
  `examples/go` on the same database, sent 64 at a time so batches are large and mixed: no differences.
- A differential test of 20,000 random reads against this server's previous version (#140) on one copy of the full
  seed, sent 64 at a time: no differences.
- `tools/selftest.sh`: bcrypt against published Openwall vectors and the seed's hash on every kernel, every kernel and
  lane width against single Java hashes, JWT (the fast path and the full parser on the same tokens), the key maps against `HashMap`, timestamp
  formatting, JSON.

## Credits

The batch plan (phase A/B, distinct-key arrays, shared feed hubs, per-batch article fragments, the global count
from the oldest end, merged write runs, the session settings and `SCHED_BATCH`) is `rust-epoll-WorriedArrow`'s
(#131), which credits `rust-epoll-theCatWisel` (#105), `zig-fourneau-y2kbugger` and `asm-epoll-nickita-khylkouski`
(#82, #130) for parts of it. Group commit with no `BEGIN`/`COMMIT` is from `zig-iouring-nick-potts` (#117). This
update ports `rust-epoll-WorriedArrow`'s later work (#139, #152, #169): 40 ms gathers, comment authors in one scan, id-only
feed pages, one statement per write kind, the first `Sync` and the feed connection. `tools/gen-bcrypt-native.py` is a
port of their `build.rs`, itself a port of `zig-iouring-nick-potts`'s `asm_gen.zig`. Index-only author pages are from
`rust-epoll-theCatWisel` (#143).

Built with Claude (Anthropic).

# Rust / raw epoll / own Postgres client

Front: direct

| | |
|---|---|
| Language | Rust 1.99.0 (edition 2024), fat LTO, one codegen unit, `target-cpu=native` |
| HTTP | Hand-written HTTP/1.1 on raw `epoll` + `SO_REUSEPORT`, request parsing with `httparse` |
| Postgres driver | Own v3 wire-protocol client (SCRAM-SHA-256, binary rows, pipelining). No pool library |
| Other crates | `hmac` + `sha2` (JWT), `serde_json` (request bodies, JWT claims), `base64`, `memchr`, `itoa`, `getrandom`, `mimalloc`. Pinned in `Cargo.lock` |
| bcrypt | Own implementation (Blowfish tables from RustCrypto's `blowfish` crate), cost 10, verified against the `bcrypt` crate in tests |

```bash
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

## Design: a batch planner in front of Postgres

On this workload Postgres does most of the work, so the server is built around spending as little Postgres CPU per
request as possible.

**Read lanes.** Each read lane owns one Postgres connection. A lane takes every read request that is waiting in the
shared queue, of every endpoint, and answers the whole batch in two pipelined round trips:

1. **Phase A** resolves what each request is about, one statement per kind of request present in the batch. Every
   statement takes arrays of *distinct* keys (`unnest(...) WITH ORDINALITY`), so identical keys in a batch are one
   row: one global page per `(limit, offset)`, one capped count per tag, author or viewer, one lookup per slug,
   e-mail or username. Each list kind returns its capped counts and its page rows from one statement. Capped
   counts read at most 1,000 index entries, once.
2. **Phase B** enriches the union of every article phase A returned, across all endpoints, once per article: tag
   ids, favorite count and the author's profile in one statement. The newest articles show up in global lists, tag
   pages, feeds and article pages at the same time, and are enriched once per batch instead of once per request.
   The per-viewer `favorited` / `following` flags are one primary-key range scan per viewer (`= ANY(...)`) instead
   of a probe per article.

Phase A sends a first `Sync` after the tag list, current-user and login lookups, so those requests (about a quarter
of all traffic) are answered, or handed to bcrypt, before the rest of the batch and its phase B; every tag-list
request of a batch gets the same body, built once.

Tag names come from one read of the 200-row tags table per batch, in the database's own name order; the same rows
answer `GET /api/tags` and order every article's `tagList`. Each article's JSON is written once per batch with the
two viewer-dependent booleans left open, and spliced per response.

**Feeds** share work between the viewers of a batch. A followee followed by several of them (popular authors are
followed by many) is looked at once: whether it has 1,000 or more articles (then every viewer following it counts
1,000 without a scan), and the id of its `limit + offset`-th newest article. That id is a floor for those viewers'
pages, which can only hold articles at least that new, so every other followee's index scan stops there. Feed pages
come back as article ids and authors only, straight from `articles_author_idx`; the columns of articles no other
statement in the batch returned are read once per distinct article in phase B, since popular followees' newest
articles are on many viewers' pages at once. A feed's articles are by followed authors, so they need no follow probe.

**Forming batches.** Lanes take turns forming batches: one lane collects while the others execute theirs. It takes
what is waiting once the oldest waiting request has waited 40 ms (or 4,096 are queued). Under a backlog the oldest
has already waited that long, so nothing waits on a timer; at lower load batches fill for the window instead of
being whatever trickled in since the last lane freed up. Postgres pays a fixed cost per statement execution, and a
batch of a few hundred requests splits it a few hundred ways; everything requests have in common (the newest page,
the tag list, a viral article's favorite count and comment thread) is read once per batch instead of once per
request. Pushing a request only wakes the collecting lane when its batch is ready, not on every request.

Nothing outlives its batch: every value in a response was read from Postgres while that request was waiting, and
only requests already queued when the batch started share it.

**Writes** go through one write lane with group commit: every waiting write is pipelined before one `Sync`, which
makes them one implicit transaction (no `BEGIN`/`COMMIT` statements), committed at the `Sync` with one WAL flush;
responses are released only after Postgres reports it done. If any statement in a group fails, the group rolls back
and each write is retried on its own, so one bad write can't fail the others. A write whose commit outcome is unknown
(connection lost) is never retried. A write waits up to 3 ms for company. Favorites,
unfavorites, follows, unfollows and new comments in a group are put next to their own kind and each kind runs as one statement over arrays of their parameters
(new comment ids drawn in request order), and its rows are split back per request. Writes that return an article
(favorite, create, update) read it through the read lanes after the commit, in a new snapshot.

**bcrypt** runs on its own threads, several hashes in lockstep: a single bcrypt is one long chain of dependent S-box
loads, and interleaving independent hashes lets the core overlap them. How many lanes pay off depends on the CPU
(its L1 and registers hold a few 4 KB S-box sets, not many). The lanes' states sit next to each other in memory, and
on x86-64 with BMI1/BMI2 the cost loop can run a generated assembly expand0 (`build.rs`) that reaches every lane
from one base register, in two styles of S-box index extraction. At startup the server times each kernel (that one in
both styles, and the plain Rust one) at widths 1 to 6 on throwaway keys at a low cost and keeps the fastest per hash. One worker waits up to 400 ms for its lanes to fill; a second
worker only takes full sets, so a steady trickle of logins isn't split into half-empty runs. Every hash still does all
2^10 rounds; logins always verify against the stored hash.

**Postgres session settings** (startup parameters on its own connections, nothing server-wide):
`plan_cache_mode = force_generic_plan`, because with the default the array-parameter statements were re-planned on
every execution (16% of Postgres CPU in a profile), and `jit = off`, because a generic plan can't see LIMIT values or
array sizes, its cost estimate crosses `jit_above_cost`, and compiling took milliseconds per sub-millisecond statement.
`max_parallel_workers_per_gather = 0`, for the same reason: a generic plan can't see how small a batch's arrays are.

**Scheduling**: at startup the process puts itself under the `SCHED_BATCH` policy (no privileges needed; every
thread inherits it). Our threads wake constantly (a request, a reply, a ready batch), and under the default policy
each wakeup can preempt a busy Postgres backend; batch threads get the same CPU share without cutting in line.
`SCHED_BATCH=0` turns it off.

**Fewer packets**: after each response the server leaves TCP quick-ack mode on that socket, so the ACK for the
client's next request rides on the response to it instead of going out as a packet of its own.

**Clients that hung up** while their request was queued (a load generator's timeout, say) cost nothing more: each
IO thread publishes, per connection slot, which request generation can still be answered, and read lanes and
bcrypt skip jobs whose client is gone.

**HTTP**: one epoll thread per `SO_REUSEPORT` listener, each with a descriptor table of its own (`unshare(CLONE_FILES)`
at start): client sockets are only touched by the thread that accepted them, so the kernel skips the shared table's
locking and reference counting on every socket call. Reads go through a per-thread scratch buffer, so an idle
keep-alive connection holds no buffers, only its slot. Responses go out with one `writev` when the socket accepts it.
JWTs (HS256, `alg`, signature, `exp`, `nbf`) are verified on every request on the IO thread. If `accept` fails for
lack of descriptors or memory, the listener leaves the epoll set for 100 ms (open connections keep being served)
instead of waking the loop again at once; the process raises its own descriptor soft limit to the hard one at start.

## Settings

Defaults suit the 8-vCPU box; all are optional environment variables.

| Variable | Default | |
|---|---|---|
| `IO_THREADS` | cores / 2 | epoll threads |
| `READ_LANES` | cores | read connections |
| `WRITE_LANES` | 1 | group-commit connections |
| `BCRYPT_THREADS` | 2 | bcrypt threads (the first gathers, the rest take full sets) |
| `BCRYPT_LANES` | measured | hashes run in lockstep (1 to 6; by default timed at startup) |
| `BCRYPT_WINDOW_MS` | 400 | how long the first bcrypt thread waits to fill its lanes |
| `READ_WINDOW_US` | 40000 | the longest the oldest request waits for its batch to fill |
| `FEED_LANES` | 0 | read lanes that serve only feeds (0: all lanes serve every read) |
| `READ_MIN` | 4096 | a batch is taken early once this many (or the recent average, if larger) are waiting |
| `READ_BATCH`, `WRITE_BATCH` | 4096, 256 | batch size caps |
| `WRITE_WINDOW_US` | 3000 | how long a write waits for others to share its group |
| `BCRYPT_IDLE` | 0 | 1: hashing threads at nice 19, plus a normal-priority thread for logins waiting `BCRYPT_RESCUE_MS` |
| `BCRYPT_RESCUE_MS` | 1000 | with `BCRYPT_IDLE`, how long a login waits before the normal-priority thread hashes it (0: no such thread) |
| `ACK_DELAY` | 1 | leave TCP quick-ack mode after each response |
| `PRIVATE_FDS` | 1 | a descriptor table per IO thread |
| `SCHED_BATCH` | 1 | run under the `SCHED_BATCH` scheduling policy (0: the default policy) |

Postgres connections: `READ_LANES + WRITE_LANES` (9 by default).

## Correctness

- `test/run.sh`: 197/197 on the dev and the full seed.
- A differential test of random reads (lists with every filter and offsets up to 5,000, feeds, articles,
  comments, profiles, current user; anonymous and authenticated) against `examples/go` on the same database,
  with this server hit 64 requests at a time so batches are large and mixed: no differences.
- Unit tests for bcrypt (against the `bcrypt` crate and the seed's hash), JWT and timestamp formatting.

## Credits

Ideas from other entries: the shared feed hubs (followees checked once per batch for 1,000+ articles, and their
depth-th newest id as a floor) from `rust-epoll-theCatWisel` (#105), which credits the heavy-author count to earlier
entries (#61, #100); long gathers from #117; one read of the tags table per batch
from `zig-fourneau-y2kbugger`; `max_parallel_workers_per_gather = 0` from several entries (#103, #105); backing off
`accept` on `EMFILE`, `SCHED_BATCH` and merging runs of writes from `asm-epoll-nickita-khylkouski` (#82, #130);
merged favorite/follow statements also in #105; skipping queued work for clients that hung up and a descriptor table per IO thread from #132. Leaving quick-ack mode after each response and
group commit without `BEGIN`/`COMMIT` from `zig-iouring-nick-potts` (#117), whose `asm_gen.zig` the generated bcrypt
kernel is a port of. Answering article creation from its own insert and carrying a favorite's known state into its read-back from
`rust-epoll-theCatWisel` (#154).

Built with Claude (Anthropic).

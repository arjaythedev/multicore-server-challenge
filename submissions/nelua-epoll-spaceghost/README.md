# C / Nelua + epoll + PostgreSQL

Front: direct

Conduit's application logic is Nelua: all 19 API operations, routing, parameterized
SQL, validation, response objects, and JSON emission. It compiles to native C
using [official Nelua](https://github.com/edubart/nelua-lang), pinned
to `a58450563e2d2ec49bff499865c8b5cfdf6ff81a`.

A native host supplies epoll sockets, request-owned buffers, libpq, OpenSSL 3,
and bcrypt. The build targets GCC 13 and Ubuntu 24.04's development packages;
libpq follows the benchmark's PostgreSQL packages, discovered with `PG_CONFIG`.
The executable has no Lua VM, Nelua GC, or Nelua initialization/panic path.
Request allocation uses either host libc or a privately namespaced Nelibc
archive; libpq and OpenSSL retain their own hosted allocation boundaries.

`APP_IMPL=c` selects a separately handwritten C application implementing all
19 operations, routing, batching and JSON rendering. Its application builds without invoking
Nelua; building the optional Nelibc dependency requires its own pinned compiler. Both applications consume the same 34 parameterized SQL statements;
`tools/export_sql.py --check` checks the released C statement data against Nelua.

`CORE_PROFILE=freestanding` (the default) compiles the selected application objects with
`-ffreestanding -fno-builtin -fno-stack-protector`, partially links those actual
objects with `-nostdlib`, audits their imports and links that audited object into
the host. This is a freestanding application **core**, with a hosted transport,
libpq, OpenSSL and libxcrypt bridge; the whole executable is not freestanding.

`MEMORY_IMPL=host` is the default and needs no private repository.
`MEMORY_IMPL=nelibc` is an optional comparison. With neither `NELIBC_ROOT` nor
`NELIBC_ARCHIVE` supplied, the build fetches clean pinned source and builds the
archive with GCC. `NELIBC_CACHE` selects the reproducible dependency cache
(default `.deps/nelibc-source`). Nelibc is pinned to
`73ae254aa0f4cc1fa03f8fad92711c497e9c28fc`; its build compiler uses the separate
Spaceghost Nelua fork at `dabbd9effebb7ecfe59a727f49f27b4574109d4d`.
The application compiler remains the official pin above. Source-build manifests
record compiler identities, revisions and archive hashes. Alternatively supply
both `NELIBC_ROOT` and `NELIBC_ARCHIVE` for an already built clean dependency.
The build namespaces every defined archive symbol and hides it from the dynamic ABI.
Owned bridge buffers use private allocation/copy functions; freestanding core
memory primitives use that provider. Compiler-known small copies retain bounded
inline loads/stores. No process-wide allocator interposition is used. The
ownership test checks both sides of the libpq/OpenSSL boundary. Both C and
Nelua freestanding/private-Nelibc profiles passed the 197-step API suite; this
establishes correctness, not a throughput advantage over libc.

JSON string emission skips ordinary text eight bytes at a time using bounded,
unaligned-safe word loads. Control characters, quotes, and backslashes retain
the scalar escape path; UTF-8 bytes pass through unchanged. Optional C/Nelua
SIMD scanner variants below keep that same escaping and response-buffer path.

## Build and run

On Ubuntu 24.04, from the repository root:

```sh
bash submissions/nelua-epoll-spaceghost/install.sh # install packages once, as root
bash submissions/nelua-epoll-spaceghost/build.sh
bash test/run.sh submissions/nelua-epoll-spaceghost
```

Build and run the C counterpart with matching selections:

```sh
APP_IMPL=c MEMORY_IMPL=host bash submissions/nelua-epoll-spaceghost/build.sh
APP_IMPL=c MEMORY_IMPL=host bash submissions/nelua-epoll-spaceghost/start.sh
```

Both `APP_IMPL={c,nelua}` support `MEMORY_IMPL={host,nelibc}` and the same
freestanding core profile. Keep those selections identical at build and start.

The official runner requires the challenge seed, Go, psql, curl, and PostgreSQL
test credentials; see [test/run.sh](../../test/run.sh). The build verifies a clean
compiler checkout or linked worktree at the pin, generates C afresh with
`--no-cache` into the submission build directory, links companion C sources explicitly, strips unused
symbols, and audits generated C for runtime imports. No binaries are committed.

`start.sh` runs in the foreground. Set `DATABASE_URL` and `JWT_SECRET`; `HOST`
and `PORT` default to `127.0.0.1:3000`. Direct hosting uses `0.0.0.0:80`;
the runner supplies descriptor limits and permission to bind port 80. On a
higher port, runtime needs no root privileges, kernel changes, or extra services.

## Concurrency and database work

### C/Nelua SIMD writer comparison

`JSON_SCAN=nelua-auto` enables the Nelua scanner with runtime CPU detection:
AVX-512F/BW plus AVX2 when available, otherwise AVX2, otherwise word-at-a-time.
`JSON_SCAN=c-auto` selects the independently written C counterpart. Both loop
bodies use the same small header of CPU instruction bindings. The default is the selected application language’s `auto` scanner. The legacy
inline word scanner remains available as `JSON_SCAN=legacy`.
Explicit `{c,nelua}-{scalar,word,avx2,avx512}` modes support controlled
comparisons; forcing an unavailable ISA fails startup. Selection occurs before
worker startup, with no feature detection or environment reads per request.

Every vector load is bounded by the remaining input length. The 64-byte path
uses 32-byte and word tails; UTF-8 bytes are treated as ordinary bytes. Both
languages' scanner objects compile with `-ffreestanding -fno-builtin` and have
no undefined symbols. The application-core and private-Nelibc profiles described
above are separate build choices. The executable retains hosted dependencies.

Five rotated local component runs on an Intel i7-11700F, GCC 13 with `-O3`
and LTO for the complete writer, produced these median CPU times. The driver
consumes a changing position in every rendered result through a volatile
checksum so the output cannot be discarded as unused work:

| JSON input | Legacy writer | C AVX-512 writer | Nelua AVX-512 writer |
| --- | ---: | ---: | ---: |
| 1,024 ordinary ASCII bytes | 177.6 ns | 35.8 ns | 37.2 ns |
| 1,024 bytes with frequent escapes | 475.7 ns | 265.5 ns | 267.0 ns |
| 4,096 ordinary ASCII bytes | 656.3 ns | 100.6 ns | 99.6 ns |

These are string-writer microbenchmarks on a shared desktop, not requests per
second, VM capacity, or an independently authored full C server comparison.
Small C/Nelua differences do not establish a language advantage. The report
checker requires the entire specified matrix: 720 scanner-kernel samples and
525 writer samples in these runs. Missing or duplicate samples fail analysis.

Reproduce component checks from this submission directory after building:

```sh
python3 tests/json_scan.py --sanitize
python3 tests/serialize_scan.py --sanitize --modes legacy,c-auto,nelua-auto
python3 tests/json_scan.py --benchmark 5 > kernel.log
python3 tests/serialize_scan.py --benchmark 100000 --rounds 5 \
  --modes legacy,c-auto,nelua-auto > writer.log
python3 tests/analyze_scan.py writer.log --kind writer \
  --modes legacy,c-auto,nelua-auto --output writer.json
```

The standalone scanner driver skips unsupported ISAs. When analyzing kernel
results on such a machine, supply its supported mode set with `--modes`.

### HTTP-to-libpq socket adapter experiment

Set `READ_REACTOR=1` to run the read side as one epoll-driven adapter with
`DB_READ_THREADS` independent PostgreSQL sessions. HTTP stays HTTP/1.1 on the
public side; Nelua validates and translates requests into parameterized SQL,
and libpq supplies PostgreSQL's protocol on the database side. The adapter uses
the configured `DATABASE_URL` and needs no extension, extra service, database
file access, or host tuning.

Each active read batch owns a guarded 512 KiB continuation stack and one libpq
connection. A socket wait suspends only that continuation; the scheduler runs
other batches while PostgreSQL executes. Prepared queries, pipelines, connection
recovery and session initialization after reconnect all yield to epoll. Connection
establishment during startup remains synchronous and bounded. Binary results and
request-owned JSON buffers retain their existing ownership. Idle HTTP connections
own neither a continuation nor a database connection. Authentication and mutation
workers retain their existing paths, including synchronous commits.

`READ_REACTOR=1` is the default. `READ_REACTOR=0` retains the worker
implementation for comparison. One scheduler
also serializes read-side CPU work, so fewer OS threads do not establish higher
throughput. `READ_GATHER_SERIAL` applies to worker mode; reactor mode always has
one collector. With `READ_ADAPTIVE=0`, both modes retain the oldest-request 8 ms
collection deadline and 128-request cap. This is a client adapter, not an
embedded PostgreSQL engine.

`READ_ADAPTIVE=1` (the default) experimentally adjusts read admission and collection delay.
It samples CPU counters and available host/cgroup CPU, I/O and memory PSI at
most four times per second. Cgroup quota utilization and throttled CPU time
also reveal a saturated process allocation when the wider host remains idle.
The probe walks visible cgroup ancestors, uses the smallest quota/period ratio,
and resets its counter baseline when the limiting scope changes.
It also tracks batch service time and queue age. Once service exceeds 2 ms,
collection grows to a quarter of that service time, bounded to 8 ms; this builds
denser SQL groups without mistaking latency alone for resource pressure.
CPU or memory pressure reduces active read slots; I/O stalls require concurrent
service and queue delay before reducing admission. Capacity recovers toward the
configured connection count as queued demand grows and pressure clears. The
first request on an idle lane is released immediately; collection is bounded
to 8 ms and 128 requests. Service time includes application work and database
waits. Missing kernel observations do not manufacture pressure. Admission
currently controls reads only; write/auth lanes keep their configured bounds.
Live request storage at 75% of its configured budget also reduces admission.
Latency and queue age alone never trigger admission reduction: slow I/O can
need additional concurrency, and missing PSI leaves that resource unknown.
These heuristics need workload-specific comparison;
a passing correctness suite does not establish better capacity or every tail percentile.

Completed responses go directly to `sendmsg` with `TCP_NODELAY` enabled.
There is no `TCP_CORK`, `MSG_MORE`, or application timer holding completed
output. The socket loop handles completed replies before new input, caps each
accept turn at 64 connections and each write turn at 256 KiB, then rearms pending
writes. This bounds monopolization without a completed-response batching timer.
Reactor collection deadlines use `epoll_pwait2` microsecond precision
with an `epoll_wait` fallback. Global sysctls, CPU affinity and I/O schedulers
are left to the challenge harness; the entry does not change them.

One epoll thread owns sockets; idle keep-alive connections retain no buffers.
Three bounded lanes own **44 PostgreSQL connections** by default: four read,
32 mutation, and eight authentication workers. More concurrent durable writers
allow PostgreSQL group commit to share WAL flushes; synchronous commit stays
enabled. Bcrypt stays off the epoll
thread. Pending work, memory, headers, bodies, and output are bounded; overload
receives 503. Idle keep-alive timeout is 75 seconds.

One collector gathers at most 128 reads for up to 8 ms from the oldest enqueue
time, then releases collection before database work. Other read workers execute
completed batches concurrently. Article, profile, comment, tag, and page/count
lookups share SQL and deduplicate keys within that batch. Viewer-specific flags
use each request's independently verified token; ordinality maps results back
to requests. Shared data and rendered responses end with the batch. Each frozen
tag group executes a fresh query, renders once, and copies bytes into each
request's independently owned response buffer; later arrivals cannot reuse it.

After every token and pagination argument has been checked independently,
identical effective reads in the frozen group share a query row and JSON rendering.
The identity includes the route family, decoded resource/filter key, verified
viewer ID, limit, and offset. Responses are copied into independently owned
buffers before the group ends, including missing-resource and error responses.
A bounded 256-slot lookup also shares viewer-independent article JSON fragments
within each page-query result, while both personal flags are read separately
from every viewer's own row. Fragment references use offsets into request-owned
buffers, are resolved after buffer growth, and expire with that result. Hash
probes are capped at 16; collisions fall back to ordinary rendering. No read or
rendered bytes survive into a later group.

A bounded libpq pipeline submits at most nine batch-read families before waiting
for results, with a 10-second deadline for flushing and draining the pipeline.
Failed pipelines are not replayed; the connection resets before its next operation.
Writes retain their synchronous commit path.

Statements are parameterized and prepared per connection. Binary PostgreSQL
results avoid text conversion for numeric values, booleans, timestamps, and
arrays. Article queries select a bounded page before enrichment. Session-only
settings disable JIT and parallel gather workers and use UTC. The schema and
database-wide settings stay untouched; no extensions or external cache are used.

| Variable | Default | Purpose |
| --- | ---: | --- |
| `APP_IMPL` | nelua | Handwritten C or Nelua application |
| `CORE_PROFILE` | freestanding | `freestanding` audits and links the application core |
| `MEMORY_IMPL` | host | `nelibc` selects private owned allocation/copy |
| `DB_READ_THREADS` | 4 | Read workers/connections |
| `DB_WRITE_THREADS` | 32 | Mutation workers/connections; bounded durable group commit concurrency |
| `DB_AUTH_THREADS` | 8 | Login, registration, password-change workers/connections |
| `READ_REACTOR` | 1 | One epoll scheduler for all read connections; experimental |
| `READ_ADAPTIVE` | 1 | Pressure-aware read admission and collection; experimental |
| `JSON_SCAN` | language-auto | Selected language’s CPU-dispatched scanner; explicit legacy/scalar/word/SIMD comparisons |
| `READ_GATHER_SERIAL` | 1 | Single collector; DB execution stays concurrent |
| `READ_PIPELINE` | 1 | Bounded batch-local libpq read pipeline |
| `READ_COALESCE` | 1 | Share identical reads and public article JSON within the frozen batch |
| `READ_BATCH_STATS` | 0 | Aggregate density/wait statistics at shutdown |
| `DB_RESULT_MEMORY_MB` | 64 | Process-wide conservative credits for retained batched libpq results; 1–4096 MiB |
| `REQUEST_MEMORY_MB` | 256 | Aggregate live request objects, arenas and output/vector capacities; 1–4096 MiB |
| `REQUEST_POOL` | 0 | Build-time request-header/first-arena pooling; 0 retains the original allocation path |
| `OUTPUT_RESERVE` | 0 | Build-time lower-bound reservation before long JSON strings; 0 retains incremental growth |
| `BUFFER_CACHE` | auto | Build-time untyped buffer reuse: enabled for private Nelibc, disabled for libc |
| `NELIBC_CACHE` | `.deps/nelibc-source` | Pinned Nelibc source/compiler/archive build cache |
| `NELUA_ROOT` | `.deps/nelua` | Clean checkout of the pinned compiler |
| `PG_CONFIG` | `pg_config` | Build-time libpq discovery |
| `JOBS` | 2 | Compiler bootstrap jobs |
| `NATIVE_FLAGS` | `-march=native` | CPU flags; set empty for a portable build |

The request budget reserves credits before allocation, including old and new
storage during growth. Credits grow in 8 KiB quanta and stay with their request
until destruction, so most allocations avoid a contended global counter. Exact
growth is attempted when rounding alone would exceed the cap. Reported usage is
reserved capacity, conservatively above requested live bytes. Exhaustion returns
503; freeing a request on another thread releases its entire reservation.
The context pool combines the request header and first arena in one 4032-byte
allocation. When enabled, the network thread warms 128 contexts (504 KiB);
other owners grow on demand. Each of at most 32 owner caches retains at most 128 spare contexts,
for 15.75 MiB of requested spare storage process-wide. Pop/push operations use
owner-local lists, with registration synchronized only at thread entry/exit.
Cross-thread returns enter the freeing thread's cache. Extra owners fall back
to the provider; thread exit releases its cache. Explicit trimming affects the
calling owner's cache. Active requests retain their credits until destruction,
after socket output completes; spare contexts are accounted separately.

With `OUTPUT_RESERVE=1`, both independent writers reserve space for JSON
strings of at least 128 bytes: raw length plus quotes before emitting. This is a checked lower bound, so
escaping can still grow the buffer. It avoids growing through small capacities
when the minimum output length is already known. Enable the two experiments
independently with `REQUEST_POOL=1` and `OUTPUT_RESERVE=1`; both default to 0.

Optional reusable medium buffers have a separate 32 MiB total
and 16 MiB per-class bound. They retain storage only: every response is freshly
rendered. Provider metadata/slabs, libpq connection/input buffers, OpenSSL,
continuation stacks, transport
input and kernel memory are outside these counters; this is not an RSS limit.
The default is deliberately the same reservation budget for both allocators.
Batched reads use libpq single-row reception and accumulate under a separate
process-wide `DB_RESULT_MEMORY_MB` credit cap. Row storage is conservatively
charged before copying, including metadata/slack. Result destruction refunds
credits even after the originating connection closes. Exhaustion discards the
partial batch, returns 503 and reconnects before later work, without replay.
A current wire row and libpq connection/input buffers remain outside that cap;
these counters do not bound total RSS.
The x86-64 request control object stays at most 120 bytes. Internal body lengths
and response capacities use checked 32-bit bounds, keeping libc's control-object
allocation compact as well as the private-provider comparison.

Worker counts must be positive and total at most 95. Set `READ_GATHER_SERIAL=0`
or `READ_PIPELINE=0` or `READ_COALESCE=0` to disable the corresponding strategy for comparison.

The default build uses public `edubart/nelua-lang` and the hosted allocator;
it requires no private repository access. `MEMORY_IMPL=nelibc` remains an
explicit comparison profile requiring the pinned Nelibc source and its compiler
fork (or a supplied matching source/archive). The public compiler cannot parse
the pinned dependency's `*const [0]cchar` syntax. This dependency distinction
does not affect the public compiler used for the application core.

## Correctness

Every authenticated request verifies HS256, signature, expiry, and a positive
decimal subject. Worker-local OpenSSL HMAC contexts retain only configuration
key material and keyed provider state. Every call reinitializes the context,
hashes the current token and verifies its signature; secret changes rekey it,
and cryptographic failures discard its state. Login checks the stored bcrypt hash; registration and password
changes compute **cost 10** with fresh random salts. Interleaving up to eight
independent bcrypt states shares execution resources while completing every
password's work. Libxcrypt handles compatibility cases and supplies an independent
test oracle. Passwords over 72 bytes are rejected.

User updates enter the bounded authentication lane without inspecting their
JSON on the socket owner. Authentication precedes body parsing in the worker;
large unauthenticated bodies do not allocate JSON trees on the network thread.
JWT verifications and password results are never retained across requests.
Read results and rendered bytes live only within the frozen batch described above.
Writes finish committing before queuing a response; synchronous
commit stays enabled and ambiguous failed commits are not retried. HTTP framing
and JSON checks cover conflicting lengths, invalid escapes, Unicode, embedded
NUL, nesting, and response size limits.

## Additional checks

From the submission directory:

```sh
python3 tests/request_test.py
python3 tests/auth_state.py --sanitize
python3 tests/tags_batch.py --sanitize
python3 tests/serialize_scan.py --sanitize
python3 tests/transport_gather.py --sanitize
python3 tests/read_policy.py
python3 tests/pressure_hierarchy.py
python3 tests/harness_safety.py
python3 tests/network_fair.py --sanitize
python3 tests/request_budget.py --sanitize --memory host
python3 tests/request_budget.py --sanitize --memory nelibc
python3 tests/buffer_cache.py --sanitize --memory nelibc
python3 tests/memory_ownership.py
python3 tests/request_pool.py --sanitize --memory host
python3 tests/request_pool.py --sanitize --memory nelibc
python3 tests/request_memory.py --rounds 8 --actions 65536 > memory.jsonl
python3 tests/analyze_request_memory.py memory.jsonl > memory-summary.json
python3 tests/reservation_shootout.py --output writer-results --rounds 8 --loops 50000
DATABASE_URL='dbname=postgres' python3 tests/db_result_budget.py --sanitize
DATABASE_URL='dbname=postgres' python3 tests/read_reactor.py
DATABASE_URL='dbname=postgres' python3 tests/read_pipeline.py --sanitize
createdb nc_batch_validation
DATABASE_URL='dbname=nc_batch_validation' python3 tests/batch_sql.py
DATABASE_URL='dbname=nc_batch_validation' python3 tests/read_coalesce.py
dropdb nc_batch_validation
BASE_URL=http://127.0.0.1:3000 python3 tests/edge_http.py
```

Request tests independently check JWT/HMAC, bcrypt, JSON, and HTTP boundaries.
Gather tests cover both modes, concurrent execution, and shutdown with pending
work. Pipeline tests need a PostgreSQL test server and use literal SELECTs to
check ownership, errors, timeouts, and recovery. Batch SQL tests replace rows in
the disposable `nc_batch_*` database and compare against independent SQL oracles.
HTTP edge tests require a running disposable application. Official rankings
require the maintainer's full-seed benchmark; local runs establish no score.

The request-memory shootout measures the shared request/buffer/HMAC bridge,
without sockets or SQL. It uses actual request ownership, single and four-thread
producers, groups of 1 and 128, changing consumed output and balanced provider
ordering. Its default eight variants independently cross the provider, medium
buffer cache and context pool; output reservation is disabled to isolate pool
costs. Its analyzer requires all declared rounds and variants, identical
checksums, artifact provenance and bounded retained storage. These component
measurements do not rank the two application languages or establish server capacity.
The reservation shootout separately crosses C/Nelua, both providers and
reservation on/off, with a fresh request for every timed string and the context
pool enabled throughout. Complete eight-round rotations consume identical
output; reusable-buffer timings alone would hide allocation differences.

The reactor test uses undefined-behavior instrumentation and proves four
simultaneously outstanding read sessions on one OS thread, independent binary
result ownership, large socket reads, SQL errors, reconnect/reprepare, and
completion of validation-only work without an extra wake notification. Its
`ucontext` continuations are not tested with AddressSanitizer, whose stack-switch
support requires additional runtime hooks. The ordinary libpq pipeline tests
retain address and undefined-behavior instrumentation. Private-Nelibc sanitizer
checks instrument the bridge; the dependency archive itself is not instrumented.


## Retained measurements

[Measurement manifest](evidence/manifest-v13.json) records pins, workload, limits
and hashes. These tests ran unprivileged in the authorized Incus instance on a
shared i5-10400 host: eight allowed logical CPUs and a **6 GiB parent cap**.
They do not reproduce the official 8-vCPU/16-GiB VM and establish no official
capacity score or overall language/provider winner.

The four freestanding C/Nelua × libc/private-Nelibc profiles each pass all
197 full-seed API checks at 4/8/8 lane counts. Nelua/private Nelibc also passes
197 at 4/32/8, and the final default source build/start path is checked with the
official runner. Bounds, cross-thread ownership, allocator exhaustion/recovery,
network fairness and read-admission tests are retained under `tests/`.

The [complete request-memory matrix](evidence/request-memory-v13.jsonl) has 192
samples over four balanced rounds. Median process CPU time per request below
compares libc without bridge reuse against private Nelibc with bounded reuse.
This is shared bridge code, not a C-versus-Nelua language comparison:

| Producers / group | Work | libc | Private Nelibc |
| --- | --- | ---: | ---: |
| 1 / 1 | Simple request + 2 KiB output | 314 ns | 230 ns |
| 1 / 1 | JSON parse + 2 KiB output | 814 ns | 744 ns |
| 1 / 1 | JWT verification + 16 KiB output | 2,108 ns | 2,104 ns |
| 4 / 128 | Simple request + 2 KiB output | 493 ns | 1,268 ns |
| 4 / 128 | JWT verification + 16 KiB output | 2,483 ns | 2,954 ns |

Private medium-buffer reuse reduces the last case from 39.1 µs without reuse to
2.95 µs. Nelibc is faster on important single-producer paths; libc remains faster
in the heavily concurrent grouped cases. Both controls use the compact request
layout and the same conservative request-memory budget.

The [32-writer whole-server diagnostic](evidence/diagnostic-v13-5000-w32.json)
uses the nominal client model, 5,000 users, 60 s ramp and 30 s measurement.
Compared with the [eight-writer run](evidence/diagnostic-v13-5000-w8.json),
additional concurrent durable writers reduce long tails without disabling sync
commit. A live PG sample observed WALWrite/WalSync waits while CPU remained spare.
The final default is 32 writers; all performance rows explicitly set that value.

| Application / memory | p95 | p99 | Errors | SLO |
| --- | ---: | ---: | ---: | --- |
| C / libc | 255 ms | 540 ms | 0 | Pass |
| C / private Nelibc | 421 ms | 1,015 ms | 0 | Fail |
| Nelua / libc | 168 ms | 437 ms | 0 | Pass |
| Nelua / private Nelibc | 1,976 ms | 2,677 ms | 0 | Fail |

The existing C entry's published defaults passed its separate 5,000-user run
(p95 217 ms, p99 472 ms, zero errors). Its idle tag median was 41.3 ms; these four
profiles measured 0.6–1.4 ms. These are fixed-order observations, not repeated
capacity rankings. The reference collects reads for 40 ms by default; this entry
releases the first request on an idle lane immediately. Private Nelibc has not established a consistent
whole-server latency win over libc on this host.

The [integrated pressure test](evidence/pressure-v13.json) reduces only its owned
PG/application unit from eight CPU equivalents to 0.1 during ramp, then restores
it. Read admission falls 4→1 and recovers 1→4. The subsequent measurement has
zero errors, p95 331 ms and p99 678 ms. That recovery run is diagnostic evidence,
not a capacity score. Kernel PSI is absent in this instance; actual cgroup CPU
quota consumption/throttling still drives the controller.

`tools/shootout_run.py` requires a distinct stopped pristine PG fixture per case,
checks parent limits and retains raw load/resource metadata. Configure runtime
lane counts through each case's `read_connections`, `write_connections` and
`auth_connections`. `tools/shootout_analyze.py` rejects incomplete matrices.
`tools/shootout_pressure.py` accepts exactly one adaptive load case, pulses only
its verified transient `build` service, restores its quota and checks recovery.
These root-run harnesses launch PG, application and load generation unprivileged;
the entry itself never changes cgroup limits, global sysctls or I/O schedulers.
Root launchers open artifacts with the target user's permissions and exclusive,
no-follow creation. Unit startup logs go through the journal, not a root-opened
path in a target-writable directory. Readiness requires the launched child's
listening socket inode, and occupied ports fail before any HTTP probe.
The target unit gets private IPC and a private `/dev/shm` while keeping PG/app
inside its resource cgroup. This prevents unrelated session IPC cleanup from
unlinking its database segments; no host logind setting is changed.

## Context-pool and reservation comparison

The [pool matrix](evidence/request-memory-p1.jsonl) contains 768 samples over
eight complete rotations. It compares pooling on/off separately for both
providers and both medium-buffer-cache settings, with reservation disabled.
The following are median process CPU nanoseconds per request; each provider
uses its default medium-buffer-cache setting. These are bridge lifetimes,
without PostgreSQL or sockets:

| Provider | Producers / group | Work | Pool off | Pool on |
| --- | --- | --- | ---: | ---: |
| libc | 1 / 1 | Simple request + 2 KiB output | 313 | 209 |
| libc | 4 / 128 | Simple request + 2 KiB output | 497 | 411 |
| libc | 4 / 128 | JWT verification + 16 KiB output | 3,159 | 2,790 |
| Private Nelibc | 1 / 1 | Simple request + 2 KiB output | 231 | 203 |
| Private Nelibc | 4 / 128 | Simple request + 2 KiB output | 1,147 | 508 |
| Private Nelibc | 4 / 128 | JWT verification + 16 KiB output | 3,161 | 3,207 |

Pooling improves every libc workload median in this matrix. Private Nelibc
improves most cases, with small regressions in some four-producer cases; it
still does not beat libc consistently. The fresh-request
[writer matrix](evidence/writer-p1.jsonl), with
[configuration and binary hashes](evidence/writer-p1-metadata.json), contains
960 samples across both languages/providers and reservation on/off. Reservation
reduces median process CPU time by about 8–28% for the tested 1–4 KiB strings.
Shorter cases range from improvements to a 2.8% regression. These component
results show component savings, but the combined whole-server runs regress
against controls. Both build defaults remain disabled; enable independently
with `REQUEST_POOL=1` and `OUTPUT_RESERVE=1` for further comparisons. A general
whole-server improvement, or absence of regression, has not been established.

The [whole-server comparison](evidence/diagnostic-p1-5000.json) uses distinct
fresh full-seed fixtures and two runs per version: old/new/new/old for C/libc,
and new/old/old/new for Nelua/private Nelibc. Both features are on in the new
binaries. Goodput excludes errors; ranges below retain both runs:

| Profile / version | Good responses/s | p99 | Errors |
| --- | ---: | ---: | ---: |
| C/libc, old | 66–1,131 | 3.24–10.00 s | 0–87.4% |
| C/libc, both on | 713–945 | 4.83–4.87 s | 0% |
| Nelua/private, old | 1,158–1,309 | 0.55–2.76 s | 0% |
| Nelua/private, both on | 17–288 | 10.00 s | 41.4–96.8% |

One old private-provider run passes its SLO; the other seven runs fail. The old
controls vary widely, but both new private-provider runs are worse than both
controls. PostgreSQL data-file waits were observed on the shared single-disk
ZFS pool. The cause remains unresolved; these data do not prove storage alone
explains the regression. The build defaults therefore keep both experiments
off. [The manifest](evidence/manifest-p1.json),
[merged results](evidence/load-p1-merged.json), and
[target metadata/logs](evidence/load-p1-details.json) retain the comparison.

All four updated freestanding profiles with both features on pass 197 full-seed
API checks each at 4/32/8 lane counts. The four final default builds with both
features off also pass [197 checks each](evidence/conformance-p2.json), with
[fresh core import audits](evidence/core-p2-audits.json). Host and private-provider bridge sanitizer
checks cover all four pool/reservation combinations, 40 concurrent owners,
cross-thread returns, held response isolation, memory exhaustion/recovery,
network backpressure and byte-level serialization oracles. The private library
archive remains uninstrumented.

## Review follow-up and controlled comparison

The public default bootstrap passes GitHub Actions and the official dev-seed
runner. The application still uses the pinned public compiler; private Nelibc
is an explicit opt-in dependency. Four updated C/Nelua × libc/private profiles,
plus the combined private pool/reservation build, pass 197 API checks each.
Tests additionally cover streamed result exhaustion/recovery, SQL errors after
partial rows, parent quotas without PSI, unauthenticated 20,000-node routing,
root artifact symlink attacks, occupied listeners and zero-response analysis.
All eight C/Nelua × allocator × pipeline HTTP overload/recovery combinations
also return 503 for an oversized author result, then 200 after it is reduced.

The earlier measurements need caution beyond ordinary host contention: retained
P1 C/libc logs include missing PostgreSQL shared-memory errors,
and a later diagnostic reproduced unlinked database shared memory during app
restarts. This is consistent with the
[documented systemd IPC-cleanup hazard](https://www.postgresql.org/docs/18/kernel-resources.html#SYSTEMD-REMOVEIPC).
It does not explain every previous failed case or establish an allocator cause.
The diagnostic launcher now isolates its IPC instead of changing global policy.

A four-round, rotated **2×2 fixed-hot-read** comparison isolates pooling and
reservation against one unchanged PostgreSQL instance. All 16 samples complete
with zero HTTP errors and zero byte-level response mismatches. Median throughput
is about 44k responses/s and p99 about 3.6–3.7 ms across all configurations.
This is 32 fixed article lookups with 64 clients, not the challenge mix or a
capacity score. Client CPU is about 1.7 of its two Go execution threads. Small
throughput/CPU differences do not justify enabling either default. The
[raw samples](evidence/hot-samples-20261118.jsonl),
[summary](evidence/hot-summary-20261118.json), and
[build/test manifest](evidence/review-manifest-20261118.json) retain the results.
The updated [live pressure run](evidence/review-pressure-20261118.json) restores
read admission 4→1→4 and completes its 500-user measured phase with zero errors
and 142 ms p99. That recovery diagnostic is not a capacity comparison.

`tools/hot_read.go` validates every response against its URL's preflight hash;
`tools/hot_compare.py` retains order, binary hashes, latency, process CPU, PG
buffer statistics and per-task I/O counters. ZFS disk I/O is not necessarily
attributed in `read_bytes`; a zero counter alone is not proof of no disk waits.

## Credits

Batching draws on [rust-epoll-WorriedArrow](../rust-epoll-WorriedArrow),
[c-epoll-umitaltintas](../c-epoll-umitaltintas), and
[csharp-sockets-jh-d](../csharp-sockets-jh-d). `src/bcrypt.c` and `src/bf_tables.h`
adapt Ümit Altıntaş's interleaved kernel from `c-epoll-umitaltintas`, snapshot
`d373e0dd994f4683a94c783627078431561d07f6`; its MIT notice is retained in
[src/BCRYPT-LICENSE](src/BCRYPT-LICENSE). This submission uses the repository's
MIT license, copyright 2026 arjaythedev and the challenge contributors.

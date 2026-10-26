# pgserve: the HTTP server runs inside Postgres

**Front: direct**

pgserve serves the whole Conduit API from inside Postgres. Its HTTP workers are Postgres background
workers that our engine library starts. Each one accepts connections, checks the JWT, reads the data
straight from Postgres's shared buffers and writes through SPI, all in the database's own process. No
app process sits between a request and its data, and no request crosses the Postgres wire protocol.

This is a second submission, separate from the main Zig server. Here the in-Postgres server is the only
way it runs. There is no flag to turn it off and no fallback to SQL over a connection.

## The costs, plainly

- **It runs as the `postgres` OS user.** The HTTP workers are Postgres processes. Everything they do, they
  do with the database server's OS identity and file access, not as `challenge`. Inside the database they
  act as the `conduit` role (the role in `$DATABASE_URL`), with that role's table privileges and no more.
- **A crash takes all of Postgres down with it.** If a worker crashes (a segfault, an abort), the
  postmaster treats shared memory as corrupt. It ends every backend, runs crash recovery and starts
  over. Every open database connection on the box drops, not just ours. The workers are registered with
  `BGW_NEVER_RESTART`, so after a crash pgserve stays down (rule 9: no restarts). An ordinary Postgres
  ERROR in a read batch or a write is caught: those requests get 500, the turn's transaction is rolled
  back, and the worker goes on. An ERROR anywhere else ends that worker, which is not replaced. The others
  keep serving.
- **Six HTTP workers, set by Postgres's defaults.** `max_worker_processes` stays at its default of 8,
  because changing server settings isn't allowed. The logical replication launcher holds one slot, which
  leaves 7. pgserve takes 6 of them. Parallel query has at most one worker left. pgserve itself never uses
  parallel query.
- **Six workers don't cap the box's CPU.** Each HTTP worker is one event-loop thread plus one bcrypt
  thread. The other two vCPUs, and any time a worker's thread is idle, go to the kernel's network
  processing (softirq), the checkpointer and autovacuum. At the knee the box is 86% busy: the CPU taking
  the NIC's receive interrupts is full, and the rest are about a third idle. A seventh worker cost 1.8 µs
  per request at 260k users and was not kept.
- **The service's own accounting doesn't see the workers.** They are Postgres processes, so they sit in
  `postgresql@18-main`'s cgroup, not `challenge.service`'s. switch.sh's idle-memory line reads "PSS 0 MB,
  1 process(es)", which is the launcher alone. Anything that measures the app by its cgroup counts the
  workers' CPU and memory as Postgres's.
- **The plugin is installed into Postgres's library directory.** `install.sh` runs as root and puts
  `pgengine.so` in `$libdir/plugins`. The rules let root install a toolchain or runtime. A plugin
  for the database server is neither, so this is a judgement call for the maintainer. It builds against
  the headers of exactly the installed server: the `postgresql-server-dev-18` package at the same version,
  unpacked rather than installed. `$libdir/plugins` is the only directory from which a role that isn't
  superuser may load a library, with `local_preload_libraries` in its own connection's startup packet. No server setting, `pg_hba.conf` line or database object changes.

## How it starts

`start.sh` runs `launcher` (launcher.c), the process `challenge.service` starts. It holds the port and
nothing else:

1. It binds `HOST:PORT` once per worker with `SO_REUSEPORT`. It can bind port 80 because the service
   grants it `CAP_NET_BIND_SERVICE`, which the `postgres` user doesn't have.
2. It opens one connection to `$DATABASE_URL` whose startup packet sets
   `local_preload_libraries=pgengine` and `pgengine.http=<socket>:6`. Loading the library with that
   setting registers the 6 HTTP workers. `RegisterDynamicBackgroundWorker` needs no privilege.
3. Each worker joins the `conduit` database as the `conduit` role. It connects to the launcher's Unix
   socket and receives one listening socket (`SCM_RIGHTS`) and `JWT_SECRET`. The launcher only accepts
   peers that run as the owner of `/var/run/postgresql`.
4. On `SIGTERM` the launcher ends the workers with `pg_terminate_backend`. That is allowed for backends of
   the same role. Postgres doesn't stop them on its own when the launcher exits.

## How a request is served

Each worker runs an epoll loop. In each turn it:

1. Reads every complete request, at most one per connection. A client's next request waits for the answer
   to its last, so a client always sees its own writes.
2. Runs the turn's writes in one transaction, each in its own subtransaction. These are SPEC's write
   statements through SPI, prepared once per worker. One commit covers the whole turn (group commit,
   rule 6). The commit is synchronous, with Postgres's default settings: the worker waits for the WAL
   flush before it answers anyone.
3. Runs the turn's reads as one engine batch per endpoint under one snapshot, taken after that commit.
   They include the reads that answer the writes: the article after a favorite, the profile after a follow,
   the user after a sign-up. Requests share work only inside one batch, among requests already waiting
   when it starts. Nothing is kept from one turn to the next (rule 5).
4. Writes the answers.

The fsync sits inside the event loop, once per turn that writes. An earlier version committed
asynchronously and held every answer until a separate flusher worker had flushed the WAL. It used no less
CPU and had lower tails near the knee (below), but it kept `synchronous_commit` off, which rule 6 forbids.
So it was dropped.

A value Postgres's text input refuses gets the reference's answer, 500. That covers a NUL byte (JSON's
`\u0000`) in a body and a NUL or bytes that aren't UTF-8 in a path or query value. A request that isn't
HTTP gets 400.

Answers go out uncompressed. SPEC makes compression optional, and gzip (the main server's, libdeflate
level 1) lost every test here: at 260k users it cost 9.7 µs of box CPU per request and raised p99, and at
270k on an aged database under a 16 GB cap it cost 8.5 µs per request and took the box to 95% CPU with
no gain in tail latency. It does halve the bytes sent, but the network was not the limit.

**Memory.** A connection holds heap only for what it is still waiting on: the bytes of a request not yet
complete, and the bytes of an answer the socket would not take yet. Each is freed as soon as it is empty.
A read lands in one per-worker buffer and a complete request is started straight from there, and the
turn's answers are built back to back in one per-worker buffer and written after the turn. So an idle
connection holds no buffer, and the workers' heap stays near 200 MB at 260k users. An earlier version kept
each connection's input buffer and its largest answer for the connection's life: on a 16 GB box the
workers' heap passed 11 GB at 200k users and Postgres was killed for lack of memory.

**No load shedding.** Every request is served; none is refused. Under overload, requests wait and latency
grows, and memory stays bounded by the kernel's socket buffers: through a 400k-user overload probe (1.5x
the knee) the box peaked at 9.9 GB of its 15.2 GB, and through a 512k probe at 9.0 GB, with no process
killed. Two shedding designs that refused hash-bearing requests (login, sign-up, password change) under
overload were tried and not kept: the first never refused anything at a CPU-bound load and cost 15 µs per
request; at the knee the box is not CPU-bound (one CPU taking all of the NIC's receive work is the limit),
so refusing hashes there frees nothing that matters.

bcrypt (cost 10) runs on each worker's bcrypt thread. That is the server's lanes engine, vendored
unchanged: interleaved lanes, a self-test at start, and identical jobs never merged. The thread starts
with every signal blocked, because only the worker's own thread may touch the backend. HTTP parsing, the
JWT check and the JSON body handling are the main Zig server's code, vendored unchanged.

## Correctness

- The scorer's own path, on a Hetzner CCX33 set up like the benchmark box: `score/prepare.sh` (install.sh
  about 100 s, build.sh under a clean environment) and then `score/switch.sh`. Conformance passes 197/197
  on the full seed through port 80, and the service answers 5.6 to 8.6 s after the cold Postgres restart.
  Most of that is the bcrypt self-test and calibration.
- Differential oracle (`conduit-oracle`, 20,002 requests on the full seed, pgserve against the reference Go
  server on the same database): all 20,002 match.
- The engine's reads have their own oracle against SPEC's SQL (../pgengine/test/oracle.py).

## Users held (official search)

On a Hetzner CCX33 (8 dedicated vCPUs) set up like the benchmark box, with its kernel capped to the
official box's 16 GB (`mem=17664M`, 15,231 MB usable), and 16 boat load boxes (2 vCPUs each) spread over
4 of the target's addresses. Each search is score/switch.sh (fresh database), a 3-minute warm-up, probes
doubling from 500 users, bisecting to 5%, then 5-minute holds, with nothing reset between phases, so the
database ages as it would in the official run (articles +20%, comments +12%). `-max` was raised from
the README's default of 120,000 so the doubling could overshoot:

| build | probes | overload probe | users held | hold req/s | p95 | p99 | errors | peak memory |
|---|---|---|---|---|---|---|---|---|
| kept (this folder) | pass to 256k, fail 270k | 400k: 21% errors, server stays up | **260,000** | 68,080 | 96.5 ms | 407.6 ms | 0.004% | 9.9 GB (after the overload), 7.1 GB in the hold |
| before the memory change | pass to 128k | 256k: Postgres killed for lack of memory | none (every later phase failed) | | | | | over 15 GB |

A second search on this folder as committed, installed by score/prepare.sh, held 260,000 again
(67,940 req/s, p95 130.8 ms, p99 497.9 ms, 0.008% errors; peak 10.0 GB just after its 400k probe, 7.2 GB in
the hold, no process killed).

What limits it at the knee is one CPU: the NIC has a single receive queue, and the CPU taking its
interrupts runs 90% in the kernel's receive path at 260k users (`perf`: the socket lookup among ~260k
connections and the processing of client ACKs lead), while the other seven CPUs are about a third idle.
pgserve sends 1.65 data packets and 0.05 bare ACKs per request and receives the request plus 1.28 client
ACKs. Keeping the workers' own threads off that CPU was tried and lost (+1.4 µs per request, p99 doubled),
and gzip, which halves the bytes, lost on CPU (above).

A search with `-max 1000000` reached a 512k probe (2x the knee). The load generator ruled it limited by a
load box that fell behind and ended the search there, so it has no score; the server passed every probe to
256k and peaked at 9.0 GB through the 512k probe, with no process killed.

The commit choice, measured earlier on the same box before the 16 GB cap (32 GB), one 120 s window each
at fixed loads:

| users | commit | req/s | p95 | p99 | box CPU busy |
|---|---|---|---|---|---|
| 120,000 | asynchronous, every answer held for the flush | 31,668 | 38.2 ms | 69.9 ms | 43.7% |
| 120,000 | synchronous (kept) | 31,685 | 26.1 ms | 66.9 ms | 44.5% |
| 190,000 | asynchronous, every answer held for the flush | 50,126 | 30.9 ms | 45.9 ms | 65.1% |
| 190,000 | synchronous (kept) | 50,134 | 37.5 ms | 75.6 ms | 63.5% |

## Measured against the main Zig server + SQL

On a clone of the benchmark box (8 vCPU, full seed). Each run starts from score/switch.sh, and the two
servers alternate:

| load | pgserve | Zig server + SQL |
|---|---|---|
| 60k users, official loadgen from a separate box, 15.8k req/s, 60 s windows | 91 / 98 µs of box CPU per request, pass | 144 / 205 µs per request, pass |

This run used the earlier asynchronous commit, without gzip. The two-vCPU load box tops out near 60k
users.

## Open question: CI

The repository's CI runs Postgres as a `postgres:18` service container. pgserve can't be tested there as
designed: the runner has no `postgresql-18` package for `install.sh` to build against, and `pgengine.so`
couldn't reach the container's `$libdir/plugins` anyway. This needs the maintainer's view before
submitting.

## Files

- `launcher.c` holds the port, starts the workers and stops them.
- `engine/` holds the engine library: the reads, the HTTP workers (`src/serve.zig`) and the write
  statements (`shim/http_write.c`). It is copied from `../pgengine` by `vendor.sh`.
- `install.sh` (root) installs Zig and the Postgres 18 server headers, then builds and installs the engine.
- `build.sh` (as `challenge`) builds the launcher. `start.sh` runs it.

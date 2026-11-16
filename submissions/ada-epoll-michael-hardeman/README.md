# Ada / epoll / own Postgres client

Front: direct

| | |
|---|---|
| Language | Ada 2022, GNAT 15.2 (GNAT-FSF-builds), gprbuild 25.0 |
| HTTP | own HTTP/1.1 server on edge-triggered `epoll`, `SO_REUSEPORT`, one reactor task per listener |
| Postgres driver | own v3 wire client: SCRAM-SHA-256, prepared statements, pipelining, binary parameters and results |
| Other dependencies | none: SHA-256, HMAC, JWT, Base64, bcrypt and JSON are in `src/` |

```sh
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

## What makes this submission unique

Ada is a systems programming language for high integrity applications. It is great for any kind of programming task
but it also has some of the best tooling out there to write high integrity applications. The `gnatprove` formal proof
toolchain has the ability to prove the abscence of runtime errors or even program correctness. The former lets you
disable runtime error checks with full confidence your program will never need them and the latter will remove the
need for most unit testing.

The code here doesn't have any particularly novel breakthrough improvements; I'm essentially pulling many of the great
ideas others have already brought to the table. What is truly unique here is that I've used SPARK to prove abscence of
runtime errors, abscense of data races, memory safety etc. This lets me know that barring system memory starvation that 
this program should never crash.

I did this because I wanted to show off Ada.
Ada doesn't abbreviate or symbolize things and it can look like a bit of a wall of text at first. Many people see that
wall of text they have flashbacks to their worst Java moments. They just close the tab and ignore the language.
They don't read some and take note of how easy it is to read and understand the code, even as someone completely 
unfamiliar with the language. 
Sure, it may take more time to type out things the first time you write it, but it pays dividends when you have to 
read a bit of code you may not have written yourself or you haven't looked at in 6 months.
I wanted to show you can get top quality preformance and unbeatable reliability at the same time.
I hope you enjoy.

## Current state

- Reactor tasks parse HTTP, verify the JWT and validate bodies, then hand a job to a stage: read lanes, write
  lanes, or the bcrypt hashers. Completed jobs come back to their reactor over a queue and an `eventfd`.
- A bcrypt hasher takes up to 6 waiting jobs and checks their logins together, interleaving the key schedules:
  six cost-10 checks take 50 ms on one core, against 33 ms for one alone. Hashers take the newest jobs first,
  so a backlog times out the oldest logins (skipped once their client hangs up) instead of delaying them all.
- Read lanes each own one Postgres connection and take turns gathering: after a short window they take every
  read waiting and the batch planner answers them all in two pipelined round trips, one statement per kind of
  read over arrays of distinct keys, then one for article details and one for favorited/following flags.
- Each write lane owns one Postgres connection and pipelines each write's reference SQL.
- Writes use durable group commit: every write waiting goes out before one `Sync` (one implicit transaction,
  one WAL flush); if any fails, each is retried alone. Responses wait for `ReadyForQuery`.
- SQL is SPEC.md's reference SQL; a lookup followed by a write is one data-modifying statement. Writes that
  return an article are read back through the read lanes after their commit.
- Each reactor has its own descriptor table (`unshare(CLONE_FILES)`) and its own `SO_REUSEPORT` listener, so the
  service's descriptor limit applies per reactor rather than to the whole process.
- Jobs whose client hung up are skipped by the planner and the bcrypt hashers.
- No caches of any kind; every request reads Postgres.

## Settings

| Variable | Default | |
|---|---|---|
| `READ_WINDOW_MS` | 10 | how long the oldest read waits for others to join its batch (0 to 1000) |
| `STATS` | unset | `1` logs each lane's and hasher's batches, jobs per batch, queue wait, work and busy time every 10 s |

The tasks are fixed at compile time for the benchmark box's 8 cores (the Jorvik profile creates every task at
start-up): 4 reactors (`Server.Reactors`), 8 read lanes, 2 write lanes and 3 hashers (`Lanes`).

Build with `CONDUIT_MODE=debug bash build.sh` for all runtime checks, assertions and contracts.

## Proofs

The whole program is SPARK, proved free of run-time errors (silver). The program runs under the Jorvik
profile (`gnat.adc`), so GNATprove also proves it free of data races. The proofs also show that the planner,
the reactor and the lanes hand every job on, and the ownership checks that nothing they allocate leaks. What
stays outside SPARK, behind SPARK contracts: the syscall bindings, the bodies of the two protected queues (a
GNATprove 15 internal error on them) and the job handle a reactor keeps to flag a job abandoned. The release
build runs with checks suppressed (`-gnatp`) at no loss of safety. To re-run the proofs :

```
gnatprove -P conduit.gpr -XCONDUIT_MODE=debug --mode=silver --level=2 -j0
```

**SPARK newcomers be warned**

Running the provers is not a trivial computation task. It took about 10 minutes to fully prove the system on 
a Ryzen 9 9950X3D with 32 threads. It will lag your computer and take a while.

## Credits

This server is written from scratch in Ada, but its design comes from reading the top entries before writing a
line. They converged on the same architecture, and this submission follows the same design as everyone else.
Here are some of the main inspirations:

- [rust-epoll-theCatWisel](../rust-epoll-theCatWisel): the two-phase read planner (first what each request is
  about, then the union of articles enriched once), counts that settle at 1000 instead of counting on, ids
  sorted before they are bound, and `unshare(CLONE_FILES)` per event loop.
- [rust-epoll-WorriedArrow](../rust-epoll-WorriedArrow): its batched SQL (one statement per kind of read over
  arrays of distinct keys, `unnest ... WITH ORDINALITY`) was the reference the planner's statements were ported
  from; also write read-backs going through the read path after the commit, and the `STATS=1` log of batch
  sizes and timings every 10 s.
- [c-epoll-unorig-username](../c-epoll-unorig-username): flat statements with the joins done in the
  application, favorited/following flags fetched only for the pairs a response shows, and its interleaved
  bcrypt kernel as the reference point for ours (written in plain SPARK here instead of assembly).
- [swift-iouring-Tabonx](../swift-iouring-Tabonx): one planner shared by every reactor instead of one per
  reactor (its measurement: a per-reactor planner cost half again as much Postgres CPU), and its multi-lane
  bcrypt `expand0`.
- [zig-iouring-nick-potts](../zig-iouring-nick-potts) and [nish-std-amritk](../nish-std-amritk): a single
  box-wide planner, flags only for the pairs shown, sorted ids, and the advice to tune on an aged database
  with paired 5-minute holds; nish's measurement that gzip is a loss is why there is none here.
- Every top entry: own HTTP/1.1 on `epoll` with `SO_REUSEPORT`, an own Postgres wire client with pipelining
  and binary results, durable group commit (every pending write before one `Sync`, retried alone on failure),
  session settings in the startup packet (`jit=off`, no parallel workers), `SCHED_BATCH` and nice levels so
  bcrypt and the event loops yield to Postgres, and skipping work for clients that hung up.

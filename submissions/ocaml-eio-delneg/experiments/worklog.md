# ocaml-eio-delneg worklog

All numbers are local, on wsl26 (Ryzen 9 7900X3D under WSL2, kernel 6.18), not the grader's box.
Harness `lg.sh` (kept outside the repo): server + Postgres pinned to CPUs 0-7 (4 cores x SMT, like an 8 vCPU box),
loadgen on 12-23, `-think-scale 0.1`, so N users = 10N equivalent users. Postgres config = `box/pg-conf.sh` for
8 cores / 16 GB. Full seed. CPU per request = process CPU over the measured window / requests in it.

## Setup (1 Nov)

- Conformance 197/197 on x86_64 (wsl26).
- Exit 137 on agent-box: not reproduced on wsl26 (30 GB RAM); most likely the OOM killer on agent-box (15 GB,
  Postgres + full seed + 5000-user loadgen). Not chased further.
- Baseline (Opt's first version: 8 domains x 8 pg conns, one statement per request, libxcrypt bcrypt):

| users (eq) | req/s | p95 ms | p99 ms | app µs/req | pg µs/req |
|--:|--:|--:|--:|--:|--:|
| 20k | 5,312 | 1.3 | 1.8 | 191 | 305 |
| 60k | 15,804 | 7.1 | 12.9 | 156 | 310 |
| 80k | 18,774 | 114 | 162 | 152 | 265 |
| 120k | 17,309 | 502 | 816 | 196 | 245 |

  Ceiling ~18.7k req/s, all 8 CPUs busy. pg_stat_statements at 80k: global list 1.42 ms/call, feed 1.90 ms,
  tag list 1.01 ms, article 0.19, comments 0.20, global count 0.27, feed count 0.38. Lists dominate Postgres.
  bcrypt (libxcrypt, ~40 ms per hash here) is ~0.9 cores at 80k eq.

## Study notes

- #1 rust-epoll-theCatWisel (#143, 190k): 4 reactor threads, 8 read workers + 1 write worker each with ONE pg
  connection, batches in two pipelined round trips (phase A: ids per list kind over distinct keys with
  `unnest ... WITH ORDINALITY`; phase B: enrich each unique article/author once, flags by viewer), group-commit
  writes in one pipeline per batch, 4-lane bcrypt, session settings `plan_cache_mode=force_generic_plan`,
  `jit=off`, `max_parallel_workers_per_gather=0`.
- Our F# entry (PR #87, `fsharp-multicore-kestrel-uring`): same planner idea (from #47), 20 ms batch clock,
  5-lane bcrypt C core (from c-iouring-tigokraft #10, MIT), capped counts via `OFFSET 999 LIMIT 1` probes.

## Experiments

### E1 batch planner (kept)
Per domain, every waiting read goes into one batch (2 planner loops per domain, a batch = everything queued
after one `Fiber.yield`), phase A + phase B as in the F# entry. Session settings in the startup packet.
120k eq: before p95 502 / p99 816 ms (FAIL), pg 245 µs/req; after p95 59 / p99 81 ms (PASS), app 118, pg 141.
80k eq: pg 265 → 221 µs/req, p95 114 → 11 ms. Batches are small (artx ~15 articles per call).
Profile at 120k: artx 615 µs/call (tags subplan seq-scans all 200 tags per article), feed 867, comments 301.

### E2 tag ids + one read of all tags (kept)
artx returns `ARRAY(tag_id)`, phase B reads `SELECT id, name FROM tags ORDER BY name` once; GET /api/tags uses
the same read. 120k eq x2: pg 135 / 133 µs/req (E1 141), app 118 / 120, p95 39 / 43 ms (E1 59).

### Real-scale harness
`lgr.sh`: think-scale 1.0, 3 loadgen processes to 127.0.0.1/2/3 (64k source ports each), so connection counts are
real. E2 at 60k real users: 15.9k req/s, p95 7 ms, **RSS 2,552 MB** (~40 KB per connection), app 195 µs/req.
At the grader's ~190k connections that is ~7.6 GB. The scaled runs hid this (10x fewer connections).

### E3 connection loop without per-connection buffers (kept)
`idle.py` (20k connections, then a request on each): E2 35 KB/conn (Eio.Buf_read 2 KB + a 4 KB output Buffer that
grows to the biggest response + fiber), E3 **4.8 KB/conn**. A connection waits with `Eio_unix.await_readable`, reads
into the domain's buffer, and bodies are writer closures run straight into the domain's output buffer; the
socket is non-blocking and written with `Unix.single_write` (waiting with `await_writable` on a private copy if the
kernel buffer is full). 120k eq x2: app 117/119 → 115/111 µs/req, RSS 838 → 125 MB. 60k real: RSS 2,552 → 266 MB.
At equal req/s, real connections cost ~9% more app CPU than scaled ones (196 vs 180).

### E4 one central planner (kept)
One shared queue (Mutex) for every domain's reads, 4 planner loops on domain 0 with their own 4 read connections;
answers resolve the requesting fiber's promise and its body is written on its own domain. Writes keep per-domain
connections. 120k eq: pg 135 → 98 µs/req. DOMAINS=4 better than 8 (total 207/209 vs 217 µs/req).
Knobs on E3: OCAMLRUNPARAM s=1M app -8% but pg up (total ~same); DOMAINS=4 total 232 vs 249.

### E5 5-lane bcrypt (kept)
perf on E4: libcrypt = 42% of the app's CPU. The interleaved core from c-iouring-tigokraft (#10, MIT; 5 lanes as
in our F# #87) at -O3 -funroll-loops: 11.3 ms/hash with 5 lanes vs libxcrypt 36.2 ms (wsl26, one core); 6-8
lanes no better. 2 hasher threads take up to 5 queued hashes, waiting 30 ms for company when fewer.
120k eq DOMAINS=4 x2: app 110.5/110.4 → 93.4/92.5 µs/req, total 208/211 → 197/198. Login p50 44 → 75 ms.

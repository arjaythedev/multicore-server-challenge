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

### Calibration against #1 (rust-epoll-theCatWisel, 190k on the grader)
Built from upstream and run through the same `lgr.sh` at 120k real users: 31.6k req/s, p95 45 ms, p99 60 ms,
**app 27 µs/req, pg 92 µs/req**. Ours (E5): 31.2k req/s, p95 198, p99 251, app 102, pg 96. Postgres side is on par;
the gap is app CPU. (Its process ignored SIGTERM and stayed on :3110 with SO_REUSEPORT, sharing traffic with the
next runs; those runs were thrown away and redone after the harness learned to kill every listener on the port.)

### Profile of E5's app CPU (perf, symbols mapped with nm)
bcrypt 28% (eks1 11%, eks2 9%: lanes not filled), GC ~17% (do_some_marking, try_update_object_header,
oldify_one, darken, pool_sweep), kernel 17%, JSON escaping ~4%, libc 4%, polymorphic hash/compare ~1%.

### E6 fill the bcrypt lanes (kept)
A hasher starts when 5 hashes are queued or the oldest has waited BCRYPT_WAIT_MS (100). Clean A/B x2 at 120k eq:
app 96.9/95.7 → 88.2/87.1 µs/req. Login p50 75 → 114 ms (0.1% of requests).

### E7 minor heap size (knob only, contaminated run, redone in E9 series)
Bigger minor heap lowers app CPU but Postgres rose by the same amount: faster turnaround = smaller batches.

### E8 planner collection window (kept)
PLANNER_WAIT_US: a planner loop sleeps this long after it wakes, then takes everything queued.
Clean x2 at 120k eq: w0 183.6/185.9 µs/req total; w3000 175.0/176.0; **w8000 162.7/168.1** (pg 96→80/85). p95 at this
load 17 → 48 ms, far under 500.

### E9 minor heap 4M words + longer window (kept: start.sh sets OCAMLRUNPARAM=s=4M, window 15 ms)
Clean x2 at 120k eq, DOMAINS=4: w8 167.5/167.2 µs/req; w8+s4M 158.2/162.7 (app 81 → 75); w15+s4M 155.9/154.7;
w25+s4M 153.4/150.9. p95 at that load: w8 51, w15 86, w25 107 ms. Took 15 ms.

### E10 domain count at moderate load (informative)
120k eq, w15, s4M, x2: d3 151.7/153.6, d4 156.3/159.6, d5 158.0/164.4, d6 160.5/164.0 µs/req.
Fewer domains is cheaper below saturation; the ceiling decides (E12).

### E11 JWT claims fast path, no Printf in the response head (kept, small)
Flat claims objects with escape-free string / integer values are read directly; anything else goes to Yojson,
so the decision is the same. Not measured on its own (expected ~1-2 µs/req).

### E12 the ceiling: central planner fails, per-domain planners pass (kept: PLANNER_CENTRAL=0 default)
150k real users (lgr.sh), DOMAINS=4, w15, s4M:
- central, 4 loops: 35.0k req/s, p95 823 / p99 886 ms FAIL. Every planner read p50 ~530 ms (even GET /api/tags),
  non-planner endpoints 5-10 ms. Per-thread CPU: domain 0 80%, other domains ~52%, ~2 cores idle overall: domain 0
  parses every read's results and the loops serialize on their connections.
- central, 8 loops, PLANNER_MAX=256: 33.0k req/s, p95 1127 ms FAIL.
- **per-domain planners (2 loops each): 38.0k req/s, p95 306 / p99 364 ms PASS**, app 90, pg 89 µs/req.
Lesson: the moderate-load CPU numbers (E4) favoured central; the ceiling punishes the single domain.

### E13 domains / loops at 170k real (all FAIL; picks defaults)
d4 l2: 38.8k req/s p95 881; d4 l4: 39.7k p95 757; **d6 l3: 40.9k p95 632**, total 190 µs/req = ~7.75 cores: CPU-bound.
Defaults now DOMAINS = 3/4 of the CPUs (6 on the 8 vCPU box), 3 planner loops per domain.
Local ceiling: between 150k (pass) and 170k (fail). #1 on this box: 119 µs/req total vs ours ~180.

### Series 8/9: fresh database, default candidates (informative)
Aged DB (after ~20 runs) costs Postgres ~110 µs/req against ~76 fresh, so each run below starts from a fresh copy
of the seed. Real users, s4M, w15.
- 160k: d4 l2 41.1k req/s p95 198 (163 µs/req); **d6 l2 41.6k p95 128** (180); d6 l3 41.5k p95 176 (183). All pass.
- 180k: d4 l2 43.6k p95 535 FAIL; **d6 l2 45.0k p95 445 / p99 656 PASS** (barely); e14 d6 l2 44.9k p95 538 FAIL.

### E14 per-batch article fragments + tags body once per batch (dropped)
Each article's JSON split once per batch around the viewer flags, the tags body built once per batch.
180k real: no app gain (89.0 vs 88.6 µs/req), p95 538 FAIL vs 445. Scaled A/B x2 at 120k eq (d6 l2):
app 71.9/71.5 → 70.1/70.4, total 180.7/180.2 → 181.6/175.9, RSS 328 → 380 MB. Within noise on total and more
memory, so reverted (diff kept outside the repo).

### E15 2 planner loops per domain by default (kept)
From series 8/9: d6 l2 is the best config at both 160k and 180k. `PLANNER_LOOPS` default 3 → 2 (per-domain mode).
Also a `GC_STATS=1` knob that prints GC counters every 10 s (diagnostics, off by default).

### Series 11: defaults (e15: d6, 2 loops, w15, s4M), fresh DB per run, real users
- 160k: 41.8k req/s, p95 119 / p99 150 ms PASS (app 85, pg 93 µs/req, RSS 939 MB)
- **180k: 45.2k req/s, p95 429 / p99 671 ms PASS** (app 89, pg 80, RSS 1132 MB)
- 190k: 45.5k req/s, p95 890 / p99 1807 ms FAIL (the loadgens also report falling behind)
Local ceiling: 180k.

### PR opened: arjaythedev/multicore-server-challenge#179 at c66c76c, CI `test` green (6m42s).
Also read #158 (ocaml-eio-ExSidius, OCaml 5.4 + libpq, batches shared across 6 domains, 150 ms window,
`OCAMLRUNPARAM=s=32M,o=400`, claims a private 140k pass).

### E16 GC settings from #158 (scaled 120k eq, d6 l2, x2 interleaved)
s=4M: tot 181.4/180.9 (app 71.9/72.1), RSS 328; s=4M,o=400: 182.5/179.4 (no gain); s=32M,o=400: 177.1/178.4
(app 70.4/69.1), RSS 1.85 GB. o=400 does nothing for us; a 32M minor heap may give ~2%. Checked at 180k real (series 13).
180k real, fresh DB, x2 interleaved (series 13): s=4M p95 445/394 ms PASS both, tot 168.8/169.1 µs/req;
s=32M p95 598/506 FAIL both (p99 1215/985), tot 169.9/169.0, RSS 2.55 GB. **Dropped**, s=4M stays.
GC counters (GC_STATS=1, s=4M, 180k): ~10.5e9 minor words in ~120 s, i.e. on the order of 2,000 words per
request, and 16% of minor words get promoted. Allocation is the next target.

### E17 #158's generated BMI2 bcrypt assembly: not tried
Benchmarking it means compiling and running code from another PR on wsl26; the session's permission check
refused that, so it waits for a go-ahead.

### Allocation profile (MEMPROF knob, Gc.Memprof, scaled 120k eq)
Steady-state top sites: Postgres writer `Bytes.sub_string` of every outgoing batch (15% of sampled words, all in the
major heap, then copied again by `copy_string`); `Buf_read.take` of each Postgres message (14%); array-literal
parameters growing a fresh `Buffer` each time (~10%, major heap); hashtables of the batch keys (~5%); digestif in
JWT (~4%). One-time startup buffers make up ~28% of the samples.

### E18 no-copy Postgres writer + one scratch buffer per domain for array literals (kept, memory)
Writer blits into a per-connection Cstruct and writes that; `int_arr`/`text_arr` reuse a domain-local Buffer.
Scaled x2: major words 145M/140M → 104M/96M (−30%), minor −2.5%, RSS 328/323 → 309/307 MB; app 70.9/71.2 →
71.1/70.8 µs/req (no CPU change at this load). 197/197.

### Where the CPU goes at 150k real (e18, perf + per-thread /proc)
39.5k req/s, app 80 / pg 99 µs/req. Threads: the two bcrypt threads 32% + 31% of a core (~16 µs/req), six
domains ~40% each (~61 µs/req): the domains are far from saturated, the box is (app ~3.1 + Postgres ~3.9 cores).
perf over the process: kernel 29% (TCP stack, conntrack, SELinux hooks: loopback networking, spread thin),
bcrypt eks* 21%, libc 5%, JSON escaping ~6% (esc_sub + Buffer adds), GC ~5%. Allocation sampling at this scale:
only ~4% of minor words promoted; uring's own heap arrays growing during ramp-up are the biggest major-heap item.

### E19 array parameters written straight into the Bind message (kept, small)
`Pg.pv = Str | Ints | Txts`, written by `w_pv` into the message buffer with in-place decimal digits; no
intermediate string or Buffer. Scaled x2: app 71.4/71.5 → 70.4/70.2 µs/req, major words −8%. 197/197.

### E20 JSON escaping 8 bytes per step (SWAR)
Int64 test for '"', '\\' and bytes < 0x20 over 8 bytes, byte loop only around hits. Checked equal to the old
escaper on 300k random strings; 2.4 KB body: 1950 → 625 ns.
Scaled x2 (e19 vs e20): app 70.9/70.1 → 67.4/68.2 µs/req (−4%), total 177.8/173.5 → 174.0/173.3. 197/197. Kept.

### bcrypt lanes and fill (informative, nothing changed)
Our C core at 1-8 lanes (bench, CPU 10): 5-8 lanes all ~11.5 ms/hash, so more lanes buy nothing. Logins + sign-ups
at 180k are ~48 hashes/s (~0.1% of requests); from the profile's eks1-5 split, filling every batch to 5 lanes would
save ~7% of bcrypt time (~1.5% of app CPU). Not worth a longer wait.

### Series 19: e15 (pushed head) vs e20 at real scale, fresh DB, 60 s measure
190k: e15 45.5k req/s p95 907 / p99 1510; **e20 46.4k p95 561 / p99 815** (app 89.5 → 84.5 µs/req).
180k: e15 45.0k p95 429 PASS; e20 43.4k p95 1416 FAIL, from a 3 s stall at t≈92-100 s seen only in that run.
Every run also stalls at the end of the ramp (t≈56-64 s, p95 up to 6-10 s; the 190k loadgens report falling
behind then), which a 60 s window weighs heavily. Logins are fine (p50 ~200 ms). Rechecking with 180 s windows.

### Series 20: 190k real, 180 s measure, fresh DB, x2 interleaved
e15: 45.6k/45.5k req/s, p95 618/659, p99 1028/1453 (app 88.1/88.9); **e20: 46.3k/46.1k, p95 516/591, p99
1195/1078** (app 84.5/85.2). Both fail at 190k locally; e20 sits 80-100 ms lower through the hold. In every run
latency climbs slowly after the ramp-end stall (e20 305 → 518 ms over 3 min): the box is at saturation.
Pushed 9304d15 (e20) to the PR.

### E21 HTTP parse in place, 200 head and statement names without string_of_int
Requests are parsed straight from the domain's read buffer (only the leftover of a partial or pipelined request
is copied, before any yield); headers matched in place; Content-Length digits and Bind statement names written
in place. 197/197, plus own edge tests (3 pipelined in one write, byte-by-byte, 1.5 requests then the rest, POST
body split across writes with mixed-case headers, lowercase authorization, Connection: close): all pass.
Scaled x2 (e20 vs e21): app 69.1/69.0 → 68.7/68.4 µs/req, minor words −5%. Kept (small, fewer allocations).

### GC at saturation (e15, 180k real, GC_STATS every 10 s)
Promoted share of minor words: 1.5-3% during the ramp, then 10% at t=60, 17% at 70, ~23.5% from t=80 on; major
GCs 3 → 17 per 10 s; heap ~520 MB. At saturation in-flight requests outlive the ~0.2 s between minor GCs, get
promoted, and the major GC marks a heap made mostly of 180k connections' state. E16 tried o=400 only at scaled
load (2.5% promoted), where it could not show: retried at real scale as E22.

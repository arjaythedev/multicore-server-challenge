# Rust / Tokio / PostgreSQL

Front: direct

This is an experimental extension of [Scooter1337's Rust/Tokio submission](../rust-tokio-Scooter1337),
which builds on [cknutson12's Rust/Hyper submission](../rust-hyper-cknutson12). Their code and licences
are retained. It is a local candidate, with no official challenge score.

Rust 1.99.0, Tokio 1.53.2, vendored tokio-postgres 0.7.18 and mimalloc 0.1.52.
All Rust dependencies are pinned in `Cargo.lock`. The native bcrypt implementation derives from
Openwall/libxcrypt 4.4.36. Its authors and licence are retained in `native/`.

```sh
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=example-local-key HOST=0.0.0.0 PORT=80 bash start.sh
```

## Changes from the baseline

- Global, tag and feed counts, which usually reach the cap, step to the 1,000th row and stop instead of
  counting up to 1,000 rows through an aggregate. Author and favourited counts are usually far below the
  cap, so they count in one pass rather than walking their rows twice. Postgres is the bottleneck on the
  benchmark box, and the counts were about a third of each list statement. Results are identical.
- A read connection that finds its queue empty sleeps briefly before executing, so concurrent requests
  share one batch instead of each paying a round trip. `READ_BATCH_US` defaults to 300, but Tokio's timer
  rounds up to its next millisecond tick, so the real wait is under about a millisecond. Under load the
  queue is never empty and nothing waits. In six paired local runs this cut Postgres CPU per request by
  about 6%.
- List statements read the viewer's followee set once instead of probing `follows` for every article.
- Comments join the existing array-parameterised read batching. Each request keeps its own viewer,
  article lookup and at-most-100-comment result. The outer query orders by request ordinal, comment
  timestamp and comment id, preserving the original per-request order. Missing articles still return 404.
- When at least half of a batch of list requests repeat the same filter and page, the batch shares work
  within one SQL execution. Each distinct filter is counted once, each distinct page is selected once and
  each distinct article is enriched once. Each viewer's followee set and its favourites among the page are
  read once. Viewer-specific flags stay separate. Batches of three or more personal feeds share article
  enrichment the same way, while each feed keeps its own page and count. Small or mixed batches use the
  baseline queries. Results never survive an execution.
- Shared batches look tag names up once per execution. All the page's tags are joined to one small hash of
  the 200-row `tags` table, instead of two index reads per tag. On aged data this cut feed buffer reads
  by about 7%.
- At startup the server reads the database collation. Under `C` or `C.UTF-8`, which order text like its
  UTF-8 bytes, Postgres no longer sorts tag names per article or for the tag list, and the server sorts
  them while writing the JSON. Any other collation keeps the sorts in SQL. In a profile these sorts were
  about 2% of Postgres CPU, and the tag list alone sorted all 200 names on every call.
- Comments route to connections already holding comment requests, like the other batched families.
- Personal feeds return `following: true` because their article selection already joins the viewer's
  follows in the same statement snapshot. This removes a redundant index probe per returned article.

The sharing threshold follows local full-seed SQL measurements. Broad sharing made mixed groups
slower and was removed. Query-level savings are conditional on duplicate concurrent work and do not
establish an end-to-end capacity improvement.

## Existing techniques retained

- Direct HTTP/1.1 with compact idle connection state, borrowed request data, pooled buffers and vectored writes.
- Prepared generic plans and PostgreSQL binary results, with pipelined messages and batched compatible reads.
- Pagination before article enrichment, primary-key tag lookup, bounded generic-plan cardinality and
  capped counts. Concurrent list requests can share article metadata within an execution.
- Bounded read-family routing and separate read/write connections. Durable group commit waits for
  PostgreSQL's successful commit before releasing write responses. Errors drain before connection reuse.
- Existing tags are read without needless updates. New tag inserts are ordered to reduce deadlocks.
- HS256 signature and expiry checks on every authenticated request. Bcrypt cost 10 with bounded
  workers and up to four independent hashes interleaved. No token or password-result caching.
- Fat LTO, one codegen unit and mimalloc. No host tuning, CPU affinity or schema changes.

On eight available CPUs, the inherited defaults are two Tokio workers, six read connections,
two write connections and one bcrypt worker. Existing process settings are documented in the
[baseline README](../rust-tokio-Scooter1337/README.md). No extra settings are required.

## Validation

The candidate passes all 197 official conformance checks on both dev and full seeds. Both generated
seeds match the upstream fingerprints. Concurrent read comparison covers 470 cases, including different
viewers, ordering, missing articles and empty pages. The database regression test compares batched
rows against individual queries, including both comment-follow query variants. Clippy passes with warnings denied.

```sh
bash test/run.sh submissions/rust-tokio-semyonfox
TEST_DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit_dev READ_COMMENT_SET=1 cargo test --locked batched_reads_match_individual_queries -- --ignored
TEST_DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit_dev READ_COMMENT_SET=0 cargo test --locked batched_reads_match_individual_queries -- --ignored
cargo clippy --locked --all-targets -- -D warnings
```

Run the first command from the challenge root and the Cargo commands from this folder.
Use an unchanged generated seed for the database regression test. It performs reads only.
The localhost URLs and key above are examples for disposable development data.

## Local measurements

Postgres is about 70% of the benchmark box under the base, so the number that matters is Postgres CPU per
request. Locally Postgres 18 runs in its own container (four-CPU quota, 3 GiB, 512 MiB shared buffers), so its
cgroup CPU time over the measured window, divided by requests served, isolates that cost from the load
generator sharing the host. Each run uses a fresh full-seed copy, 3,000 users at think scale 0.1 (about
7,500 req/s, Postgres near its quota), a 20-second ramp and a 60-second window. Variants alternate to spread
host drift. Two machine-learning jobs were also running on the host, so single runs vary by about 15%.

| Run | Postgres µs/req | App µs/req | req/s | p99 ms | Errors |
|---|---:|---:|---:|---:|---:|
| baseline | 321.5 | 119.7 | 7,551 | 108 | 0 |
| candidate | 287.6 | 123.2 | 7,537 | 98 | 0 |
| candidate | 275.5 | 115.7 | 7,269 | 175 | 0 |
| baseline | 277.6 | 114.5 | 7,099 | 183 | 0 |
| baseline | 292.2 | 117.1 | 7,348 | 116 | 0 |
| candidate | 281.9 | 114.8 | 7,440 | 102 | 0 |

Mean Postgres CPU per request: 297.1 µs for the baseline, 281.6 µs for this candidate, 5% lower. App CPU is
unchanged. An earlier four-run comparison gave 6% lower. This is a local measurement, not a score.

The 300 µs read window was measured the same way, each run next to a run without it: 308, 314, 310, 294,
280 and 265 µs against 323, 329, 326, 319, 273 and 315 µs. Tail latency stayed within run-to-run noise.

Two other ideas were measured and dropped. Running the bcrypt thread at `SCHED_BATCH` and nice 10 halved
p95 in quiet runs, but when the host saturated, login p95 rose past 3 s because the deprioritised hash
thread was starved. That would fail the benchmark at exactly the load that sets the score. Disabling
`enable_memoize` for the session made no consistent difference.

### Second iteration, aged database

The scored run never resets the database between warm-up, probes and holds, so the hold runs on data that
has absorbed many minutes of writes. These runs therefore use a template that first took 20 minutes of the
same load (153k favourites, 107k comments, 46k follows and 34k articles written) and a Postgres configured
with the box's `box/pg-conf.sh` planner settings. The profiler uses six read connections, as on the box,
and also reports shared-buffer accesses per request, which host noise does not change. The host was fully
busy with unrelated jobs during these runs.

| Run | Postgres µs/req | Buffers/req | req/s | p95 ms | p99 ms | Errors |
|---|---:|---:|---:|---:|---:|---:|
| before | 302.5 | 109.9 | 7,083 | 141 | 271 | 0 |
| after | 314.4 | 103.4 | 7,358 | 83 | 142 | 0 |
| before | 300.7 | 109.8 | 7,111 | 118 | 355 | 0 |
| after | 303.0 | 102.8 | 7,445 | 66 | 100 | 0 |
| before | 304.5 | 111.0 | 7,272 | 101 | 161 | 0 |
| after | 298.1 | 103.3 | 7,441 | 77 | 136 | 0 |

Buffer accesses fell 6% in every pair and throughput rose about 3.5% at the same user count, with clearly
lower tails. Postgres CPU per request did not move outside the noise of a saturated host.

Measured and dropped in this iteration: weighting connection load by family cost (more Postgres CPU and
lower throughput in both runs), looking articles up by the id in their slug (25% slower with a regex, no
difference with the id parsed in the app), building tag names with one grouped join for a single request
(no difference, though the same join over a whole shared batch helps, as above), and read batch size 64 (one good and one very bad run). A 0 or 2 ms read wait was within noise
of the default. Seven read connections gave the best tails locally (p95 66 and 71 ms against about 110 ms)
at equal CPU. That is worth testing on the real box but is not the default.

### Third iteration, profile-guided

A `perf` profile of the Postgres backends under load on the aged database put 90% of Postgres CPU in the
executor and 10% in the kernel. Most of it went to index lookups the queries need. Two changes came out of it.

Tag names per shared batch: in three interleaved pairs on aged data, buffer accesses per request fell from
101.5, 101.6 and 99.0 to 100.2, 99.9 and 96.8, and throughput rose 3 to 5% in every pair. Postgres CPU per
request moved by -3% to +1%, within the noise of a fully busy host.

Tag sorting under a byte-order collation, measured with pgbench on a `C.UTF-8` copy of the full seed, best
of three runs: the tag list statement took 0.065 ms instead of 0.081 ms, and tags for a 10-article page
0.174 ms instead of 0.180 ms. Three interleaved end-to-end pairs on that copy averaged 317 and 316 µs of
Postgres CPU per request, so the gain is below what this machine can resolve. Conformance and the
concurrent read comparison pass under both `en_US.utf8` and `C.UTF-8`, and the batched-read regression
test runs on both.

Measured and dropped: five bcrypt lanes instead of four and XORing each round key in before the S-box
loads (both within noise of the current code on an i7-8750H), and sharing comment lists within a batch
(only 0.4% of batched comment requests repeated an article).

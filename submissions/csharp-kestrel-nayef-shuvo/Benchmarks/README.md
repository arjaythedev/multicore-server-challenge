# Benchmarks (BenchmarkDotNet)

Micro-benchmarks for the server's hot code, to measure a tweak before and after. This is a separate project: the server
(`Conduit.csproj`) excludes this folder and `build.sh` never builds it. It compiles the server's own source files
(`Http.cs`, `Auth.cs`, `Bcrypt*.cs`, `BlowfishConstants.g.cs`, `Db.cs`, `Sql.cs`, linked from `..`), so every run measures the code as it is on disk.

## What is measured

| Class | Code under test | Notes |
|---|---|---|
| `HttpBenchmarks` | `Http.cs`: `ReadWrapper` + `ReqString` (register, create article), `Json` (a 20-article page, 200 tags), `Error`, `ParseUint` | the response goes to a writer that copies and discards, like Kestrel's pipe without the socket |
| `AuthBenchmarks` | `Auth.cs`: `IssueToken`, `Authenticate` (valid token, no header, bad signature) | the JWT work on nearly every request |
| `BcryptBenchmarks` | `BcryptCore` (1 to 4 hashes at once) against libcrypt and BCrypt.Net-Next, time per hash | about 25 to 65 ms each, so a few minutes |
| `QueryBenchmarks` | every statement in `Sql.cs` against a real Postgres, one at a time; each with and without Npgsql auto-prepare | needs a database (below) |

Not covered: the handlers in `Api*.cs` (they need the whole host and their helpers are private), so for example the
query-string loop in `ListArticles` has no benchmark. To measure one, move it into an `internal static` method in a file
that this project links (add a `<Compile Include=... />` line to `Conduit.Benchmarks.csproj`) and add a benchmark for it.

## Check bcrypt against other implementations

```bash
bash Benchmarks/run.sh --check      # about 20 seconds
```

Hashes made by `BcryptCore` in every grouping of 1 to 8 at once (so every lane kernel runs) must verify under libcrypt
(`LibcryptReference.cs`) and BCrypt.Net-Next, hashes made by those must verify under ours, and the worker-thread path is checked too.
Run it after any change to `BcryptCore.cs` or `Tools/gen_bcrypt.py`.

## Run

```bash
bash Benchmarks/run.sh before                       # Http, Auth and bcrypt benchmarks: about 6 minutes
bash Benchmarks/run.sh before '*HttpBenchmarks*'    # only what matches the filter (a BenchmarkDotNet glob)
bash Benchmarks/run.sh --list                       # every benchmark name
```

A run is saved under `Benchmarks/results/<label>/` (ignored by git), with a markdown table and the JSON.

### SQL benchmarks

They need their own copy of the seed (they only read it), and a Postgres reachable at `BENCH_DATABASE_URL`
(default `postgres://conduit:conduit@127.0.0.1:5433/conduit_bench`):

```bash
export PGHOST=127.0.0.1 PGPORT=5433 PGUSER=postgres PGPASSWORD=postgres
psql -d postgres -c 'CREATE DATABASE conduit_bench TEMPLATE conduit_dev'
bash Benchmarks/run.sh sql-before '*QueryBenchmarks*'
```

## Measure a tweak

```bash
bash Benchmarks/run.sh before '*HttpBenchmarks*'     # 1. run on the current code
# ...change the code...
bash Benchmarks/run.sh after '*HttpBenchmarks*'      # 2. run again with the same filter
bash Benchmarks/compare.sh before after              # 3. time and bytes allocated per operation, and the change
```

`compare.sh` marks a difference as `(noise)` when it is smaller than three times the runs' combined standard error. Trust
only unmarked changes, and repeat a run if a result looks surprising.

## Reading the numbers, and their limits

- **Mean** is time per call; **Allocated** is managed bytes per call (`Gen0` is the GC collections it causes per 1000 calls).
  A change that lowers allocations helps the server under load even if the mean barely moves.
- The benchmarks run **in-process on the JIT**, the server runs Native AOT. The ranking of two versions of a function is
  usually the same, but absolute times differ a little. Confirm anything that matters with the load tests (`test.md`).
- Quiet the machine first (close the IDE and VMs). `--job short` is for checking that a benchmark works, not for
  deciding: it runs 3 iterations and is noisy. Extra arguments after the filter go straight to BenchmarkDotNet.
- A micro-benchmark shows the cost of one piece. Most requests spend milliseconds in Postgres, so a saving of
  microseconds here can disappear in a load test: check the size of the piece (`QueryBenchmarks` and the tour) first.

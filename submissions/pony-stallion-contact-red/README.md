# Pony: Stallion + libpq

Front: direct

## Current Stack

| Piece | Version |
|-------|---------|
| ponyc | 0.77.0  |
| libpq | system package |
| stallion | becc51753ec076fdda011f7f9d5c73a50e814368 |

## Installation and Testing

`DATABASE_URL` and `JWT_SECRET` are required. `HOST` defaults to `127.0.0.1`; `PORT` defaults to `3000`. The binary's `--db-worker-count` option defaults to 8 and accepts values from 1 through 95. Production always uses 95 database connections, distributed as evenly as possible across those workers: the default is seven pools of 12 and one of 11. `DB_WORKERS` is no longer read. The database connection requires SCRAM authentication and disables TLS, matching the previous driver settings. On the benchmark box, direct serving uses `HOST=0.0.0.0 PORT=80`.

```sh
sudo bash submissions/pony-stallion-contact-red/install.sh
bash submissions/pony-stallion-contact-red/build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit \
  JWT_SECRET=development-secret \
  bash submissions/pony-stallion-contact-red/start.sh
```

Run wrapper tests with `make -C submissions/pony-stallion-contact-red test`. Run the challenge suite with `bash test/run.sh submissions/pony-stallion-contact-red` after creating the dev seed and configuring PostgreSQL access as described in the repository README.

`make -C submissions/pony-stallion-contact-red test-integration` creates temporary databases from `conduit_dev`, checks prepared-statement startup and execution, round-robin assignment, reconnect and failed-query handling, article tags, atomic article failure, concurrent tag conflicts, password bytes, and HTTP pipelining, then removes the databases. It needs Python 3, psql, and PostgreSQL superuser access through the usual `PGHOST`, `PGPORT`, `PGUSER`, and `PGPASSWORD` variables.

## Diagnostic build

> The metric reference and capture example in this section are outdated. The current diagnostic build emits schema 3 JSON records and Worker CSV on stdout, so the example's `metrics.ndjson` file contains mixed output. The schema 1 fields and Session metrics below describe the previous implementation and must not be used to interpret current output.

Set `CONDUIT_VARIANT=diagnostic` to build and launch `bin/conduit-diagnostic` with ponyc's `-Dconduit_diagnostic` define. The default `ordinary` variant builds and launches `bin/conduit`. Both variants use the same optimized compiler settings; neither uses ponyc's `-d` or `--debug` option.

```sh
diagnostic_dir=$(mktemp -d)
CONDUIT_VARIANT=diagnostic bash submissions/pony-stallion-contact-red/build.sh
CONDUIT_VARIANT=diagnostic make -C submissions/pony-stallion-contact-red test
CONDUIT_VARIANT=diagnostic make -C submissions/pony-stallion-contact-red test-integration
CONDUIT_VARIANT=diagnostic DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit \
  JWT_SECRET=development-secret \
  bash submissions/pony-stallion-contact-red/start.sh \
  > "$diagnostic_dir/metrics.ndjson" 2> "$diagnostic_dir/server.err"
```

Server-mode diagnostic stdout contains only newline-delimited JSON records with `kind: "conduit_diag"` and `schema: 1`. Keep stdout and stderr in separate private files: database errors on stderr can include data supplied in a query. Test modes retain their usual stdout messages. The first record has `owner: 0`, `worker_count`, and `period_ns`. Later `owner: 0` records contain `report_ns` and `next_request`. A Worker snapshot has `owner: 1`; a Session snapshot has `owner: 2`. Each snapshot carries `slot`, `generation`, `request`, `observed_ns`, `report_ns`, `overflow`, `invalid_clock`, `counters`, `gauges`, and `histograms`. A record with `missing: true` marks a request without a snapshot in that window. Its `reason` is `overdue` when a late snapshot may follow, or `unavailable` when the Session is closing or absent. Reporter-originated Worker missing records use `generation: null` because the reporter has not observed that Worker. Match these by slot and request. Match other records by slot, generation, and request, and compare only observation windows that overlap. A Session record with request 0 contains its final counters after shutdown accounting.

All counters are cumulative. Each histogram is a duration distribution in nanoseconds with `count`, `sum_ns`, `max_ns`, `overflow`, and 27 `buckets`: bucket 0 is zero, bucket 1 is 1–999 ns, buckets 2–25 double from 1,000 ns, and bucket 26 holds 16,777,216,000 ns and above. Numeric totals saturate at `U64.max_value()` and set `overflow`; `invalid_clock` counts discarded intervals whose finish timestamp preceded their start.

Worker counter positions are: 0 received, 1 accepted, 2 rejected after stop, 3 settled, 4 canceled after submission, 5 callbacks sent, 6 completed with result, 7 tombstone, 8 completed with failure, 9 canceled while pending, and 10 failed while pending on close. Positions 11–15 are reserved. Worker gauges are pending depth, submitted job depth, oldest pending age, oldest submitted job age, peak pending depth, and peak submitted depth. Worker histogram positions are operation-to-Worker mailbox delay, pending residence, and submitted job residence. Submitted depth counts the Worker's ledger entries; it is not the number of database commands executing.

Session counter positions are: 0 prepares accepted, 1 executes accepted, 2 prepares settled, 3 executes settled, 4 executes rejected after close, 5 prepares rejected after close, 6 executes without a send timestamp, 7 executes with a send timestamp, 8 `PQflush` returned 1, 9 `PQconsumeInput` calls, and 11 shutdown. Position 10 is reserved. Session gauges are serial queue depth, active command count, oldest queued age, and peak queue depth. Session histogram positions 0–9 are Worker-to-Session mailbox delay, serial queue residence, command lifetime, `PQsend*`, `PQflush`, `PQconsumeInput`, `PQisBusy`, `PQgetResult`, result decoding, and ASIO arm-to-handler elapsed time. The last measurement includes actor scheduling delay, so it does not isolate database or network wait. Positions 10–38 are command lifetimes for the statement kinds in `_Catalog.kind`, in that order; 39 is the unknown-kind overflow slot. Preparation also contributes to the common command and queue histograms.

The command lifetime starts when `Session` removes a command from its serial queue and ends when it settles the command. It is not PostgreSQL execution time. These probes do not measure a full HTTP request or the return mailbox to `_Connection`. Use the load generator's latency alongside these records, and use a separate CPU profile for CPU attribution. A missing or stale Session record leaves that interval unlocalized.

## How we use multiple cores

Pony is an actor-based language. By default, it starts one scheduler per available core; our benchmarks cap it at eight with `--ponymaxthreads=8`. Connection actors share those schedulers.

### Stallion

Stallion is Pony's HTTP server. Each connection opens up a separate _Connection actor. Each _Connection actor handles HTTP/1.1 protocols, keep-alive, and the application logic.  If you have 15,000 concurrent connections, there are 15,000 _Connection actors.

### _Worker

A `_Worker` actor owns a pool of libpq connections. By default, eight workers share 95 database connections. Each accepted `_Connection` is assigned a worker by round-robin and keeps that assignment. A worker queues queries from all of its HTTP connections in one FIFO and dispatches them to idle database connections. Each database connection executes one command at a time; commands on different connections can run concurrently and finish in any order. Successive queries from one HTTP operation can use different database connections in the same worker.

`_PGConnection`, `_PoolSlot`, and `_PGEvents` are objects owned by the worker, with synchronous method calls and callbacks. Socket readiness arrives as an ASIO message to that worker. Each pool slot connects, prepares statements, and recovers independently. Closing a `_PGConnection` unsubscribes its socket event; libpq frees the connection when the object is collected.

![Connection and database worker architecture](connection-architecture.svg)

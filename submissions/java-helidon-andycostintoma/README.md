# Java · Helidon SE

Front: direct

Java 25, Gradle 9, Helidon SE 4.5.6, jOOQ 3.21.9, pgjdbc 42.7.14, HikariCP 7.1.0 and PostgreSQL 18.6. Authentication uses java-jwt 4.6.2 (HS256) and bcrypt 0.10.2 (cost 10). No Jox or preview APIs.

## Local development

Requires JDK 25 and Gradle 9 on PATH, plus a running Docker engine. On the development Mac, Java and Gradle are managed globally through Home Manager, not a project flake.

```sh
docker compose up -d --wait
./build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit ./start.sh
```

The default listener is `127.0.0.1:3000`. Override `HOST` and `PORT` as needed. `JWT_SECRET` defaults to `multicore-server-challenge`; use a separate secret outside the challenge. Test with `curl http://127.0.0.1:3000/api/tags`.

`./build.sh` runs unit, architecture and HTTP/database integration tests, and creates the runnable distribution. Integration tests use disposable PostgreSQL Docker containers, separate from the persistent Compose database. `gradle clean test installDist` builds and runs unit tests without Docker or PostgreSQL.

Format handwritten Java with `./gradlew spotlessApply`; verify it with `./gradlew spotlessCheck`. Spotless uses pinned Eclipse JDT with four-space indentation and one record component per line, with the closing parenthesis on its own line. Its formatting check runs as part of `check`. Generated jOOQ sources retain the generator's formatting.

jOOQ sources are checked in under `src/main/java/conduit/generated/postgres/jooq` and excluded from formatting. After changing the upstream `schema.sql`, run `./gradlew generateJooq` with Docker available and include the regenerated sources with the schema change. Normal builds and `clean` do not regenerate or delete them.

To change the local database port, set `CONDUIT_PG_PORT` when starting Compose and use that port in `DATABASE_URL`. `docker compose down` stops the development database without deleting its data volume.

## Architecture and status

HTTP adapters call application usecases through explicit wiring, with one operation per class under `usecases/commands/` or `usecases/queries/`. Readers return projections from `contracts/<area>/readmodel/`; repositories load and persist domain entities, while transaction callbacks group their operations into one commit or rollback. Follows and favorites have dedicated relationship ports. Login uses a credential lookup rather than loading a domain entity through a query reader. Writes invoke domain behavior within application-owned transaction boundaries; response-enrichment queries run after commit. Login is a command that issues a token; verification of an existing token is a query. Generated SQL types and security libraries remain in outbound adapters. ArchUnit checks layer dependencies and prevents queries from depending on commands or write ports. The fixed pool uses 16 connections; HTTP keep-alive is five minutes. No response or authentication-result caches are used.

One `UnitOfWork` scopes users, articles, comments, follows and favorites to the same jOOQ transaction. User validation and password hashing stay outside it; article creation validates before allocating an id; registration tokens and response-enrichment reads happen after commit. Expected validation, authorization, missing-resource and conflict failures are typed `conduit.errors` exceptions, mapped to HTTP statuses in one central handler. Transactions roll back when the callback throws. The user persistence adapter translates only known username/email unique violations into conflicts; the unit of work handles transaction mechanics without user-specific error mapping. Unexpected infrastructure exceptions propagate to the central handler, which logs them and returns a generic 500 response.

Each HTTP endpoint has a dedicated handler with only its own dependencies; route classes only register paths and delegate to handlers. Route classes stay in their HTTP area packages, with endpoint handlers in child `handlers` packages. HTTP adapters use Jackson to decode typed user and article envelopes into application request records and wrap returned read models in HTTP response envelopes. Inbound adapters may depend on contract read models, but not contract ports. Decoding rejects scalar coercion and trailing JSON values while ignoring unknown fields. Handlers only check JSON shape; domain methods own field, tag, password and ownership rules and throw typed errors; handlers call usecases in straight-line code with no intermediate result wrapper.

All 19 endpoints are implemented. The upstream 197-step conformance suite passes against its verified development seed. Local benchmarks are development comparisons, not challenge capacity scores.

```sh
./build.sh
./conformance.sh
```

The conformance and benchmark runners require Docker Compose and Perl. Both use `compose.benchmark.yaml` to run the installed Java distribution, PostgreSQL 18.6 and upstream Go tools on a private Linux network with no published ports. Each invocation verifies a fresh development seed and cleans up only its own containers, network and volume. Logs and transcripts remain under `.local/`; the development `compose.yaml` and its database are untouched.

## Local performance baseline

```sh
make benchmark
BENCH_USERS="500 1000" BENCH_REPEATS=3 BENCH_MEASURE=300s make benchmark
BENCH_USERS=1000 BENCH_REPEATS=1 make profile
BENCH_USERS="32000 36000 40000" BENCH_REPEATS=1 BENCH_STOP_ON_FAIL=1 make benchmark
```

The runner uses the upstream load generator and verified development seed (10,000 articles), with normal seven-second mean think time. It warms the JVM, then repeats increasing loads. Defaults are 500/1,000/2,000 users, three repetitions, 120 seconds of warm-up, a 30-second ramp, a 60-second measurement and a five-second tail. Override `BENCH_USERS`, `BENCH_REPEATS`, `BENCH_WARMUP`, `BENCH_RAMP`, `BENCH_MEASURE` and `BENCH_TAIL` as needed.

Results remain under `.local/benchmark.*`: raw load-generator JSON, merged per-endpoint throughput/latencies/errors, JVM/run metadata, distribution SHA-256 hashes, server and PostgreSQL logs, and database statistics. `make profile` also records `profile.jfr`; open it in IntelliJ's profiler or JDK Mission Control to inspect CPU, allocation, GC and thread/socket waits. The recording includes startup and warm-up: select the measured interval before diagnosing steady-state hotspots. Profiling adds overhead: compare unprofiled runs for performance, then profile the problematic load separately. Database contents evolve during warm-up and repetitions, matching the upstream search workflow; compare equivalent complete runs, not arbitrary phases from different runs.

The upstream verdict checks p95 < 500 ms, p99 < 1 s and errors < 1%. Set `BENCH_MEASURE=300s` for a five-minute measured hold; short probes only locate a candidate boundary. All three services share the Docker VM's CPU and memory, and load-box CPU describes that shared VM, not just the generator. Check `lg_limited`, wake-up lag, application and PostgreSQL activity before attributing a limit to the server. Container client ports remain finite. These development measurements are not official challenge scores.

The runner pauses 30 seconds between phases for socket cleanup (`BENCH_PAUSE` overrides the seconds). `BENCH_STOP_ON_FAIL=1` stops increasing load on the first measured threshold failure (exit 3), or on load-generator limitation (exit 4, not evidence of server failure). Otherwise all requested repetitions run.

Measure before changing concurrency: inspect slow endpoint SQL and pool/thread waits first. Jox is only a candidate if profiling demonstrates a benefit from bounded cross-request batching; extra channels or parallel JDBC calls are not a baseline optimization.

## Challenge Linux setup

On Ubuntu 24.04 x86-64, run `sudo ./install.sh` once, then `./build.sh` as the unprivileged submission user. Installation pins checksum-verified Temurin 25.0.5+8 and Gradle 9.8.2 under `/opt/`. Linux builds use the checked-in jOOQ sources and run unit and architecture tests without PostgreSQL or Docker; set `RUN_INTEGRATION_TESTS=1` to include Docker-backed integration tests. Start with the challenge-provided `DATABASE_URL`, `HOST`, `PORT` and `JWT_SECRET` using `./start.sh`.

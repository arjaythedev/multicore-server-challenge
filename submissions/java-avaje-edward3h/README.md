# Conduit: Java 26 (Avaje, Helidon SE, kiwiproc)

**Front: nginx**

Plain Java on the [Avaje](https://avaje.io/) stack, with [Helidon SE](https://helidon.io/) as the HTTP server and
[kiwiproc](https://edward3h.github.io/kiwiproc/) for SQL. The package layout follows `examples/java` (one controller
per area, `Auth`, `Jwt`, `Body`, `Dto`, `ApiException`), with Avaje replacing Spring. One JVM; every request runs on its
own virtual thread. Annotation processors generate the routes, the JSON adapters, the validators and the DAO
implementations, so there is no reflection on the request path.

## Stack

| Piece | Version |
|---|---|
| JDK | Eclipse Temurin 26.0.2.1+1 (`install.sh` -> `/opt/jdk`), `--release 26` |
| Build | Gradle 9.5.1 via the checked-in wrapper (`./gradlew`), Kotlin DSL |
| DI | avaje-inject 12.7 |
| HTTP | avaje-http 3.12.1 annotations and `helidon` generator, on Helidon SE (WebServer) 4.5.6 |
| JSON | avaje-jsonb 3.16 |
| Validation | avaje-validator 2.18 |
| SQL | kiwiproc 1.0 (Gradle plugin), reference SQL from `SPEC.md` |
| Driver and pool | pgjdbc 42.7.14, HikariCP 7.1.0 (10 connections per core, capped at 95, set in `start.sh`) |
| bcrypt | `at.favre.lib:bcrypt` 0.10.2, cost 10 |
| JWT | hand-written HS256 (`javax.crypto.Mac`), in `Jwt.java` |

Avaje Config is not used: `Config.java` reads `DATABASE_URL`, `JWT_SECRET`, `HOST` and `PORT` straight from the
environment (plus `DB_POOL_SIZE`, which `start.sh` derives from the core count).

```bash
./build.sh   # ./gradlew installDist -> build/install/conduit/lib/*.jar
./start.sh   # java -cp "build/install/conduit/lib/*" conduit.Main
```

kiwiproc checks every SQL statement and result mapping at compile time. For that the Gradle plugin starts a
throwaway embedded PostgreSQL (zonky, no Docker, runs as a normal user) and loads `src/main/resources/schema.sql`
through `changelog.xml`. `schema.sql` is a copy of the repository's fixed `schema.sql`; it is only used at build
time and never touches the real database. The `checkSchema` task (run by `compileJava`, so by `build.sh`) fails if the
copy differs from `../../schema.sql`, and is skipped if that file isn't there.

## Code layout

```
src/main/java/conduit/
├── Main.java            starts the Avaje bean scope and Helidon; maps exceptions to JSON errors
├── Config.java          environment variables, Hikari pool, Jsonb, the Jwt bean
├── *Controller.java     one per area: users, profiles, articles, comments, tags (avaje-http annotations)
├── Requests.java        request bodies as records, with validation constraints
├── Dto.java             response shapes
├── AuthFilter.java      @Filter: authenticates before the body is bound
├── Access.java          @Access(NONE | OPTIONAL | REQUIRED) on controller methods
├── AccessTable.java     reads those annotations at startup and matches request paths
├── Auth.java, Jwt.java  token handling
├── Passwords.java       bcrypt on its own small thread pool
├── Body.java            the few checks the constraints can't express
└── *Dao.java            kiwiproc interfaces holding the SQL
```

## What I did and why

The box is CPU-bound: the app and Postgres share the cores. Every change below was measured on the 4-core test
machine described under [Results](#results); the ones that didn't help are listed afterwards.

**Database**
- The SQL is the reference SQL from `SPEC.md`, in the same order, except that article queries first pick their page
  of ids (a `page` CTE with the reference query's filter, order and limit) and then join one aggregate of those
  articles' tags, instead of running a tag subquery per article. The result is identical; in Postgres the list
  query ran about twice as fast (pgbench, 4 clients).
- `POST /api/articles` runs its inserts in one transaction with kiwiproc's `TransactionalDAO.call`.
- The pool is 10 connections per core, capped at 95, and was not very sensitive (see below).

**HTTP and threads**
- Helidon SE instead of the JDK's built-in `HttpServer` (via Jex): 9,200 users held, against 9,500.
- Helidon runs every request on its own virtual thread. Its connection read timeout is 75 s, which also bounds an
  idle keep-alive connection, so it outlasts Nginx's 60 s upstream keep-alive. The listen backlog is 1024.
- `tcpNoDelay` is on. Without it, a response written in two pieces (headers, then a larger body) waited for the
  client's delayed ACK, about 40 ms on the list endpoints.
- bcrypt (about 70 ms of CPU per hash) runs on a small pool of platform threads (`Passwords.java`, half the cores),
  so a few simultaneous logins can't occupy every virtual-thread carrier. At 10,000 users this cut the hold's p95
  from 108 ms to 5.4 ms and CPU from 79% to 69%.

**Authentication**
- JWTs are verified on every request with no cache: the signature is recomputed and the header and claims are parsed
  each time. Only the initialised `Mac` objects are reused (a lock-free pool).
- Auth is a `@Filter` (`AuthFilter.java`) that runs before the body is bound, so a missing or invalid token is a 401
  even when the body is also malformed.
- Each controller method declares what it needs with `@Access` (`NONE`, `OPTIONAL`, or `REQUIRED`, the default, so a
  new endpoint is protected until it says otherwise). `AccessTable` reads those at startup and matches the request
  path against the route templates without allocating; a path that matches no route is left for Helidon's 404. The
  caller is passed to the handlers through the request context (`Auth.java`).

## What didn't help

| Tried | Result |
|---|---|
| `prepareThreshold=0` (no server-side prepared statements) | 5,800 users held, against 10,000 with the default; reverted |
| Pool of 8, 16 or 24 connections instead of 40 | 10,000 held each time, no score difference; kept 10 per core |
| Other bcrypt libraries (jBCrypt, spring-security-crypto, Bouncy Castle, Password4j, native libxcrypt) | 47 to 59 ms per hash at cost 10, against 57 ms; the native one was 17% faster, under 2% of the box; kept `at.favre` |
| `AS MATERIALIZED` on the `page` CTE | Same plan with and without it: Postgres materialises a CTE used twice anyway |
| Reading JWT claims with Jsonb's streaming reader and a header fast path | JWT fell from 6.0% to 2.5% of the JVM's samples, but the score didn't move; reverted for readability |
| JDK 27 instead of 26 | 9,300 against 9,200 users held with the JDK server; the submission uses 26 |

## Behaviour notes

- Controller methods take the request record (`Requests.java`) as a parameter and the generated route binds it with
  Jsonb, which rejects a value of the wrong JSON type, so `{"title": 123}` is a 422, not coerced. A parse error is a
  422 through the `JsonException` handler in `Main.java`.
- Required and non-empty fields are checked by [avaje-validator](https://avaje.io/validator/) constraints on the
  records (`@NotEmpty`; `@Nullable` plus `@NotEmpty` for fields that are optional but can't be empty), which the
  generated route runs before the method; a violation is a 422 through the `ValidationException` handler. Only the
  password length in bytes (over 72 is a 422) is checked by hand.
- Timestamps are formatted with `uuuu-MM-dd'T'HH:mm:ss.SSS'Z'` in UTC, which truncates.
- Nulls are serialised explicitly (`bio` and `image` are JSON `null`).

## Results

Measured on a mini PC with 4 cores (Intel N150) that ran the server, Postgres 18 (pgtune settings) and the load
generator together, on the full seed, with no Nginx and the JDK 27 runtime. Each probe had a 60 s ramp and 60 s
measured; the hold lasted 5 minutes. A probe passes at p95 under 500 ms, p99 under 1,000 ms and errors under 1%.
Not comparable with the leaderboard: it has half the cores, and they are shared with the database and the client.

| Users | Run 1 | Run 2 |
|---:|---|---|
| 8,000 | pass | pass |
| 9,000 / 9,500 / 9,800 | not probed | pass (9,800: p95 87 ms) |
| 10,000 | pass, p95 277 ms | **fail, p95 506 ms** |
| 11,000 | fail, p95 1,659 ms | not probed |
| 12,000 | fail, p95 2,765 ms | fail, p95 3,285 ms, 1.17% errors |
| 16,000 | fail, 13.3% errors | fail, 12.0% errors |
| **Hold (5 min)** | **10,000 users: p95 118 ms, p99 416 ms, 0% errors, CPU 85%** | **9,800 users: p95 65 ms, p99 192 ms, 0% errors, CPU 74%** |

For comparison, the Spring example held 10,000 users on the same machine, and this submission's earlier builds held
9,200 to 10,000. Hold latency at 10,000 users varies by about 70 to 160 ms at p95 between runs: the machine is close to
saturation there, so one run can pass or fail the same step.

Where the CPU goes at 9,500 users (JFR samples of the JVM): bcrypt 39% (about 10% of the whole box, a fixed cost of
every login), the database driver 19%, Helidon 16%, JSON 11%, GC and other JVM work 7%, JWT 4%, the DAOs 2%, auth and
the access lookup 2%, validation under 1%. Postgres used about 36% of the box, the JVM 26% and the load generator 7%.

## Development

`./gradlew spotlessCheck` and `./gradlew spotlessApply` check and apply the code style (Palantir Java format, ktlint for
the Gradle files). They are not part of `build.sh`.

`./gradlew checkNullness` runs the Checker Framework's Nullness Checker (4.3.1) over `src/main/java`, using the
jspecify annotations (`@NullMarked` in `package-info.java`, `@Nullable`). It is not part of `build`, `check` or
`build.sh`.

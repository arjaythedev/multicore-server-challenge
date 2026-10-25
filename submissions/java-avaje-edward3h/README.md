# Conduit: Java 26 (Avaje, Helidon SE, kiwiproc)

**Front: nginx**

Plain Java on the [Avaje](https://avaje.io/) stack with [Helidon SE](https://helidon.io/) as the HTTP server with [kiwiproc](https://edward3h.github.io/kiwiproc/) for SQL.
The package layout follows `examples/java` (one controller per area, `Auth`, `Jwt`, `Body`, `Dto`, `ApiException`),
with Avaje replacing Spring. One JVM; every request runs on its own virtual thread.

| Piece | Version |
|---|---|
| JDK | Eclipse Temurin 26.0.2.1+1 (`install.sh` -> `/opt/jdk`), `--release 26` |
| Build | Gradle 9.5.1 via the checked-in wrapper (`./gradlew`) |
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

## Build and run

```bash
./build.sh   # ./gradlew installDist -> build/install/conduit/lib/*.jar
./start.sh   # java -cp "build/install/conduit/lib/*" conduit.Main
```

kiwiproc checks every SQL statement and result mapping at compile time. For that the Gradle plugin starts a
throwaway embedded PostgreSQL (zonky, no Docker, runs as a normal user) and loads `src/main/resources/schema.sql`
through `changelog.xml`. `schema.sql` is a copy of the repository's fixed `schema.sql`; it is only used at build
time and never touches the real database.

## Notes

- The SQL is the reference SQL from `SPEC.md`, in the same order, except that article queries first pick their page
  of ids (a `page` CTE with the reference query's filter, order and limit) and then join one aggregate of those
  articles' tags, instead of running a tag subquery per article. The result is identical; in Postgres the list
  query ran about twice as fast (pgbench, 4 clients). `POST /api/articles` runs its inserts in
  one transaction with kiwiproc's `TransactionalDAO.call`.
- Helidon runs every request on its own virtual thread. Its connection read timeout is 75 s, which also bounds an
  idle keep-alive connection, so it outlasts Nginx's 60 s upstream keep-alive. The listen backlog is 1024.
- `tcpNoDelay` is on. Without it, a response written in two pieces (headers, then a larger body) waited for the
  client's delayed ACK, about 40 ms on the list endpoints.
- bcrypt (about 70 ms of CPU per hash) runs on a small pool of platform threads (`Passwords.java`, half the cores),
  so a few simultaneous logins can't occupy every virtual-thread carrier.
- The first version used Jex on the JDK's built-in `HttpServer`; Helidon replaced it after load testing (below).

- Controller methods take the request record (`Requests.java`) as a parameter and the generated route binds it with
  Jsonb, which rejects a value of the wrong JSON type, so `{"title": 123}` is a 422, not coerced. A parse error is a 422
  through the `JsonException` handler in `Main.java`. Required and non-empty fields are checked by
  [avaje-validator](https://avaje.io/validator/) constraints on the records (`@NotEmpty`; `@Nullable` plus `@NotEmpty` for
  fields that are optional but can't be empty), which the generated route runs before the method; a violation is a 422
  through the `ValidationException` handler. Only the password length in bytes (over 72 is a 422) is checked by hand.
- JWTs are verified on every request with no cache: the signature is recomputed and the header and claims are parsed each
  time. Only the initialised `Mac` objects are reused (a lock-free pool).
- Auth is a `@Filter` (`AuthFilter.java`) that runs before the body is bound, so a missing or invalid token is a 401 even
  when the body is also malformed. Each controller method declares what it needs with `@Access` (`NONE`, `OPTIONAL`, or
  `REQUIRED`, the default, so a new endpoint is protected until it says otherwise). `AccessTable` reads those at startup
  and matches the request path against the route templates; a path that matches no route is left for Helidon's 404. The
  caller is passed to the handlers through the request context (`Auth.java`).
- Timestamps are formatted with `uuuu-MM-dd'T'HH:mm:ss.SSS'Z'` in UTC, which truncates.
- Nulls are serialised explicitly (`bio` and `image` are JSON `null`).

## Load test (not the benchmark box)

A 4-core mini PC running the server, Postgres 18 (pgtune settings) and the load generator together, full seed, no
Nginx, 60 s probes and a 5-minute hold. Users held for 5 minutes: JDK `HttpServer` 9,200 (JDK 26) and 9,300 (JDK 27);
Helidon 9,500, then 9,800 with the page-first SQL and 10,000 with `tcpNoDelay` as well (JDK 27); the Spring example 10,000 (JDK 27). Adding the bcrypt pool kept 10,000 but cut
the hold's p95 from 108 ms to 5.4 ms and CPU from 79% to 69%. 11,000 failed. Not comparable with the leaderboard.

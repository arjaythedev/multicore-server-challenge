# Conduit: Java 26 (Avaje, Jex, kiwiproc)

**Front: nginx**

Plain Java on the [Avaje](https://avaje.io/) stack with [kiwiproc](https://edward3h.github.io/kiwiproc/) for SQL.
The package layout follows `examples/java` (one controller per area, `Auth`, `Jwt`, `Body`, `Dto`, `ApiException`),
with Avaje replacing Spring. One JVM; every request runs on its own virtual thread.

| Piece | Version |
|---|---|
| JDK | Eclipse Temurin 26.0.2.1+1 (`install.sh` -> `/opt/jdk`), `--release 26` |
| Build | Gradle 9.5.1 via the checked-in wrapper (`./gradlew`) |
| DI | avaje-inject 12.7 |
| HTTP | avaje-http 3.12.1 annotations and `jex` generator, on avaje-jex 3.6 (the JDK's built-in `HttpServer`) |
| JSON | avaje-jsonb 3.16 |
| SQL | kiwiproc 1.0 (Gradle plugin), reference SQL from `SPEC.md` |
| Driver and pool | pgjdbc 42.7.14, HikariCP 7.1.0 (10 connections per core, set in `start.sh`) |
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

- Every statement is the reference SQL from `SPEC.md`, in the same order. `POST /api/articles` runs its inserts in
  one transaction with kiwiproc's `TransactionalDAO.call`.
- The JDK HTTP server closes idle keep-alive connections after 30 s and keeps at most 200 of them; `start.sh`
  sets `sun.net.httpserver.idleInterval=75` (longer than Nginx's 60 s) and `maxIdleConnections`.
- Request bodies are parsed as a JSON tree so `{"title": 123}` is a 422, not coerced. Passwords over 72 bytes are a 422.
- Timestamps are formatted with `uuuu-MM-dd'T'HH:mm:ss.SSS'Z'` in UTC, which truncates.
- Nulls are serialised explicitly (`bio` and `image` are JSON `null`).

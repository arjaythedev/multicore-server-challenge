# Kotlin/Native, no framework: own HTTP/1.1 server on epoll, own Postgres client, batched reads

Front: direct

| | |
|---|---|
| Language / runtime | Kotlin 2.4.21, Kotlin/Native (LLVM) for linuxX64: a native executable, no JVM at run time |
| HTTP | own HTTP/1.1 engine on raw epoll (`platform.linux`), one SO_REUSEPORT listener per event-loop thread |
| Postgres | own wire-protocol 3.0 client (SCRAM-SHA-256, extended protocol, binary results), batched reads, group commit |
| JSON, JWT, bcrypt | own: streaming JSON writer straight from binary rows, HS256, bcrypt cost 10 with interleaved lanes |
| Coroutines | Kotlin `suspend` with stdlib intrinsics only; continuations resume on the thread that did the I/O |
| Build | Gradle 9.8.2 (wrapper, checksummed) on Temurin JDK 27 (`install.sh`), used at build time only |
| Dependencies | none besides the Kotlin stdlib |

This is the Kotlin/Native build of the same Kotlin Multiplatform code as `kotlin-raw-luben93` (the JVM build);
DESIGN.md describes the architecture and the rules it keeps (no caching, bcrypt cost 10 on every login, HS256 + exp
checked on every request, writes committed before responding).

```bash
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

Optional process settings (defaults sized from the CPU count): `HTTP_THREADS`, `DB_READ_CONNS`, `DB_WRITE_CONNS`,
`BCRYPT_THREADS`, `BCRYPT_BATCH_MS`, `DB_OPTIONS`.

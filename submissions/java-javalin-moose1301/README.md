# Conduit: Java (Javalin)

**Front: direct.**

Javalin 7 on Jetty 12 with plain JDBC. Reads from concurrent requests are gathered into shared batches (the lane
design from [rust-epoll-WorriedArrow](../rust-epoll-WorriedArrow) and [java-vertx-bowbahdoe](../java-vertx-bowbahdoe),
whose batched SQL this follows), writes are one statement each, and bcrypt runs up to four hashes at once on its own
threads. Jetty's per-connection header cache is turned off so tens of thousands of keep-alive connections stay cheap.

# Stack

| | |
|---|---|
| Runtime | JDK 25 (Temurin 25.0.5+8, `install.sh`), G1 with a fixed 3 GB heap |
| HTTP | Javalin 7.2.4 on Jetty 12.1.14; handlers return `CompletableFuture`s via `ctx.future()` |
| Database | pgjdbc 42.7.14; batched reads on 8 lane connections, writes on 16 writer connections, prepared statements |
| JSON | hand-written writer and parser |
| Auth | HS256 JWTs checked with `javax.crypto.Mac` |
| bcrypt | own implementation, cost 10, up to four hashes interleaved per thread |
| Logging | slf4j-simple 2.0.20 |
| Build | Maven 3.9.16 (checked-in wrapper) |

# Getting started

## Prerequisites

* Java 25 (`install.sh` installs it to `/opt/jdk`)

## Usage

```
$ ./build.sh
$ DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 ./start.sh
```

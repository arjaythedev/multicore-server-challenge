# Conduit: Java (JDK HTTP Server Facade, backed by Jetty)

**Front: direct.**

This was adapted from a repository [I made some time ago](https://github.com/bowbahdoe/jdk-httpserver-realworld) whose goal
was to show that you can do server side development in Java without using annotation metaprogramming heavy things 
(like quarkus and spring). The overall structure is similar to a Go `net/http` based server - the JDK comes with an HTTP server
facade which is 90% of the way there to being just as ergonomic.

Almost all the code is in the `RealWorldAPI` class.

Although I tweaked some things, performance was not my goal. It was mostly to show that you can assemble a functional server
out of pieces that are easy to teach. The JSON library is one I wrote for that express purpose, as are the jdk-httpserver
helpers.

My hope is that this demonstrates a good effort+mental overhead to performance ratio.

# Stack

| | |
|---|---|
| Runtime | JDK 27 (Temurin, `install.sh`), compiled with `--release 25` |
| HTTP | The JDK's `jdk.httpserver` API, backed by Jetty 12.1.14 (`jetty-http-spi`); every request on its own virtual thread |
| Routing | `dev.mccue:jdk-httpserver-regexrouter` 2024.12.05 |
| Responses | `dev.mccue:jdk-httpserver` 2024.11.18, `dev.mccue:jdk-httpserver-json` 2024.12.04 |
| JSON | `dev.mccue:json` 2024.11.20 for request bodies and users/tags; articles, comments and profiles are built in Postgres with `json_build_object` |
| Database | PostgreSQL JDBC (pgjdbc) 42.7.14 over HikariCP 7.1.0 (pool of 80), SQL composed with `SQLFragment` from `dev.mccue:jdbc` 2025.10.07 |
| Auth | auth0 `java-jwt` 4.6.2, HS256 |
| bcrypt | Bouncy Castle `bcprov-jdk18on` 1.86, cost 10 |
| Query params | `dev.mccue:urlparameters` 2024.01.05 |
| Config | `dotenv-java` 3.2.0 (environment variables, or a `.env` file locally) |
| Logging | SLF4J 2.0.20 with Rainbow Gum 0.15.1 |
| Build | Maven 3.9.16 (checked-in wrapper) |

# Getting started

## Prerequisites

* Java 27 (`install.sh` installs it to `/opt/jdk`)

## Usage

```
$ ./build.sh
$ DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=127.0.0.1 PORT=3000 ./start.sh
```

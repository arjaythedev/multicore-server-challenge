# Conduit: Java (microhttp server + Vert.x PostgreSQL client)

**Front: nginx.**

This entry is similar in structure to the one I submitted for the JDK HTTP Server with two major changes.

First, I swapped the server implementation for microhttp. This seemed to give better performance when running benchmarks
locally. Second, I swapped the postgres JDBC client for the Vert.x Postgres client that the higher ranking Kotlin submission
uses.

Microhttp is designed to be used behind a proxy, so a front of nginx is appropriate.

I hope to get close in performance to that Kotlin implementation. Just like with the JDK http server submission,
the goal here is to demonstrate a good effort+mental overhead to performance ratio.

# Stack

| | |
|---|---|
| Runtime | JDK 27 (Temurin, `install.sh`), compiled with `--release 25` |
| HTTP | microhttp 0.11 (one event loop per core); every request on its own virtual thread |
| Routing | `dev.mccue:microhttp-handler` 2024.04.20 |
| Responses | `dev.mccue:microhttp-json` 2024.04.20 |
| JSON | `dev.mccue:json` 2024.11.20 for request bodies and users/tags; articles, comments and profiles are built in Postgres with `json_build_object` |
| Database | Vert.x PostgreSQL client 5.2.2, pipelined over 16 connections with prepared statements cached; virtual threads block on results with `Future.await()`; SCRAM-SHA-256 login via `com.ongres.scram:scram-client` 3.4; SQL composed with `SQLFragment` from `dev.mccue:jdbc` 2025.10.07 |
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

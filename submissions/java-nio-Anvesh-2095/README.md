# Java, raw NIO

Front: direct

A Conduit server in plain Java with no dependencies: its own HTTP/1.1 server on `java.nio` selectors, its own
Postgres wire-protocol client, JWT and bcrypt.

| | |
|---|---|
| Language | Java (source level 21), run on Eclipse Temurin JDK 27+35 (`install.sh`, checksum-verified) |
| Framework | None: `java.nio` `Selector` event loops |
| Postgres driver | Our own, protocol v3 (in `pg/`) |
| Build | Plain `javac` + `jar`, no build tool, no dependencies |
| JVM flags | `-Xms2g -Xmx2g -XX:+UseZGC` |

## Design

- **One JVM process.** `min(8, cores)` event-loop threads, each with its own `Selector`, accept from one shared
  listening socket and serve their connections: parse, dispatch, write. Connections hold no buffers of their own
  unless a request arrives split across reads or a response doesn't fit in the socket buffer.
- **Postgres client written for this.** Protocol v3, every statement prepared once per connection at startup,
  binary parameters and results, SCRAM-SHA-256 auth. Each connection pipelines many requests' queries (a writer
  thread and a reader thread per connection). Two pools: 24 read and 4 write connections, so writes never wait
  behind reads.
- **One round trip per request.** A request's statements go out together, ended by one Sync, so they run as one
  implicit transaction. Lookups that only gate a write are folded into it or sent in the same batch (for example,
  favorite = insert-by-slug, then re-read the article in a separate statement so it sees the insert). Responses
  are sent after ReadyForQuery, so writes have committed.
- **JSON written straight from the binary rows** into the response buffer: no intermediate objects. Timestamps
  are formatted by hand (truncated to milliseconds).
- **bcrypt (cost 10)** runs on 3 threads, off the event loops. JWT HS256 is checked on every request.

## Layout

| Path | What |
|---|---|
| `src/main/java/conduit/Main.java` | Configuration and startup |
| `net/EventLoop.java`, `net/Conn.java` | Selector loops and per-connection state |
| `http/` | Request parser, response/JSON writer, JSON reader |
| `auth/` | JWT and bcrypt |
| `pg/` | Postgres client, pipelining, pool |
| `api/Api.java`, `api/Sql.java` | Routing, the 19 endpoints, and their SQL |

# Swift: Hummingbird 2 + PostgresNIO

**Front: nginx.**

Implements [`SPEC.md`](../../SPEC.md) with the reference SQL verbatim. One process, one `PostgresClient`
connection pool, one thread per core for the event loops. No caching across requests: every request hits
Postgres, every token's HS256 signature and `exp` are re-verified, every login re-runs bcrypt (cost 10).

| Piece | Version |
|---|---|
| Swift | 6.4.1 (official Ubuntu 24.04 x86_64 tarball, sha256-checked) |
| HTTP | [Hummingbird](https://github.com/hummingbird-project/hummingbird) 2.28.0 (`HTTP1Channel`, trie router) |
| JSON | hand-rolled encoder (byte-exact `null`s, RFC 3339 ms timestamps) |
| Postgres | [postgres-nio](https://github.com/vapor/postgres-nio) 1.33.1 (`PostgresClient` pool, extended protocol) |
| JWT | HS256 via [swift-crypto](https://github.com/apple/swift-crypto) 3.12.3 (`HMAC<SHA256>`), hand-rolled compact JWS |
| bcrypt | OpenBSD bcrypt C sources (vendored under `Sources/CVaporBcrypt`, as in Vapor 4; cost 10) |

All dependencies are pinned exactly in `Package.swift` (plus `Package.resolved`).

## Design notes

- **Multicore model**: one process. SwiftNIO runs one event loop per core; bcrypt hashing/verification runs on a
  concurrent `DispatchQueue` so the ~50 ms cost-10 operations never block an event loop. The Postgres pool size is
  `DB_POOL_SIZE` (default `10 × cores`, capped at 95 for the box's `max_connections = 100`).
- **HTTP**: HTTP/1.1 with keep-alive, `idleTimeout = 75 s` (outlives Nginx's 60 s upstream keep-alive). Unknown
  routes return the RealWorld JSON error shape instead of plain text.
- **JSON**: responses are built by hand (no Codable) so `bio`/`image` come out as real `null`s, timestamps are
  truncated to exactly 3 fractional digits, and list endpoints omit `body`.
- **Auth**: `Authorization: Token <jwt>`; the header is parsed and the signature checked (constant-time) on every
  request. Present-but-invalid is 401 even on auth-optional endpoints; absent means anonymous (`viewer = 0`).
- **Bodies** are parsed with `JSONSerialization` into dictionaries, so key matching is case-sensitive, unknown
  fields are ignored, and `null` vs absent is distinguished exactly as in the spec.

## Build and run

```bash
bash build.sh    # swift build -c release -> ./.build/release/Conduit
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit_dev JWT_SECRET=conduit-dev-secret \
  DB_POOL_SIZE=10 PORT=3104 bash start.sh
```

Environment: `DATABASE_URL`, `JWT_SECRET` (required); `HOST` (127.0.0.1), `PORT` (3000),
`DB_POOL_SIZE` (min(10 × cores, 95)).

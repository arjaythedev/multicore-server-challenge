# C + io_uring, no framework

**Front: direct.** The server listens on `0.0.0.0:80` itself and holds every user's keep-alive connection.

| Piece | Version |
|---|---|
| Language | C (gnu11), GCC 13.3 from Ubuntu 24.04 (`build-essential`) |
| I/O | io_uring via liburing 2.5 (Ubuntu 24.04 `liburing-dev`) |
| HTTP/1.1, JSON, JWT (HS256), SHA-256, bcrypt | written from scratch, in `src/` |
| Postgres driver | written from scratch: protocol 3.0, SCRAM-SHA-256, named prepared statements, binary rows, pipelining (`src/pg_wire.c`) |

`install.sh` installs `build-essential liburing-dev` from the Ubuntu archive. `build.sh` is one `gcc` call.
`start.sh` runs `bin/conduit`, configured by `DATABASE_URL`, `JWT_SECRET`, `HOST` and `PORT`.

Optional tuning variables (defaults in brackets): `WORKERS` [CPUs / 2], `READ_CONNS` per worker [2],
`WRITE_CONNS` per worker [1], `BCRYPT_THREADS` per worker [CPUs / workers], `PG_PIPELINE` units in flight per
Postgres connection [16].

## Design

Work in progress; the full write-up of the optimizations and their measurements comes with the final version.

- **Worker processes, one io_uring each.** The parent forks `WORKERS` processes; each opens its own
  `SO_REUSEPORT` listener, its own Postgres connections and its own bcrypt threads. If any worker dies, the parent
  kills the rest and exits, so a crash is visible instead of a half-working server.
- **No per-connection buffers.** Each connection has one multishot receive into the ring's provided buffers;
  requests are parsed where they land and only partial leftovers are copied. An idle connection is a small struct.
- **One send per response.** The body is written first behind a reserved gap, then the header goes into the gap.
- **One Postgres round trip per step, pipelined.** A request's statements go out as Bind/Execute pairs and one
  Sync (one implicit transaction); units from many requests share each connection without waiting for each
  other. Responses are sent only after ReadyForQuery, so writes are committed first (rule 6).
- **Every statement is prepared at startup** with binary parameters and results, and each statement's result
  column types are checked against the live database before the server starts answering.

## Tests

- `bash tests/unit.sh`: SHA-256, HMAC, PBKDF2, base64, JWT, JSON, bcrypt and the Postgres wire format,
  checked against vectors computed independently by Python (`tools/gen_vectors.py`).
- `bash test/run.sh submissions/c-iouring-aslahtp` from the repo root: the 197-check conformance suite.

# Database ownership and recovery

Each database slot has one connection, one active primary request, an optional bounded read group and its own generation, deadline and retry state. All sockets, connection setup and query progress remain owned by the reactor thread. Bcrypt workers never touch a database connection.

`-Ddb-connections=N` selects a fixed pool at build time, with a checked range of 1–95. This does not create an unbounded pool or a thread per connection. Requests remain in the bounded HTTP client set until an idle owner is available. The oldest queued request is dispatched first. A slot stays exclusive through every query stage, transaction completion and rollback; another request cannot borrow it mid-operation.

Active database work has its own client state. A disconnected or expired client detaches its recipient without freeing an active operation. The database owner retains the operation until completion or connection retirement. Client generations protect reused HTTP slots. Database generations protect connection replacement and stale socket-readiness events. libpq can change its socket during authentication, so the reactor refreshes its registration as setup progresses.

## Failure decisions

- A fully drained ordinary SQL error can leave a connection reusable. Explicit transactions first roll back; failed rollback or an uncertain transaction boundary retires the owner.
- A connection or network failure detaches and fails its active request with 503. The active request is never returned to the dispatch queue. This includes writes for which PostgreSQL may already have committed.
- Healthy owners continue serving while another owner reconnects. If all ready owners are busy, queued work waits within its existing bounds. If the database is entirely unavailable, unsent work receives 503 promptly.
- A lost HTTP response is not proof that a write failed. The application does not invent idempotency guarantees absent from the API.

## Replacement lifecycle

Retired slots reconnect independently, starting after 250 ms with exponential backoff capped at five seconds. The existing event-loop tick can add scheduling delay when the process is otherwise idle. Each slot owns at most one attempt, with a twenty-second setup deadline. A completed replacement resets its backoff.

`PQconnectStart`/`PQconnectPoll`, parameterized setup and all forty-seven named preparations advance from socket readiness. A replacement is admitted only after all results have been drained and the connection is idle. No startup/session state is inherited from the lost connection. The official numeric loopback database address avoids libpq's potentially blocking hostname resolution; this design does not promise asynchronous DNS for arbitrary URLs.

Each owned session sets `statement_timeout` to eight seconds. This matches the existing application query deadline and bounds abandoned backend work as well as waiting in the application. It changes only that session, with no schema, database, role or server-wide configuration change. Durable commit settings stay untouched. Setup also drains session-only `jit=off` and the selected `plan_cache_mode`; the automatic-plan control remains available. See PERFORMANCE.md for the measurements.

Sources: [libpq connection establishment and changing sockets](https://www.postgresql.org/docs/18/libpq-connect.html#LIBPQ-PQCONNECTSTARTPARAMS), [asynchronous query completion](https://www.postgresql.org/docs/18/libpq-async.html), [session statement timeout](https://www.postgresql.org/docs/18/runtime-config-client.html#GUC-STATEMENT-TIMEOUT).

## Targeted verification

`python3 tests/recovery.py` uses fresh development-seed clones and a small standard-library TCP proxy. The proxy records prepared-statement names and session-setup counts, never credentials or parameter values. It can withhold authentication traffic, refuse new connections and close the stream after receiving PostgreSQL's COMMIT completion but before forwarding it to libpq.

The checks cover rebuilt statements/settings, isolated backend loss, bounded reconnect attempts, HTTP progress during stalled authentication, uncertain committed writes without replay, repeated replacement with concurrent clients, independent reads during a blocked write, statement-timeout rollback and all 197 unchanged conformance steps after recovery. The earlier tests now inspect eventual committed state rather than treating a tags request on another connection as a transaction barrier.

`python3 tests/recovery.py --restart-cluster` additionally restarts the dedicated project cluster while the application remains alive. It refuses to target any PGDATA other than `work/runtime/postgres-18` on port 55432. Its `finally` path brings that cluster back if stopped. This optional check temporarily affects the interactive project server too; it is not part of the official runner.

The proxy, application and disposable databases are stopped/removed on exit. All logs and JSON evidence stay under `work/results/recovery/`. No extra software, service or external infrastructure is installed.

The final optimisation round also counts all forty-seven preparations and all three session settings after replacement. Grouped read recipients receive the same drained success/error, or 503 on connection retirement; none are returned to the pending queue.

Grouped favorite mutations also distinguish a fully acknowledged rollback from an uncertain implicit commit. `tests/favorite_batch.py` drops ReadyForQuery after the mutation commits and requires HTTP 503, durable rows and no replay. Only an explicit SQL error followed by idle transaction status permits splitting an aborted group into individual operations.

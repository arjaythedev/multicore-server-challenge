This is tokio-postgres 0.7.18 with local changes to `src/client.rs` and
`src/query.rs`. The upstream MIT and Apache-2.0 licenses are retained.

The added methods encode prepared Bind/Execute messages and execute several
queries before a single Sync. The application's actors exclusively own
these connections. Driver results are released after ReadyForQuery, and SQL errors
are drained to that boundary before returning an error. The driver does not
retry statements. The application's read actor may retry failed read batches
individually. The write actor also uses the packed-query method inside an explicit
transaction, waits separately for COMMIT before successful HTTP replies, and
rolls back a failed statement group before retrying each job in isolation.
An uncertain COMMIT is not replayed.

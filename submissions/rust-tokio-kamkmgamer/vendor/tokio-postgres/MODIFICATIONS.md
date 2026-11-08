This is tokio-postgres 0.7.18 with local changes to `src/client.rs` and
`src/query.rs`. The upstream MIT and Apache-2.0 licenses are retained.

The added methods encode prepared Bind/Execute messages and execute several
reads before a single Sync. The application's read actors exclusively own
these connections. Results are released after ReadyForQuery, and SQL errors
are drained to that boundary before returning an error. The driver does not
retry statements. The application's read actor may retry failed read batches
individually; writes use the existing durable commit path.

`src/bin/group-check.rs` in the application checks group sizes, empty results,
SQL-error recovery, packed frames and separate READ COMMITTED snapshots.

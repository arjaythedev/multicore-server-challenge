This is tokio-postgres 0.7.18 with local changes to `src/client.rs`,
`src/query.rs` and `src/row.rs`. The upstream MIT and Apache-2.0 licenses are retained.

The added methods encode prepared Bind/Execute messages and execute several
reads before a single Sync. The application's read actors exclusively own
these connections. Results are released after ReadyForQuery, and SQL errors
are drained to that boundary before returning an error. The driver does not
retry statements. The application's read actor may retry failed read batches
individually; writes use the existing durable commit path.

`Row` is a reference-counted group of DataRow bodies plus an index: the rows
of one result share one allocation and one `Statement` reference, so cloning
or dropping a row is one atomic operation. `Row::raw` returns a column's raw
bytes (None for NULL) without a type check. The grouped Bind writes its
parameter formats and values straight into the message buffer, so no
intermediate vectors are allocated; the bytes are the same.

`src/bin/group-check.rs` in the application checks group sizes, empty results,
SQL-error recovery, packed frames and separate READ COMMITTED snapshots.

Shared article serialization: each immutable result `Group` can lazily own per-row
JSON bytes and the offsets of its two viewer-dependent fields. Cloned row handles
share the bytes through `OnceLock`; the application inserts each request's flags
separately. The storage is released with the last row handle and is never reused
by another query.

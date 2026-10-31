# Rust / Tokio shared batches

Front: direct

Rust 1.99.0, Tokio 1.53.2, vendored tokio-postgres 0.7.18, PostgreSQL 18, mimalloc 0.1.52. Dependencies are pinned.

Based on [#82](https://github.com/arjaythedev/multicore-server-challenge/pull/82), which builds on [my #7](https://github.com/arjaythedev/multicore-server-challenge/pull/7). MIT notices and native bcrypt attribution are retained.

Keeps #82's shared per-family read queues, packed SQL results, separate database runtime, adaptive gzip and interleaved cost-10 bcrypt. Adds:

- Feed page bounds proved from followed authors' Nth newest articles, recomputed within the same statement. Older IDs cannot enter the requested page, so each followee index scan can stop earlier. Counts remain unchanged.
- Article JSON serialized once per shared query-result row. Favorited/following flags are inserted independently for each viewer. The bytes belong to that immutable result set and disappear with its last row handle; they are never available to a later query.

Three HTTP workers, one database I/O worker, six read connections and two durable grouped-write connections on eight CPUs. Every request reads PostgreSQL and verifies its JWT; writes wait for COMMIT. No schema, server configuration, affinity or kernel changes.

Build and run:

```sh
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://... JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

Optional process settings from #82 remain available; `JSON_BATCH=0` disables shared serialization for comparisons.

## Validation

24 release tests; 197/197 official conformance checks on both dev and full seeds; 1,112 concurrent differential responses matched #82, including different viewers sharing articles.

Same-machine, full-seed official-workload screens at 112,000 users (20-second ramp, one-minute measurement):

| Version | req/s | p95 | p99 |
|---|---:|---:|---:|
| #82, exact head `3c8168b` | 28,809 | 353 ms | 560 ms |
| This submission | 29,043 | 221 ms | 347 ms |

At 96,000 users, throughput was within 0.05%; p95 was 76 → 73 ms and p99 139 → 160 ms. A final #82 control at 112,000 users after the hold served 27,880 req/s, p95 603 ms (failed), p99 888 ms. The database was not reset between these phases.

The five-minute hold at 112,000 users passed: **28,985 req/s, p95 234 ms, p99 394 ms, 0.020% errors**. A 128,000-user screen failed the p95 limit (772 ms). These are local measurements, not an official score or a completed maximum-user search. All reported runs passed the load-generator guards.

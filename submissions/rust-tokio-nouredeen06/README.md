# Rust / Tokio: request-cohort SQL optimization

Front: direct

Rust 1.99.0, Tokio 1.53.2, PostgreSQL 18, mimalloc 0.1.52. Dependencies are pinned in `Cargo.toml` and `Cargo.lock`. This is an attributed derivative of `rust-tokio-Scooter1337`; see `UPSTREAM.md` and the retained component licenses.

## Optimizations

- Coalesces already-queued filtered-list and comment requests, sharing repeated database lookups while preserving per-request pagination and viewer-specific fields.
- Uses a capped global-feed count fast path, with exact counts below the cap.
- Bounds request cohorts and bcrypt workers; each login still verifies the stored cost-10 hash and each request validates its token.
- Packs write queries into one PostgreSQL protocol group inside a transaction. Successful responses wait for durable commit; failed statement groups are rolled back and isolated before retry.
- Keeps fresh PostgreSQL reads, separate bounded read/write pools, and independent bcrypt salts. It does not change the database schema or server/host configuration.

## Build and run

```sh
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit \
  JWT_SECRET=your-secret HOST=0.0.0.0 PORT=80 bash start.sh
```

The scripts install a pinned Rust toolchain on Ubuntu 24.04, build a locked release binary, and run the server in the foreground. On eight CPUs, defaults are two Tokio workers, six read connections, two write connections and two bcrypt workers; the total DB connection count is limited to 95. Optional process settings are listed in `src/main.rs`.

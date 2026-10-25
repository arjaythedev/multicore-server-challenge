# Rust: axum + tokio-postgres

Front: direct

Rust 1.97.1, axum 0.8.9 (hyper 1, tokio 1.52), tokio-postgres 0.7.18, serde_json, jsonwebtoken 11.1, bcrypt 0.19
and mimalloc 0.1.52. Dependencies are pinned in `Cargo.lock`.

Written like a normal production service rather than a benchmark special: feature modules under `src/features/`
(`route.rs` for HTTP, `service.rs` for the rules, `data.rs` for named SQL), typed rows and errors, and no panics
outside tests. No custom HTTP parser, no request coalescing, no patched driver.

- Shared Postgres connections that tokio-postgres pipelines, 2 × cores for reads and 2 × cores for writes, so a commit
  waiting on its WAL flush never holds up a read. The one multi-statement transaction (an article with its tags) gets
  a connection of its own.
- One statement per request: lists carry their capped count, comments carry the article lookup, and follows,
  favorites, comments and deletes are data-modifying CTEs.
- Lists cut their page of ids first and compute tags, favorite counts and viewer flags only for those rows. Tag names
  come from primary-key lookups, which avoids the hash join over all tags that the generic plan picks.
- Every statement is prepared on every connection at boot; `plan_cache_mode = force_generic_plan` and `jit = off`
  are set per session.
- bcrypt (cost 10) runs on tokio's blocking pool behind a semaphore of 3/8 of the cores.

Every request reads Postgres, every write commits before the response, and every token's signature and expiry are
checked. No caching, schema changes or server settings.

```sh
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

Optional settings: `DB_READ_CONNECTIONS`, `DB_WRITE_CONNECTIONS`, `DB_TRANSACTION_CONNECTIONS` (2), `APP_THREADS`,
`BCRYPT_THREADS`, `DB_ACQUIRE_TIMEOUT_SECS` (8), `DB_STATEMENT_TIMEOUT_SECS` (30).

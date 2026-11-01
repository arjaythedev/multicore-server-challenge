# Crystal + Kemal

Front: direct

| Component | Version |
|---|---|
| Crystal | 1.22.1, release build, x86-64-v3 CPU target |
| HTTP framework | Kemal 1.15.0 |
| PostgreSQL driver | crystal-pg 0.31.0 / crystal-db 0.15.0 |
| JWT | crystal-community/jwt 1.7.2 |
| Password hashing | Crystal standard library `Crypto::Bcrypt`, cost 10 |

Dependencies, including transitive shards, are pinned in `shard.lock`. The installer
checks the official Crystal toolchain archive's SHA-256 digest. The fixed x86-64-v3
(AVX2) baseline avoids SIGILL from native CPU detection on some CI runners.

```bash
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit \
JWT_SECRET=multicore-server-challenge HOST=0.0.0.0 PORT=80 bash start.sh
```

`start.sh` runs `WORKERS` independent processes (default: `nproc`) in the foreground.
Each process binds `HOST:PORT` with `reuse_port: true`; the kernel distributes
connections. No Nginx is required. Each process uses Crystal fibers and a database
pool capped at `POOL = 95 // WORKERS` (minimum 1). On the eight-core box this means
eight processes and up to 88 PostgreSQL connections. Keep `WORKERS` between 1 and 95.

The routes use the reference SQL from `SPEC.md`, including capped counts, newest-first
pagination and transactional article creation. Responses use `JSON::Builder`.
There is no application data cache: each request reads PostgreSQL, every authenticated
request verifies its HS256 token and expiry, and login checks the stored bcrypt hash.
Writes finish before their responses are sent.

Validation: `bash test/run.sh submissions/crystal-kemal-faustinoaq` passes all
197 conformance checks against the development seed.

# Mojo, no framework, no C

Front: direct

The whole server is Mojo 1.2.0, and none of its code calls into C: no `external_call`, no FFI, no C libraries. Linux
syscalls are raw `syscall` (x86_64) / `svc #0` (aarch64) instructions through Mojo's inline assembly, and everything
else is written here in Mojo: the HTTP/1.1 server, the PostgreSQL wire-protocol client, SHA-256, HMAC, PBKDF2,
base64, JWT, JSON and bcrypt. (Mojo's own runtime and standard library are linked as part of the toolchain.)

| | |
|---|---|
| Language | Mojo 1.2.0 (`mojo-compiler` and `mojo-compiler-mojo-libs` from PyPI, pinned by version and SHA-256) |
| Framework | none |
| HTTP | HTTP/1.1 with keep-alive and pipelining, epoll, written here (`src/http.mojo`, `src/server.mojo`) |
| Postgres driver | written here (`src/pg.mojo`): protocol v3, SCRAM-SHA-256, prepared statements, pipelining |
| bcrypt | written here (`src/bcrypt.mojo`), following OpenBSD's algorithm; `$2a$`/`$2b$`/`$2y$`, cost 10 |
| Front | **direct**: the server holds every user's keep-alive connection itself |

```sh
sudo bash install.sh   # Mojo compiler into /opt/mojo (Ubuntu's python3-venv + pip --require-hashes)
bash build.sh          # bin/conduit
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

The binary links Mojo's runtime libraries from `/opt/mojo`, so it stays installed. Optional settings: `WORKERS`
(HTTP worker processes, default 2), `PG_READ_CONNS` / `PG_WRITE_CONNS` (Postgres connections per worker, default 6
and 2: 16 in all), `BCRYPT_WORKERS` (default 4), `PG_GENERIC_PLANS` (default 1), `PG_GROUP_STATS=N` (log the
group-commit counters every N groups).

## Design

- **Processes, not threads.** `main.mojo` forks (raw `clone`) the HTTP workers and the bcrypt workers and supervises
  them: if one dies, the rest are killed and the server exits (the box never restarts it). Workers die with the
  supervisor (`PR_SET_PDEATHSIG`). Nothing is shared between workers, so there are no locks.
- **Each HTTP worker is one epoll loop** with its own `SO_REUSEPORT` listener, connection table and Postgres
  connections. Level-triggered; reads land in one scratch buffer per worker, so an idle keep-alive connection owns no
  buffer, only its table slot (50,000 idle connections: about 4 MB per worker).
- **A request is a short chain of steps** on its connection (`api.mojo`): Postgres batches, completed when their
  `ReadyForQuery` arrives, and bcrypt jobs, completed by a bcrypt worker. A connection has at most one request in
  flight; pipelined requests behind it wait in its input buffer, so responses go out in order. A connection
  generation number keeps a late result from reaching a reused fd.
- **Postgres**: every statement is prepared once per connection; each request's statements go out as Bind/Execute
  pairs and one Sync, and all batches from one loop iteration leave in one `send` per connection. Results are read
  in place from the receive buffer and rendered straight into the response.
- **bcrypt runs in separate processes**, reached over `SOCK_SEQPACKET` socketpairs, so a ~50 ms hash never blocks an
  event loop. A job's id carries the client fd and generation, so the reply needs no lookup table.

## Optimizations

Measured on the full seed with the repo's loadgen, in interleaved A/B rounds (`tools/ab.sh`, or `tools/compare.sh`
on an x86 machine), as Postgres CPU per request unless stated.

- **Session `jit = off` and `plan_cache_mode = force_generic_plan`** (startup parameters; session-level, rule 2).
  A generic plan can't know `LIMIT $2` is at most 100, so it costs the list queries at ~50k rows, above
  `jit_above_cost`: each execution would JIT-compile for ~136 ms, so `plan_cache_mode = auto` re-planned them on
  every call instead (~0.25 ms, as much as executing them). With JIT off the generic plans run as fast as custom
  ones. Planning 154 → 2 ms per second of load, Postgres CPU per request −14%.
- **Each list is one statement**: the page's ids first (an index walk with `OFFSET $3 LIMIT 100`, then `LIMIT $2`;
  the constant bounds the generic plan's estimate, and `limit` is validated to 1..100, so the rows are the same),
  then the per-article subqueries for those rows only, with the capped count joined in the same statement. The
  reference global and author pages ran the subqueries for the rows `OFFSET` skips too. −4% overall, global list
  −22% per request.
- **Tag names by primary key**: `ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags
  at WHERE at.article_id = a.id ORDER BY 1)` instead of the reference join, whose generic plan seq-scans and hashes
  all 200 tags for every article. −7 to −10%; global list −23%, tag list −15% per call.
- **Separate read and write connections.** A batch waits for every batch pipelined before it, so with shared
  connections a commit that stalls (a slow WAL flush, a lock) held up every read behind it. Every batch with an
  INSERT, UPDATE or DELETE goes to a write connection. With writes to `favorites` locked 3 s in every 10
  (`tools/stall_test.sh`): read p95 2.3 s → 0.3 ms.
- **Group commit.** A write connection keeps one batch in flight; requests that arrive meanwhile then go out
  together, all their statements before one Sync, so one implicit transaction and one WAL flush commit them (up to
  128). A slow flush makes the next group bigger instead of growing a queue. Every response waits for its commit
  (rule 6). If any statement in a group fails, the transaction has rolled back as a whole, so each member is resent
  alone and gets the result it would have had by itself; a lost connection ends the server, so an uncertain commit
  is never retried. On a slow SATA SSD with btrfs: write p90 during disk stalls 7.4 s → 317 ms.
- **bcrypt**: one base pointer per S-box, so each lookup is a single register-offset load (−13% per hash: 63.2 →
  55.2 ms on an Apple M1 Max, 47 ms on an i7-8700).

## Correctness and the rules

- Conformance 197/197, and the normalized transcript is identical to `bench/cmd/conformance/golden-dev.jsonl`, on
  arm64 and on x86_64 (also from a clean `ubuntu:24.04` through `install.sh`, `build.sh`, `start.sh`).
- Every SQL rewrite was checked against SPEC.md's reference SQL on the full seed (`tools/diff_lists.py`): 480 random
  cases (all five lists, deep offsets, missing filters, anonymous and logged-in viewers, single articles) give
  identical rows, columns and counts.
- No caching across requests: every request reads Postgres; nothing is retained between requests.
- bcrypt cost 10 for every new hash, every login verified against the stored hash; output byte-identical to Python's
  `bcrypt` (`tests/check_auth.py`). Passwords over 72 bytes are rejected at registration.
- JWT HS256 signature and `exp` checked on every request; `alg` must be HS256, `sub` a decimal string.
- Group commit under conflicts (`tests/group_commit_check.py`): duplicate registrations piled into failing groups
  resolve exactly as they would one by one.

## Local measurements (not official)

Same machine, same load for each (an i7-8700, 15,000 users, ~4,000 req/s, full seed, each server in an
`ubuntu:24.04` container pinned to 8 CPUs, 2 rounds): server and Postgres CPU per 1,000 req/s.

| | server | Postgres | total | p99 |
|---|---|---|---|---|
| this server | 0.064 | 0.155 | 0.219 | 5–49 ms |
| rust-tokio-Scooter1337 | 0.061 | 0.135 | 0.197 | 8 ms |
| c-iouring-tigokraft | 0.055 | 0.144 | 0.199 | 90–123 ms |
| csharp-sockets-jh-d | 0.058 | 0.161 | 0.219 | 5 ms |
| go example | 0.182 | 0.275 | 0.456 | 8–10 ms |

About 0.047 of every server's figure is bcrypt (logins). That machine's Postgres sits on a DRAM-less SATA SSD with
btrfs, which makes commits slow; these are comparisons, not predictions of the box's score.

## Layout

- `src/main.mojo` supervisor; `src/app.mojo` event loop; `src/server.mojo` transport (connections, Postgres and
  bcrypt sockets, group commit); `src/api.mojo` routing and endpoints; `src/reqs.mojo` shared parsing and rendering;
  `src/sql.mojo` the statements; `src/pg.mojo` Postgres client; `src/http.mojo`, `src/json.mojo`, `src/jsonin.mojo`,
  `src/jwt.mojo`, `src/crypto.mojo`, `src/bcrypt.mojo`, `src/bcrypt_worker.mojo`, `src/linux.mojo`, `src/buf.mojo`.
- `src/blowfish_pi.mojo` is generated by `tools/gen_blowfish_pi.py`, which computes pi's hex digits.
- `tests/`: HTTP framing (`smoke.sh`), crypto against Python's `hashlib`, bcrypt/JSON/JWT against Python, the raw
  `fork`, and group commit under conflicts.
- `tools/`: profiling and A/B tools, for scratch databases only (`pg_stat_statements` must never exist on the
  benchmark database): `pgss.py`, `explain.py`, `plan_modes.py`, `diff_lists.py`, `ab.sh`; and `run_submission.sh`
  / `compare.sh` to run any submission the way the box does, in an `ubuntu:24.04` container.

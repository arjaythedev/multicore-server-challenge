# Submission rules audit

Reviewed against the root README and SPEC.md at challenge commit
`c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e`, verified as upstream `main` on
October 25, 2026. The README blob was
`89d16fdc6c3b901b28ea892d3a1caf2b34bdbcc1`.

**No violation of the README's implementation or submission rules was found in
the reviewed runtime paths.** The folder name was corrected to match the GitHub
account, `submissions/rust-tokio-nouredeen06/`. This is a source audit supported
by prior validation, not a proof of every possible behavior or a claim that
upstream CI has already accepted this PR.

| Rule | Evidence and finding |
|---|---|
| 1. Language/runtime freedom | Rust/Tokio, a vendored PostgreSQL driver, native bcrypt and bounded worker pools are permitted implementation choices. |
| 2. PostgreSQL 18 only; fixed server settings | Runtime connects only through `DATABASE_URL`, using PostgreSQL. `src/db.rs` sets only `plan_cache_mode=force_generic_plan` and `jit=off` on its own sessions. No other database, external cache or server-wide settings are used. |
| 3. Fixed schema/data model | Runtime SQL in `src/sql.rs`, `src/read_batch.rs` and `src/comment_batch.rs` reads/mutates the supplied tables through API operations. It creates no tables, indexes, functions, extensions, views or triggers. Test fixture DDL is outside the runtime path. |
| 4. Conformance | The recorded latest-source run passed all 197 unchanged official API checks. It used the debug application build; a separate release build also completed. These checks were not rerun after the user stopped local testing. GitHub CI remains the fresh acceptance check. |
| 5. No caching across requests | Pools retain connections, prepared statements, routing counters and empty allocations. Database results exist only for a cohort collected before its SQL execution; the actor does not add later requests to an execution already in progress. Requests arriving later receive a new execution. JWT and bcrypt verification results are not cached. |
| 6. Commit before response | A single write waits for the implicit transaction's ReadyForQuery. A write group uses BEGIN, packed statements and an awaited COMMIT before success replies. Statement errors drain, roll back and retry individually; uncertain commits are not replayed. No synchronous-commit disabling or unlogged tables. |
| 7. Real security | User password hashing uses cost 10 and independent random salts. Login reads the current stored hash and performs bcrypt verification. `src/auth.rs` verifies the HS256 MAC, algorithm and expiration for every token-bearing request. Low-cost internal bcrypt self-test vectors are startup canaries, not user-password hashing. |
| 8. Real app behavior | No benchmark/seed detection or fixed dataset answers were found in the runtime. Counts derive from SQL; the 1,000 cap is required by SPEC.md and has an exact fallback. Static error/HTTP formatting and the canonical JWT header do not replace database reads or token verification. |
| 9. Ubuntu x86_64, 8 vCPUs / 16 GB | Source builds target Linux x86_64. Eight-CPU defaults are two app workers, six read connections, two write connections and two bcrypt workers. These are process settings. Actual capacity and memory compliance at the organizer's final load still require its benchmark; no result on that box is claimed. |
| 10. Frontend selection | README declares `Front: direct`. The server binds `HOST:PORT` and implements HTTP/1.1 keep-alive directly. |
| 11. Source builds, pins, health | `install.sh` installs Rust 1.99.0 and a C toolchain; `build.sh` runs a locked release build. Direct dependencies are exact-pinned and Cargo.lock is included. No build artifacts are submitted. Previous validation exercised startup and `/api/tags`; the current release build succeeded. |
| 12. No host tuning/affinity | Install/build/start paths contain no sysctl changes, CPU pinning or changes to other processes. Runtime knobs affect only its own pools, threads, batching and allocator. Local diagnostic resource caps are not installed or run by the submission entrypoints. |

## Runtime and packaging contract

- Required configuration is `DATABASE_URL`, `JWT_SECRET`, `HOST` and `PORT`.
  Optional process settings have defaults; `start.sh` requires no extra service
  and uses `exec` to leave the server in the foreground.
- `Db::connect` enforces a positive read/write pool with at most 95 total
  connections. Default eight-CPU allocation uses eight connections.
- `install.sh`, `build.sh`, `start.sh`, README, source and retained licenses are
  contained in the one submission directory. The root spec, schema, test suite,
  CI workflow and other submissions remain unchanged.
- Build output and raw workspace state (`target*`, `.local`, bytecode) are ignored.
  The selected textual evidence in `results/` is intentionally included so the
  documentation links remain usable.
- The contribution is under the repository's MIT terms, with original upstream
  and third-party notices preserved. Its AI provenance is prominent in the
  README, AI_DISCLOSURE.md and PR description.

## Validation evidence and boundaries

[results/bounded-checks.txt](results/bounded-checks.txt) records 14 passing unit
tests, the opt-in PostgreSQL transaction test, 197/197 conformance checks, Clippy
with warnings denied, and a successful release build. The recorded SHA-256 values
for `src/read_batch.rs`, `src/writer.rs`, `src/writer_tests.rs` and the local release
binary still matched when this audit was prepared. No application/native/driver
source was changed during PR preparation; the final changes concern packaging,
disclosure, documentation and development tooling.

The source-build and start scripts are the organizer's execution path. Development
helpers and the opt-in test may create isolated fixtures, databases or volumes;
they are never called by those scripts and do not modify the challenge schema at
runtime. Local CPU/I/O quotas, Docker fixtures and laptop power modes are not
part of the submission's deployment configuration.

The local benchmark reports explicitly distinguish short probes, passing holds,
failed holds, interruptions and different resource budgets. They establish no
official score and do not multiply accelerated virtual users into one. All local
testing is stopped at the user's request; no more local tests should be started
without a new request.

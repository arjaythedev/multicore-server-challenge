# Goose / native primitives / PostgreSQL

Front: direct

Goose implements the Conduit API, PostgreSQL wire protocol and SQL, HS256
claim validation, response construction, epoll scheduling and cost-10 bcrypt.
Small C helpers provide our SIMD JSON string writer, per-thread prepared
OpenSSL HMAC and Linux syscall bindings.

This adapts our [single-core Goose implementation](https://github.com/arjaythedev/twelve-dollar-server-challenge/pull/143)
and the MIT-licensed asynchronous Conduit/Postgres core from
[XeonFX's PR #31](https://github.com/arjaythedev/multicore-server-challenge/pull/31).
Read batching and shared article enrichment retain attribution to
[Scooter1337's Rust PR #7](https://github.com/arjaythedev/multicore-server-challenge/pull/7).
See [NOTICE.md](NOTICE.md) and [LICENSE](LICENSE) for pinned origins and terms.

## Build and run

```sh
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit \
  JWT_SECRET=multicore-server-challenge HOST=0.0.0.0 PORT=80 bash start.sh
```

A clean build compiles Goose from commit
`f605b5a07dd2aa3a5cb3f4c9b14002bd3c9d3d1a`, verifying its source archive by
SHA-256. GCC compiles the generated C and native helpers with optimization
and LTO. Ubuntu 24.04 supplies the dependencies; no application binary is
downloaded. `GOOSE_BIN` may select an already installed matching compiler.
Build and start run as a normal user after the dependency installation.

## Defaults and conditions

| Setting | Default | Purpose |
|---|---:|---|
| `WORKERS` | 2 | Independent epoll loops |
| `PG_READERS` | 3 | Read connections per loop, plus one writer |
| `HASHERS` | 2 | Dedicated bcrypt workers |
| `BCRYPT_BATCH_MS` | 250 | Collection deadline measured from job enqueue |
| `READ_BATCH` | 32 | Maximum members of a compatible read batch; 0 disables pooling |
| `READ_HOLD` | 1 | In-flight admission threshold for an underfull read pool |
| `ARTICLE_BATCH` | 1 | Share overlapping article reads within one execution |
| `WRITE_BATCH_US` | 1000 | Writer collection window; 0 sends Sync immediately |
| `READ_BATCH_US` | 5000 | Pending-read collection window; 0 dispatches immediately |

The default uses **eight PostgreSQL connections**: six readers and two writers.
Configurations exceeding 95 total connections are rejected. `DATABASE_URL`,
`JWT_SECRET`, `HOST` and `PORT` follow SPEC.md.

- Prepared statements pipeline requests. Lists deduplicate compatible page and
  count work before enriching distinct articles. Feeds select each viewer's
  own page before sharing common metadata. Article and comment batches retain
  each member's viewer flags, ordering, missing-resource and empty-page behavior.
  Shared rows and followee sets exist only inside that SQL execution; no response
  or query result is retained for a later request.
- Quiet reads wake on their collection deadline without another HTTP request.
  A full pool can dispatch earlier. The event loop waits for the earlier eligible
  read or writer deadline, so read collection does not delay an independent write.
  The existing in-flight admission gate can also make an underfull pool wait
  for a PostgreSQL reply.
- Writers collect compatible work before Sync and wait for commit completion
  before returning success. Article updates and favorite/unfavorite responses
  then reread by **immutable article ID in a fresh statement snapshot**. A
  concurrent slug rename cannot redirect that read, and a read retry cannot
  replay the committed mutation.
- Bcrypt computes only the actual number of occupied lanes, from one to five.
  Every login verifies its stored hash; collection time starts when the job is
  enqueued. Legal embedded-NUL password bytes are preserved, including UTF-8
  passwords at the 72-byte limit. Passwords never enter PostgreSQL text columns;
  other text fields still reject NUL and the password-length rules are unchanged.
  Completed bcrypt replies wait through pipe backpressure and interruptions.
- Each authenticated request computes a fresh HS256 MAC and checks its header,
  expiry and subject. Only per-thread HMAC key setup is reused. Response strings
  use SSE2/NEON escaping while Goose owns JSON structure and validation.
- PostgreSQL 18 uses the supplied schema and cluster settings. The app sets no
  CPU affinity, changes no host tuning and does not restart crashed workers.
  Idle connections remain open within the challenge's descriptor budget.

## Correctness validation

The final Linux ARM64 binary `7a7c31fb...` passed the unchanged **197/197**
conformance steps on both dev and full seeds. Original seed fingerprints match.
Additional black-box checks passed:

- 1,664 baseline/candidate read comparisons across global, tag, author,
  favorited, feed and comments routes, including actual batch-SQL witnesses,
  mixed viewers, Unicode, empty/missing resources, count caps, ordering and
  committed changes.
- Deferred-COMMIT/no-early-response and grouped-rollback probes; quiet read and
  writer timer checks; concurrent favorite counts, article updates and
  favorite/slug-rename races with fresh post-commit responses.
- Embedded-NUL password interoperability in both directions against pinned
  Go `x/crypto/bcrypt` at cost 10, including rejection of truncated prefixes
  and unchanged nonpassword text/length validation.

`bash tests/native.sh` passes **293,966 native assertions plus 4,000 Goose JWT
assertions**: threaded HMAC and failure recovery, SIMD boundaries, syscall ABI
and reply-pipe backpressure/signals. `bash tests/bcrypt-lanes.sh` passes **252**
comparisons against the single-lane reference, using distinct keys/salts and
costs 4, 5 and 10. These checks use no database.

These local checks use Ubuntu 24.04 ARM64 Docker on a Mac, with the app and
PostgreSQL sharing eight CPUs / 16 GiB / no swap and no CPU affinity. Native
x86 validation and its exact submission-tree receipt are tracked in
[PR #32](https://github.com/arjaythedev/multicore-server-challenge/pull/32).

## Measurement status

One exploratory 80,000-user calibration block of the earlier `a34ee531...`
binary used **26.3% less combined app + PostgreSQL CPU per successful request**
than Rust #7. Its p50/p95 were slower: 3.081/5.611 ms versus 0.414/2.783 ms.
That fixed-load ARM64 comparison selected the defaults above; subsequent
correctness fixes produced a different binary. It is not a capacity result
or a measurement of this final binary.

The [published official result](https://github.com/arjaythedev/multicore-server-challenge/blob/c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e/LEADERBOARD.md)
for the earlier `3e908747` source remains **eighth place at 65,000 users**.
This revision awaits a new official run. No first-place or lead-over-all result
is established by the local calibration or correctness checks.

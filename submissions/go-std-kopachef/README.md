# Go Conduit server

Front: direct

A RealWorld Conduit API implementation for the Multicore Server Challenge.
Go 1.27.3, the standard library HTTP parser/router, a compact HTTP/1.1 connection
loop, pgx/v5 v5.11.0, and x/crypto v0.58.0. Dependencies are pinned in `go.mod`
and `go.sum`. JWTs use standard-library HS256; bcrypt uses internal cost-10
kernels with the x/crypto compatibility fallback.

## Build and run

On clean Ubuntu 24.04 x86_64, run `sudo bash install.sh` once, then
`bash build.sh` as a normal user. The installer verifies the official Go
archive checksum. The build produces a static `bin/conduit` from source.

The organizer supplies `DATABASE_URL`, `JWT_SECRET`, `HOST` and `PORT`.
Run `bash start.sh` to serve in the foreground. The launcher automatically
exports [config/tuned.env](config/tuned.env), preserving those four variables.
It uses a 24-connection pool and serves HTTP/1.1 directly with keep-alive.
No additional services or database objects are required.

## Implementation

Bcrypt kept turning up in the profiles. I ended up giving it a few kernels:
generated Go for batches, and a small amd64 assembly path for single hashes.
Same algorithm, same cost, with independent hashes interleaved along the way.
The single-hash cost loop stays in Go. New hashes get fresh salts, cost stays
at 10, and every login checks the stored hash. x/crypto handles compatibility
cases, and its Blowfish implementation supplies the portable single-hash path.

JWTs use standard-library HMAC and SHA-256 directly. The fixed HS256 header
saves decoding it on the usual path; other headers are parsed and checked for
the right algorithm. I reuse the HMAC scratch state and reset it between uses.
Signature and expiration checks happen on every authenticated request.

Several requests were asking Postgres for the same articles, so I grouped the
lookups. The read queue collects current requests into bounded batches, selects
the page IDs, then reads each distinct article once. Each request keeps its own
favorite and follow flags, and the next batch reads everything again. Channels
and fixed workers keep the number of concurrent database operations under
control.

Sorting article IDs before enrichment was another small change worth keeping.
It changes the lookup order without changing the response order. I also moved
slug lookups into favorite and comment writes, saving a separate query and
connection acquisition. Independent writes can share a transaction.

A returned row is still provisional until the transaction commits. I let
Postgres finish that part before waking the caller with a successful result.
Retries are reserved for failures where I know the transaction rolled back.

Tag names come from a fresh dictionary read, in Postgres's own sort order.
Custom pgx array scanners put the tag IDs into reusable batch-owned storage
and translate them into ranks from that dictionary. That avoids an intermediate
array for each article while keeping PostgreSQL's collation order. The schema
and durability settings stay unchanged; session-level generic plans and
disabled JIT are the only PostgreSQL settings applied.

A batch can finish in pieces. Tags, profiles and comments return once their
own results are fully decoded, while article requests continue through
enrichment. Once the worker hands a result back, it stops touching it.

The HTTP/1.1 connection loop is custom. General requests use the standard
request parser and router. Complete GETs that match the narrow fast path go
straight to the read queue, without the usual header map and router parameters.

The JSON encoder knows the API's fixed shapes and appends straight into pooled
buffers. Other response values keep the standard encoding path. An SSE2 scanner
finds bytes that need escaping or the Unicode fallback. Request JSON uses the
standard token decoder; raw field values reference the owned request body
until a handler needs to decode them.

For the common response path, I leave a little space before the JSON body for
the HTTP headers. Once the body is ready, the headers go into that space and
the response leaves in one write.

I also tried packing a row's strings into one allocation. It cut the object
count, but didn't show a useful reduction in server CPU or GC activity. That
one stayed out; the existing row decoder is still in place.

The compact backend handles complete JSON responses, keep-alive, HEAD,
chunked request bodies and `100-continue`. Headers are bounded, with a 10-second
header timeout and a 75-second idle timeout. It doesn't support streaming,
upgrades or immediate peer-disconnect cancellation during a handler.

## Source and verification

`cmd/conduit` contains the entry point. `internal/server` contains the API,
HTTP backend, encoders and database queues; `internal/auth`,
`internal/jsonquote` and `internal/bcryptlane` hold independent helpers.
Bcrypt source attribution and its upstream license remain in
`internal/bcryptlane`.

From the challenge repository root, use its official runner:

```sh
bash test/run.sh submissions/go-std-kopachef
```

Clean Ubuntu 24.04 installation and the official 197-step conformance runner
passed with this launcher.

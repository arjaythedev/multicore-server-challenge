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

I found that bcrypt was still taking a significant share of the application's
CPU, so I implemented compatible kernels around the same Blowfish algorithm.
The batch kernels are generated Go, making each independent hash explicit so
their work can be interleaved. The single-hash path uses a small amd64 assembly
routine for key expansion, with the cost loop kept in Go. New hashes still get
fresh salts, cost stays at 10, and every login checks the stored hash. The
x/crypto handles compatibility cases; the portable single-hash fallback uses
its Blowfish implementation.

For JWTs, I build and verify tokens directly with standard-library HMAC and
SHA-256. Tokens with the fixed HS256 header can skip header JSON decoding;
other headers retain JSON parsing and algorithm validation. I reuse HMAC
scratch state, resetting it between uses. Every authenticated request still
checks the signature and expiration.

I found that separate requests were often doing the same database lookups.
The read queue groups current requests into bounded batches, selects the page
IDs, then reads each distinct article once for that batch. Viewer-specific
favorite and follow flags are applied separately. Channels and fixed workers
keep database concurrency under control, and no result is reused by a later
batch.

One small change that was worth keeping was sorting article IDs before
enrichment. This changes the database lookup order while keeping the response
order intact. I also moved slug lookups into favorite and comment writes to
avoid a separate query and connection acquisition. Independent writes can
share a transaction, but every successful response waits for its commit.
Tag names are read afresh for each enrichment batch, with PostgreSQL supplying
their sort order. The schema and durability settings stay unchanged; the only
PostgreSQL settings applied are session-level generic plans and disabled JIT.

I also added custom pgx array scanners for tags. They decode IDs into reusable
batch-owned storage, then translate them to ranks from a freshly read tag
dictionary. This avoids a separate intermediate array for each article while
keeping the tag order supplied by PostgreSQL's collation.

I also found that every request in a batch didn't need to wait for all the
batch's reads. Tags, profiles and comments can finish once their own results
are fully decoded, while article requests continue through enrichment.
Once a result is handed back to its request, the worker leaves it alone.

I use a custom HTTP/1.1 connection loop, keeping the standard request parser
and router for general requests. Complete, recognized GETs can go straight to
the read queue without building the usual header map and router parameters.

JSON responses use a handwritten encoder for the API's fixed shapes, with
standard encoding fallbacks for other values. It appends into pooled buffers,
and a handwritten SSE2 scanner locates bytes that need JSON escaping or the
Unicode fallback. On input, a standard token decoder reads the request fields,
while their raw values reference the owned request body until a handler needs
to decode them. On the common response path, space for the headers is reserved
before the JSON body so both can be sent together without copying the body
into another buffer.

One observation along the way was that fewer allocations didn't always make
a change worth keeping. I tried packing a row's strings into one allocation,
but the lower object count didn't translate into a useful change for the
server as a whole. The existing row decoder stays in place.

The compact backend supports complete JSON responses, keep-alive, HEAD,
chunked request bodies and `100-continue`. It has bounded headers, a 10-second
header timeout and a 75-second idle timeout. Streaming, upgrades and immediate
peer-disconnect cancellation during a handler are outside this backend's scope.

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

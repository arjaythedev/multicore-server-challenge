# V: veb + libpq

Submitter: **kamkmgamer**

Language: **V**

**Front: direct.** This submission uses V's `veb` fasthttp backend (`-d new_veb`), V's `db.pg` libpq bindings, `crypto.bcrypt`, and V crypto primitives for JWT authentication. It starts four worker processes and opens 32 PostgreSQL connections in total on the benchmark box; each process leases its own connections to requests through a bounded channel. `SERVER_PROCS` and `DB_CONNS_TOTAL` can tune those defaults (1–4 processes and at most 90 connections); the challenge-wide connection limit is 95.

Article-list pages and their capped counts come from one SQL statement. Article creation, including tag insertion and linking, is one atomic statement. Page metadata is calculated only for returned articles. There are no response caches; every request authenticates its token and reads committed database state.

The hot read statements are prepared once on every PostgreSQL session, avoiding repeated parse and plan work while retaining PostgreSQL's per-session plan state. Article list and full article queries return scalar columns, and V assembles the response JSON to avoid PostgreSQL building a nested document for every row. Canonical HS256 tokens use a small allocation-light verifier path; non-canonical but valid HS256 headers and claims use the full JSON fallback.

Direct mode lets the V server accept keep-alive connections on the benchmark port without Nginx in front. This saves the proxy CPU and avoids an extra request hop. The service unit grants the capability needed to bind port 80 without running the server as root.

`install.sh` builds V at commit `c36172591e766668cf8aa7cc307f05764b6a0d49` with its matching VC bootstrap snapshot (`c3063f8ca58150f6c6d98d86dc95bd3543e620f3`) and links against the system `libpq` client. Pinning both repositories keeps V's bootstrap compiler and source tree in sync. The installer also builds V's bundled Boehm GC from source so the bootstrap does not depend on a TCC library bundle. This V revision includes the Linux syscall header fix needed by its bootstrap compiler on Ubuntu 24.04. `build.sh` compiles the server with `-prod -prealloc -d new_veb`. No generated binaries or vendored dependencies are committed.

## Local load results

On the development host, the full 500,000-article seed passed a five-minute hold at 4,000 VUs with `-think-scale 0.2`: 5,133 req/s, p95 126.1 ms, p99 487.7 ms, and no errors. This ran after a 60-second ramp; the app, PostgreSQL, and load generator shared a 24-thread host. The accelerated think scale and shared host make this a local comparison result, not the official score: the challenge box has 8 vCPUs and its official five-minute hold uses the default workload settings.

## Attribution and changes

This submission is derived from [PR #2](https://github.com/arjaythedev/multicore-server-challenge/pull/2) by [@ulises-jeremias](https://github.com/ulises-jeremias), using submissions/v-fasthttp-ulises-jeremias as its base. Credit for the original V/veb implementation belongs to ulises-jeremias.

Our changes are:

- prepare the hot PostgreSQL statements once per session;
- return scalar article columns and assemble response JSON in V;
- add an allocation-light canonical JWT verification path with full validation fallback;
- run four SO_REUSEPORT workers with 32 PostgreSQL connections by default;
- pin the V and VC revisions and build the Boehm GC from source for a reproducible Ubuntu 24.04 install.
- collapse follow/unfollow, article deletion, comment creation, and comment deletion into single CTE statements;
  each mutation now checks ownership and commits the state change in the same PostgreSQL round trip.
- collapse favorite/unfavorite lookup plus mutation into one CTE round trip before the final article read, removing
  one database lease from the hottest write path.
- prepare all of those CTE mutation statements on every PostgreSQL session, so the fast paths do not fall back to
  repeated parse and plan work.

This is an optimized derivative of #2; the inherited code and the changes above are documented here so the lineage is clear.

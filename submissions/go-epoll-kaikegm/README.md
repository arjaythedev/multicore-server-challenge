# Go: epoll + pgx with family-routed query coalescing, shared-enrichment CTEs, and zerojwt

**Front: direct**

A Conduit server in pure Go (`CGO_ENABLED=0`, PGO-enabled) built on a custom multi-loop `epoll` reactor, zero-allocation request/response path, and PostgreSQL query coalescing. Source is in `src/`.

| Piece | Version |
|---|---|
| Go | 1.27 (`-pgo=auto`) |
| HTTP | Custom epoll reactor (`SO_REUSEPORT`, `TCP_DEFER_ACCEPT`, `EPOLLONESHOT`) and zero-copy HTTP/1.1 parser |
| Postgres driver | `github.com/jackc/pgx/v5` v5.11.0 (`pgconn` extended binary protocol + pipeline mode) |
| JSON | Custom binary-row encoder (8-byte unrolled string escaper) + zero-alloc flat JSON body scanner with `encoding/json` fallback |
| JWT | `github.com/KaikeGM/zerojwt/v2` v2.2.0 (`VerifyWithScratch` / `SignWithScratch`, 0 allocs/op) with `github.com/golang-jwt/jwt/v5` fallback |
| bcrypt | 4-lane bit-sliced/interleaved pure-Go Eksblowfish (cost 10) with `golang.org/x/crypto/bcrypt` fallback |

## Key Optimizations (`go-epoll-kaikegm`)

1. **Family-Affinity Read Routing & Adaptive Batching (`src/db.go`, `src/api.go`):**
   - Requests are classified into 8 read families (`GET /api/tags`, `GET /api/articles` unfiltered/tag/author/favorited, `GET /api/articles/feed`, `GET /api/articles/:slug`, `GET /api/articles/:slug/comments`, `GET /api/profiles/:username`, `GET /api/user`) at HTTP frame time before leaving the reactor loop.
   - Each read connection worker owns an independent ring queue (`w.q`) and tracks in-queue counts per `readFamily`. Incoming read jobs route to a worker already accumulating the same family (within `readRouteSlack = 8`), maximizing batch homogeneity.
   - While one batch is in flight on a connection, the worker holds subsequent queued requests until a full batch (`readBatch = 16`) accumulates or the in-flight batch completes, forming large coalesced batches under load with zero artificial linger delay when idle.

2. **Broadcast, Coalesced `LATERAL`, and Shared-Enrichment `MATERIALIZED` CTE Queries (`src/sql.go`, `src/db.go`):**
   - **`groupBroadcast` (`GET /api/tags`):** Executes `stTags` once and broadcasts the serialized JSON response across all requests in the group.
   - **`groupCoalesced` (`unnest(...) WITH ORDINALITY CROSS JOIN LATERAL`):** Collapses up to 16 concurrent single-row or feed/comment reads into a single PostgreSQL statement execution, demultiplexed by `__ord` in `rowReader`.
   - **Shared-Enrichment Article List CTEs (`stShareListAll`, `stShareListTag`, `stShareListAuthor`, `stShareListFavorite`):** Deduplicates `(filter, limit, offset)` pages (`distinct_pages`), computes `LIMIT 1000` bounded counts once per distinct filter (`distinct_filters`), aggregates tags once per distinct article ID (`article_tag_arrays`), and enriches author/favorite/following metadata once per distinct `(article_id, viewer_id)` pair (`enriched`). Reduces buffer hits by >3x on concurrent article list queries.

3. **Short-Circuit Anonymous Viewer & Single-Pass Count Subqueries (`src/sql.go`):**
   - All `EXISTS (... WHERE follower_id = $1)` and `EXISTS (... WHERE user_id = $1)` subqueries guard on `$1::bigint <> 0`, eliminating B-tree index probes when `viewer == 0` (anonymous traffic).
   - `favoritesCount` uses an index-only scan on `favorites_article_idx` (`WHERE f.article_id = a.id`).
   - `countByTag` uses a single-pass `SELECT count(*) FROM (SELECT 1 FROM article_tags WHERE tag_id = ... LIMIT 1000) s`, cutting tag count buffer hits in half.

4. **Zero-Allocation Hot Path (`src/jwt.go`, `src/util.go`, `src/jsonw.go`):**
   - JWT HS256 verification and signing use `zerojwt/v2` (`VerifyWithScratch` / `SignWithScratch`) with per-worker stack/struct scratch buffers.
   - Write request bodies (`POST/PUT`) use `parseFastWrapper` to scan flat JSON payloads in-place without heap allocations.
   - JSON string escaping processes 8 bytes per iteration using a 256-entry lookup table.

## Build and run

```bash
sudo bash install.sh && bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

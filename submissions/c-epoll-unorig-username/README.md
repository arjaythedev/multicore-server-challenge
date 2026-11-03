# C / epoll

Front: direct

| | |
|---|---|
| Language | C11, built with Ubuntu 24.04's gcc 13 from `build-essential` |
| Framework | none: HTTP/1.1 on raw `epoll` |
| Database driver | none: own PostgreSQL wire client (SCRAM-SHA-256, prepared statements, binary rows, no RowDescription) |
| Database | PostgreSQL 18 |
| Other dependencies | none beyond libc. JSON, JWT, SHA-256, bcrypt and gzip are written here |

```sh
sudo bash install.sh && bash build.sh
DATABASE_URL=... JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

No caches across requests, no schema or Postgres config changes, no host tuning. Session-level `SET` only.

@@RESULTS@@

## 1. Flat statements, joined here

The top entries send Postgres one large statement per batch, so each article is read once. This one sends a pipeline of
flat index scans over keys that are already distinct and sorted, and does every join in the server:

```
 phase 1   tags, users, list windows, follows of feed viewers, articles by slug, comment threads
 phase 2   each distinct followee's newest ids; the viewer's feed is merged here
 phase 3   article rows for every id on every page
 phase 4   article_tags, favorite counts, authors, favorited pairs, following pairs
```

Nothing is materialized, aggregated into arrays or sorted inside Postgres unless an index gives it for free, and a list
window is shared by every page of that list in the batch. Rendering happens once per article and once per author, and
each response is assembled from those pieces. Everything lives in an arena that is reset before the next batch.

Two details matter a lot:

- **Two-array lookups are pinned to the primary key.** With `user_id = ANY($1) AND article_id = ANY($2)` the generic plan
  picks `favorites_article_idx` and filters `user_id` linearly: on the first run this statement was 87% of all Postgres
  statement time. `OFFSET 0` around the primary-key scan pins it, and a hash join applies the second array. `enable_indexscan
  = off` does not help on Postgres 18: it disables index-only scans too, and the planner then goes by cost.
- **Feeds merge here, from each followee once.** Two viewers sharing a followee share its scan. Feed requests are a small
  share of traffic but their statement was 29% of Postgres statement time.

## 2. Feed counts: the likely hub first

`articlesCount` stops at 1,000, and most viewers follow an author with 1,000+ articles, which alone settles it (307 of 399
sampled viewers, through just 28 such authors). Counting was costlier than reading the ids (43 ms against 24 ms on a batch
of 5,336 followees). So:

1. An id array shorter than requested holds all that author's articles, so it is already the exact count.
2. Authors whose newest ids fall densely enough to suggest 600+ articles are counted first.
3. Everyone else's counts are read only for viewers still unsettled.

The result is the exact capped count either way; the estimate only decides the order. In paired holds at 200k users this
took Postgres from 59.4 and 58.4 µs per request to 52.8 and 52.7.

## 3. Longer drain gaps, because the limit is 500 ms

Each lane (feeds, comments, the rest) starts a drain at most every 160 ms. A bigger batch shares more, and p95 has room. At
230k users on the test box, 160 ms against 80 ms took Postgres from 54.9 and 53.9 µs per request to 46.1, and p95 from 184
and 182 ms to 327 ms. A freed connection goes to the lane whose oldest read has waited longest, with at most 6 drains at
once.

## 4. bcrypt

- A hand-written x86-64 kernel (`src/bf_x86.S`) keeps five lanes' L and R in general-purpose registers. 12.6 ms per hash
  against 49.6 ms for one lane, and 14.7 ms for the same five lanes in C. Chosen at startup if the CPU has BMI2, and checked
  against vectors from `golang.org/x/crypto/bcrypt` at every lane count.
- A hasher waits up to 150 ms for a full set of lanes. Without that, hashes ran one or two lanes at a time.
- Hashers run at `SCHED_IDLE`. A watchdog at normal priority takes over any batch held up for 700 ms, so a saturated box slows
  logins but never strands them.

## 5. Scheduling

Event loops run under `SCHED_BATCH` at nice 5, and database threads under `SCHED_BATCH`, so a wakeup doesn't preempt a Postgres
backend mid-query.

## 6. Packets and sharing

- **Gzip only when it saves a TCP segment**, with a fixed Huffman table shaped by typical responses. It costs CPU: 5-7% of
  the box on a NIC with 8 queues. But with one NIC queue, p95 at 200k users was 174-178 ms with it and 303-304 ms without.
- **Identical reads in a batch share one response** when no viewer flag is set. It is freed when its last send completes, and
  each batch starts with nothing shared.

## 7. Writes

Up to 128 writes go out with one Sync, with no `BEGIN`/`COMMIT`, so they share a transaction and a WAL flush, and each is
answered only after ReadyForQuery. Favorites and article writes then answer through the read queue, so the response is read
after the commit.

## Failure handling

`tests/failure_test.sh` runs these against a live server:

- A statement failure rolls the group back and retries each write alone, so duplicates, unknown users and missing articles
  fail only themselves.
- A lost read connection reconnects and retries. After a few attempts the request is answered 500 rather than left hanging.
- A write whose connection dies mid-group is answered 500: its commit is unknown, so nothing is claimed.
- With backends killed, Postgres crashed, then down for 6 s, under load: @@FAILURE@@
- `accept()` out of descriptors stops accepting for 100 ms instead of exiting. Each loop has its own fd table
  (`unshare(CLONE_FILES)`), so `LimitNOFILE` applies per loop.
- Reads from clients that hung up are dropped before they reach Postgres.

## Tried and dropped

@@DROPPED@@

## Credits

Ideas borrowed: the drain gap and lanes from nick-potts' #79, #117 and #168; the freed connection going to the oldest waiting
lane from theCatWisel's #154, which is also where the flat array-scan phases and the shared global window come from; dropping
reads of clients that hung up from theCatWisel's #132; SCHED_BATCH and SCHED_IDLE hashers from #130 and #168; gzip only when it
saves a segment, and group commit without `BEGIN`/`COMMIT`, from #168; sharing a response within a batch from #31, #132 and
#143; the private fd table from #154. The bcrypt vectors come from `golang.org/x/crypto/bcrypt`; the array-parameter reads
and the mutation statements started from go-epoll-unorig-username (#89).

Ours: every join in the server with Postgres doing only flat scans, the hash-joined flag statements, feeds merged from each
followee once, feed counts ordered by estimated hub, and the choice of drain gap against the p95 limit.

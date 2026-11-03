# C / epoll

Front: direct

Written in C11 and built with the gcc 13 that Ubuntu 24.04's `build-essential` installs. There is no framework and nothing
beyond libc: HTTP/1.1 on raw `epoll`, and in-tree JSON, JWT, SHA-256, bcrypt, gzip and a PostgreSQL client (SCRAM-SHA-256,
prepared statements, binary rows, no RowDescription) for PostgreSQL 18.

```sh
sudo bash install.sh && bash build.sh
DATABASE_URL=... JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

No caches across requests, no schema or Postgres config changes, no host tuning. Session-level `SET` only.

@@RESULTS@@

## 1. Flat statements, joined here

Each drain sends a pipeline of index scans over keys that are already distinct and sorted, in phases. The phased shape, and
reading each article and author once, follow theCatWisel's #154. Array parameters follow #7. This entry takes it further by
keeping joins out of Postgres altogether:

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
- **Feeds merge here, from each followee once.** #154 and #168 compute each viewer's feed page in SQL. Here two viewers sharing
  a followee share its scan, and the server does the merge. Feed requests are a small share of traffic, but their statement was
  29% of Postgres statement time, so this is still where much of the cost sits.

## 2. Feed counts: the likely hub first

`articlesCount` stops at 1,000, so an author with 1,000+ articles settles a viewer's count alone. That shortcut is #61's, and
#105 and #168 use it as well. Here 307 of 399 sampled viewers followed one of just 28 such authors, and counting cost more than
reading the ids (43 ms against 24 ms on a batch of 5,336 followees). What this entry adds is how it finds those authors with no
extra query:

1. An id array shorter than requested holds all that author's articles, so it is already the exact count.
2. Authors whose newest ids fall densely enough to suggest 600+ articles are counted first.
3. Everyone else's counts are read only for viewers still unsettled.

The result is the exact capped count either way; the estimate only decides the order. In paired holds at 200k users this
took Postgres from 59.4 and 58.4 µs per request to 52.8 and 52.7.

## 3. Longer drain gaps, because the limit is 500 ms

Each lane (feeds, comments, the rest) starts a drain at most every 160 ms. A bigger batch shares more, and p95 has room. At
230k users on the test box, 160 ms against 80 ms took Postgres from 54.9 and 53.9 µs per request to 46.1, and p95 from 184
and 182 ms to 327 ms. A freed connection goes to the lane whose oldest read has waited longest, with at most 6 drains at
once. That cap of 6 and the 8 read connections are #168's values, kept without a sweep of my own. The gap is the one constant
here that was tested against the leader's, and only at those two values.

## 4. bcrypt

- A hand-written x86-64 kernel (`src/bf_x86.S`) keeps five lanes' L and R in general-purpose registers. 12.6 ms per hash
  against 49.6 ms for one lane, and 14.7 ms for the same five lanes in C. Chosen at startup if the CPU has BMI2, and checked
  against vectors from `golang.org/x/crypto/bcrypt` at every lane count.
- A hasher waits up to 150 ms for a full set of lanes. Without that, hashes ran one or two lanes at a time.
- Hashers run at `SCHED_IDLE`. A watchdog at normal priority takes over any batch held up for 3 s, so a saturated box slows
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
answered only after ReadyForQuery. 128 comes from go-epoll-unorig-username (#89) and #168 uses the same number; it wasn't swept. Favorites and article writes then answer through the read queue, so the response is read
after the commit.

## Failure handling

`tests/failure_test.sh` runs these against a live server:

- A statement failure rolls the group back and retries each write alone, so duplicates, unknown users and missing articles
  fail only themselves.
- A lost read connection reconnects and retries. After a few attempts the request is answered 500 rather than left hanging.
- A write whose connection dies mid-group is answered 500: its commit is unknown, so nothing is claimed.
- With backends killed, Postgres crashed, then down for 6 s, under load: 127,743 writes claimed and every one found in the database afterwards, 97 answered 500, the
  longest request 4.3 s, and the server still up.
- `accept()` out of descriptors stops accepting for 100 ms instead of exiting. Each loop has its own fd table
  (`unshare(CLONE_FILES)`), so `LimitNOFILE` applies per loop.
- Reads from clients that hung up are dropped before they reach Postgres.

## Tried and dropped

| Tried | Measured | |
|---|---|---|
| AVX-512 gather bcrypt, 16 lanes | 18.5 ms per hash against 12.95 ms | dropped |
| One `rorx` per two index bytes, using the high-byte register | 15.0 ms against 13.2 ms | dropped |
| Phase 4 on parallel helper connections | 7% more Postgres CPU per request, no steady latency gain on an aged database | dropped |
| Database threads at the default policy | p95 1,482 and 1,666 ms against 1,310 and 1,277 ms on an aged database | dropped |
| 80 and 100 ms gaps on an aged database | p95 no better, Postgres CPU higher | dropped |

## Credits

Borrowed, by section:

- Section 1: phases of array scans, each article and author read once, fragments rendered once (#154); array-parameter batching
  (#7); the mutation statements (go-epoll-unorig-username, #89).
- Section 2: the 1,000-article count shortcut (#61, also #105 and #168).
- Section 3: the drain gap and lanes (#79, #117, #168), a freed connection going to the oldest waiting lane (#154), the cap of 6
  drains and 8 read connections (#168).
- Section 4: register-resident multi-lane kernels (#130, #154, #168), SCHED_IDLE hashers with a watchdog (#168). This watchdog
  restarts a batch, where #168's resumes from a saved round. Test vectors come from `golang.org/x/crypto/bcrypt`.
- Section 5: SCHED_BATCH and nice 5 for loops (#130, #168).
- Section 6: gzip only when it saves a segment (#168), with an encoder written here; sharing a response within a batch (#31, #132,
  #143, #168).
- Section 7: group commit without `BEGIN`/`COMMIT` (#168).
- Also: dropping reads of clients that hung up (#132), and a private fd table per loop (#154).

New in this entry, as far as I could find: feeds merged in the server from one scan per followee, flag lookups as one hash-joined
scan pinned with `OFFSET 0`, and ordering feed counts by id density.

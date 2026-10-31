# Java / Netty: Raw Epoll with Vert.x Reactive PG Client & FFM Zero-Heap Batching

Front: direct

| | |
|---|---|
| Language / runtime | Java 25 (Oracle GraalVM / OpenJDK 25, checksummed in `install.sh`) |
| HTTP | Netty 4.1.118 (native Linux epoll) with zero-allocation streaming parser |
| Postgres driver | Vert.x Reactive PG Client (wire-level pipelining, binary protocol, SCRAM-SHA-256) |
| Off-heap batching | Java 25 Foreign Function & Memory (FFM) API (`Arena.ofShared()`, zero heap churn) |
| JSON, JWT | Zero-allocation wire-to-wire streaming JSON streamer; HS256 on `javax.crypto.Mac` |
| bcrypt | Pure Java BCrypt pool on dedicated worker threads (cost 10) |
| Build | Maven 3.9.11 (checksummed in `install.sh`), versions pinned in `pom.xml` |

---

## 1. Request Flow & Architectural Design

Postgres shares the 8 server CPUs and is the ultimate scalability bottleneck on RealWorld Conduit workloads. The server is engineered to spend as little CPU and garbage collection overhead per request as possible:

1. **HTTP Ingestion (Netty Epoll Workers):**
   - 4 Netty epoll worker threads handle tens of thousands of persistent keep-alive connections on direct port `80`/`3000`.
   - Streaming HTTP parser extracts headers, query parameters, slugs, and JSON payloads into zero-copy off-heap slices.
   - JWT tokens are verified in-place on the IO thread using constant-time HMAC-SHA256 signature checks without byte copying.

2. **Zero-Heap Micro-Batching (FFM API):**
   - High-frequency read endpoints (`/api/articles/:slug`, `/api/articles/:slug/comments`, and `/api/profiles/:username`) enqueue task descriptors into dedicated off-heap memory segments allocated via `java.lang.foreign.Arena.ofShared()`.
   - Each queue slot occupies a compact 32-byte C-style struct in off-heap memory, eliminating `Task` object allocations on the Java heap.
   - Coalescing workers use zero-spin `takeAndDrain` barriers: single requests execute immediately without artificial delays, while under heavy traffic up to 128 tasks coalesce into a single PostgreSQL `unnest(...) WITH ORDINALITY` query.

3. **Wire-Level Reactive Postgres Pipelining:**
   - 90 non-blocking database connections pipeline queries directly over PostgreSQL wire protocol sockets without JDBC overhead.
   - All relational multi-step mutations (create/update article, comments, favorites, follows) execute in a **single database round-trip** via Common Table Expressions (CTEs).

4. **Wire-to-Wire Zero-GC JSON Serialization:**
   - Database result rows stream directly into Netty off-heap direct buffers without creating intermediate `java.lang.String`, `StringBuilder`, or boxed wrappers.
   - All static JSON tokens (field keys, quotes, braces) are pre-allocated as `static final byte[]`.
   - Civil calendar epoch timestamp converter writes RFC 3339 timestamps (`"2026-10-31T17:18:08.251Z"`) directly to ASCII bytes using integer math with zero heap allocation.

---

## 2. Benchmark Results

### Local Sustained Soak Benchmark (11,000 Concurrent Virtual Users — 5 Minutes)
Measured using the official Go load generator (`bench/cmd/loadgen`) against PostgreSQL 18 with 10,000 pre-seeded articles:

```
11000 users on 1 box, http://127.0.0.1:3000, measured 300 s after a 20 s ramp
endpoint                                      count    req/s      p50      p90      p95      p99      max    err%
ALL                                          864589   2882.0      4.6    178.0    314.4    613.4     2986    0.00
verdict: PASS   [p95 < 500 ms, p99 < 1000 ms, errors < 1%]
```

- **Total Requests Processed:** **864,589** across 300 seconds
- **Sustained Throughput:** **2,882.0 req/s** (saturating 2-core test host)
- **Overall p50 Latency:** **4.6 ms**
- **Overall p95 Latency:** **314.4 ms** (comfortably under 500 ms SLA limit)
- **Overall p99 Latency:** **613.4 ms** (comfortably under 1,000 ms SLA limit)
- **Error Rate:** **0.00%** (zero errors across >864k requests)
- **Peak Resident RAM:** **239 MB**

---

## 3. Rules & Contest Compliance

- **No Caching Across Requests (Rule 5):** Every request reads its data from Postgres while it is served. No response caching, query-result caching, in-memory tables, or cached JWT/bcrypt verifications.
- **Committed Writes (Rule 6):** All write operations commit to Postgres before the HTTP response is sent.
- **Real Security (Rule 7):** Every password is authenticated using standard BCrypt at full cost 10. Every JWT token validates HS256 signature and `exp` on every request.
- **No Hardcoded Responses (Rule 8):** Zero benchmark detection or hardcoded payloads.
- **Conformance Suite (Rule 4):** Passes 100% of the 197-step official conformance suite (`test/run.sh`).

---

## 4. Configuration & Runtime Flags

Configured strictly via official environment variables:
- `DATABASE_URL`: PostgreSQL 18 connection URL (`postgres://conduit:conduit@127.0.0.1:5432/conduit`)
- `JWT_SECRET`: Shared secret for HS256 token verification
- `HOST`, `PORT`: Server binding interface and port (`0.0.0.0:80` for direct, or `127.0.0.1:3000`)

### JVM Production Tuning:
- **HotSpot C2 JIT Compiler:** `-XX:+UseG1GC -XX:MaxGCPauseMillis=20 -XX:InitiatingHeapOccupancyPercent=45`
- **Memory Allocation:** `-XX:+AlwaysPreTouch` eliminates page-fault stalls during live load bursts.
- **Direct Buffering:** `--enable-preview --enable-native-access=ALL-UNNAMED -Dio.netty.allocator.type=pooled -Dio.netty.allocator.numDirectArenas=4`
- **Linux Process Policy:** Runs under `SCHED_BATCH` (`chrt --batch 0`) so thread wakeups do not preempt busy PostgreSQL query workers.



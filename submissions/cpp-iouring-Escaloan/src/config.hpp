// All tunables for the server, as compile-time constants. Sweep a value by editing it and rebuilding.
// Runtime configuration comes only from the environment (DATABASE_URL, JWT_SECRET, HOST, PORT).
#pragma once
#include <cstddef>
#include <cstdint>

namespace cfg {

// ---- threads ----
// Event loops are derived from the CPUs this process may run on, so ratios tuned on a 4-vCPU dev VM carry over
// to the 8-vCPU box (8 / 4 = 2 loops). App threads compete with Postgres for the same cores.
inline constexpr int kCpusPerEventLoop = 4;
inline constexpr int kEventLoopsFallback = 2;  // used only if the CPU count cannot be read
inline constexpr int kMaxEventLoops = 16;
inline constexpr int kBcryptThreads = 1;
inline constexpr int kBcryptNice = 0;          // setpriority() for bcrypt threads; 0 = same as event loops
inline constexpr int kBcryptBatchWaitMs = 100; // wait up to this long to fill a 4-way interleaved batch
inline constexpr int kBcryptCost = 10;

// ---- postgres ----
inline constexpr int kReadConnsPerLoop = 4;
inline constexpr int kWriteConnsPerLoop = 1;
inline constexpr int kReadDepth = 1;           // in-flight sync groups per read connection
inline constexpr int kBatchMaxPoint = 64;      // article / profile / user lookups
inline constexpr int kBatchMaxComments = 32;
inline constexpr int kBatchMaxList = 16;       // global, tag, author, favorited lists
inline constexpr int kBatchMaxFeed = 8;
inline constexpr int kFeedMaxInflight = 2;     // read connections per loop that may run feed batches at once
inline constexpr int kWriteBatchMax = 128;
inline constexpr bool kTagsShareExecution = true;   // queued /api/tags requests share one execution
inline constexpr bool kBatchReads = true;           // false = every read runs its single-form statement alone
inline constexpr bool kListSharedEnrichment = true;
inline constexpr bool kShareCountsInExecution = true; 
inline constexpr bool kFeedSharedEnrichment = false; // For testing purposes
inline constexpr int kFeedSharedMinBatch = 2;
inline constexpr int kDeepOffset = 200;             // offsets above this use the deep-offset statement forms
inline constexpr int kPgStatementTimeoutMs = 5000;
inline constexpr int kPgReconnectMinMs = 100;
inline constexpr int kPgReconnectMaxMs = 2000;
inline constexpr std::size_t kPgSendBufInitial = 64 * 1024;
inline constexpr std::size_t kPgRecvBufInitial = 256 * 1024;

// ---- io_uring / network ----
inline constexpr unsigned kSqEntries = 4096;
inline constexpr unsigned kCqEntries = 16384;
inline constexpr int kCqeBurst = 256;          // CQEs drained per tick before dispatching queued work
inline constexpr int kListenBacklog = 65535;
inline constexpr std::size_t kRecvScratchBytes = 64 * 1024;
inline constexpr int kAcceptBackoffMs = 10;    // re-arm delay after EMFILE/ENFILE
inline constexpr std::uint32_t kMaxConnsPerLoop = 1u << 18;  // slot table capacity (virtual memory only)

// ---- http ----
inline constexpr std::size_t kMaxHeaderBytes = 8 * 1024;
inline constexpr std::size_t kMaxBodyBytes = 1024 * 1024;
inline constexpr int kPartialRequestTimeoutS = 30;
inline constexpr std::size_t kHeaderReserve = 128;  // bytes reserved in front of a response body for headers

// ---- memory ----
// Slab classes: 1 KiB, 4 KiB, 16 KiB, 64 KiB, 256 KiB, 1 MiB, 4 MiB. The largest holds a maximal request
// (8 KiB headers + 1 MiB body) and any response the API can produce from normal data.
inline constexpr int kSlabClasses = 7;
inline constexpr std::size_t kSlabMinShift = 10;    // 1 KiB
inline constexpr std::size_t kSlabShiftStep = 2;    // x4 per class
// Per-loop cap on bytes held by each class; past it new requests wait (backpressure).
inline constexpr std::size_t kSlabClassCapBytes = 256ull * 1024 * 1024;
inline constexpr std::size_t kSlabChunkBytes = 2 * 1024 * 1024;  // allocation granule (huge-page sized)
// A/B switch: true sends every request/response buffer through malloc/free instead of the slab pools.
inline constexpr bool kHeapBuffers = false;

// ---- stats ----
inline constexpr bool kStatsEnabled = true;
inline constexpr int kStatsIntervalS = 10;

}  // namespace cfg

#ifndef CONFIG_H
#define CONFIG_H

/* every tunable lives here; values fixed by external contract (status codes,
 * SQLSTATEs, bcrypt cost, SPEC limits) stay at their use site */

#define DEFAULT_HOST                "0.0.0.0"
#define DEFAULT_PORT                "3000"
#define NPROC_FALLBACK              4
#define WORKERS_DEFAULT_MIN         2
#define WORKERS_DEFAULT_MAX         4       // adaptive default: clamp(cores/2)
#define WORKERS_MAX                 32      // = pg's shared scheduler slot count

#define LISTEN_BACKLOG              4096
#define ACCEPT_BURST                128     // accepts per loop turn
#define CONN_READ_CHUNK             16384   // one recv per syscall, looped while it fills
#define IN_COMPACT_THRESHOLD        (64 * 1024) // compact in-buf once this much is consumed
#define IDLE_TIMEOUT_MS             70000   // > nginx's 60 s upstream keep-alive (SPEC)
#define SWEEP_INTERVAL_MS           1000
#define IDLE_BUF_CAP                4096    // idle keep-alives drop big bufs

#define HTTP_METHOD_MAX             8
#define HTTP_PATH_MAX               1024
#define HTTP_QUERY_MAX              2048
#define AUTH_TOKEN_MAX              1024
#define HTTP_HEADER_BLOCK_MAX       16384
#define BODY_MAX                    (1024 * 1024)
#define HTTP_MAX_BUFFER             (BODY_MAX + IN_COMPACT_THRESHOLD)

#define ARENA_BLOCK_BYTES           1024
#define FILTER_MAX                  256     // tag/author/favorited query values
#define JSON_MAX_DEPTH              64
#define BUF_MIN_CAPACITY            256

#define PAGE_LIMIT_DEFAULT          20
#define PAGE_LIMIT_MAX              100     // SPEC: limit 1..100
#define OFFSET_MAX                  (1LL << 62) // keeps count math inside bigint

#define PG_CONNS_PER_WORKER         4       // one write + three reads
#define PG_CONNS_MAX_TOTAL          90      // SPEC: <= 95 process-wide
#define PG_WRITE_CONNS_PER_WORKER   1
#define PG_READ_BATCH               512     // requests per shared batched read
#define PG_READ_WINDOW_MS           0       // 0: dispatch as soon as a conn frees
#define PG_READ_TAG_BATCH           1024    // tags broadcast may cover every waiter
#define PG_WRITE_GROUP              32      // writes sharing one transaction
#define PG_WRITE_GROUP_MAX          64
#define PG_WRITE_WINDOW_MS          5       // let a lone write gather siblings
#define PG_WRITE_IMMEDIATE          4       // a queue this deep commits now

#define PG_RECONNECT_BACKOFF_MIN    100     // first retry after a lost conn
#define PG_RECONNECT_BACKOFF_MAX    5000    // exponential retry cap

#define CRYPTO_THREADS_DIV          1       // one bcrypt lane per core
#define CRYPTO_THREADS_MIN          1

#endif

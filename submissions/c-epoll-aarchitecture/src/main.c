#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>

#include "api/api.h"
#include "api/route.h"
#include "config.h"
#include "core/server.h"
#include "crypto/offload.h"
#include "util.h"

static void *worker_main(void *arg) {
    srv_worker_run((srv_worker *)arg);
    return NULL;
}

static int env_positive(const char *name, int fallback) {
    const char *value = getenv(name);
    if (!value || !*value) return fallback;
    char *end = NULL;
    errno = 0;
    long parsed = strtol(value, &end, 10);
    if (errno != 0 || !end || *end != '\0' || parsed <= 0 || parsed > 200)
        return fallback;
    return (int)parsed;
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);

    /* suite keeps many idle keep-alive conns; images ship a soft limit far
     * below the hard one */
    struct rlimit nofile;
    CHECK(getrlimit(RLIMIT_NOFILE, &nofile) == 0,
          "getrlimit RLIMIT_NOFILE: %s", strerror(errno));
    nofile.rlim_cur = nofile.rlim_max;
    CHECK(setrlimit(RLIMIT_NOFILE, &nofile) == 0,
          "setrlimit RLIMIT_NOFILE: %s", strerror(errno));

    const char *db_url = getenv("DATABASE_URL");
    if (!db_url || !*db_url) FATAL("DATABASE_URL is required");
    const char *secret = getenv("JWT_SECRET");
    if (!secret || !*secret) FATAL("JWT_SECRET is required");
    const char *host = getenv("HOST");
    if (!host || !*host) host = DEFAULT_HOST;
    const char *port = getenv("PORT");
    if (!port || !*port) port = DEFAULT_PORT;

    long cores = sysconf(_SC_NPROCESSORS_ONLN);
    if (cores < 1) cores = NPROC_FALLBACK;

    /* adaptive default: a shared read scheduler keeps every core busy without
     * one lucky worker, so scale with core count (clamped 2..4: top entries
     * use 2-4 and more conns cost more than they earn) */
    int default_workers = (int)cores / 2;
    if (default_workers < WORKERS_DEFAULT_MIN)
        default_workers = WORKERS_DEFAULT_MIN;
    if (default_workers > WORKERS_DEFAULT_MAX)
        default_workers = WORKERS_DEFAULT_MAX;
    int nworkers = env_positive("WORKERS", default_workers);
    if (nworkers > WORKERS_MAX) nworkers = WORKERS_MAX;

    /* pool budget is process-wide: workers * per stays under pg's connection
     * allowance (SPEC). one write lane per worker, rest batch reads */
    int max_total = env_positive("PG_CONNS_MAX_TOTAL", PG_CONNS_MAX_TOTAL);
    int per_worker = max_total / nworkers;
    if (per_worker > PG_CONNS_PER_WORKER) per_worker = PG_CONNS_PER_WORKER;
    int write_conns = PG_WRITE_CONNS_PER_WORKER;
    int read_conns = per_worker - write_conns;
    if (read_conns < 1)
        FATAL("connection budget %d is too small for %d workers", max_total,
              nworkers);

    int read_batch = env_positive("READ_BATCH", PG_READ_BATCH);
    int read_window_ms = env_positive("READ_WINDOW_MS", PG_READ_WINDOW_MS);
    int write_group = env_positive("WRITE_GROUP", PG_WRITE_GROUP);
    if (write_group > PG_WRITE_GROUP_MAX) write_group = PG_WRITE_GROUP_MAX;
    int write_window_ms = env_positive("WRITE_WINDOW_MS", PG_WRITE_WINDOW_MS);

    int crypto_threads =
        env_positive("CRYPTO_THREADS", (int)cores / CRYPTO_THREADS_DIV);
    if (crypto_threads < CRYPTO_THREADS_MIN) crypto_threads = CRYPTO_THREADS_MIN;

    route_init();
    crypto_init(crypto_threads, nworkers);

    const conn_hooks hooks = {
        .on_request = api_begin,
        .on_abandon = api_abandon,
    };

    srv_worker *workers = xcalloc((size_t)nworkers, sizeof *workers);
    for (int i = 0; i < nworkers; i++)
        srv_worker_init(&workers[i], i, db_url, read_conns, write_conns,
                        read_batch, read_window_ms, write_group, write_window_ms,
                        secret, host, port, &hooks);

    pthread_t *threads = xmalloc((size_t)nworkers * sizeof *threads);
    for (int i = 0; i < nworkers; i++) {
        /* bind the completion eventfd before the worker thread runs its loop */
        crypto_bind(i, workers[i].loop);
        int rc = pthread_create(&threads[i], NULL, worker_main, &workers[i]);
        if (rc != 0) FATAL("pthread_create: %s", strerror(rc));
    }
    for (int i = 0; i < nworkers; i++) pthread_join(threads[i], NULL);
    return 0;
}

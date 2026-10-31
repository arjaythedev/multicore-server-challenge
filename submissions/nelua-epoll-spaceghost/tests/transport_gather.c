/* Exercise the actual queue/worker implementation without PostgreSQL or sockets.
 * The host callbacks below count ownership and deliberately block one execution
 * so a second batch must be collected and execute concurrently. */
#define main nc_transport_program_main
#include "../src/transport.c"
#undef main

#include <assert.h>

struct nc_request { unsigned id; };

static pthread_mutex_t test_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t test_changed = PTHREAD_COND_INITIALIZER;
static unsigned seen[64], handled, executions, active, max_active;
static bool release_first;

nc_db *nc_db_open(const char *url) { (void)url; return (nc_db *)1; }
void nc_db_close(nc_db *db) { assert(db == (nc_db *)1); }
void conduit_handle(nc_request *req, nc_db *db)
{ (void)req; (void)db; abort(); }

void conduit_batch(nc_request **requests, int count, nc_db *db)
{
    assert(db == (nc_db *)1 && count > 0 && count <= NC_READ_BATCH_MAX);
    pthread_mutex_lock(&test_lock);
    unsigned ordinal = ++executions;
    ++active;
    if (active > max_active) max_active = active;
    for (int i = 0; i < count; ++i) {
        assert(requests[i]->id < 64);
        assert(++seen[requests[i]->id] == 1);
        ++handled;
    }
    pthread_cond_broadcast(&test_changed);
    if (ordinal == 1) {
        while (!release_first) pthread_cond_wait(&test_changed, &test_lock);
    }
    --active;
    pthread_cond_broadcast(&test_changed);
    pthread_mutex_unlock(&test_lock);
}

static void wait_for(unsigned *value, unsigned minimum)
{
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 5;
    pthread_mutex_lock(&test_lock);
    while (*value < minimum)
        assert(pthread_cond_timedwait(&test_changed, &test_lock, &deadline) == 0);
    pthread_mutex_unlock(&test_lock);
}

static void enqueue(nc_connection *connections, unsigned first, unsigned count)
{
    nc_pool *pool = &server.pools[0];
    pthread_mutex_lock(&pool->lock);
    for (unsigned i = first; i < first + count; ++i) {
        connections[i].queued_at = nc_now();
        connections[i].queue_next = NULL;
        if (pool->tail) pool->tail->queue_next = &connections[i];
        else pool->head = &connections[i];
        pool->tail = &connections[i];
    }
    pthread_cond_broadcast(&pool->available);
    pthread_mutex_unlock(&pool->lock);
}

int main(int argc, char **argv)
{
    assert(argc == 3);
    bool shutdown_early = atoi(argv[2]) != 0;
    struct nc_request requests[64];
    nc_connection connections[64];
    memset(&server, 0, sizeof(server));
    memset(connections, 0, sizeof(connections));
    server.serial_read_gather = atoi(argv[1]) != 0;
    server.read_batch_stats = true;
    server.completion_fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    assert(server.completion_fd >= 0);
    pthread_mutex_init(&server.startup_lock, NULL);
    pthread_cond_init(&server.startup_ready, NULL);
    pthread_mutex_init(&server.done_lock, NULL);
    for (int i = 0; i < 3; ++i) {
        pthread_mutex_init(&server.pools[i].lock, NULL);
        pthread_mutex_init(&server.pools[i].gather_lock, NULL);
        pthread_cond_init(&server.pools[i].available, NULL);
    }
    for (unsigned i = 0; i < 64; ++i) {
        requests[i].id = i;
        connections[i].request = &requests[i];
    }
    for (unsigned i = 0; i < 4; ++i) {
        assert(pthread_create(&server.workers[i], NULL, nc_worker, &server.pools[0]) == 0);
        ++server.worker_count;
    }
    pthread_mutex_lock(&server.startup_lock);
    while (server.ready_count < 4)
        pthread_cond_wait(&server.startup_ready, &server.startup_lock);
    pthread_mutex_unlock(&server.startup_lock);

    if (shutdown_early) {
        release_first = true;
        enqueue(connections, 0, 1);
        nc_stop_workers();
        assert(handled <= 1);
    } else {
        enqueue(connections, 0, 32);
        wait_for(&executions, 1);
        enqueue(connections, 32, 32);
        wait_for(&executions, 2);
        pthread_mutex_lock(&test_lock);
        assert(max_active >= 2); /* Collection lock cannot cover execution. */
        release_first = true;
        pthread_cond_broadcast(&test_changed);
        pthread_mutex_unlock(&test_lock);
        wait_for(&handled, 64);
        nc_stop_workers();
        assert(server.read_requests == 64);
        assert(server.read_batches >= 2);
        for (unsigned i = 0; i < 64; ++i) assert(seen[i] == 1);
        assert(server.read_max_batch <= 32);
    }
    close(server.completion_fd);
    printf("PASS: gather serial=%d early_stop=%d handled=%u batches=%llu concurrent=%u\n",
           server.serial_read_gather, shutdown_early, handled,
           (unsigned long long)server.read_batches, max_active);
    return 0;
}

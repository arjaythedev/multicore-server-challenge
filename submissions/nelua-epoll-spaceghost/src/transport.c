/* Linux socket ownership stays on one epoll thread. Nelua runs in bounded DB lanes. */
#define _GNU_SOURCE
#include "native.h"

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

#define NC_EVENTS 1024
#define NC_PENDING_MAX 4096U
#define NC_PENDING_BYTES (128U * 1024U * 1024U)
#define NC_INPUT_BYTES (256U * 1024U * 1024U)
#define NC_INPUT_MAX (1024U * 1024U + 65536U)
#define NC_INITIAL_INPUT 4096U
#define NC_IDLE_MS 75000U
#define NC_HEADER_MS 15000U
#define NC_WRITE_MS 30000U
#define NC_READ_BATCH_MAX 128
#define NC_READ_WINDOW_MS 8U

/* Also declared by native.h once the Nelua batch entrypoint lands. */
extern void conduit_batch(nc_request **requests, int count, nc_db *db);

enum nc_stage { NC_READING, NC_WORKING, NC_WRITING, NC_DEAD, NC_RETIRED };

typedef struct nc_output {
    char header[192];
    const char *body;
    size_t header_length;
    size_t body_length;
    size_t sent;
    bool keepalive;
} nc_output;

typedef struct nc_connection {
    struct nc_connection *previous, *next;
    struct nc_connection *queue_next, *done_next, *gc_next;
    nc_request *request;
    nc_output *output;
    char *input;
    size_t input_length, input_capacity, charge;
    uint64_t activity, queued_at;
    int fd;
    enum nc_stage stage;
    bool peer_eof;
} nc_connection;

typedef struct nc_pool {
    pthread_mutex_t lock;
    /* Only the read pool uses this: collecting a batch does not own execution. */
    pthread_mutex_t gather_lock;
    pthread_cond_t available;
    nc_connection *head, *tail;
    int threads;
    bool stopping;
} nc_pool;

typedef struct nc_server {
    int epoll_fd, listener_fd, completion_fd, reserve_fd;
    nc_pool pools[3];
    pthread_t workers[95];
    int worker_count;
    pthread_mutex_t startup_lock;
    pthread_cond_t startup_ready;
    int ready_count;
    bool startup_failed;
    pthread_mutex_t done_lock;
    nc_connection *done_head, *done_tail;
    nc_connection *connections, *garbage;
    size_t input_bytes, pending_bytes, pending_count;
    const char *database_url;
    bool serial_read_gather, read_batch_stats;
    /* Updated under the read pool lock; inspected after all workers join. */
    uint64_t read_batches, read_requests, read_solo_batches, read_oldest_ms;
    unsigned read_max_batch;
    uint64_t read_max_oldest_ms;
} nc_server;

static nc_server server;
static volatile sig_atomic_t interrupted;
static char listener_tag, completion_tag;

static uint64_t
nc_now(void)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) abort();
    return (uint64_t) now.tv_sec * 1000U + (uint64_t) now.tv_nsec / 1000000U;
}

static void
nc_signal(int number)
{
    (void) number;
    interrupted = 1;
}

static int
nc_thread_count(const char *name, int fallback)
{
    const char *value = getenv(name);
    char *end;
    long parsed;
    if (!value || !*value) return fallback;
    errno = 0;
    parsed = strtol(value, &end, 10);
    if (errno || *end || parsed < 1 || parsed > 93) {
        fprintf(stderr, "%s must be an integer in 1..93\n", name);
        return -1;
    }
    return (int) parsed;
}

static int
nc_switch(const char *name, int fallback)
{
    const char *value = getenv(name);
    if (!value || !*value) return fallback;
    if (strcmp(value, "0") == 0) return 0;
    if (strcmp(value, "1") == 0) return 1;
    fprintf(stderr, "%s must be 0 or 1\n", name);
    return -1;
}

static void
nc_input_free(nc_connection *connection)
{
    if (connection->input) {
        server.input_bytes -= connection->input_capacity;
        free(connection->input);
        connection->input = NULL;
        connection->input_length = connection->input_capacity = 0;
    }
}

static void
nc_charge_release(nc_connection *connection)
{
    if (connection->charge) {
        server.pending_bytes -= connection->charge;
        --server.pending_count;
        connection->charge = 0;
    }
}

static void
nc_retire(nc_connection *connection)
{
    if (connection->stage == NC_RETIRED) return;
    if (connection->previous) connection->previous->next = connection->next;
    else server.connections = connection->next;
    if (connection->next) connection->next->previous = connection->previous;
    connection->stage = NC_RETIRED;
    connection->gc_next = server.garbage;
    server.garbage = connection;
}

static void
nc_close(nc_connection *connection)
{
    enum nc_stage old = connection->stage;
    if (old == NC_RETIRED || old == NC_DEAD) return;
    if (connection->fd >= 0) {
        epoll_ctl(server.epoll_fd, EPOLL_CTL_DEL, connection->fd, NULL);
        close(connection->fd);
        connection->fd = -1;
    }
    connection->stage = NC_DEAD;
    /* A worker may still be reading/writing the request, never the socket. */
    if (old != NC_WORKING) nc_retire(connection);
}

static void
nc_collect(void)
{
    nc_connection *connection = server.garbage;
    server.garbage = NULL;
    while (connection) {
        nc_connection *next = connection->gc_next;
        nc_input_free(connection);
        nc_charge_release(connection);
        nc_request_free(connection->request);
        free(connection->output);
        free(connection);
        connection = next;
    }
}

static bool
nc_arm(nc_connection *connection, uint32_t events)
{
    struct epoll_event event;
    memset(&event, 0, sizeof(event));
    event.events = events | EPOLLRDHUP | EPOLLONESHOT;
    event.data.ptr = connection;
    if (epoll_ctl(server.epoll_fd, EPOLL_CTL_MOD, connection->fd, &event) != 0) {
        nc_close(connection);
        return false;
    }
    return true;
}

static const char *
nc_reason(int status)
{
    switch (status) {
    case 200: return "OK";
    case 201: return "Created";
    case 204: return "No Content";
    case 400: return "Bad Request";
    case 401: return "Unauthorized";
    case 403: return "Forbidden";
    case 404: return "Not Found";
    case 405: return "Method Not Allowed";
    case 413: return "Content Too Large";
    case 422: return "Unprocessable Entity";
    case 431: return "Request Header Fields Too Large";
    case 503: return "Service Unavailable";
    default: return "Internal Server Error";
    }
}

static bool
nc_output_start(nc_connection *connection, int status, const char *body,
                size_t length, bool keepalive)
{
    nc_output *output = calloc(1, sizeof(*output));
    int header_length;
    if (!output) {
        nc_close(connection);
        return false;
    }
    if (status == 204) length = 0;
    header_length = snprintf(output->header, sizeof(output->header),
        "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\n"
        "Content-Length: %zu\r\nConnection: %s\r\n\r\n",
        status, nc_reason(status), length, keepalive ? "keep-alive" : "close");
    if (header_length < 0 || (size_t) header_length >= sizeof(output->header)) {
        free(output);
        nc_close(connection);
        return false;
    }
    output->body = body;
    output->body_length = length;
    output->header_length = (size_t) header_length;
    output->keepalive = keepalive;
    connection->output = output;
    connection->stage = NC_WRITING;
    connection->activity = nc_now();
    return true;
}

static void nc_flush(nc_connection *connection);
static bool nc_dispatch(nc_connection *connection);

static void
nc_simple_error(nc_connection *connection, int status)
{
    static const char body[] = "{\"errors\":{\"body\":[\"request rejected\"]}}";
    nc_input_free(connection);
    if (nc_output_start(connection, status, body, sizeof(body) - 1, false))
        nc_flush(connection);
}

static void
nc_flush(nc_connection *connection)
{
    nc_output *output = connection->output;
    size_t total = output->header_length + output->body_length;
    while (output->sent < total) {
        struct iovec vectors[2];
        struct msghdr message;
        ssize_t written;
        int count = 0;
        memset(&message, 0, sizeof(message));
        if (output->sent < output->header_length) {
            vectors[count].iov_base = output->header + output->sent;
            vectors[count++].iov_len = output->header_length - output->sent;
            if (output->body_length) {
                vectors[count].iov_base = (char *) output->body;
                vectors[count++].iov_len = output->body_length;
            }
        } else {
            size_t sent_body = output->sent - output->header_length;
            vectors[count].iov_base = (char *) output->body + sent_body;
            vectors[count++].iov_len = output->body_length - sent_body;
        }
        message.msg_iov = vectors;
        message.msg_iovlen = (size_t) count;
        written = sendmsg(connection->fd, &message, MSG_NOSIGNAL);
        if (written > 0) {
            output->sent += (size_t) written;
            connection->activity = nc_now();
            continue;
        }
        if (written < 0 && errno == EINTR) continue;
        if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            nc_arm(connection, EPOLLOUT);
            return;
        }
        nc_close(connection);
        return;
    }
    {
        bool keepalive = output->keepalive;
        free(output);
        connection->output = NULL;
        nc_request_free(connection->request);
        connection->request = NULL;
        nc_charge_release(connection);
        if (!keepalive) {
            nc_close(connection);
            return;
        }
    }
    connection->stage = NC_READING;
    connection->activity = nc_now();
    if (connection->input_length) {
        if (nc_dispatch(connection)) return;
        if (connection->peer_eof) {
            nc_close(connection);
            return;
        }
    } else {
        nc_input_free(connection);
        if (connection->peer_eof) {
            nc_close(connection);
            return;
        }
    }
    nc_arm(connection, EPOLLIN);
}

static void *
nc_worker(void *argument)
{
    nc_pool *pool = argument;
    nc_db *database = nc_db_open(server.database_url);
    pthread_mutex_lock(&server.startup_lock);
    ++server.ready_count;
    if (!database) server.startup_failed = true;
    pthread_cond_signal(&server.startup_ready);
    pthread_mutex_unlock(&server.startup_lock);
    if (!database) return NULL;
    for (;;) {
        nc_connection *connections[NC_READ_BATCH_MAX];
        nc_request *requests[NC_READ_BATCH_MAX];
        nc_connection *connection;
        int count = 0, i;
        uint64_t notification = 1;
        bool read_pool = pool == &server.pools[0];
        bool gather = read_pool && server.serial_read_gather;
        /* A single collector keeps arrivals together. Other workers may execute
         * earlier batches, and this mutex is never held during a DB call. */
        if (gather) pthread_mutex_lock(&pool->gather_lock);
        pthread_mutex_lock(&pool->lock);
        while (!pool->head && !pool->stopping)
            pthread_cond_wait(&pool->available, &pool->lock);
        if (pool->stopping) {
            pthread_mutex_unlock(&pool->lock);
            if (gather) pthread_mutex_unlock(&pool->gather_lock);
            break;
        }
        connection = pool->head;
        pool->head = connection->queue_next;
        if (!pool->head) pool->tail = NULL;
        connections[count] = connection;
        requests[count++] = connection->request;
        if (read_pool) {
            uint64_t deadline = connection->queued_at + NC_READ_WINDOW_MS;
            while (count < NC_READ_BATCH_MAX && !pool->stopping) {
                if (pool->head) {
                    connection = pool->head;
                    pool->head = connection->queue_next;
                    if (!pool->head) pool->tail = NULL;
                    connections[count] = connection;
                    requests[count++] = connection->request;
                } else {
                    struct timespec until;
                    uint64_t now = nc_now(), remaining;
                    if (now >= deadline) break;
                    remaining = deadline - now;
                    clock_gettime(CLOCK_REALTIME, &until);
                    until.tv_nsec += (long) remaining * 1000000L;
                    until.tv_sec += until.tv_nsec / 1000000000L;
                    until.tv_nsec %= 1000000000L;
                    pthread_cond_timedwait(&pool->available, &pool->lock, &until);
                }
            }
        }
        if (read_pool && server.read_batch_stats) {
            uint64_t oldest = nc_now() - connections[0]->queued_at;
            ++server.read_batches;
            server.read_requests += (unsigned) count;
            if (count == 1) ++server.read_solo_batches;
            if ((unsigned) count > server.read_max_batch)
                server.read_max_batch = (unsigned) count;
            server.read_oldest_ms += oldest;
            if (oldest > server.read_max_oldest_ms) server.read_max_oldest_ms = oldest;
        }
        pthread_mutex_unlock(&pool->lock);
        if (gather) pthread_mutex_unlock(&pool->gather_lock);

        if (read_pool) conduit_batch(requests, count, database);
        else conduit_handle(requests[0], database);

        pthread_mutex_lock(&server.done_lock);
        for (i = 0; i < count; ++i) {
            connection = connections[i];
            connection->done_next = NULL;
            if (server.done_tail) server.done_tail->done_next = connection;
            else server.done_head = connection;
            server.done_tail = connection;
        }
        pthread_mutex_unlock(&server.done_lock);
        /* EAGAIN means an unread notification already wakes the loop. */
        while (write(server.completion_fd, &notification, sizeof(notification)) < 0 && errno == EINTR) {}
    }
    nc_db_close(database);
    return NULL;
}

/* true means the connection was dispatched, rejected, or closed. */
static bool
nc_dispatch(nc_connection *connection)
{
    ssize_t size = nc_request_size(connection->input, connection->input_length);
    nc_pool *pool;
    int lane;
    if (size == 0) return false;
    if (size < 0) {
        nc_simple_error(connection, size == -2 ? 413 : 400);
        return true;
    }
    if ((size_t) size > connection->input_length) {
        nc_simple_error(connection, 400);
        return true;
    }
    if (server.pending_count >= NC_PENDING_MAX ||
        (size_t) size > NC_PENDING_BYTES - server.pending_bytes) {
        nc_simple_error(connection, 503);
        return true;
    }
    connection->request = nc_request_create(connection->input, (size_t) size);
    if (!connection->request) {
        nc_simple_error(connection, 400);
        return true;
    }
    connection->charge = (size_t) size;
    ++server.pending_count;
    server.pending_bytes += connection->charge;
    connection->input_length -= (size_t) size;
    if (connection->input_length)
        memmove(connection->input, connection->input + size, connection->input_length);
    else nc_input_free(connection);

    lane = conduit_lane(connection->request);
    if (lane < 0 || lane > 2) lane = 0;
    pool = &server.pools[lane];
    connection->stage = NC_WORKING;
    connection->queued_at = nc_now();
    connection->queue_next = NULL;
    /* Do not leave the request readable while a worker owns it. */
    if (!nc_arm(connection, 0)) {
        /* No worker owns the request yet; it can be retired immediately. */
        nc_retire(connection);
        return true;
    }
    pthread_mutex_lock(&pool->lock);
    if (pool->tail) pool->tail->queue_next = connection;
    else pool->head = connection;
    pool->tail = connection;
    pthread_cond_signal(&pool->available);
    pthread_mutex_unlock(&pool->lock);
    return true;
}

static bool
nc_input_reserve(nc_connection *connection)
{
    size_t capacity;
    char *data;
    if (connection->input_length < connection->input_capacity) return true;
    capacity = connection->input_capacity ? connection->input_capacity * 2 : NC_INITIAL_INPUT;
    if (capacity > NC_INPUT_MAX) capacity = NC_INPUT_MAX;
    if (capacity <= connection->input_capacity ||
        capacity - connection->input_capacity > NC_INPUT_BYTES - server.input_bytes)
        return false;
    data = realloc(connection->input, capacity);
    if (!data) return false;
    server.input_bytes += capacity - connection->input_capacity;
    connection->input = data;
    connection->input_capacity = capacity;
    return true;
}

static void
nc_read(nc_connection *connection)
{
    for (;;) {
        ssize_t length;
        if (!nc_input_reserve(connection)) {
            nc_simple_error(connection, connection->input_capacity >= NC_INPUT_MAX ? 413 : 503);
            return;
        }
        length = recv(connection->fd, connection->input + connection->input_length,
                      connection->input_capacity - connection->input_length, 0);
        if (length > 0) {
            connection->input_length += (size_t) length;
            connection->activity = nc_now();
            if (nc_dispatch(connection)) return;
            continue;
        }
        if (length == 0) {
            connection->peer_eof = true;
            if (connection->input_length && nc_dispatch(connection)) return;
            nc_close(connection);
            return;
        }
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            nc_arm(connection, EPOLLIN);
            return;
        }
        nc_close(connection);
        return;
    }
}

static void
nc_completions(void)
{
    uint64_t notifications;
    nc_connection *connection;
    while (read(server.completion_fd, &notifications, sizeof(notifications)) > 0) {}
    pthread_mutex_lock(&server.done_lock);
    connection = server.done_head;
    server.done_head = server.done_tail = NULL;
    pthread_mutex_unlock(&server.done_lock);
    while (connection) {
        nc_connection *next = connection->done_next;
        if (connection->stage == NC_DEAD) nc_retire(connection);
        else if (connection->stage == NC_WORKING) {
            size_t length = 0;
            const char *body;
            int status = nc_status(connection->request);
            if (status < 100 || status > 599) {
                nc_error(connection->request, 500);
                status = 500;
            }
            body = nc_response_data(connection->request, &length);
            if (!body && length) {
                nc_close(connection);
                nc_retire(connection);
            } else if (nc_output_start(connection, status, body, length,
                       nc_keepalive(connection->request) &&
                       (!connection->peer_eof || connection->input_length))) {
                nc_flush(connection);
            } else nc_retire(connection);
        }
        connection = next;
    }
}

/* Returns false when acceptance should pause briefly under descriptor pressure. */
static bool
nc_accept(void)
{
    for (;;) {
        struct epoll_event event;
        nc_connection *connection;
        int enabled = 1;
        int fd = accept4(server.listener_fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
        if (fd < 0) {
            if (errno == EINTR || errno == ECONNABORTED || errno == EPROTO) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) return true;
            if (errno == EMFILE || errno == ENFILE) {
                if (server.reserve_fd >= 0) close(server.reserve_fd);
                server.reserve_fd = -1;
                fd = accept4(server.listener_fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
                if (fd >= 0) close(fd);
                server.reserve_fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
            }
            return false;
        }
        connection = calloc(1, sizeof(*connection));
        if (!connection) {
            close(fd);
            return false;
        }
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &enabled, sizeof(enabled));
        connection->fd = fd;
        connection->stage = NC_READING;
        connection->activity = nc_now();
        connection->next = server.connections;
        if (server.connections) server.connections->previous = connection;
        server.connections = connection;
        memset(&event, 0, sizeof(event));
        event.events = EPOLLIN | EPOLLRDHUP | EPOLLONESHOT;
        event.data.ptr = connection;
        if (epoll_ctl(server.epoll_fd, EPOLL_CTL_ADD, fd, &event) != 0)
            nc_close(connection);
    }
}

static int
nc_listener(const char *host, const char *port)
{
    struct addrinfo hints, *addresses = NULL, *address;
    int fd = -1, code;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE;
    code = getaddrinfo(host, port, &hints, &addresses);
    if (code) {
        fprintf(stderr, "listen address: %s\n", gai_strerror(code));
        return -1;
    }
    for (address = addresses; address; address = address->ai_next) {
        int enabled = 1;
        fd = socket(address->ai_family, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC,
                    address->ai_protocol);
        if (fd < 0) continue;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled));
        if (bind(fd, address->ai_addr, address->ai_addrlen) == 0 && listen(fd, 4096) == 0)
            break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(addresses);
    if (fd < 0) perror("listen");
    return fd;
}

static bool
nc_add_descriptor(int fd, void *tag)
{
    struct epoll_event event;
    memset(&event, 0, sizeof(event));
    event.events = EPOLLIN;
    event.data.ptr = tag;
    return epoll_ctl(server.epoll_fd, EPOLL_CTL_ADD, fd, &event) == 0;
}

static void
nc_expire(uint64_t now)
{
    nc_connection *connection = server.connections;
    while (connection) {
        nc_connection *next = connection->next;
        uint64_t timeout = NC_IDLE_MS;
        if (connection->stage == NC_READING && connection->input_length) timeout = NC_HEADER_MS;
        else if (connection->stage == NC_WRITING) timeout = NC_WRITE_MS;
        if (connection->fd >= 0 && now - connection->activity >= timeout)
            nc_close(connection);
        connection = next;
    }
}

static void
nc_stop_workers(void)
{
    int i;
    for (i = 0; i < 3; ++i) {
        pthread_mutex_lock(&server.pools[i].lock);
        server.pools[i].stopping = true;
        pthread_cond_broadcast(&server.pools[i].available);
        pthread_mutex_unlock(&server.pools[i].lock);
    }
    for (i = 0; i < server.worker_count; ++i) pthread_join(server.workers[i], NULL);
}

int
main(void)
{
    const char *host = getenv("HOST"), *port = getenv("PORT");
    struct epoll_event events[NC_EVENTS];
    struct sigaction action;
    pthread_attr_t attributes;
    uint64_t sweep, resume = 0;
    bool accepting = true;
    int i, j, expected = 0, exit_code = 0, serial_gather, batch_stats;
    memset(&server, 0, sizeof(server));
    server.epoll_fd = server.listener_fd = server.completion_fd = server.reserve_fd = -1;
    server.database_url = getenv("DATABASE_URL");
    if (!server.database_url || !*server.database_url || !getenv("JWT_SECRET")) {
        fprintf(stderr, "DATABASE_URL and JWT_SECRET are required\n");
        return 1;
    }
    server.pools[0].threads = nc_thread_count("DB_READ_THREADS", 4);
    server.pools[1].threads = nc_thread_count("DB_WRITE_THREADS", 8);
    server.pools[2].threads = nc_thread_count("DB_AUTH_THREADS", 8);
    serial_gather = nc_switch("READ_GATHER_SERIAL", 1);
    batch_stats = nc_switch("READ_BATCH_STATS", 0);
    if (serial_gather < 0 || batch_stats < 0) return 1;
    server.serial_read_gather = serial_gather != 0;
    server.read_batch_stats = batch_stats != 0;
    for (i = 0; i < 3; ++i) {
        if (server.pools[i].threads < 0) return 1;
        expected += server.pools[i].threads;
    }
    if (expected > 95) {
        fprintf(stderr, "total database worker connections must be <=95\n");
        return 1;
    }
    pthread_mutex_init(&server.startup_lock, NULL);
    pthread_cond_init(&server.startup_ready, NULL);
    pthread_mutex_init(&server.done_lock, NULL);
    for (i = 0; i < 3; ++i) {
        pthread_mutex_init(&server.pools[i].lock, NULL);
        pthread_mutex_init(&server.pools[i].gather_lock, NULL);
        pthread_cond_init(&server.pools[i].available, NULL);
    }
    server.epoll_fd = epoll_create1(EPOLL_CLOEXEC);
    server.completion_fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    if (server.epoll_fd < 0 || server.completion_fd < 0 ||
        !nc_add_descriptor(server.completion_fd, &completion_tag)) {
        perror("epoll/eventfd");
        exit_code = 1;
        goto cleanup;
    }
    memset(&action, 0, sizeof(action));
    action.sa_handler = nc_signal;
    sigemptyset(&action.sa_mask);
    sigaction(SIGINT, &action, NULL);
    sigaction(SIGTERM, &action, NULL);
    signal(SIGPIPE, SIG_IGN);
    pthread_attr_init(&attributes);
    pthread_attr_setstacksize(&attributes, 512U * 1024U);
    for (i = 0; i < 3; ++i) {
        for (j = 0; j < server.pools[i].threads; ++j) {
            int error = pthread_create(&server.workers[server.worker_count], &attributes,
                                       nc_worker, &server.pools[i]);
            if (error) {
                fprintf(stderr, "pthread_create: %s\n", strerror(error));
                pthread_attr_destroy(&attributes);
                exit_code = 1;
                goto shutdown;
            }
            ++server.worker_count;
        }
    }
    pthread_attr_destroy(&attributes);
    pthread_mutex_lock(&server.startup_lock);
    while (server.ready_count < expected && !server.startup_failed)
        pthread_cond_wait(&server.startup_ready, &server.startup_lock);
    if (server.startup_failed) {
        pthread_mutex_unlock(&server.startup_lock);
        fprintf(stderr, "database worker initialization failed\n");
        exit_code = 1;
        goto shutdown;
    }
    pthread_mutex_unlock(&server.startup_lock);
    server.listener_fd = nc_listener(host && *host ? host : "127.0.0.1", port && *port ? port : "3000");
    if (server.listener_fd < 0 || !nc_add_descriptor(server.listener_fd, &listener_tag)) {
        exit_code = 1;
        goto shutdown;
    }
    server.reserve_fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
    fprintf(stderr, "Nelua epoll ready on %s:%s; DB lanes %d/%d/%d (%zu bytes/idle connection)\n",
            host && *host ? host : "127.0.0.1", port && *port ? port : "3000",
            server.pools[0].threads, server.pools[1].threads, server.pools[2].threads,
            sizeof(nc_connection));
    sweep = nc_now() + 1000;
    while (!interrupted) {
        uint64_t now = nc_now();
        int timeout = accepting ? 1000 : (resume > now ? (int) (resume - now) : 0);
        int count = epoll_wait(server.epoll_fd, events, NC_EVENTS, timeout);
        if (count < 0) {
            if (errno == EINTR) continue;
            perror("epoll_wait");
            exit_code = 1;
            break;
        }
        for (i = 0; i < count; ++i) {
            if (events[i].data.ptr == &listener_tag) {
                if (accepting && !nc_accept()) {
                    epoll_ctl(server.epoll_fd, EPOLL_CTL_DEL, server.listener_fd, NULL);
                    accepting = false;
                    resume = nc_now() + 100;
                }
            } else if (events[i].data.ptr == &completion_tag) nc_completions();
            else {
                nc_connection *connection = events[i].data.ptr;
                uint32_t flags = events[i].events;
                /* Deferred collection keeps stale events in this batch valid. */
                if (connection->stage == NC_RETIRED || connection->stage == NC_DEAD) continue;
                if (flags & (EPOLLERR | EPOLLHUP)) {
                    nc_close(connection);
                    continue;
                }
                if (flags & EPOLLRDHUP) connection->peer_eof = true;
                if (connection->stage == NC_READING) nc_read(connection);
                else if (connection->stage == NC_WRITING) nc_flush(connection);
            }
        }
        now = nc_now();
        if (!accepting && now >= resume) {
            if (nc_add_descriptor(server.listener_fd, &listener_tag)) accepting = true;
            else resume = now + 100;
        }
        if (now >= sweep) {
            nc_expire(now);
            sweep = now + 1000;
        }
        nc_collect();
    }
shutdown:
    if (server.listener_fd >= 0) {
        close(server.listener_fd);
        server.listener_fd = -1;
    }
    nc_stop_workers();
    if (server.read_batch_stats) {
        fprintf(stderr,
            "read batches: serial=%d batches=%llu requests=%llu mean=%.2f max=%u "
            "solo=%llu mean_oldest_ms=%.2f max_oldest_ms=%llu\n",
            server.serial_read_gather ? 1 : 0,
            (unsigned long long) server.read_batches,
            (unsigned long long) server.read_requests,
            server.read_batches ? (double) server.read_requests / server.read_batches : 0.0,
            server.read_max_batch, (unsigned long long) server.read_solo_batches,
            server.read_batches ? (double) server.read_oldest_ms / server.read_batches : 0.0,
            (unsigned long long) server.read_max_oldest_ms);
    }
    while (server.connections) {
        nc_connection *connection = server.connections;
        if (connection->fd >= 0) close(connection->fd);
        nc_retire(connection);
    }
    nc_collect();
cleanup:
    if (server.listener_fd >= 0) close(server.listener_fd);
    if (server.completion_fd >= 0) close(server.completion_fd);
    if (server.reserve_fd >= 0) close(server.reserve_fd);
    if (server.epoll_fd >= 0) close(server.epoll_fd);
    return exit_code;
}

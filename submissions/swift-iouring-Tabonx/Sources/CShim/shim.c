// Socket and thread setup. Kept in C so Swift never has to know the sockaddr or cpu_set_t layouts.
#define _GNU_SOURCE
#include "shim.h"
#include <netdb.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <sys/syscall.h>
#include <sys/random.h>
#include <sys/time.h>

int sv_listen(const char *host, int port, int backlog, int reuseport) {
    char service[16];
    snprintf(service, sizeof service, "%d", port);
    struct addrinfo hints = {0}, *res = 0;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE | AI_NUMERICSERV;
    if (getaddrinfo(host, service, &hints, &res) != 0 || !res) return -1;
    int fd = socket(res->ai_family, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) { freeaddrinfo(res); return -1; }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    if (reuseport && setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one) != 0) {
        close(fd);
        freeaddrinfo(res);
        return -1;
    }
    // Accepted sockets inherit TCP_NODELAY from the listener on Linux.
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    if (bind(fd, res->ai_addr, res->ai_addrlen) != 0 || listen(fd, backlog) != 0) {
        close(fd);
        freeaddrinfo(res);
        return -1;
    }
    freeaddrinfo(res);
    return fd;
}

int sv_connect(const char *host, int port, int timeout_ms) {
    char service[16];
    snprintf(service, sizeof service, "%d", port);
    struct addrinfo hints = {0}, *res = 0;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_NUMERICSERV;
    if (getaddrinfo(host, service, &hints, &res) != 0) return -1;
    int fd = -1;
    for (struct addrinfo *a = res; a; a = a->ai_next) {
        fd = socket(a->ai_family, SOCK_STREAM | SOCK_CLOEXEC, 0);
        if (fd < 0) continue;
        struct timeval t = {.tv_sec = timeout_ms / 1000, .tv_usec = (timeout_ms % 1000) * 1000};
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &t, sizeof t);
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, sizeof t);
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        if (connect(fd, a->ai_addr, a->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    return fd;
}

void sv_set_nonblocking(int fd) {
    struct timeval t = {0, 0};
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &t, sizeof t);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, sizeof t);
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
}

void sv_random(void *out, unsigned n) {
    unsigned char *p = out;
    while (n > 0) {
        ssize_t got = getrandom(p, n, 0);
        if (got <= 0) continue;
        p += got;
        n -= (unsigned)got;
    }
}

int sv_cpu_count(void) {
    cpu_set_t set;
    if (sched_getaffinity(0, sizeof set, &set) != 0) return 1;
    int n = CPU_COUNT(&set);
    return n > 0 ? n : 1;
}

int sv_spawn(void *(*body)(void *), void *arg) {
    pthread_t t;
    pthread_attr_t a;
    pthread_attr_init(&a);
    pthread_attr_setstacksize(&a, 8 << 20);
    int rc = pthread_create(&t, &a, body, arg);
    pthread_attr_destroy(&a);
    return rc;
}

int sv_raise_nofile(void) {
    struct rlimit r;
    if (getrlimit(RLIMIT_NOFILE, &r) != 0) return 1024;
    r.rlim_cur = r.rlim_max;
    setrlimit(RLIMIT_NOFILE, &r);
    getrlimit(RLIMIT_NOFILE, &r);
    return r.rlim_cur > 1048576 ? 1048576 : (int)r.rlim_cur;
}

void sv_ignore_sigpipe(void) { signal(SIGPIPE, SIG_IGN); }

int sv_tune_thread(int nice_value, int batch) {
    if (batch) {
        struct sched_param param = {0};
        sched_setscheduler(0, SCHED_BATCH, &param);
    }
    return setpriority(PRIO_PROCESS, (id_t)syscall(SYS_gettid), nice_value);
}

long sv_header_end(const void *p, size_t n) {
    const char *at = memmem(p, n, "\r\n\r\n", 4);
    return at ? (long)(at - (const char *)p) + 4 : -1;
}

void *sv_mutex_new(void) {
    pthread_mutex_t *m = malloc(sizeof *m);
    pthread_mutex_init(m, 0);
    return m;
}
void sv_lock(void *m) { pthread_mutex_lock(m); }
void sv_unlock(void *m) { pthread_mutex_unlock(m); }

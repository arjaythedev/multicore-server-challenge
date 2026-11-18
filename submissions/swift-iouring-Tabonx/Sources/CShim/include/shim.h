// System headers and small wrappers for macros, errno and socket setup.
#ifndef SV_SHIM_H
#define SV_SHIM_H
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static inline int sv_errno(void) { return errno; }

static inline int64_t sv_now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_REALTIME, &t);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static inline int64_t sv_monotonic_s(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec;
}

static inline int64_t sv_monotonic_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}

static inline const char *sv_getenv(const char *name) { return getenv(name); }

int sv_listen(const char *host, int port, int backlog, int reuseport);
/// A blocking TCP connection with TCP_NODELAY and `timeout_ms` send and receive timeouts, or -1.
int sv_connect(const char *host, int port, int timeout_ms);
/// Drops the socket timeouts and makes it nonblocking, for handing it to a ring.
void sv_set_nonblocking(int fd);
/// Fills `out` with random bytes.
void sv_random(void *out, unsigned n);
/// The CPUs this process may run on (taskset, CPUAffinity).
int sv_cpu_count(void);
int sv_spawn(void *(*body)(void *), void *arg);
int sv_raise_nofile(void);
void sv_ignore_sigpipe(void);
/// SCHED_BATCH (if `batch`) and a nice value for the calling thread.
int sv_tune_thread(int nice_value, int batch);
/// The offset just past the first CRLFCRLF in `p`, or -1.
long sv_header_end(const void *p, size_t n);
void *sv_mutex_new(void);
void sv_lock(void *mutex);
void sv_unlock(void *mutex);
#endif

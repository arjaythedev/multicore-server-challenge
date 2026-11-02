// The GNU extensions CEventLoop.h declares, and the descriptor limit.
#ifdef __linux__
#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <stddef.h>
#include <sys/socket.h>
#endif
#include <limits.h>
#include <sys/resource.h>
#include "CEventLoop.h"

#ifdef __linux__
int CEventLoop_accept(int listener, int flags) {
    return accept4(listener, NULL, NULL, flags);
}

int CEventLoop_nameThread(const char *name) {
    return pthread_setname_np(pthread_self(), name);
}

int CEventLoop_cpusAllowed(void) {
    cpu_set_t set;
    CPU_ZERO(&set);
    if (sched_getaffinity(0, sizeof(set), &set) != 0) return -1;
    return CPU_COUNT(&set);
}
#endif

long CEventLoop_descriptorLimit(void) {
    struct rlimit limit;
    if (getrlimit(RLIMIT_NOFILE, &limit) != 0) return -1;
    if (limit.rlim_cur < limit.rlim_max) {
        struct rlimit raised = limit;
        raised.rlim_cur = limit.rlim_max;
#ifdef __APPLE__
        if (raised.rlim_cur > OPEN_MAX) raised.rlim_cur = OPEN_MAX;
#endif
        if (setrlimit(RLIMIT_NOFILE, &raised) == 0) limit = raised;
    }
    return limit.rlim_cur == RLIM_INFINITY || limit.rlim_cur > LONG_MAX ? LONG_MAX : (long)limit.rlim_cur;
}

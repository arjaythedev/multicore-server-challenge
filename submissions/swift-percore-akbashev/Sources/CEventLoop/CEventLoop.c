// The GNU extensions CEventLoop.h declares.
#ifdef __linux__
#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <stddef.h>
#include <sys/socket.h>
#include "CEventLoop.h"

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

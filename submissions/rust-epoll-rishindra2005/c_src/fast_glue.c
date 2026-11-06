// Fast C helper glue for Conduit Multicore Server (Rust + C + ASM)
#define _GNU_SOURCE
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <fcntl.h>
#include <unistd.h>
#include <sched.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <errno.h>

// Tuning socket options for low latency & high throughput (let kernel auto-tune buffers)
int fast_tune_socket(int fd) {
    int opt = 1;
    if (setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &opt, sizeof(opt)) < 0) return -1;
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt)) < 0) return -1;
    #ifdef SO_REUSEPORT
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt)) < 0) return -1;
    #endif
    return 0;
}

// Sets TCP_DEFER_ACCEPT option to defer listener wakeup until client payload arrives
int fast_set_defer_accept(int fd, int secs) {
#ifdef TCP_DEFER_ACCEPT
    return setsockopt(fd, IPPROTO_TCP, TCP_DEFER_ACCEPT, &secs, (socklen_t)sizeof(secs));
#else
    (void)fd; (void)secs;
    return 0;
#endif
}

// Deprecated in Sprint 5: No-op to avoid delayed ACK latency penalties and syscall churn
int fast_set_quickack(int fd, int val) {
    (void)fd; (void)val;
    return 0;
}

// Sets TCP_CORK option for writev vector packing
int fast_set_cork(int fd, int val) {
#ifdef TCP_CORK
    return setsockopt(fd, IPPROTO_TCP, TCP_CORK, &val, (socklen_t)sizeof(val));
#else
    (void)fd; (void)val;
    return 0;
#endif
}

// Deprecated in Sprint 5: No-op to allow Linux TCP receive/send window auto-tuning
int fast_set_buffer_size(int fd, int size) {
    (void)fd; (void)size;
    return 0;
}

// Fast thread affinity pinning
int fast_pin_cpu(int cpu_id) {
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(cpu_id, &cpuset);
    return sched_setaffinity(0, sizeof(cpu_set_t), &cpuset);
}

// Return the list of allowed CPU IDs according to the current thread affinity mask.
// Returns the number of CPUs populated in allowed_cpus, or -1 on error.
int fast_get_allowed_cpus(int *allowed_cpus, int max_count) {
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    if (sched_getaffinity(0, sizeof(cpu_set_t), &cpuset) != 0) {
        return -1;
    }
    int count = 0;
    for (int i = 0; i < CPU_SETSIZE && count < max_count; i++) {
        if (CPU_ISSET(i, &cpuset)) {
            allowed_cpus[count++] = i;
        }
    }
    return count;
}

// Fast thread affinity pinning to a bitmask of CPUs
int fast_pin_cpuset(unsigned long mask) {
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    for (int i = 0; i < 64; i++) {
        if ((mask >> i) & 1) {
            CPU_SET(i, &cpuset);
        }
    }
    return sched_setaffinity(0, sizeof(cpu_set_t), &cpuset);
}

// Low-overhead process configuration
int fast_tune_process(void) {
    // Disable Transparent Huge Pages for deterministic tail latencies
    prctl(PR_SET_THP_DISABLE, 1, 0, 0, 0);
    return 0;
}

// Unshare file descriptor table to eliminate files_struct lock contention
int fast_unshare_files(void) {
    #ifdef CLONE_FILES
    return unshare(CLONE_FILES);
    #else
    return 0;
    #endif
}

// Set batch scheduling policy to maximize throughput
int fast_set_sched_batch(void) {
    struct sched_param param;
    param.sched_priority = 0;
    #ifdef SCHED_BATCH
    return sched_setscheduler(0, SCHED_BATCH, &param);
    #else
    return 0;
    #endif
}

// Set thread nice value (e.g. +2 for low-priority background crypto without starvation)
int fast_set_nice(int nice_val) {
    return setpriority(PRIO_PROCESS, 0, nice_val);
}

// Set idle scheduling policy (SCHED_IDLE or nice +19) for background crypto workers
// to guarantee bcrypt cost 10 never causes latency spikes on read/write or epoll loops.
int fast_set_sched_idle(void) {
    struct sched_param param;
    param.sched_priority = 0;
    int ret = -1;
    #ifdef SCHED_IDLE
    ret = sched_setscheduler(0, SCHED_IDLE, &param);
    #endif
    if (ret != 0) {
        setpriority(PRIO_PROCESS, 0, 19);
    }
    return 0;
}



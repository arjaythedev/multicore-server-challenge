// Failure diagnostics, compiled in only with -DDIAG. Every thread keeps a ring of its last events; a fatal condition, a
// fatal signal or an uncaught exception prints the reason, a backtrace and the last 100 events of every thread to the
// file named by $DIAG_LOG (stderr if unset). Without -DDIAG every macro is empty.
#pragma once
#ifdef DIAG
#include <dirent.h>
#include <execinfo.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#include <atomic>
#include <cstdarg>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <thread>

namespace diag {
struct Ev {
    uint64_t ns;
    const char *tag;
    int64_t a, b, c;
};
struct Ring {
    Ev e[256];
    uint32_t n = 0;
    int tid = 0;
};
inline Ring *g_rings[64];
inline std::atomic<int> g_nrings{0};
inline std::atomic<int> g_dumping{0};
inline int g_fd = 2;
inline thread_local Ring *t_ring = nullptr;

inline uint64_t now_ns() {
    timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
}
inline Ring *ring() {
    if (!t_ring) {
        t_ring = new Ring();
        t_ring->tid = int(syscall(SYS_gettid));
        int i = g_nrings.fetch_add(1);
        if (i < 64) g_rings[i] = t_ring;
    }
    return t_ring;
}
inline void ev(const char *tag, int64_t a = 0, int64_t b = 0, int64_t c = 0) {
    Ring *r = ring();
    r->e[r->n++ & 255] = {now_ns(), tag, a, b, c};
}
inline void out(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
inline void out(const char *fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (n > 0) (void)!write(g_fd, buf, size_t(n < int(sizeof buf) ? n : int(sizeof buf) - 1));
}
inline void dump_rings() {
    uint64_t t0 = now_ns();
    int n = g_nrings.load();
    for (int i = 0; i < n && i < 64; i++) {
        Ring *r = g_rings[i];
        uint32_t cnt = r->n < 100 ? r->n : 100;
        out("---- thread %d: last %u events (ms before now, tag, a b c) ----\n", r->tid, cnt);
        for (uint32_t k = r->n - cnt; k != r->n; k++) {
            const Ev &e = r->e[k & 255];
            out("  -%9.3f  %-14s %lld %lld %lld\n", double(int64_t(t0 - e.ns)) / 1e6, e.tag, (long long)e.a, (long long)e.b,
                (long long)e.c);
        }
    }
}
inline void backtrace_out() {
    void *bt[48];
    int n = backtrace(bt, 48);
    out("---- backtrace (resolve with addr2line -f -C -e conduit) ----\n");
    backtrace_symbols_fd(bt, n, g_fd);
}
[[noreturn]] inline void die(const char *file, int line, const char *why, int64_t a = 0, int64_t b = 0, int64_t c = 0) {
    if (g_dumping.exchange(1)) for (;;) pause();  // another thread is already reporting
    int e = errno;
    out("\n==== DIAG FATAL %s:%d: %s  (a=%lld b=%lld c=%lld errno=%d %s) ====\n", file, line, why, (long long)a,
        (long long)b, (long long)c, e, strerror(e));
    backtrace_out();
    dump_rings();
    out("==== END DIAG ====\n");
    fsync(g_fd);
    abort();
}
// A non-fatal but suspicious event: reported with the ring of the calling thread, at most `limit` times per site.
inline void warn(std::atomic<int> &cnt, int limit, const char *file, int line, const char *why, int64_t a = 0, int64_t b = 0,
                 int64_t c = 0) {
    int k = cnt.fetch_add(1);
    if (k >= limit) return;
    out("DIAG WARN %s:%d: %s  (a=%lld b=%lld c=%lld) [%d/%d]\n", file, line, why, (long long)a, (long long)b, (long long)c,
        k + 1, limit);
}
inline void on_signal(int sig, siginfo_t *si, void *) {
    if (g_dumping.exchange(1)) _exit(128 + sig);
    out("\n==== DIAG SIGNAL %d (%s) fault addr %p ====\n", sig, strsignal(sig), si ? si->si_addr : nullptr);
    backtrace_out();
    dump_rings();
    out("==== END DIAG ====\n");
    fsync(g_fd);
    signal(sig, SIG_DFL);
    raise(sig);
}
inline void on_terminate() {
    if (g_dumping.exchange(1)) abort();
    out("\n==== DIAG std::terminate ====\n");
    if (auto p = std::current_exception()) {
        try {
            std::rethrow_exception(p);
        } catch (const std::exception &e) {
            out("uncaught exception: %s\n", e.what());
        } catch (...) {
            out("uncaught non-std exception\n");
        }
    }
    backtrace_out();
    dump_rings();
    out("==== END DIAG ====\n");
    fsync(g_fd);
    abort();
}
inline long rss_mb() {
    long pages = 0, rss = 0;
    if (FILE *f = fopen("/proc/self/statm", "r")) {
        if (fscanf(f, "%ld %ld", &pages, &rss) != 2) rss = 0;
        fclose(f);
    }
    return rss * (sysconf(_SC_PAGESIZE) / 1024) / 1024;
}
inline void init() {
    if (const char *p = getenv("DIAG_LOG")) {
        int fd = open(p, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) g_fd = fd;
    }
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = on_signal;
    sa.sa_flags = SA_SIGINFO;
    for (int s : {SIGSEGV, SIGBUS, SIGABRT, SIGFPE, SIGILL}) sigaction(s, &sa, nullptr);
    std::set_terminate(on_terminate);
    std::thread([] {  // memory / descriptor watchdog: one line every 5 s
        for (;;) {
            sleep(5);
            int fds = 0;
            if (DIR *d = opendir("/proc/self/fd")) {
                while (readdir(d)) fds++;
                closedir(d);
            }
            out("DIAG heartbeat: rss=%ldMB fds=%d\n", rss_mb(), fds);
        }
    }).detach();
    out("DIAG enabled, pid %d\n", int(getpid()));
}
}  // namespace diag

#define DIAG_EV(tag, ...) ::diag::ev(tag, ##__VA_ARGS__)
#define DIAG_FATAL(why, ...) ::diag::die(__FILE__, __LINE__, why, ##__VA_ARGS__)
#define DIAG_ASSERT(cond, why, ...) \
    do {                            \
        if (!(cond)) [[unlikely]] ::diag::die(__FILE__, __LINE__, "ASSERT " #cond ": " why, ##__VA_ARGS__); \
    } while (0)
#define DIAG_WARN(limit, why, ...)                                                       \
    do {                                                                                 \
        static std::atomic<int> diag_cnt_{0};                                            \
        ::diag::warn(diag_cnt_, limit, __FILE__, __LINE__, why, ##__VA_ARGS__);          \
    } while (0)
#define DIAG_INIT() ::diag::init()
#else
#define DIAG_EV(...) ((void)0)
#define DIAG_FATAL(...) ((void)0)
#define DIAG_ASSERT(...) ((void)0)
#define DIAG_WARN(...) ((void)0)
#define DIAG_INIT() ((void)0)
#endif

// Optional phase profiler, compiled in only with -DPROF (never in the shipped build).
// Each worker keeps a stack of phases and charges TSC cycles to the innermost one (exclusive time).
// SIGUSR1 prints the delta since the previous SIGUSR1: CPU microseconds per request, split by phase.
#pragma once
#include <cstddef>
#include <cstdint>

#ifdef PROF
#include <x86intrin.h>

namespace prof {

enum Phase : int {
    kWait,      // blocked in io_uring_submit_and_wait (idle)
    kLoop,      // event loop glue: cqe dispatch, re-arming, pg poll
    kAccept,
    kRecv,      // on_recv: copy bytes out of the provided buffer
    kHttp,      // process_one: picohttpparser + building Request
    kHandler,   // coroutine bodies: routing, SQL param build, row decode, JSON output
    kJwt,       // Jwt::verify
    kJsonIn,    // yyjson parse of the request body
    kPgSend,    // dispatch(): batching + libpq wire-protocol Bind encoding
    kPgFlush,   // PgConn::flush: the send() to the Postgres socket
    kPgRecv,    // PgConn::drain: recv + message decoding
    kPgDone,    // on_pg bookkeeping (group fan-out)
    kRespond,   // response header + queueing the send
    kSendDone,  // on_send
    kEfd,       // bcrypt completions
    kCount
};

inline constexpr const char *kNames[kCount] = {"idle (wait)", "loop glue",   "accept",    "recv copy",   "http parse",
                                               "handler (route/sql/decode/json out)", "jwt verify", "json parse (body)",
                                               "pg send (batch+encode)", "pg flush (write syscall)", "pg recv (decode)", "pg fan-out", "respond/send",
                                               "send done", "bcrypt done"};

struct Counters {
    uint64_t cyc[kCount] = {};
    uint64_t requests = 0;
    int stack[24];
    int sp = 0;
    uint64_t last = 0;
};

extern thread_local Counters *tl;
void attach();                 // registers this thread's counters (call at the top of the event loop)
void start_dumper();           // thread printing a report on every SIGUSR1; call before creating threads
void bcrypt_done(uint64_t cyc, int n);
void read_group(size_t members, size_t sent);  // one read segment: requests in it, statements actually sent

inline void enter(Phase p) {
    if (!tl) return;
    uint64_t now = __rdtsc();
    if (tl->sp) tl->cyc[tl->stack[tl->sp - 1]] += now - tl->last;
    tl->stack[tl->sp++] = p;
    tl->last = now;
}
inline void leave() {
    if (!tl) return;
    uint64_t now = __rdtsc();
    tl->cyc[tl->stack[--tl->sp]] += now - tl->last;
    tl->last = now;
}
struct Scope {
    explicit Scope(Phase p) { enter(p); }
    ~Scope() { leave(); }
};
inline void request_done() {
    if (tl) tl->requests++;
}

}  // namespace prof

#define PROF_CAT2(a, b) a##b
#define PROF_CAT(a, b) PROF_CAT2(a, b)
#define PROF_SCOPE(p) ::prof::Scope PROF_CAT(prof_scope_, __LINE__)(::prof::p)
#define PROF_REQUEST_DONE() ::prof::request_done()
#define PROF_READ_GROUP(m, s) ::prof::read_group((m), (s))
#else
#define PROF_READ_GROUP(m, s) ((void)0)
#define PROF_SCOPE(p) ((void)0)
#define PROF_REQUEST_DONE() ((void)0)
#endif

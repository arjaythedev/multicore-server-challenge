/* Portable syscall boundary for the inherited Goose epoll scheduler.
   Our twelve-dollar-server-challenge PR #143 transport also crosses into C
   before socket/epoll calls. Here the existing async Goose scheduler stays in
   charge; C only translates the native ABI, including ARM's epoll padding. */
#define _GNU_SOURCE
#include "json_fast.h"
#include <errno.h>
#include <limits.h>
#include <stddef.h>
#include <poll.h>
#include <sys/epoll.h>
#include <sys/random.h>
#include <sys/socket.h>
#include <unistd.h>

#pragma pack(push, 1)
typedef struct { uint32_t events; uint64_t data; } GooseEpollEvent;
typedef struct { GooseEpollEvent *data; int64_t len; } GooseEpollSlice;
#pragma pack(pop)

int64_t native_sys_read(int32_t fd, mutable_bytes buffer) {
    return read(fd, buffer.data, (size_t)buffer.len);
}

int64_t native_sys_write(int32_t fd, bytes buffer) {
    return write(fd, buffer.data, (size_t)buffer.len);
}

/* A bcrypt reply is one 72-byte record on an O_NONBLOCK pipe. Writes no
   larger than PIPE_BUF either transfer the complete record or return EAGAIN;
   waiting here backpressures the hash worker instead of discarding its job. */
int64_t native_write_atomic_reply(int32_t fd, bytes buffer) {
    if (buffer.len <= 0 || buffer.len > PIPE_BUF) { errno = EINVAL; return -1; }
    for (;;) {
        ssize_t n = write(fd, buffer.data, (size_t)buffer.len);
        if (n == buffer.len) return n;
        if (n >= 0) { errno = EIO; return -1; }
        if (errno == EINTR) continue;
        if (errno != EAGAIN && errno != EWOULDBLOCK) return -1;
        struct pollfd pipe = { .fd = fd, .events = POLLOUT };
        int ready;
        do { ready = poll(&pipe, 1, -1); } while (ready < 0 && errno == EINTR);
        if (ready < 0) return -1;
        if (pipe.revents & POLLNVAL) { errno = EBADF; return -1; }
        if (pipe.revents & (POLLERR | POLLHUP)) { errno = EPIPE; return -1; }
        /* Another worker can fill the pipe before this one writes. Retry. */
    }
}

int64_t native_sys_recv(int32_t fd, mutable_bytes buffer, int32_t flags) {
    return recv(fd, buffer.data, (size_t)buffer.len, flags);
}

int64_t native_sys_send(int32_t fd, bytes buffer, int32_t flags) {
    return send(fd, buffer.data, (size_t)buffer.len, flags);
}

int64_t native_sys_getrandom(mutable_bytes buffer, uint32_t flags) {
    return getrandom(buffer.data, (size_t)buffer.len, flags);
}

int32_t native_sys_epoll_ctl(int32_t epfd, int32_t op, int32_t fd, GooseEpollEvent *event) {
#if defined(__x86_64__) || defined(__i386__)
    /* Linux x86 packs epoll_event exactly like Goose: retain zero-copy. */
    _Static_assert(sizeof(struct epoll_event) == sizeof(GooseEpollEvent), "x86 epoll size");
    _Static_assert(offsetof(struct epoll_event, data) == offsetof(GooseEpollEvent, data), "x86 epoll offset");
    return epoll_ctl(epfd, op, fd, (struct epoll_event *)(void *)event);
#else
    struct epoll_event native;
    if (event) { native.events = event->events; native.data.u64 = event->data; }
    return epoll_ctl(epfd, op, fd, event ? &native : NULL);
#endif
}

int32_t native_sys_epoll_wait(int32_t epfd, GooseEpollSlice events, int32_t timeout) {
    if (events.len <= 0 || events.len > INT_MAX) { errno = EINVAL; return -1; }
#if defined(__x86_64__) || defined(__i386__)
    return epoll_wait(epfd, (struct epoll_event *)(void *)events.data, (int)events.len, timeout);
#else
    /* The scheduler asks for 256 events. A larger slice is safely capped to
       that many; no allocation or per-event ownership survives this call. */
    struct epoll_event native[256];
    int capacity = events.len < 256 ? (int)events.len : 256;
    int n = epoll_wait(epfd, native, capacity, timeout);
    for (int i = 0; i < n; ++i) {
        events.data[i].events = native[i].events;
        events.data[i].data = native[i].data.u64;
    }
    return n;
#endif
}

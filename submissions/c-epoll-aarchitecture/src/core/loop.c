#include "core/loop.h"

#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/timerfd.h>
#include <unistd.h>

#include "util.h"

struct loop_fd {
    int fd;
    unsigned events;
    loop_fd_fn *fn;
    void *user;
    struct loop *owner;
    struct loop_fd *next;
    struct loop_fd *znext;
    bool removed;               // pending free; a current epoll batch may still
                                // hold events for this fd
};

struct loop {
    int ep;
    int timer_fd;               // -1 until loop_timer
    loop_fd *timer_source;
    loop_timer_fn *timer_fn;
    void *timer_user;
    loop_fd *sources;
    loop_fd *zombie;            // removed source structs, freed after the batch
};

static uint32_t epoll_mask(unsigned events) {
    uint32_t mask = 0;
    if (events & LOOP_IN) mask |= EPOLLIN;
    if (events & LOOP_OUT) mask |= EPOLLOUT;
    return mask;
}

loop *loop_create(void) {
    int ep = epoll_create1(EPOLL_CLOEXEC);
    CHECK(ep >= 0, "epoll_create1: %s", strerror(errno));
    loop *l = xcalloc(1, sizeof *l);
    l->ep = ep;
    l->timer_fd = -1;
    return l;
}

void loop_destroy(loop *l) {
    if (!l) return;
    loop_fd *e = l->sources;
    while (e) {
        loop_fd *next = e->next;
        free(e);
        e = next;
    }
    while (l->zombie) {
        loop_fd *next = l->zombie->znext;
        free(l->zombie);
        l->zombie = next;
    }
    if (l->timer_fd >= 0) close(l->timer_fd);
    close(l->ep);
    free(l);
}

loop_fd *loop_add(loop *l, int fd, unsigned events, loop_fd_fn *fn, void *user) {
    CHECK(fn != NULL, "loop_add: callback is required");
    loop_fd *e = xcalloc(1, sizeof *e);
    e->fd = fd;
    e->events = events;
    e->fn = fn;
    e->user = user;
    e->owner = l;

    struct epoll_event ev;
    memset(&ev, 0, sizeof ev);
    ev.events = epoll_mask(events);
    ev.data.ptr = e;
    if (epoll_ctl(l->ep, EPOLL_CTL_ADD, fd, &ev) != 0) {
        free(e);
        return NULL;
    }
    e->next = l->sources;
    l->sources = e;
    return e;
}

void loop_set_events(loop *l, loop_fd *e, unsigned events) {
    if (!e || e->removed || e->events == events) return;
    struct epoll_event ev;
    memset(&ev, 0, sizeof ev);
    ev.events = epoll_mask(events);
    ev.data.ptr = e;
    CHECK(epoll_ctl(l->ep, EPOLL_CTL_MOD, e->fd, &ev) == 0,
          "epoll_ctl MOD fd %d: %s", e->fd, strerror(errno));
    e->events = events;
}

/* A removed fd's data.ptr may still sit later in the epoll_wait batch that is
 * running, so the struct is not freed here: removal only marks it and moves it
 * onto the zombie list, which loop_run drains after the batch has been
 * dispatched. Idempotent, since a caller may reach it twice. */
void loop_remove(loop *l, loop_fd *e) {
    if (!e || e->removed) return;
    epoll_ctl(l->ep, EPOLL_CTL_DEL, e->fd, NULL);
    loop_fd **at = &l->sources;
    while (*at && *at != e) at = &(*at)->next;
    if (*at) *at = e->next;
    e->removed = true;
    e->fn = NULL;
    e->user = NULL;
    e->fd = -1;
    e->znext = l->zombie;
    l->zombie = e;
}

static void timer_event(void *user, loop_fd *self, unsigned events) {
    (void)self;
    (void)events;
    loop *l = user;
    uint64_t ticks;
    while (read(l->timer_fd, &ticks, sizeof ticks) > 0) {
    }
    l->timer_fn(l->timer_user);
}

void loop_timer(loop *l, int interval_ms, loop_timer_fn *fn, void *user) {
    CHECK(l->timer_fd < 0, "loop_timer called twice on one loop");
    CHECK(interval_ms > 0, "loop_timer interval must be positive");
    CHECK(fn != NULL, "loop_timer callback is required");

    int fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
    CHECK(fd >= 0, "timerfd_create: %s", strerror(errno));
    struct itimerspec its;
    memset(&its, 0, sizeof its);
    its.it_interval.tv_sec = interval_ms / 1000;
    its.it_interval.tv_nsec = (long)(interval_ms % 1000) * 1000000L;
    its.it_value = its.it_interval;
    CHECK(timerfd_settime(fd, 0, &its, NULL) == 0,
          "timerfd_settime: %s", strerror(errno));

    l->timer_fd = fd;
    l->timer_fn = fn;
    l->timer_user = user;
    l->timer_source = loop_add(l, fd, LOOP_IN, timer_event, l);
    CHECK(l->timer_source != NULL, "loop_add timerfd failed");
}

static __thread loop *t_current;    // loop running on this thread, else NULL

void loop_run(loop *l, int timeout_ms) {
    t_current = l;
    struct epoll_event ready[128];
    int n = epoll_wait(l->ep, ready, (int)(sizeof ready / sizeof ready[0]),
                       timeout_ms);
    if (n < 0) {
        CHECK(errno == EINTR, "epoll_wait: %s", strerror(errno));
        return;
    }
    for (int i = 0; i < n; i++) {
        loop_fd *e = ready[i].data.ptr;
        if (e->removed) continue;   // a callback freed it earlier this batch
        unsigned events = 0;
        if (ready[i].events & EPOLLIN) events |= LOOP_IN;
        if (ready[i].events & EPOLLOUT) events |= LOOP_OUT;
        if (ready[i].events & (EPOLLERR | EPOLLHUP)) events |= LOOP_ERR;
        if (events) e->fn(e->user, e, events);
    }
    /* deferred removals are drained here: nothing is freed while the ready
     * array of this batch is still being walked */
    loop_fd *z = l->zombie;
    l->zombie = NULL;
    while (z) {
        loop_fd *next = z->znext;
        free(z);
        z = next;
    }
    t_current = NULL;
}

loop *loop_current(void) {
    return t_current;
}

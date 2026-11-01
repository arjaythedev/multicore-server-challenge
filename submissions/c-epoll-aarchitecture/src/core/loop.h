#ifndef CORE_LOOP_H
#define CORE_LOOP_H

/* one epoll set per worker; only this module calls epoll/timerfd, everything
 * else registers callbacks. level-triggered: handlers may return with work
 * pending */

typedef struct loop loop;
typedef struct loop_fd loop_fd;

enum {
    LOOP_IN  = 1u,      // readable
    LOOP_OUT = 2u,      // writable
    LOOP_ERR = 4u,      // epoll error/hangup: unusable fd
};

typedef void loop_fd_fn(void *user, loop_fd *self, unsigned events);
typedef void loop_timer_fn(void *user);

loop *loop_create(void);
void loop_destroy(loop *l);

/* dispatch ready fds until timeout_ms; -1 blocks */
void loop_run(loop *l, int timeout_ms);

/* NULL = registration failed; fd stays caller-owned (removal won't close it) */
loop_fd *loop_add(loop *l, int fd, unsigned events, loop_fd_fn *fn, void *user);
void loop_set_events(loop *l, loop_fd *e, unsigned events);
void loop_remove(loop *l, loop_fd *e);

/* one periodic callback per loop (idle sweep) */
void loop_timer(loop *l, int interval_ms, loop_timer_fn *fn, void *user);

/* the loop running on THIS thread, or NULL off-loop (pool threads) */
loop *loop_current(void);

#endif

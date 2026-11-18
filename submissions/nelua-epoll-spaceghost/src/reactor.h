#ifndef NC_REACTOR_H
#define NC_REACTOR_H
#include "native.h"

typedef struct nc_reactor_hooks {
    /* take returns a frozen batch, or NULL and its next collection deadline
     * (CLOCK_MONOTONIC microseconds, zero when there is no queued work). */
    void *(*take)(void *context, uint64_t *deadline);
    void (*execute)(void *work, nc_db *db);
    void (*complete)(void *context, void *work);
    bool (*stopping)(void *context);
    void (*started)(void *context, bool good);
} nc_reactor_hooks;

/* One OS thread, slots independently owned PG connections, bounded stacks.
 * wake_fd is an eventfd notified on enqueue and shutdown. */
void nc_reactor_run(const char *url, int slots, int wake_fd,
                    const nc_reactor_hooks *hooks, void *context);
#endif

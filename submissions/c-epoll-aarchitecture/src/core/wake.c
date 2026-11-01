#include "core/wake.h"

#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <sys/eventfd.h>
#include <unistd.h>

#include "util.h"

int wake_new(void) {
    return eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
}

void wake_fire(int fd) {
    uint64_t one = 1;
    ssize_t n;
    do {
        n = write(fd, &one, sizeof one);
    } while (n < 0 && errno == EINTR);
    CHECK(n == (ssize_t)sizeof one, "wake_fire: %s", strerror(errno));
}

void wake_drain(int fd) {
    uint64_t counter;
    while (read(fd, &counter, sizeof counter) > 0) {
    }
}

#define _GNU_SOURCE
#include "uring.h"
#include <unistd.h>
#include <sys/syscall.h>

int conduit_uring_setup(uint32_t entries, struct io_uring_params *p) {
    return (int)syscall(__NR_io_uring_setup, entries, p);
}

int conduit_uring_register(int fd, uint32_t opcode, const void *arg, uint32_t nr_args) {
    return (int)syscall(__NR_io_uring_register, fd, opcode, arg, nr_args);
}

int conduit_uring_enter(int fd, uint32_t to_submit, uint32_t min_complete, uint32_t flags, const void *sig, size_t sigsz) {
    return (int)syscall(__NR_io_uring_enter, fd, to_submit, min_complete, flags, sig, sigsz);
}

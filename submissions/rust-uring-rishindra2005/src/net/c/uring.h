#ifndef CONDUIT_URING_H
#define CONDUIT_URING_H

#include <stdint.h>
#include <stddef.h>
#include <linux/io_uring.h>

#ifndef IORING_REGISTER_FILES2
#define IORING_REGISTER_FILES2 13
#endif

#ifndef IORING_RSRC_REGISTER_SPARSE
#define IORING_RSRC_REGISTER_SPARSE 1
#endif

#ifndef IORING_FILE_INDEX_ALLOC
#define IORING_FILE_INDEX_ALLOC (~0U)
#endif

#ifndef IORING_REGISTER_PBUF_RING
#define IORING_REGISTER_PBUF_RING 22
#endif

#ifndef IORING_UNREGISTER_PBUF_RING
#define IORING_UNREGISTER_PBUF_RING 23
#endif

int conduit_uring_setup(uint32_t entries, struct io_uring_params *p);
int conduit_uring_register(int fd, uint32_t opcode, const void *arg, uint32_t nr_args);
int conduit_uring_enter(int fd, uint32_t to_submit, uint32_t min_complete, uint32_t flags, const void *sig, size_t sigsz);

#endif // CONDUIT_URING_H

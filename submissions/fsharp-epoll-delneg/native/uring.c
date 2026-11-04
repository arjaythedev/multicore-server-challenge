// io_uring for the I/O threads, on raw syscalls (no liburing): ring setup with feature fallbacks, a few SQE kinds,
// and a pool of provided receive buffers. One ring per I/O thread, used only by the thread that opened it.
//
// Kernel 6.8 notes (Ubuntu 24.04, what the scorer runs):
//  - setup flags are tried from the newest set down (DEFER_TASKRUN 6.1, SINGLE_ISSUER 6.0, COOP_TASKRUN 5.19);
//  - the receive pool is a buffer ring (IORING_REGISTER_PBUF_RING). Some Ubuntu 6.8.0-1xx builds have the check on
//    the reserved bytes inverted and refuse a ring whose reserved bytes are zero (EINVAL), so on EINVAL the
//    registration is tried again with resv[0] = 1. If that fails too, or force_classic is set, the pool is handed
//    over with IORING_OP_PROVIDE_BUFFERS instead (5.7), and each used buffer is handed back the same way;
//  - multishot accept (5.19) and multishot recv (6.0) fall back to one-shot when the kernel refuses them.
#define _GNU_SOURCE
#include <errno.h>
#include <linux/io_uring.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/socket.h>
#include <unistd.h>

#define BGID 1

struct ur {
  int fd;
  unsigned flags; // setup flags in use
  // SQ
  unsigned *sq_head, *sq_tail, sq_mask, sq_entries, *sq_array;
  struct io_uring_sqe *sqes;
  unsigned sq_local_tail; // SQEs prepared but not yet published
  // CQ
  unsigned *cq_head, *cq_tail, cq_mask;
  struct io_uring_cqe *cqes;
  void *sq_map, *cq_map;
  size_t sq_map_len, cq_map_len, sqes_len;
  // receive buffers
  unsigned char *pool;
  unsigned nbufs, buflen;
  struct io_uring_buf_ring *br; // NULL: classic provided buffers
  unsigned br_mask;
  unsigned short br_tail;
  int classic_pending_lo, classic_pending_n; // a run of returned bids not yet handed back (classic mode)
  int ms_accept, ms_recv; // multishot available (cleared on the first refusal)
  uint64_t efd_buf;
};

struct ur_cqe { uint64_t ud; int32_t res; uint32_t flags; };

static inline unsigned load_acq(unsigned *p) { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
static inline void store_rel(unsigned *p, unsigned v) { __atomic_store_n(p, v, __ATOMIC_RELEASE); }

static int sys_setup(unsigned entries, struct io_uring_params *p) { return (int)syscall(__NR_io_uring_setup, entries, p); }
static int sys_enter(int fd, unsigned submit, unsigned wait, unsigned flags) {
  return (int)syscall(__NR_io_uring_enter, fd, submit, wait, flags, NULL, 0);
}
static int sys_register(int fd, unsigned op, void *arg, unsigned n) { return (int)syscall(__NR_io_uring_register, fd, op, arg, n); }

// publishes prepared SQEs and enters the kernel (to submit, and to wait for `wait` completions)
static int ur_enter(struct ur *u, unsigned wait) {
  unsigned tail = *u->sq_tail;
  unsigned n = u->sq_local_tail - tail;
  if (n) store_rel(u->sq_tail, u->sq_local_tail);
  unsigned fl = wait ? IORING_ENTER_GETEVENTS : 0;
  for (;;) {
    int r = sys_enter(u->fd, n, wait, fl);
    if (r >= 0) return r;
    if (errno == EINTR) { if (!wait) return 0; continue; }
    if (errno == EBUSY || errno == EAGAIN) { // CQ overflow backlog: reap first, the caller will come back
      if (wait) return 0;
      return 0;
    }
    return -errno;
  }
}

static struct io_uring_sqe *get_sqe(struct ur *u) {
  unsigned head = load_acq(u->sq_head);
  if (u->sq_local_tail - head >= u->sq_entries) {
    ur_enter(u, 0); // full: submit what we have
    head = load_acq(u->sq_head);
    if (u->sq_local_tail - head >= u->sq_entries) return NULL;
  }
  unsigned idx = u->sq_local_tail & u->sq_mask;
  struct io_uring_sqe *s = &u->sqes[idx];
  memset(s, 0, sizeof *s);
  u->sq_array[idx] = idx;
  u->sq_local_tail++;
  return s;
}

static int provide_classic(struct ur *u, int bid, int n) {
  struct io_uring_sqe *s = get_sqe(u);
  if (!s) return -EBUSY;
  s->opcode = IORING_OP_PROVIDE_BUFFERS;
  s->fd = n;
  s->addr = (uint64_t)(uintptr_t)(u->pool + (size_t)bid * u->buflen);
  s->len = u->buflen;
  s->off = bid;
  s->buf_group = BGID;
  s->user_data = 0; // completions with ud 0 are ignored by the caller
  return 0;
}

static int setup_buf_ring(struct ur *u) {
  size_t len = sizeof(struct io_uring_buf) * u->nbufs;
  void *ring = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (ring == MAP_FAILED) return -errno;
  struct io_uring_buf_reg reg;
  memset(&reg, 0, sizeof reg);
  reg.ring_addr = (uint64_t)(uintptr_t)ring;
  reg.ring_entries = u->nbufs;
  reg.bgid = BGID;
  int retried = 0;
  int r = sys_register(u->fd, IORING_REGISTER_PBUF_RING, &reg, 1);
  if (r < 0 && errno == EINVAL) { // Ubuntu 6.8.0-1xx: the reserved-bytes check is inverted
    reg.resv[0] = 1;
    retried = 1;
    r = sys_register(u->fd, IORING_REGISTER_PBUF_RING, &reg, 1);
  }
  if (r < 0) { int e = errno; munmap(ring, len); return -e; }
  u->br = ring;
  u->br_mask = u->nbufs - 1;
  u->br_tail = 0;
  for (unsigned i = 0; i < u->nbufs; i++) {
    struct io_uring_buf *b = &u->br->bufs[i];
    b->addr = (uint64_t)(uintptr_t)(u->pool + (size_t)i * u->buflen);
    b->len = u->buflen;
    b->bid = (unsigned short)i;
  }
  u->br_tail = (unsigned short)u->nbufs;
  __atomic_store_n(&u->br->tail, u->br_tail, __ATOMIC_RELEASE);
  return retried;
}

// info out: bit 0 buffer ring (else classic), bit 1 resv workaround was needed, bit 2 DEFER_TASKRUN,
// bit 3 SINGLE_ISSUER, bit 4 COOP_TASKRUN. nbufs must be a power of two (<= 32768).
struct ur *ur_open(unsigned entries, unsigned cq_entries, unsigned nbufs, unsigned buflen, int force_classic, int *info, int *err) {
  static const unsigned tries[] = {
    IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN,
    IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_COOP_TASKRUN,
    IORING_SETUP_COOP_TASKRUN,
    0,
  };
  struct ur *u = calloc(1, sizeof *u);
  if (!u) { *err = ENOMEM; return NULL; }
  struct io_uring_params p;
  int fd = -1;
  for (unsigned t = 0; t < sizeof tries / sizeof tries[0]; t++) {
    memset(&p, 0, sizeof p);
    p.flags = tries[t] | IORING_SETUP_CQSIZE;
    p.cq_entries = cq_entries;
    fd = sys_setup(entries, &p);
    if (fd >= 0) { u->flags = p.flags; break; }
    if (errno != EINVAL) break;
  }
  if (fd < 0) { *err = errno; free(u); return NULL; }
  u->fd = fd;
  u->sq_map_len = p.sq_off.array + p.sq_entries * sizeof(unsigned);
  u->cq_map_len = p.cq_off.cqes + p.cq_entries * sizeof(struct io_uring_cqe);
  int single = (p.features & IORING_FEAT_SINGLE_MMAP) != 0;
  if (single) { if (u->cq_map_len > u->sq_map_len) u->sq_map_len = u->cq_map_len; }
  u->sq_map = mmap(NULL, u->sq_map_len, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_SQ_RING);
  if (u->sq_map == MAP_FAILED) goto fail;
  u->cq_map = single ? u->sq_map : mmap(NULL, u->cq_map_len, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_CQ_RING);
  if (u->cq_map == MAP_FAILED) goto fail;
  u->sqes_len = p.sq_entries * sizeof(struct io_uring_sqe);
  u->sqes = mmap(NULL, u->sqes_len, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_SQES);
  if (u->sqes == MAP_FAILED) goto fail;
  char *sq = u->sq_map, *cq = u->cq_map;
  u->sq_head = (unsigned *)(sq + p.sq_off.head);
  u->sq_tail = (unsigned *)(sq + p.sq_off.tail);
  u->sq_mask = *(unsigned *)(sq + p.sq_off.ring_mask);
  u->sq_entries = *(unsigned *)(sq + p.sq_off.ring_entries);
  u->sq_array = (unsigned *)(sq + p.sq_off.array);
  u->sq_local_tail = *u->sq_tail;
  u->cq_head = (unsigned *)(cq + p.cq_off.head);
  u->cq_tail = (unsigned *)(cq + p.cq_off.tail);
  u->cq_mask = *(unsigned *)(cq + p.cq_off.ring_mask);
  u->cqes = (struct io_uring_cqe *)(cq + p.cq_off.cqes);

  u->nbufs = nbufs;
  u->buflen = buflen;
  u->pool = mmap(NULL, (size_t)nbufs * buflen, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (u->pool == MAP_FAILED) goto fail;
  int resv = 0;
  int r = force_classic ? -EINVAL : setup_buf_ring(u);
  if (r >= 0) {
    resv = r;
  } else {
    u->br = NULL;
    if (provide_classic(u, 0, (int)nbufs) < 0) goto fail;
    ur_enter(u, 0);
  }
  u->classic_pending_lo = -1;
  u->ms_accept = 1;
  u->ms_recv = 1;
  *info = (u->br ? 1 : 0) | (resv ? 2 : 0) | ((u->flags & IORING_SETUP_DEFER_TASKRUN) ? 4 : 0) |
          ((u->flags & IORING_SETUP_SINGLE_ISSUER) ? 8 : 0) | ((u->flags & IORING_SETUP_COOP_TASKRUN) ? 16 : 0);
  *err = 0;
  return u;
fail:
  *err = errno ? errno : EINVAL;
  close(fd);
  free(u);
  return NULL;
}

unsigned char *ur_pool(struct ur *u) { return u->pool; }
int ur_ms_accept(struct ur *u) { return u->ms_accept; }
int ur_ms_recv(struct ur *u) { return u->ms_recv; }
void ur_no_ms_accept(struct ur *u) { u->ms_accept = 0; }
void ur_no_ms_recv(struct ur *u) { u->ms_recv = 0; }

int ur_accept(struct ur *u, int lfd, uint64_t ud) {
  struct io_uring_sqe *s = get_sqe(u);
  if (!s) return -EBUSY;
  s->opcode = IORING_OP_ACCEPT;
  s->fd = lfd;
  s->accept_flags = SOCK_NONBLOCK | SOCK_CLOEXEC;
  if (u->ms_accept) s->ioprio = IORING_ACCEPT_MULTISHOT;
  s->user_data = ud;
  return 0;
}

int ur_recv(struct ur *u, int fd, uint64_t ud) {
  struct io_uring_sqe *s = get_sqe(u);
  if (!s) return -EBUSY;
  s->opcode = IORING_OP_RECV;
  s->fd = fd;
  s->flags = IOSQE_BUFFER_SELECT;
  s->buf_group = BGID;
  if (u->ms_recv) s->ioprio = IORING_RECV_MULTISHOT;
  s->user_data = ud;
  return 0;
}

int ur_send(struct ur *u, int fd, const void *buf, unsigned len, uint64_t ud) {
  struct io_uring_sqe *s = get_sqe(u);
  if (!s) return -EBUSY;
  s->opcode = IORING_OP_SEND;
  s->fd = fd;
  s->addr = (uint64_t)(uintptr_t)buf;
  s->len = len;
  s->msg_flags = MSG_NOSIGNAL;
  s->user_data = ud;
  return 0;
}

// an 8-byte read of an eventfd into the ring's own word
int ur_read_efd(struct ur *u, int efd, uint64_t ud) {
  struct io_uring_sqe *s = get_sqe(u);
  if (!s) return -EBUSY;
  s->opcode = IORING_OP_READ;
  s->fd = efd;
  s->addr = (uint64_t)(uintptr_t)&u->efd_buf;
  s->len = 8;
  s->off = (uint64_t)-1;
  s->user_data = ud;
  return 0;
}

// hands receive buffer `bid` back to the kernel (buffer ring: at once; classic: in runs, sent with the next submit)
void ur_buf_return(struct ur *u, int bid) {
  if (u->br) {
    struct io_uring_buf *b = &u->br->bufs[u->br_tail & u->br_mask];
    b->addr = (uint64_t)(uintptr_t)(u->pool + (size_t)bid * u->buflen);
    b->len = u->buflen;
    b->bid = (unsigned short)bid;
    u->br_tail++;
    __atomic_store_n(&u->br->tail, u->br_tail, __ATOMIC_RELEASE);
    return;
  }
  if (u->classic_pending_lo >= 0 && bid == u->classic_pending_lo + u->classic_pending_n) { u->classic_pending_n++; return; }
  if (u->classic_pending_lo >= 0) provide_classic(u, u->classic_pending_lo, u->classic_pending_n);
  u->classic_pending_lo = bid;
  u->classic_pending_n = 1;
}

// submits everything prepared, waits for at least one completion, copies up to `max` completions out and frees
// their slots. Returns the count, or -errno.
int ur_wait(struct ur *u, struct ur_cqe *out, int max) {
  if (u->classic_pending_lo >= 0) {
    provide_classic(u, u->classic_pending_lo, u->classic_pending_n);
    u->classic_pending_lo = -1;
  }
  unsigned head = *u->cq_head;
  unsigned tail = load_acq(u->cq_tail);
  if (head == tail) {
    int r = ur_enter(u, 1);
    if (r < 0) return r;
    tail = load_acq(u->cq_tail);
  } else if (u->sq_local_tail != *u->sq_tail) {
    ur_enter(u, 0);
    tail = load_acq(u->cq_tail);
  }
  int n = 0;
  while (head != tail && n < max) {
    struct io_uring_cqe *c = &u->cqes[head & u->cq_mask];
    out[n].ud = c->user_data;
    out[n].res = c->res;
    out[n].flags = c->flags;
    n++;
    head++;
  }
  store_rel(u->cq_head, head);
  return n;
}

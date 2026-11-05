// Shared-memory message rings between the HTTP workers and the planner processes (remote_planner.rb).
//
// A Shmq::Ring is one single-producer, single-consumer byte ring in an anonymous MAP_SHARED mapping, made
// before the fork so both processes see the same memory, plus an eventfd the producer writes to wake the
// consumer. Messages are a 4-byte length and the bytes; a message may wrap around the end of the ring.
// The producer owns `tail`, the consumer owns `head`; each publishes with a release store and reads the
// other's with an acquire load, so a message's bytes are visible before its length is.
//
//   Shmq::Ring.new(capacity)   (before fork)
//   ring.push(string)   -> true, or false when the ring is full (try again after the consumer drains)
//   ring.notify         -> wakes the consumer (once per batch of pushes)
//   ring.eventfd        -> the descriptor the consumer waits on (IO#wait_readable)
//   ring.drain          -> every waiting message, as binary strings (and clears the eventfd)
#include <ruby.h>
#include <ruby/encoding.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <unistd.h>
#include <errno.h>

typedef struct {
  _Atomic uint64_t head;
  char pad1[56];
  _Atomic uint64_t tail;
  char pad2[56];
} ctrl_t;

typedef struct {
  ctrl_t *ctrl;
  char *data;
  uint64_t cap;
  size_t map_size;
  int efd;
} ring_t;

static void ring_free(void *p) {
  ring_t *r = p;
  if (r->ctrl) munmap(r->ctrl, r->map_size);
  if (r->efd >= 0) close(r->efd);
  xfree(r);
}

static const rb_data_type_t ring_type = {"Shmq::Ring", {NULL, ring_free, NULL}, NULL, NULL, RUBY_TYPED_FREE_IMMEDIATELY};

static VALUE ring_alloc(VALUE klass) {
  ring_t *r = ALLOC(ring_t);
  memset(r, 0, sizeof *r);
  r->efd = -1;
  return TypedData_Wrap_Struct(klass, &ring_type, r);
}

static ring_t *get(VALUE self) {
  ring_t *r;
  TypedData_Get_Struct(self, ring_t, &ring_type, r);
  return r;
}

static VALUE ring_initialize(VALUE self, VALUE vcap) {
  ring_t *r = get(self);
  uint64_t cap = NUM2ULL(vcap);
  if (cap < 4096) rb_raise(rb_eArgError, "capacity of at least 4096 bytes");
  r->cap = cap;
  r->map_size = sizeof(ctrl_t) + cap;
  void *m = mmap(NULL, r->map_size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
  if (m == MAP_FAILED) rb_sys_fail("mmap");
  r->ctrl = m;
  r->data = (char *)m + sizeof(ctrl_t);
  atomic_store(&r->ctrl->head, 0);
  atomic_store(&r->ctrl->tail, 0);
  r->efd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
  if (r->efd < 0) rb_sys_fail("eventfd");
  return self;
}

static void copy_in(ring_t *r, uint64_t at, const char *src, uint64_t n) {
  uint64_t off = at % r->cap, first = r->cap - off < n ? r->cap - off : n;
  memcpy(r->data + off, src, first);
  if (first < n) memcpy(r->data, src + first, n - first);
}

static void copy_out(ring_t *r, uint64_t at, char *dst, uint64_t n) {
  uint64_t off = at % r->cap, first = r->cap - off < n ? r->cap - off : n;
  memcpy(dst, r->data + off, first);
  if (first < n) memcpy(dst + first, r->data, n - first);
}

static VALUE ring_push(VALUE self, VALUE str) {
  ring_t *r = get(self);
  StringValue(str);
  uint64_t len = (uint64_t)RSTRING_LEN(str), need = 4 + len;
  if (need > r->cap) rb_raise(rb_eArgError, "message larger than the ring");
  uint64_t tail = atomic_load_explicit(&r->ctrl->tail, memory_order_relaxed);
  uint64_t head = atomic_load_explicit(&r->ctrl->head, memory_order_acquire);
  if (r->cap - (tail - head) < need) return Qfalse;
  uint32_t l32 = (uint32_t)len;
  copy_in(r, tail, (const char *)&l32, 4);
  copy_in(r, tail + 4, RSTRING_PTR(str), len);
  atomic_store_explicit(&r->ctrl->tail, tail + need, memory_order_release);
  return Qtrue;
}

static VALUE ring_notify(VALUE self) {
  ring_t *r = get(self);
  uint64_t one = 1;
  if (write(r->efd, &one, sizeof one) < 0 && errno != EAGAIN) rb_sys_fail("eventfd write");
  return Qnil;
}

static VALUE ring_eventfd(VALUE self) { return INT2NUM(get(self)->efd); }

static VALUE ring_drain(VALUE self) {
  ring_t *r = get(self);
  uint64_t count;
  if (read(r->efd, &count, sizeof count) < 0 && errno != EAGAIN) rb_sys_fail("eventfd read");
  uint64_t head = atomic_load_explicit(&r->ctrl->head, memory_order_relaxed);
  uint64_t tail = atomic_load_explicit(&r->ctrl->tail, memory_order_acquire);
  VALUE out = rb_ary_new();
  while (tail - head >= 4) {
    uint32_t len;
    copy_out(r, head, (char *)&len, 4);
    VALUE s = rb_str_buf_new(len);
    copy_out(r, head + 4, RSTRING_PTR(s), len);
    rb_str_set_len(s, len);
    rb_ary_push(out, s);
    head += 4 + (uint64_t)len;
  }
  atomic_store_explicit(&r->ctrl->head, head, memory_order_release);
  return out;
}

static VALUE ring_used(VALUE self) {
  ring_t *r = get(self);
  return ULL2NUM(atomic_load(&r->ctrl->tail) - atomic_load(&r->ctrl->head));
}

void Init_shmq(void) {
  VALUE module = rb_define_module("Shmq");
  VALUE klass = rb_define_class_under(module, "Ring", rb_cObject);
  rb_define_alloc_func(klass, ring_alloc);
  rb_define_method(klass, "initialize", ring_initialize, 1);
  rb_define_method(klass, "push", ring_push, 1);
  rb_define_method(klass, "notify", ring_notify, 0);
  rb_define_method(klass, "eventfd", ring_eventfd, 0);
  rb_define_method(klass, "drain", ring_drain, 0);
  rb_define_method(klass, "used", ring_used, 0);
}

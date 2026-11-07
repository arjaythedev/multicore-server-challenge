#include <sched.h>
#include <stdio.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>

#include "common.h"

void buf_grow(buf_t *b, size_t need) {
  size_t c = b->cap ? b->cap * 2 : 256;
  if (c < need) c = need;
  char *p = realloc(b->p, c);
  if (!p) {
    perror("realloc");
    abort();
  }
  b->p = p;
  b->cap = c;
}

void buf_i64(buf_t *b, int64_t v) {
  char t[24];
  int i = 24;
  bool neg = v < 0;
  uint64_t u = neg ? 0 - (uint64_t)v : (uint64_t)v;
  do {
    t[--i] = '0' + u % 10;
    u /= 10;
  } while (u);
  if (neg) t[--i] = '-';
  buf_put(b, t + i, 24 - i);
}

// 1 = needs an escape: control bytes, quote, backslash.
static const uint8_t esc[256] = {
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
};

void buf_json(buf_t *b, const char *s, size_t l) {
  buf_need(b, l * 6);
  char *o = b->p + b->n;
  for (size_t i = 0; i < l; i++) {
    unsigned char c = s[i];
    if (likely(!esc[c])) {
      *o++ = c;
      continue;
    }
    *o++ = '\\';
    switch (c) {
      case '"': *o++ = '"'; break;
      case '\\': *o++ = '\\'; break;
      case '\n': *o++ = 'n'; break;
      case '\r': *o++ = 'r'; break;
      case '\t': *o++ = 't'; break;
      default:
        *o++ = 'u'; *o++ = '0'; *o++ = '0';
        *o++ = "0123456789abcdef"[c >> 4];
        *o++ = "0123456789abcdef"[c & 15];
    }
  }
  b->n = o - b->p;
}

void buf_ts(buf_t *b, int64_t us) {
  // Postgres epoch 2000-01-01 is day 10957 after 1970-01-01.
  int64_t secs = us >= 0 ? us / 1000000 : -((-us + 999999) / 1000000);
  int64_t frac = us - secs * 1000000;
  int64_t days = secs >= 0 ? secs / 86400 : -((-secs + 86399) / 86400);
  int64_t sod = secs - days * 86400;
  int64_t z = days + 10957 + 719468;
  int64_t era = (z >= 0 ? z : z - 146096) / 146097;
  unsigned doe = (unsigned)(z - era * 146097);
  unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  int64_t y = (int64_t)yoe + era * 400;
  unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  unsigned mp = (5 * doy + 2) / 153;
  unsigned d = doy - (153 * mp + 2) / 5 + 1;
  unsigned m = mp < 10 ? mp + 3 : mp - 9;
  if (m <= 2) y++;
  buf_need(b, 32);
  char *o = b->p + b->n;
  unsigned h = sod / 3600, mi = sod % 3600 / 60, s = sod % 60, ms = frac / 1000;
#define D2(v) (*o++ = '0' + (v) / 10, *o++ = '0' + (v) % 10)
  *o++ = '"';
  D2((unsigned)(y / 100));
  D2((unsigned)(y % 100));
  *o++ = '-';
  D2(m);
  *o++ = '-';
  D2(d);
  *o++ = 'T';
  D2(h);
  *o++ = ':';
  D2(mi);
  *o++ = ':';
  D2(s);
  *o++ = '.';
  *o++ = '0' + ms / 100;
  D2(ms % 100);
  *o++ = 'Z';
  *o++ = '"';
  b->n = o - b->p;
}

void arena_init(arena_t *a, size_t size) {
  a->base = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
  if (a->base == MAP_FAILED) {
    perror("mmap arena");
    abort();
  }
  a->off = 0;
  a->size = size;
  a->fail = NULL;
}

void arena_overflow(arena_t *a) {
  a->off = 0;
  if (a->fail) longjmp(*a->fail, 2);
  abort();
}

void thread_sched(const char *policy, int nice) {
  struct sched_param sp = {0};
  if (policy && !strcmp(policy, "batch")) sched_setscheduler(0, SCHED_BATCH, &sp);
  if (policy && !strcmp(policy, "idle")) sched_setscheduler(0, SCHED_IDLE, &sp);
  if (nice) setpriority(PRIO_PROCESS, (id_t)syscall(SYS_gettid), nice);
}

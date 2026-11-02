// Event loops: one thread, epoll instance, SO_REUSEPORT listener and private fd table each. A connection is a small
// struct and a socket; buffers exist only while bytes are in flight.
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <strings.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <unistd.h>

#include "common.h"

#define MAX_HEAD 16384
#define MAX_BODY (4 << 20)
#define RD_BUF (256 << 10)

typedef struct {
  _Atomic uint32_t gen;  // read by other threads to drop work of closed connections
  bool open, busy, want_close, want_out;
  char *in;  // bytes kept between reads
  uint32_t in_n, in_cap;
  char *out;  // the unsent rest of a response
  size_t out_off, out_len;
  bool out_close;
} conn_t;

typedef struct {
  int id, ep, ev, lsn;
  conn_t *conns;
  size_t nconns;
  _Atomic(job *) done;
  _Atomic int sleeping;
  bool lsn_off;
  int64_t lsn_retry;
  char *rd;
} loop_t;

static loop_t *loops;
static int nloops;
static char *listen_host;
static int listen_port;

job *job_new(size_t extra) {
  job *j = calloc(1, sizeof(job) + extra);
  if (!j) abort();
  return j;
}

// ---- answering
static size_t put_head(char *o, int status, size_t n, bool close) {
  const char *st;
  switch (status) {
    case 200: st = "200 OK"; break;
    case 201: st = "201 Created"; break;
    case 204: st = "204 No Content"; break;
    case 400: st = "400 Bad Request"; break;
    case 401: st = "401 Unauthorized"; break;
    case 403: st = "403 Forbidden"; break;
    case 404: st = "404 Not Found"; break;
    case 413: st = "413 Content Too Large"; break;
    case 422: st = "422 Unprocessable Entity"; break;
    case 503: st = "503 Service Unavailable"; break;
    default: st = "500 Internal Server Error"; break;
  }
  char *s = o;
  o = stpcpy(o, "HTTP/1.1 ");
  o = stpcpy(o, st);
  if (status != 204) {
    o = stpcpy(o, "\r\nContent-Type: application/json");
    o = stpcpy(o, "\r\nContent-Length: ");
    char t[24];
    int i = 24;
    size_t v = n;
    do {
      t[--i] = '0' + v % 10;
      v /= 10;
    } while (v);
    memcpy(o, t + i, 24 - i);
    o += 24 - i;
  }
  if (close) o = stpcpy(o, "\r\nConnection: close");
  o = stpcpy(o, "\r\n\r\n");
  return o - s;
}

// Gzip only what saves a TCP segment: a client ACKs every second segment, so a segment less is less work on both sides.
static int gz_mss = 1448, gz_min_segs = 3;
static inline size_t segs(size_t n) { return (n + (size_t)gz_mss - 1) / (size_t)gz_mss; }

void job_reply(job *j, int status, const char *body, size_t n) {
  char *r = malloc(200 + n);
  if (!r) abort();
  if (j->gzip && gz_min_segs && n + 120 > (size_t)gz_mss * (size_t)gz_min_segs - (size_t)gz_mss) {
    static __thread uint8_t *z;
    static __thread size_t zc;
    if (zc < n + 1024) {
      free(z);
      zc = n * 2 + 4096;
      z = malloc(zc);
    }
    size_t want = (segs(n + 120) - 1) * (size_t)gz_mss - 140;
    size_t zn = gz_encode((const uint8_t *)body, n, z, want);
    if (zn) {
      size_t h = put_head(r, status, zn, j->close);
      h -= 2;
      static const char CE[] = "Content-Encoding: gzip\r\n\r\n";
      memcpy(r + h, CE, sizeof CE - 1);
      h += sizeof CE - 1;
      memcpy(r + h, z, zn);
      j->resp = r;
      j->resp_len = h + zn;
      loop_post(j);
      return;
    }
  }
  size_t h = put_head(r, status, n, j->close);
  memcpy(r + h, body, n);
  j->resp = r;
  j->resp_len = h + n;
  loop_post(j);
}

void job_error(job *j, int status, const char *msg) {
  char b[256];
  int n = snprintf(b, sizeof b, "{\"errors\":{\"body\":[\"%s\"]}}", msg);
  job_reply(j, status, b, n);
}

void loop_post(job *j) {
  loop_t *l = &loops[j->loop];
  job *h = atomic_load_explicit(&l->done, memory_order_relaxed);
  do j->next = h;
  while (!atomic_compare_exchange_weak_explicit(&l->done, &h, j, memory_order_release, memory_order_relaxed));
  if (!h && atomic_load_explicit(&l->sleeping, memory_order_seq_cst)) {
    uint64_t one = 1;
    if (write(l->ev, &one, 8) < 0) { /* the loop is awake if the counter is full */ }
  }
}

bool conn_alive(const job *j) {
  return atomic_load_explicit(&loops[j->loop].conns[j->fd].gen, memory_order_relaxed) == j->gen;
}

// ---- connection lifetime
static void conn_close(loop_t *l, int fd) {
  conn_t *c = &l->conns[fd];
  if (!c->open) return;
  c->open = false;
  atomic_fetch_add_explicit(&c->gen, 1, memory_order_relaxed);
  free(c->in);
  free(c->out);
  c->in = c->out = NULL;
  c->in_n = c->in_cap = 0;
  c->want_out = false;
  c->busy = false;
  close(fd);  // leaves the epoll set with it
}

static void set_out(loop_t *l, int fd, bool on) {
  conn_t *c = &l->conns[fd];
  if (c->want_out == on) return;
  c->want_out = on;
  struct epoll_event e = {.events = EPOLLIN | EPOLLRDHUP | (on ? EPOLLOUT : 0), .data.u64 = (uint64_t)fd};
  epoll_ctl(l->ep, EPOLL_CTL_MOD, fd, &e);
}

static void process_input(loop_t *l, int fd, const char *p, size_t n);

// Writes a whole response; keeps the rest for EPOLLOUT if the socket is full.
static void conn_send(loop_t *l, int fd, char *r, size_t len, bool close_after) {
  conn_t *c = &l->conns[fd];
  ssize_t w = write(fd, r, len);
  if (w == (ssize_t)len) {
    free(r);
    if (close_after) conn_close(l, fd);
    return;
  }
  if (w < 0 && errno != EAGAIN && errno != EINTR) {
    free(r);
    conn_close(l, fd);
    return;
  }
  c->out = r;
  c->out_off = w > 0 ? w : 0;
  c->out_len = len;
  c->out_close = close_after;
  set_out(l, fd, true);
}

static void finish_jobs(loop_t *l) {
  job *h = atomic_exchange_explicit(&l->done, NULL, memory_order_acquire);
  // Oldest first: the list is a stack.
  job *rev = NULL;
  while (h) {
    job *nx = h->next;
    h->next = rev;
    rev = h;
    h = nx;
  }
  for (job *j = rev; j;) {
    job *nx = j->next;
    conn_t *c = &l->conns[j->fd];
    if (atomic_load_explicit(&c->gen, memory_order_relaxed) == j->gen && c->open) {
      c->busy = false;
      conn_send(l, j->fd, j->resp, j->resp_len, j->close);
      j->resp = NULL;
      // Pipelined bytes that arrived while this request ran.
      if (c->open && !c->out && c->in_n) {
        char *in = c->in;
        uint32_t n = c->in_n;
        c->in = NULL;
        c->in_n = c->in_cap = 0;
        process_input(l, j->fd, in, n);
        free(in);
      }
    } else {
      free(j->resp);
    }
    free(j);
    j = nx;
  }
}

// ---- JSON bodies: validation and field extraction
typedef struct {
  const char *p, *e;
} jp_t;
static void ws(jp_t *j) {
  while (j->p < j->e && (*j->p == ' ' || *j->p == '\n' || *j->p == '\t' || *j->p == '\r')) j->p++;
}
static bool skip_str(jp_t *j) {
  if (j->p >= j->e || *j->p != '"') return false;
  j->p++;
  while (j->p < j->e) {
    unsigned char c = *j->p;
    if (c == '"') {
      j->p++;
      return true;
    }
    if (c < 0x20) return false;
    if (c == '\\') {
      j->p++;
      if (j->p >= j->e) return false;
      char x = *j->p;
      if (x == 'u') {
        if (j->e - j->p < 5) return false;
        for (int i = 1; i <= 4; i++)
          if (!strchr("0123456789abcdefABCDEF", j->p[i]) || !j->p[i]) return false;
        j->p += 4;
      } else if (!strchr("\"\\/bfnrt", x) || !x) {
        return false;
      }
    }
    j->p++;
  }
  return false;
}
static bool skip_val(jp_t *j, int depth);
static bool skip_num(jp_t *j) {
  const char *s = j->p;
  if (j->p < j->e && *j->p == '-') j->p++;
  if (j->p >= j->e) return false;
  if (*j->p == '0') j->p++;
  else if (*j->p >= '1' && *j->p <= '9') while (j->p < j->e && *j->p >= '0' && *j->p <= '9') j->p++;
  else return false;
  if (j->p < j->e && *j->p == '.') {
    j->p++;
    const char *d = j->p;
    while (j->p < j->e && *j->p >= '0' && *j->p <= '9') j->p++;
    if (d == j->p) return false;
  }
  if (j->p < j->e && (*j->p == 'e' || *j->p == 'E')) {
    j->p++;
    if (j->p < j->e && (*j->p == '+' || *j->p == '-')) j->p++;
    const char *d = j->p;
    while (j->p < j->e && *j->p >= '0' && *j->p <= '9') j->p++;
    if (d == j->p) return false;
  }
  return j->p > s;
}
static bool lit(jp_t *j, const char *w, size_t n) {
  if ((size_t)(j->e - j->p) < n || memcmp(j->p, w, n)) return false;
  j->p += n;
  return true;
}
static bool skip_val(jp_t *j, int depth) {
  if (depth > 64) return false;
  ws(j);
  if (j->p >= j->e) return false;
  switch (*j->p) {
    case '"': return skip_str(j);
    case 't': return lit(j, "true", 4);
    case 'f': return lit(j, "false", 5);
    case 'n': return lit(j, "null", 4);
    case '[':
      j->p++;
      ws(j);
      if (j->p < j->e && *j->p == ']') { j->p++; return true; }
      for (;;) {
        if (!skip_val(j, depth + 1)) return false;
        ws(j);
        if (j->p >= j->e) return false;
        if (*j->p == ',') { j->p++; continue; }
        if (*j->p == ']') { j->p++; return true; }
        return false;
      }
    case '{':
      j->p++;
      ws(j);
      if (j->p < j->e && *j->p == '}') { j->p++; return true; }
      for (;;) {
        ws(j);
        if (!skip_str(j)) return false;
        ws(j);
        if (j->p >= j->e || *j->p != ':') return false;
        j->p++;
        if (!skip_val(j, depth + 1)) return false;
        ws(j);
        if (j->p >= j->e) return false;
        if (*j->p == ',') { j->p++; continue; }
        if (*j->p == '}') { j->p++; return true; }
        return false;
      }
    default: return skip_num(j);
  }
}
static int hexv(char c) { return c <= '9' ? c - '0' : (c | 32) - 'a' + 10; }
static int hex4(const char *p) { return hexv(p[0]) << 12 | hexv(p[1]) << 8 | hexv(p[2]) << 4 | hexv(p[3]); }
static char *put_utf8(char *o, uint32_t u) {
  if (u < 0x80) *o++ = u;
  else if (u < 0x800) { *o++ = 0xC0 | u >> 6; *o++ = 0x80 | (u & 63); }
  else if (u < 0x10000) { *o++ = 0xE0 | u >> 12; *o++ = 0x80 | ((u >> 6) & 63); *o++ = 0x80 | (u & 63); }
  else { *o++ = 0xF0 | u >> 18; *o++ = 0x80 | ((u >> 12) & 63); *o++ = 0x80 | ((u >> 6) & 63); *o++ = 0x80 | (u & 63); }
  return o;
}
// Decodes a validated JSON string (from its opening quote) into o; returns the end of the output.
static char *unescape_str(const char *s, const char *e, char *o) {
  s++;
  while (s < e && *s != '"') {
    if (*s != '\\') { *o++ = *s++; continue; }
    s++;
    char c = *s++;
    switch (c) {
      case 'b': *o++ = '\b'; break;
      case 'f': *o++ = '\f'; break;
      case 'n': *o++ = '\n'; break;
      case 'r': *o++ = '\r'; break;
      case 't': *o++ = '\t'; break;
      case 'u': {
        uint32_t u = hex4(s);
        s += 4;
        if (u >= 0xD800 && u < 0xDC00 && e - s >= 6 && s[0] == '\\' && s[1] == 'u') {
          uint32_t v = hex4(s + 2);
          if (v >= 0xDC00 && v < 0xE000) {
            u = 0x10000 + ((u - 0xD800) << 10) + (v - 0xDC00);
            s += 6;
          } else u = 0xFFFD;
        } else if (u >= 0xD800 && u < 0xE000) u = 0xFFFD;
        o = put_utf8(o, u);
        break;
      }
      default: *o++ = c;
    }
  }
  return o;
}
static bool storable(const char *s, size_t n) {
  size_t i = 0;
  while (i < n) {
    unsigned char c = s[i];
    if (c < 0x80) {
      if (!c) return false;
      i++;
    } else if (c >= 0xC2 && c <= 0xDF) {
      if (i + 1 >= n || (s[i + 1] & 0xC0) != 0x80) return false;
      i += 2;
    } else if (c >= 0xE0 && c <= 0xEF) {
      if (i + 2 >= n || (s[i + 1] & 0xC0) != 0x80 || (s[i + 2] & 0xC0) != 0x80) return false;
      unsigned char d = s[i + 1];
      if ((c == 0xE0 && d < 0xA0) || (c == 0xED && d > 0x9F)) return false;
      i += 3;
    } else if (c >= 0xF0 && c <= 0xF4) {
      if (i + 3 >= n || (s[i + 1] & 0xC0) != 0x80 || (s[i + 2] & 0xC0) != 0x80 || (s[i + 3] & 0xC0) != 0x80) return false;
      unsigned char d = s[i + 1];
      if ((c == 0xF0 && d < 0x90) || (c == 0xF4 && d > 0x8F)) return false;
      i += 4;
    } else return false;
  }
  return true;
}

typedef struct {
  const char *key;
  const char **dst;
  uint32_t *len;
} jfield;
// {"<root>":{...}}: strings go to the fields (decoded into *pool); null/absent leave NULL.
// tags != NULL collects tagList. False on malformed JSON, a wrong type or unstorable text.
static bool parse_body(const char *b, size_t n, const char *root, jfield *fs, int nf, char **pool, job *tj) {
  jp_t j = {b, b + n};
  { jp_t v = j; if (!skip_val(&v, 0)) return false; ws(&v); if (v.p != v.e) return false; }
  ws(&j);
  if (j.p >= j.e || *j.p != '{') return false;
  j.p++;
  ws(&j);
  const char *obj = NULL;
  size_t rl = strlen(root);
  while (j.p < j.e && *j.p != '}') {
    ws(&j);
    const char *k = j.p;
    skip_str(&j);
    size_t kl = j.p - k - 2;
    ws(&j);
    j.p++;  // ':'
    ws(&j);
    const char *v = j.p;
    skip_val(&j, 0);
    if (kl == rl && !memcmp(k + 1, root, rl)) obj = v;
    ws(&j);
    if (j.p < j.e && *j.p == ',') { j.p++; ws(&j); }
  }
  if (!obj || *obj != '{') return false;
  j.p = obj + 1;
  ws(&j);
  while (j.p < j.e && *j.p != '}') {
    ws(&j);
    const char *k = j.p;
    skip_str(&j);
    size_t kl = j.p - k - 2;
    ws(&j);
    j.p++;
    ws(&j);
    const char *v = j.p;
    skip_val(&j, 0);
    bool taken = false;
    for (int i = 0; i < nf; i++) {
      if (strlen(fs[i].key) != kl || memcmp(fs[i].key, k + 1, kl)) continue;
      taken = true;
      *fs[i].dst = NULL;
      *fs[i].len = 0;
      if (*v == 'n') break;
      if (*v != '"') return false;
      char *o = unescape_str(v, j.e, *pool);
      if (!storable(*pool, o - *pool)) return false;
      *fs[i].dst = *pool;
      *fs[i].len = o - *pool;
      *o++ = 0;
      *pool = o;
      break;
    }
    if (!taken && tj && kl == 7 && !memcmp(k + 1, "tagList", 7)) {
      tj->ntags = 0;
      if (*v == '[') {
        int cap = 0;
        jp_t a = {v + 1, j.p};
        // First count, then decode: tags point into the pool.
        for (const char *q = v; q < j.p; q++) if (*q == ',') cap++;
        cap += 2;
        tj->tags = (const char **)(((uintptr_t)*pool + 7) & ~(uintptr_t)7);
        tj->tag_lens = (uint32_t *)(tj->tags + cap);
        *pool = (char *)(tj->tag_lens + cap);
        ws(&a);
        while (a.p < a.e && *a.p != ']') {
          const char *s = a.p;
          if (*s != '"') {
            if (*s == 'n' ) return false;
            return false;
          }
          skip_str(&a);
          char *o = unescape_str(s, a.p, *pool);
          if (o == *pool || !storable(*pool, o - *pool)) return false;
          tj->tags[tj->ntags] = *pool;
          tj->tag_lens[tj->ntags++] = o - *pool;
          *o++ = 0;
          *pool = o;
          ws(&a);
          if (a.p < a.e && *a.p == ',') { a.p++; ws(&a); }
        }
      } else if (*v != 'n') return false;
    }
    ws(&j);
    if (j.p < j.e && *j.p == ',') { j.p++; ws(&j); }
  }
  return true;
}

// ---- routing
typedef struct {
  const char *method;
  size_t mlen;
  const char *path;
  size_t plen;
  const char *query;
  size_t qlen;
  const char *auth;
  size_t alen;
  const char *body;
  size_t blen;
  bool close, gzip;
} req_t;

static void quick(loop_t *l, int fd, int status, const char *msg, bool close_after) {
  char b[256], *r = malloc(512);
  int n = snprintf(b, sizeof b, "{\"errors\":{\"body\":[\"%s\"]}}", msg);
  size_t h = put_head(r, status, n, close_after);
  memcpy(r + h, b, n);
  conn_send(l, fd, r, h + n, close_after);
}

// decode %xx (and + when plus) into o; false on a bad escape
static bool url_dec(const char *s, size_t n, char *o, size_t *ol, bool plus) {
  size_t k = 0;
  for (size_t i = 0; i < n; i++) {
    char c = s[i];
    if (c == '%') {
      if (i + 2 >= n + 0 && i + 2 > n - 1) return false;
      char a = s[i + 1], b = s[i + 2];
      if (!((a >= '0' && a <= '9') || ((a | 32) >= 'a' && (a | 32) <= 'f'))) return false;
      if (!((b >= '0' && b <= '9') || ((b | 32) >= 'a' && (b | 32) <= 'f'))) return false;
      o[k++] = hexv(a) << 4 | hexv(b);
      i += 2;
    } else if (plus && c == '+') o[k++] = ' ';
    else o[k++] = c;
  }
  *ol = k;
  return true;
}

static bool parse_int_strict(const char *s, size_t n, int64_t maxv, int64_t *out) {
  if (!n) return false;
  uint64_t v = 0;
  for (size_t i = 0; i < n; i++) {
    if (s[i] < '0' || s[i] > '9') return false;
    if (v > (UINT64_MAX - 9) / 10) return false;
    v = v * 10 + (s[i] - '0');
    if (v > (uint64_t)INT64_MAX) return false;
  }
  if ((int64_t)v > maxv) return false;
  *out = (int64_t)v;
  return true;
}

// Returns false after having answered the request.
static bool get_viewer(loop_t *l, int fd, const req_t *q, bool required, int64_t *v) {
  *v = 0;
  if (!q->auth) {
    if (required) quick(l, fd, 401, "unauthorized", q->close);
    return !required;
  }
  if (q->alen < 7 || memcmp(q->auth, "Token ", 6) || !jwt_verify(q->auth + 6, q->alen - 6, v)) {
    quick(l, fd, 401, "unauthorized", q->close);
    return false;
  }
  return true;
}

static job *new_for(loop_t *l, int fd, const req_t *q, int kind, int64_t viewer, size_t extra) {
  job *j = job_new(extra + q->alen + 8);
  j->kind = kind;
  j->close = q->close;
  j->gzip = q->gzip;
  j->loop = l->id;
  j->fd = fd;
  j->gen = atomic_load_explicit(&l->conns[fd].gen, memory_order_relaxed);
  j->viewer = viewer;
  j->t_in = 0;
  return j;
}

static void list_or_feed(loop_t *l, int fd, const req_t *q, bool feed) {
  int64_t v;
  if (!get_viewer(l, fd, q, feed, &v)) return;
  int64_t lim = 20, off = 0;
  const char *f[3] = {0};
  size_t fl[3] = {0};
  bool bad = false, lim_seen = false, off_seen = false;
  char *tmp = q->qlen ? malloc(q->qlen * 2 + 8) : NULL, *t = tmp;
  const char *s = q->query, *e = q->query + q->qlen;
  while (s < e) {
    const char *amp = memchr(s, '&', e - s);
    const char *pe = amp ? amp : e;
    const char *eq = memchr(s, '=', pe - s);
    const char *ke = eq ? eq : pe;
    const char *vs = eq ? eq + 1 : pe;
    size_t kl, vl;
    if (memchr(s, ';', pe - s)) bad = true;
    char *kb = t;
    if (!url_dec(s, ke - s, kb, &kl, true)) { bad = true; kl = 0; }
    t += kl;
    char *vb = t;
    if (!url_dec(vs, pe - vs, vb, &vl, true)) { bad = true; vl = 0; }
    t += vl;
    if (kl == 5 && !memcmp(kb, "limit", 5)) {
      if (!lim_seen && !parse_int_strict(vb, vl, 100, &lim)) bad = true;
      if (lim < 1) bad = true;
      lim_seen = true;
    } else if (kl == 6 && !memcmp(kb, "offset", 6)) {
      if (!off_seen && !parse_int_strict(vb, vl, INT64_MAX, &off)) bad = true;
      off_seen = true;
    } else if (kl == 3 && !memcmp(kb, "tag", 3) && !f[0]) { f[0] = vb; fl[0] = vl; }
    else if (kl == 6 && !memcmp(kb, "author", 6) && !f[1]) { f[1] = vb; fl[1] = vl; }
    else if (kl == 9 && !memcmp(kb, "favorited", 9) && !f[2]) { f[2] = vb; fl[2] = vl; }
    s = amp ? amp + 1 : e;
  }
  if (bad) {
    free(tmp);
    quick(l, fd, 422, "limit must be 1..100 and offset >= 0", q->close);
    return;
  }
  if (off > (1LL << 40)) off = 1LL << 40;
  int kind = K_LIST_ALL;
  const char *nm = NULL;
  size_t nl = 0;
  if (feed) kind = K_FEED;
  else if (fl[0]) { kind = K_LIST_TAG; nm = f[0]; nl = fl[0]; }
  else if (fl[1]) { kind = K_LIST_AUTHOR; nm = f[1]; nl = fl[1]; }
  else if (fl[2]) { kind = K_LIST_FAV; nm = f[2]; nl = fl[2]; }
  if (nl && !storable(nm, nl)) {
    free(tmp);
    char *r = malloc(256);
    static const char E[] = "{\"articles\":[],\"articlesCount\":0}";
    size_t h = put_head(r, 200, sizeof E - 1, q->close);
    memcpy(r + h, E, sizeof E - 1);
    conn_send(l, fd, r, h + sizeof E - 1, q->close);
    return;
  }
  job *j = new_for(l, fd, q, kind, v, nl + 1);
  j->lim = lim;
  j->off = off;
  if (nl) {
    memcpy(j->extra, nm, nl);
    j->extra[nl] = 0;
    j->s1 = j->extra;
    j->l1 = nl;
  }
  free(tmp);
  l->conns[fd].busy = true;
  read_enqueue(j);
}

static void slugify_prefix(const char *t, size_t n, char *o, uint32_t *ol) {
  // lower(regexp_replace(x, '[^A-Za-z0-9]+', '-', 'g')), then '-' trimmed from both ends.
  size_t k = 0;
  bool dash = false;
  for (size_t i = 0; i < n; i++) {
    unsigned char c = t[i];
    bool al = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
    if (al) {
      if (dash && k) o[k++] = '-';
      dash = false;
      o[k++] = (c >= 'A' && c <= 'Z') ? c + 32 : c;
    } else dash = true;
  }
  *ol = (uint32_t)k;
}

static void route(loop_t *l, int fd, req_t *q) {
  conn_t *c = &l->conns[fd];
  const char *m = q->method;
  bool GET = q->mlen == 3 && !memcmp(m, "GET", 3), POST = q->mlen == 4 && !memcmp(m, "POST", 4), PUT = q->mlen == 3 && !memcmp(m, "PUT", 3),
       DEL = q->mlen == 6 && !memcmp(m, "DELETE", 6);
  if (q->plen < 5 || memcmp(q->path, "/api/", 5)) {
    quick(l, fd, 404, "not found", q->close);
    return;
  }
  const char *seg[6];
  size_t sl[6];
  int ns = 0;
  const char *s = q->path + 5, *e = q->path + q->plen;
  while (ns < 6) {
    const char *sl_ = memchr(s, '/', e - s);
    const char *se = sl_ ? sl_ : e;
    seg[ns] = s;
    sl[ns++] = se - s;
    if (!sl_) break;
    s = sl_ + 1;
  }
#define IS(i, w) (sl[i] == sizeof(w) - 1 && !memcmp(seg[i], w, sizeof(w) - 1))
  int64_t v;
  size_t bl = q->blen;
#define NEED_AUTH() if (!get_viewer(l, fd, q, true, &v)) return
#define OPT_AUTH() if (!get_viewer(l, fd, q, false, &v)) return
  if (IS(0, "tags") && ns == 1 && GET) {
    job *j = new_for(l, fd, q, K_TAGS, 0, 0);
    c->busy = true;
    read_enqueue(j);
    return;
  }
  if (IS(0, "users") && ns == 1 && POST) {
    size_t cap = bl + 128 + 64;
    job *j = new_for(l, fd, q, W_REGISTER, 0, cap);
    char *pool = j->extra;
    jfield fs[] = {{"username", &j->s1, &j->l1}, {"email", &j->s2, &j->l2}, {"password", &j->s3, &j->l3}};
    if (!parse_body(q->body, bl, "user", fs, 3, &pool, NULL) || !j->s1 || !j->l1 || !j->s2 || !j->l2 || !j->s3 || !j->l3) {
      free(j);
      quick(l, fd, 422, "username, email and password are required", q->close);
      return;
    }
    if (j->l3 > 72) {
      free(j);
      quick(l, fd, 422, "password is longer than 72 bytes", q->close);
      return;
    }
    j->s4 = pool;
    c->busy = true;
    hash_enqueue_new(j);
    return;
  }
  if (IS(0, "users") && ns == 2 && IS(1, "login") && POST) {
    job *j = new_for(l, fd, q, K_LOGIN, 0, bl + 128 + 128);
    char *pool = j->extra;
    jfield fs[] = {{"email", &j->s1, &j->l1}, {"password", &j->s2, &j->l2}};
    if (!parse_body(q->body, bl, "user", fs, 2, &pool, NULL) || !j->s1 || !j->l1 || !j->s2 || !j->l2) {
      free(j);
      quick(l, fd, 422, "email and password are required", q->close);
      return;
    }
    j->s4 = pool;
    c->busy = true;
    read_enqueue(j);
    return;
  }
  if (IS(0, "user") && ns == 1 && (GET || PUT)) {
    NEED_AUTH();
    if (GET) {
      job *j = new_for(l, fd, q, K_USER, v, 0);
      memcpy(j->extra, q->auth + 6, q->alen - 6);
      j->token = j->extra;
      j->token_len = q->alen - 6;
      c->busy = true;
      read_enqueue(j);
      return;
    }
    job *j = new_for(l, fd, q, W_USER, v, bl + 192 + 64);
    char *pool = j->extra;
    memcpy(pool, q->auth + 6, q->alen - 6);
    j->token = pool;
    j->token_len = q->alen - 6;
    pool += q->alen - 6 + 1;
    jfield fs[] = {{"email", &j->s1, &j->l1}, {"username", &j->s2, &j->l2}, {"password", &j->s3, &j->l3}, {"bio", &j->s5, &j->l5}, {"image", &j->s6, &j->l6}};
    if (!parse_body(q->body, bl, "user", fs, 5, &pool, NULL) || (j->s1 && !j->l1) || (j->s2 && !j->l2) || (j->s3 && !j->l3) || j->l3 > 72) {
      free(j);
      quick(l, fd, 422, "invalid user fields", q->close);
      return;
    }
    j->s4 = NULL;
    c->busy = true;
    if (j->s3) {
      j->s4 = pool;
      hash_enqueue_new(j);
    } else {
      write_enqueue(j);
    }
    return;
  }
  if (IS(0, "profiles") && (ns == 2 || (ns == 3 && IS(2, "follow")))) {
    if (ns == 2 ? !GET : !(POST || DEL)) {
      quick(l, fd, 404, "not found", q->close);
      return;
    }
    if (ns == 2) { OPT_AUTH(); } else { NEED_AUTH(); }
    job *j = new_for(l, fd, q, ns == 2 ? K_PROFILE : POST ? W_FOLLOW : W_UNFOLLOW, v, sl[1] + 1);
    size_t nl;
    if (!url_dec(seg[1], sl[1], j->extra, &nl, false) || !storable(j->extra, nl)) {
      free(j);
      quick(l, fd, 404, "not found", q->close);
      return;
    }
    j->s1 = j->extra;
    j->l1 = nl;
    c->busy = true;
    if (ns == 2) read_enqueue(j);
    else write_enqueue(j);
    return;
  }
  if (IS(0, "articles")) {
    if (ns == 1) {
      if (GET) { list_or_feed(l, fd, q, false); return; }
      if (POST) {
        NEED_AUTH();
        size_t cap = bl * 14 + 256;  // decoded strings plus 12 bytes per possible tag
        job *j = new_for(l, fd, q, W_ARTICLE, v, cap);
        char *pool = j->extra;
        jfield fs[] = {{"title", &j->s1, &j->l1}, {"description", &j->s2, &j->l2}, {"body", &j->s3, &j->l3}};
        if (!parse_body(q->body, bl, "article", fs, 3, &pool, j) || !j->s1 || !j->l1 || !j->s2 || !j->l2 || !j->s3 || !j->l3) {
          free(j);
          quick(l, fd, 422, "title, description and body are required", q->close);
          return;
        }
        j->s4 = pool;
        slugify_prefix(j->s1, j->l1, pool, &j->l4);
        c->busy = true;
        write_enqueue(j);
        return;
      }
      quick(l, fd, 404, "not found", q->close);
      return;
    }
    if (ns == 2 && IS(1, "feed") && GET) {
      list_or_feed(l, fd, q, true);
      return;
    }
    if (ns < 2 || ns > 4) {
      quick(l, fd, 404, "not found", q->close);
      return;
    }
    int kind = -1;
    bool auth_req = true;
    if (ns == 2) kind = GET ? K_ARTICLE_SLUG : PUT ? W_ARTICLE_PUT : DEL ? W_ARTICLE_DEL : -1;
    else if (ns == 3 && IS(2, "favorite")) kind = POST ? W_FAV : DEL ? W_UNFAV : -1;
    else if (ns == 3 && IS(2, "comments")) kind = GET ? K_COMMENTS : POST ? W_COMMENT : -1;
    else if (ns == 4 && IS(2, "comments") && DEL) kind = W_COMMENT_DEL;
    if (kind < 0) {
      quick(l, fd, 404, "not found", q->close);
      return;
    }
    if (kind == K_ARTICLE_SLUG || kind == K_COMMENTS) auth_req = false;
    if (!get_viewer(l, fd, q, auth_req, &v)) return;
    job *j = new_for(l, fd, q, kind, v, sl[1] + 1 + bl * 2 + 256);
    size_t nl;
    bool slug_ok = url_dec(seg[1], sl[1], j->extra, &nl, false) && storable(j->extra, nl);
    if (slug_ok) j->extra[nl] = 0;
    else nl = 0;
    j->s1 = j->extra;
    j->l1 = nl;
    char *pool = j->extra + nl + 1;
    if (kind == W_ARTICLE_PUT) {
      jfield fs[] = {{"title", &j->s2, &j->l2}, {"description", &j->s3, &j->l3}, {"body", &j->s4, &j->l4}};
      if (!parse_body(q->body, bl, "article", fs, 3, &pool, NULL) || (j->s2 && !j->l2) || (j->s3 && !j->l3) || (j->s4 && !j->l4)) {
        free(j);
        quick(l, fd, 422, "title, description and body must be non-empty strings", q->close);
        return;
      }
      if (j->s2) {
        j->s5 = pool;
        slugify_prefix(j->s2, j->l2, pool, &j->l5);
      }
    } else if (kind == W_COMMENT) {
      jfield fs[] = {{"body", &j->s2, &j->l2}};
      if (!parse_body(q->body, bl, "comment", fs, 1, &pool, NULL) || !j->s2 || !j->l2) {
        free(j);
        quick(l, fd, 422, "body is required", q->close);
        return;
      }
    } else if (kind == W_COMMENT_DEL) {
      int64_t id;
      if (!parse_int_strict(seg[3], sl[3], INT64_MAX, &id) || id <= 0) slug_ok = false;
      else j->id = id;
    }
    if (!slug_ok) {
      free(j);
      quick(l, fd, 404, "not found", q->close);
      return;
    }
    c->busy = true;
    if (kind == K_ARTICLE_SLUG || kind == K_COMMENTS) read_enqueue(j);
    else write_enqueue(j);
    return;
  }
  quick(l, fd, 404, "not found", q->close);
}

// Parses as many requests as fit, one in flight at a time; keeps the rest on the connection.
static void process_input(loop_t *l, int fd, const char *p, size_t n) {
  conn_t *c = &l->conns[fd];
  while (n && c->open && !c->busy && !c->out) {
    const char *he = memmem(p, n, "\r\n\r\n", 4);
    if (!he) {
      if (n > MAX_HEAD) { quick(l, fd, 400, "request too large", true); return; }
      break;
    }
    size_t hl = he - p;
    const char *le = memchr(p, '\r', hl + 1);
    const char *sp1 = memchr(p, ' ', le - p);
    const char *sp2 = sp1 ? memchr(sp1 + 1, ' ', le - sp1 - 1) : NULL;
    if (!sp2) {
      quick(l, fd, 400, "bad request", true);
      return;
    }
    req_t q = {0};
    q.method = p;
    q.mlen = sp1 - p;
    q.path = sp1 + 1;
    q.plen = sp2 - sp1 - 1;
    const char *qm = memchr(q.path, '?', q.plen);
    if (qm) {
      q.query = qm + 1;
      q.qlen = q.path + q.plen - qm - 1;
      q.plen = qm - q.path;
    } else q.query = "", q.qlen = 0;
    q.close = le - sp2 - 1 == 8 && !memcmp(sp2 + 1, "HTTP/1.0", 8);
    size_t clen = 0;
    bool chunked = false;
    const char *h = le + 2;
    while (h < he) {
      const char *ne = memchr(h, '\r', he - h + 1);
      const char *col = memchr(h, ':', ne - h);
      if (col) {
        size_t kl = col - h;
        const char *vs = col + 1;
        while (vs < ne && *vs == ' ') vs++;
        size_t vl = ne - vs;
        switch (kl) {
          case 13:
            if (!strncasecmp(h, "authorization", 13)) { q.auth = vs; q.alen = vl; }
            break;
          case 14:
            if (!strncasecmp(h, "content-length", 14)) {
              clen = 0;
              for (size_t i = 0; i < vl && clen <= MAX_BODY; i++) {
                if (vs[i] < '0' || vs[i] > '9') { clen = MAX_BODY + 1; break; }
                clen = clen * 10 + (vs[i] - '0');
              }
            }
            break;
          case 15:
            if (!strncasecmp(h, "accept-encoding", 15) && memmem(vs, vl, "gzip", 4)) q.gzip = true;
            break;
          case 10:
            if (!strncasecmp(h, "connection", 10)) {
              if (vl == 5 && !strncasecmp(vs, "close", 5)) q.close = true;
              if (vl == 10 && !strncasecmp(vs, "keep-alive", 10)) q.close = false;
            }
            break;
          case 17:
            if (!strncasecmp(h, "transfer-encoding", 17)) chunked = true;
            break;
        }
      }
      h = ne + 2;
    }
    if (chunked || clen > MAX_BODY) {
      quick(l, fd, chunked ? 400 : 413, "unsupported body", true);
      return;
    }
    size_t total = hl + 4 + clen;
    if (total > n) break;
    q.body = he + 4;
    q.blen = clen;
    route(l, fd, &q);
    p += total;
    n -= total;
    if (q.close && c->open && !c->busy) return;
  }
  if (n && c->open) {  // keep the rest
    if (c->in_cap < n) {
      char *in = malloc(n);
      free(c->in);
      c->in = in;
      c->in_cap = n;
    }
    if (c->in != p) memmove(c->in, p, n);
    c->in_n = n;
  }
}

static void on_readable(loop_t *l, int fd) {
  conn_t *c = &l->conns[fd];
  if (c->in_n) {  // a partial request, or bytes waiting for the running one
    if ((size_t)c->in_n > MAX_BODY + MAX_HEAD) {
      conn_close(l, fd);
      return;
    }
    if (c->in_cap < c->in_n + RD_BUF) {
      c->in_cap = c->in_n + RD_BUF;
      c->in = realloc(c->in, c->in_cap);
    }
    ssize_t r = read(fd, c->in + c->in_n, c->in_cap - c->in_n);
    if (r == 0 || (r < 0 && errno != EAGAIN && errno != EINTR)) {
      conn_close(l, fd);
      return;
    }
    if (r < 0) return;
    c->in_n += r;
    if (!c->busy && !c->out) {
      char *in = c->in;
      uint32_t n = c->in_n;
      c->in = NULL;
      c->in_n = c->in_cap = 0;
      process_input(l, fd, in, n);
      free(in);
    }
    return;
  }
  ssize_t r = read(fd, l->rd, RD_BUF);
  if (r == 0 || (r < 0 && errno != EAGAIN && errno != EINTR)) {
    conn_close(l, fd);
    return;
  }
  if (r < 0) return;
  if (c->busy || c->out) {
    c->in = malloc(r);
    memcpy(c->in, l->rd, r);
    c->in_n = c->in_cap = r;
    return;
  }
  process_input(l, fd, l->rd, r);
}

static void on_writable(loop_t *l, int fd) {
  conn_t *c = &l->conns[fd];
  if (!c->out) {
    set_out(l, fd, false);
    return;
  }
  ssize_t w = write(fd, c->out + c->out_off, c->out_len - c->out_off);
  if (w < 0 && errno != EAGAIN && errno != EINTR) {
    conn_close(l, fd);
    return;
  }
  if (w > 0) c->out_off += w;
  if (c->out_off == c->out_len) {
    free(c->out);
    c->out = NULL;
    set_out(l, fd, false);
    if (c->out_close) {
      conn_close(l, fd);
      return;
    }
    if (c->in_n && !c->busy) {
      char *in = c->in;
      uint32_t n = c->in_n;
      c->in = NULL;
      c->in_n = c->in_cap = 0;
      process_input(l, fd, in, n);
      free(in);
    }
  }
}

static int listen_socket(void) {
  int s = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
  if (s < 0) {
    perror("socket");
    exit(1);
  }
  int one = 1;
  setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
  struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(listen_port)};
  if (inet_pton(AF_INET, listen_host, &a.sin_addr) != 1) a.sin_addr.s_addr = INADDR_ANY;
  if (bind(s, (struct sockaddr *)&a, sizeof a) || listen(s, 65535)) {
    perror("bind/listen");
    exit(1);
  }
  return s;
}

static void lsn_arm(loop_t *l, bool on) {
  struct epoll_event e = {.events = EPOLLIN, .data.u64 = 1ULL << 40};
  epoll_ctl(l->ep, on ? EPOLL_CTL_ADD : EPOLL_CTL_DEL, l->lsn, &e);
  l->lsn_off = !on;
}

// Out of descriptors: stop accepting for a moment. Clients wait in the backlog instead of the server dying.
static void on_accept(loop_t *l) {
  for (int i = 0; i < 256; i++) {
    int fd = accept4(l->lsn, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
    if (fd < 0) {
      if (errno == EMFILE || errno == ENFILE || errno == ENOBUFS || errno == ENOMEM) {
        lsn_arm(l, false);
        l->lsn_retry = now_us() + 100000;
      }
      return;
    }
    if ((size_t)fd >= l->nconns) {
      close(fd);
      continue;
    }
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    conn_t *c = &l->conns[fd];
    c->open = true;
    c->busy = false;
    c->out = NULL;
    c->in = NULL;
    c->in_n = c->in_cap = 0;
    c->want_out = false;
    struct epoll_event e = {.events = EPOLLIN | EPOLLRDHUP, .data.u64 = (uint64_t)fd};
    if (epoll_ctl(l->ep, EPOLL_CTL_ADD, fd, &e)) conn_close(l, fd);
  }
}

static _Atomic int loops_ready;
static void *loop_main(void *arg) {
  loop_t *l = arg;
  // A private fd table: no contention on the shared one, and its own descriptor limit.
  if (unshare(CLONE_FILES)) perror("unshare");
  const char *pol = getenv("LOOP_SCHED"), *nc = getenv("LOOP_NICE");
  thread_sched(pol ? pol : "batch", nc ? atoi(nc) : 5);
  l->rd = malloc(RD_BUF);
  atomic_fetch_add(&loops_ready, 1);
  struct epoll_event ev[512];
  for (;;) {
    int timeout = l->lsn_off ? 100 : -1;
    atomic_store_explicit(&l->sleeping, 1, memory_order_seq_cst);
    if (atomic_load_explicit(&l->done, memory_order_seq_cst)) timeout = 0;
    int n = epoll_wait(l->ep, ev, 512, timeout);
    atomic_store_explicit(&l->sleeping, 0, memory_order_relaxed);
    if (n < 0 && errno != EINTR) {
      perror("epoll_wait");
      continue;
    }
    if (l->lsn_off && now_us() >= l->lsn_retry) lsn_arm(l, true);
    for (int i = 0; i < n; i++) {
      uint64_t d = ev[i].data.u64;
      if (d == 1ULL << 40) {
        on_accept(l);
      } else if (d == 1ULL << 41) {
        uint64_t x;
        if (read(l->ev, &x, 8) < 0) { /* drained elsewhere */ }
      } else {
        int fd = (int)d;
        if (!l->conns[fd].open) continue;
        uint32_t e = ev[i].events;
        if (e & EPOLLOUT) on_writable(l, fd);
        if (l->conns[fd].open && (e & (EPOLLIN | EPOLLRDHUP | EPOLLHUP | EPOLLERR))) on_readable(l, fd);
      }
    }
    finish_jobs(l);
  }
  return NULL;
}

void loops_start(int n, const char *host, int port) {
  const char *ge = getenv("GZIP_MIN_SEGS");
  if (ge) gz_min_segs = atoi(ge);
  listen_host = strdup(host);
  listen_port = port;
  nloops = n;
  loops = calloc(n, sizeof(loop_t));
  struct rlimit rl;
  size_t maxfd = 1 << 20;
  if (!getrlimit(RLIMIT_NOFILE, &rl) && rl.rlim_cur != RLIM_INFINITY) maxfd = rl.rlim_cur;
  for (int i = 0; i < n; i++) {
    loop_t *l = &loops[i];
    l->id = i;
    l->ep = epoll_create1(EPOLL_CLOEXEC);
    l->ev = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    l->lsn = listen_socket();
    l->nconns = maxfd;
    l->conns = calloc(maxfd, sizeof(conn_t));  // lazily committed
    struct epoll_event e = {.events = EPOLLIN, .data.u64 = 1ULL << 41};
    epoll_ctl(l->ep, EPOLL_CTL_ADD, l->ev, &e);
    lsn_arm(l, true);
  }
  for (int i = 0; i < n; i++) {
    pthread_t t;
    pthread_create(&t, NULL, loop_main, &loops[i]);
  }
  while (atomic_load(&loops_ready) < n) usleep(100);
}

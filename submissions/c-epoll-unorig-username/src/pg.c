#include "pg.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdio.h>
#include <sys/random.h>
#include <sys/socket.h>
#include <unistd.h>

char *pg_url;
static char u_user[128], u_pass[128], u_host[128], u_port[16], u_db[128];

static void url_parse(void) {
  static bool done;
  if (done) return;
  done = true;
  // postgres://user:pass@host:port/db
  const char *p = strstr(pg_url, "://");
  p = p ? p + 3 : pg_url;
  sscanf(p, "%127[^:]:%127[^@]@%127[^:/]", u_user, u_pass, u_host);
  const char *at = strrchr(p, '@');
  const char *h = at ? at + 1 : p;
  const char *c = strchr(h, ':'), *sl = strchr(h, '/');
  strcpy(u_port, "5432");
  if (c && (!sl || c < sl)) sscanf(c + 1, "%15[0-9]", u_port);
  if (sl) sscanf(sl + 1, "%127[^?]", u_db);
}

static void put32(buf_t *b, uint32_t v) {
  v = htonl(v);
  buf_put(b, &v, 4);
}
static void put16(buf_t *b, uint16_t v) {
  v = htons(v);
  buf_put(b, &v, 2);
}
static void put_str(buf_t *b, const char *s) { buf_put(b, s, strlen(s) + 1); }
static size_t msg_begin(buf_t *b, char t) {
  if (t) buf_ch(b, t);
  size_t at = b->n;
  put32(b, 0);
  return at;
}
static void msg_end(buf_t *b, size_t at) {
  uint32_t v = htonl((uint32_t)(b->n - at));
  memcpy(b->p + at, &v, 4);
}

static bool write_all(int fd, const char *p, size_t n) {
  while (n) {
    ssize_t w = write(fd, p, n);
    if (w < 0) {
      if (errno == EINTR) continue;
      if (errno == EAGAIN) {
        struct pollfd f = {fd, POLLOUT, 0};
        if (poll(&f, 1, 30000) <= 0) return false;
        continue;
      }
      return false;
    }
    p += w;
    n -= w;
  }
  return true;
}
static bool read_full(int fd, void *dst, size_t n) {
  char *p = dst;
  while (n) {
    ssize_t r = read(fd, p, n);
    if (r == 0) return false;
    if (r < 0) {
      if (errno == EINTR) continue;
      if (errno == EAGAIN) {
        struct pollfd f = {fd, POLLIN, 0};
        if (poll(&f, 1, 30000) <= 0) return false;
        continue;
      }
      return false;
    }
    p += r;
    n -= r;
  }
  return true;
}

// Reads one whole message (startup phase only).
static bool read_msg(int fd, char *type, char *body, size_t cap, size_t *len) {
  char h[5];
  if (!read_full(fd, h, 5)) return false;
  *type = h[0];
  size_t l = (size_t)be32s(h + 1) - 4;
  if (l > cap) return false;
  *len = l;
  return read_full(fd, body, l);
}

static bool scram(int fd) {
  uint8_t rnd[18];
  char nonce[32], cfirst[64], msg[2048];
  if (getrandom(rnd, 18, 0) != 18) return false;
  size_t nl = b64_std_encode(rnd, 18, nonce);
  nonce[nl] = 0;
  int cfl = snprintf(cfirst, sizeof cfirst, "n,,n=,r=%s", nonce);
  buf_t o = {0};
  size_t at = msg_begin(&o, 'p');
  put_str(&o, "SCRAM-SHA-256");
  put32(&o, cfl);
  buf_put(&o, cfirst, cfl);
  msg_end(&o, at);
  bool ok = write_all(fd, o.p, o.n);
  o.n = 0;
  char t;
  size_t l;
  if (!ok || !read_msg(fd, &t, msg, sizeof msg - 1, &l) || t != 'R' || be32s(msg) != 11) goto fail;
  msg[l] = 0;
  char *sfirst = msg + 4, *r = strstr(sfirst, "r="), *s = strstr(sfirst, ",s="), *i = strstr(sfirst, ",i=");
  if (!r || !s || !i) goto fail;
  int iters = atoi(i + 3);
  uint8_t salt[128];
  int sl = b64_std_decode(s + 3, i - s - 3, salt);
  if (sl <= 0) goto fail;
  char final_noproof[256];
  int fl = snprintf(final_noproof, sizeof final_noproof, "c=biws,r=%.*s", (int)(s - r - 2), r + 2);
  char auth[1024];
  int al = snprintf(auth, sizeof auth, "%s,%s,%s", cfirst + 3, sfirst, final_noproof);
  uint8_t salted[32], ckey[32], skey[32], sig[32], proof[32];
  pbkdf2_sha256(u_pass, strlen(u_pass), salt, sl, iters, salted);
  hmac_sha256(salted, 32, "Client Key", 10, ckey);
  sha256(ckey, 32, skey);
  hmac_sha256(skey, 32, auth, al, sig);
  for (int k = 0; k < 32; k++) proof[k] = ckey[k] ^ sig[k];
  char pb[64];
  size_t pbl = b64_std_encode(proof, 32, pb);
  at = msg_begin(&o, 'p');
  buf_put(&o, final_noproof, fl);
  buf_lit(&o, ",p=");
  buf_put(&o, pb, pbl);
  msg_end(&o, at);
  ok = write_all(fd, o.p, o.n);
  if (!ok || !read_msg(fd, &t, msg, sizeof msg - 1, &l) || t != 'R' || be32s(msg) != 12) goto fail;
  free(o.p);
  return true;
fail:
  free(o.p);
  return false;
}

bool pg_connect(pg_t *c, const char *const *settings, int nsettings, const pg_stmt *st, int nst) {
  url_parse();
  c->fd = -1;
  struct addrinfo hints = {.ai_family = AF_INET, .ai_socktype = SOCK_STREAM}, *ai;
  if (getaddrinfo(u_host, u_port, &hints, &ai)) return false;
  int fd = socket(ai->ai_family, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0 || connect(fd, ai->ai_addr, ai->ai_addrlen)) {
    freeaddrinfo(ai);
    if (fd >= 0) close(fd);
    return false;
  }
  freeaddrinfo(ai);
  int one = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
  buf_t o = {0};
  size_t at = msg_begin(&o, 0);
  put32(&o, 196608);
  put_str(&o, "user");
  put_str(&o, u_user);
  put_str(&o, "database");
  put_str(&o, u_db);
  put_str(&o, "application_name");
  put_str(&o, "conduit");
  buf_ch(&o, 0);
  msg_end(&o, at);
  char *msg = malloc(65536);
  char t;
  size_t l;
  bool ok = write_all(fd, o.p, o.n);
  o.n = 0;
  while (ok) {
    if (!read_msg(fd, &t, msg, 65535, &l)) { ok = false; break; }
    if (t == 'R') {
      int code = be32s(msg);
      if (code == 0) continue;
      if (code == 10) { ok = scram(fd); continue; }
      if (code == 3) {
        at = msg_begin(&o, 'p');
        put_str(&o, u_pass);
        msg_end(&o, at);
        ok = write_all(fd, o.p, o.n);
        o.n = 0;
        continue;
      }
      fprintf(stderr, "pg: unsupported auth %d\n", code);
      ok = false;
    } else if (t == 'E') {
      fprintf(stderr, "pg: startup error\n");
      ok = false;
    } else if (t == 'Z') {
      break;
    }
  }
  // Session settings and statements, each checked.
  for (int i = 0; ok && i < nsettings; i++) {
    at = msg_begin(&o, 'Q');
    put_str(&o, settings[i]);
    msg_end(&o, at);
  }
  if (ok) {
    if (nst) {
      for (int i = 0; i < nst; i++) {
        at = msg_begin(&o, 'P');
        put_str(&o, st[i].name);
        put_str(&o, st[i].sql);
        put16(&o, 0);
        msg_end(&o, at);
      }
      at = msg_begin(&o, 'S');
      msg_end(&o, at);
    }
    ok = write_all(fd, o.p, o.n);
    int want_z = nsettings + (nst ? 1 : 0);
    while (ok && want_z) {
      if (!read_msg(fd, &t, msg, 65535, &l)) { ok = false; break; }
      if (t == 'E') {
        msg[l < 65535 ? l : 65534] = 0;
        for (char *f = msg; f < msg + l && *f; f += strlen(f) + 1)
          if (*f == 'M') fprintf(stderr, "pg: setup error: %s\n", f + 1);
        ok = false;
      } else if (t == 'Z') {
        want_z--;
      }
    }
  }
  free(msg);
  free(o.p);
  if (!ok) {
    close(fd);
    return false;
  }
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
  c->fd = fd;
  c->out.n = 0;
  return true;
}

void pg_close(pg_t *c) {
  if (c->fd >= 0) close(c->fd);
  c->fd = -1;
  c->out.n = 0;
}

void pg_bind(pg_t *c, const char *stmt, int nparams) {
  buf_t *b = &c->out;
  c->bind_start = msg_begin(b, 'B');
  buf_ch(b, 0);
  put_str(b, stmt);
  put16(b, 1);
  put16(b, 1);  // all parameters binary
  put16(b, nparams);
}
void pg_null(pg_t *c) { put32(&c->out, 0xffffffffu); }
void pg_i64(pg_t *c, int64_t v) {
  put32(&c->out, 8);
  uint64_t x = __builtin_bswap64((uint64_t)v);
  buf_put(&c->out, &x, 8);
}
void pg_text(pg_t *c, const char *s, size_t l) {
  put32(&c->out, (uint32_t)l);
  buf_put(&c->out, s, l);
}
void pg_i64arr(pg_t *c, const int64_t *v, int n) {
  buf_t *b = &c->out;
  size_t sz = n ? 20 + (size_t)n * 12 : 12;
  put32(b, (uint32_t)sz);
  buf_need(b, sz);
  put32(b, n ? 1 : 0);
  put32(b, 0);
  put32(b, 20);  // int8
  if (!n) return;
  put32(b, n);
  put32(b, 1);
  char *o = b->p + b->n;
  for (int i = 0; i < n; i++) {
    uint32_t l = htonl(8);
    uint64_t x = __builtin_bswap64((uint64_t)v[i]);
    memcpy(o, &l, 4);
    memcpy(o + 4, &x, 8);
    o += 12;
  }
  b->n = o - b->p;
}
void pg_textarr(pg_t *c, const char *const *s, const uint32_t *l, int n) {
  buf_t *b = &c->out;
  size_t at = b->n;
  put32(b, 0);
  put32(b, n ? 1 : 0);
  put32(b, 0);
  put32(b, 25);  // text
  if (n) {
    put32(b, n);
    put32(b, 1);
    for (int i = 0; i < n; i++) {
      put32(b, l[i]);
      buf_put(b, s[i], l[i]);
    }
  }
  uint32_t v = htonl((uint32_t)(b->n - at - 4));
  memcpy(b->p + at, &v, 4);
}
void pg_bind_end(pg_t *c) {
  buf_t *b = &c->out;
  put16(b, 1);
  put16(b, 1);  // all results binary
  msg_end(b, c->bind_start);
  static const char EXEC[] = {'E', 0, 0, 0, 9, 0, 0, 0, 0, 0};
  buf_put(b, EXEC, sizeof EXEC);
}

static void read_error(pg_res *r, const char *p, size_t l) {
  const char *e = p + l;
  while (p < e && *p) {
    char f = *p++;
    size_t n = strnlen(p, e - p);
    if (f == 'C' && n == 5) memcpy(r->sqlstate, p, 6);
    if (f == 'n' && n < sizeof r->constraint) memcpy(r->constraint, p, n + 1);
    p += n + 1;
  }
}

bool pg_exchange(pg_t *c, arena_t *a, pg_res *res) {
  memset(res, 0, sizeof *res);
  static const char SYNC[] = {'S', 0, 0, 0, 4};
  buf_put(&c->out, SYNC, 5);
  const char *op = c->out.p;
  size_t left = c->out.n;
  size_t start = a->off, scan = a->off;
  bool got_z = false;
  while (!got_z) {
    if (left) {
      ssize_t w = write(c->fd, op, left);
      if (w > 0) {
        op += w;
        left -= w;
      } else if (w < 0 && errno != EAGAIN && errno != EINTR) {
        goto lost;
      }
    }
    if (a->size - a->off < 1 << 16) arena_overflow(a);
    ssize_t r = read(c->fd, a->base + a->off, a->size - a->off);
    if (r > 0) {
      a->off += r;
      while (a->off - scan >= 5) {
        const char *m = a->base + scan;
        size_t ml = (size_t)(uint32_t)be32s(m + 1) + 1;
        if (a->off - scan < ml) break;
        if (m[0] == 'E') {
          res->error = true;
          read_error(res, m + 5, ml - 5);
        }
        scan += ml;
        if (m[0] == 'Z') {
          got_z = true;
          break;
        }
      }
      continue;
    }
    if (r == 0) goto lost;
    if (errno != EAGAIN && errno != EINTR) goto lost;
    struct pollfd f = {c->fd, (short)(POLLIN | (left ? POLLOUT : 0)), 0};
    int pr = poll(&f, 1, 30000);
    if (pr == 0) goto lost;
    if (pr < 0 && errno != EINTR) goto lost;
  }
  c->out.n = 0;
  a->off = (a->off + 15) & ~(size_t)15;
  res->p = a->base + start;
  res->end = a->base + scan;
  return !res->error;
lost:
  res->lost = true;
  c->out.n = 0;
  return false;
}

int pg_next(pg_res *r, pg_row *row) {
  while (r->p < r->end) {
    const char *m = r->p;
    uint32_t ml = (uint32_t)be32s(m + 1);
    r->p = m + 1 + ml;
    switch (m[0]) {
      case 'D': {
        int n = (uint8_t)m[5] << 8 | (uint8_t)m[6];
        const char *q = m + 7;
        if (n > PG_MAXCOL) n = PG_MAXCOL;
        row->n = n;
        for (int i = 0; i < n; i++) {
          int32_t l = be32s(q);
          q += 4;
          row->l[i] = l;
          row->v[i] = q;
          if (l > 0) q += l;
        }
        return 1;
      }
      case 'C':
        return 0;
      default:
        break;  // BindComplete, ...
    }
  }
  return 0;
}

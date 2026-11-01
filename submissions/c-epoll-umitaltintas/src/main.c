// Conduit server: one epoll loop per core, each with its own listening socket (SO_REUSEPORT) and its own
// Postgres connections in pipeline mode. bcrypt runs on a separate thread pool.
#include "app.h"

#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <sched.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>

#include <sys/epoll.h>
#include <sys/resource.h>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define MAX_HEAD (64 * 1024)
#define MAX_BODY (4 * 1024 * 1024)

void die(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vfprintf(stderr, fmt, ap);
  va_end(ap);
  fputc('\n', stderr);
  exit(1);
}

void buf_grow(buf_t *b, size_t need) {
  size_t cap = b->cap ? b->cap : 1024;
  while (cap < need) cap *= 2;
  b->p = realloc(b->p, cap);
  if (!b->p) die("out of memory");
  b->cap = cap;
}

void buf_u64(buf_t *b, uint64_t v) {
  char t[24];
  int i = 24;
  do {
    t[--i] = '0' + v % 10;
    v /= 10;
  } while (v);
  buf_put(b, t + i, 24 - i);
}

void buf_i64(buf_t *b, int64_t v) {
  if (v < 0) {
    buf_putc(b, '-');
    buf_u64(b, (uint64_t)0 - (uint64_t)v);
  } else {
    buf_u64(b, (uint64_t)v);
  }
}

static void buf_free(buf_t *b) {
  free(b->p);
  b->p = NULL;
  b->len = b->cap = 0;
}

// ---- connections ----

static void conn_process(conn_t *c);

static void conn_destroy(conn_t *c) {
  buf_free(&c->in);
  buf_free(&c->out);
  free(c);
}

static void conn_close(conn_t *c) {
  if (c->dead) return;
  close(c->fd);
  c->dead = true;
  if (!c->job) conn_destroy(c);
}

// Send what we can; the rest waits for EPOLLOUT.
static void conn_send(conn_t *c) {
  while (c->outoff < c->out.len) {
    ssize_t w = send(c->fd, c->out.p + c->outoff, c->out.len - c->outoff, MSG_NOSIGNAL);
    if (w > 0) {
      c->outoff += w;
      continue;
    }
    if (w < 0 && errno == EINTR) continue;
    if (w < 0 && errno == EAGAIN) return;
    conn_close(c);
    return;
  }
  // everything sent: an idle connection keeps no buffers
  buf_free(&c->out);
  c->outoff = 0;
  if (c->close_after && !c->job) conn_close(c);
}

static const char *status_line(int st) {
  switch (st) {
    case 200: return "HTTP/1.1 200 OK\r\n";
    case 201: return "HTTP/1.1 201 Created\r\n";
    case 204: return "HTTP/1.1 204 No Content\r\n";
    case 400: return "HTTP/1.1 400 Bad Request\r\n";
    case 401: return "HTTP/1.1 401 Unauthorized\r\n";
    case 403: return "HTTP/1.1 403 Forbidden\r\n";
    case 404: return "HTTP/1.1 404 Not Found\r\n";
    case 413: return "HTTP/1.1 413 Payload Too Large\r\n";
    case 422: return "HTTP/1.1 422 Unprocessable Entity\r\n";
    default: return "HTTP/1.1 500 Internal Server Error\r\n";
  }
}

static void put_response(conn_t *c, int status, const buf_t *body, bool keep) {
  buf_t *o = &c->out;
  const char *sl = status_line(status);
  buf_put(o, sl, strlen(sl));
  if (status == 204) {
    if (!keep) buf_lit(o, "Connection: close\r\n");
    buf_lit(o, "\r\n");
    return;
  }
  buf_lit(o, "Content-Type: application/json\r\nContent-Length: ");
  buf_u64(o, body->len);
  if (!keep) buf_lit(o, "\r\nConnection: close");
  buf_lit(o, "\r\n\r\n");
  buf_put(o, body->p, body->len);
}

void job_free(job_t *j) {
  for (int i = 0; i < j->nres; i++) PQclear(j->res[i]);
  free(j->req);
  free(j->sbuf);
  free(j->tags);
  free(j->hash);
  free(j->bc_pw);
  free(j->bc_set);
  if (j->bat) batch_release(j->bat);
  free(j);
}

void job_reply(job_t *j, int status) {
  conn_t *c = j->c;
  loop_t *L = j->L;
  bool keep = j->keep_alive;
  c->job = NULL;
  if (c->dead) {
    job_free(j);
    conn_destroy(c);
    return;
  }
  put_response(c, status, &L->body, keep);
  L->body.len = 0;
  job_free(j);
  if (!keep) c->close_after = true;
  if (c->kind == -K_CONN) return;  // called from inside conn_process: it sends when done
  conn_process(c);
}

void job_error(job_t *j, int status, const char *msg) {
  buf_t *b = &j->L->body;
  b->len = 0;
  buf_lit(b, "{\"errors\":{\"body\":[");
  json_str(b, msg, strlen(msg));
  buf_lit(b, "]}}");
  job_reply(j, status);
}

static void conn_fail(conn_t *c, int status) {
  buf_t b = {0};
  buf_lit(&b, "{\"errors\":{\"body\":[\"bad request\"]}}");
  put_response(c, status, &b, false);
  buf_free(&b);
  c->close_after = true;
}

static inline int lc(int ch) { return (ch >= 'A' && ch <= 'Z') ? ch + 32 : ch; }

static bool hname(const char *p, size_t n, const char *want) {
  size_t wn = strlen(want);
  if (n != wn) return false;
  for (size_t i = 0; i < n; i++)
    if (lc((unsigned char)p[i]) != want[i]) return false;
  return true;
}

static bool hval_has(const char *p, size_t n, const char *tok) {
  // case-insensitive substring search for a Connection token
  size_t tn = strlen(tok);
  for (size_t i = 0; i + tn <= n; i++) {
    size_t k = 0;
    while (k < tn && lc((unsigned char)p[i + k]) == tok[k]) k++;
    if (k == tn) return true;
  }
  return false;
}

// Handle every complete request in c->in, one at a time (a request waiting on Postgres holds the rest).
static void conn_process(conn_t *c) {
  c->kind = -K_CONN;  // re-entrancy marker for job_reply
  size_t pos = 0;
  while (!c->job && !c->dead && !c->close_after && pos < c->in.len) {
    char *p = c->in.p + pos;
    size_t n = c->in.len - pos;
    char *e = memmem(p, n, "\r\n\r\n", 4);
    if (!e) {
      if (n > MAX_HEAD) conn_fail(c, 400);
      break;
    }
    size_t hlen = e + 4 - p;
    // request line
    char *eol = memchr(p, '\n', hlen);
    char *sp1 = memchr(p, ' ', eol - p);
    char *sp2 = sp1 ? memchr(sp1 + 1, ' ', eol - sp1 - 1) : NULL;
    if (!sp1 || !sp2) {
      conn_fail(c, 400);
      break;
    }
    const char *method = p;
    int mlen = sp1 - p;
    const char *target = sp1 + 1;
    int tlen = sp2 - target;
    bool http10 = (eol - sp2 >= 9) && memcmp(sp2 + 1, "HTTP/1.0", 8) == 0;
    bool keep = !http10;
    size_t clen = 0;
    bool chunked = false;
    str_t auth = STR_NONE;
    char *line = eol + 1;
    while (line < e + 2) {
      char *le = memchr(line, '\n', e + 4 - line);
      char *colon = memchr(line, ':', le - line);
      if (colon) {
        char *v = colon + 1, *ve = le;
        while (v < ve && (*v == ' ' || *v == '\t')) v++;
        while (ve > v && (ve[-1] == '\r' || ve[-1] == ' ' || ve[-1] == '\t')) ve--;
        size_t nl = colon - line;
        if (hname(line, nl, "content-length")) {
          clen = 0;
          for (char *q = v; q < ve; q++) {
            if (*q < '0' || *q > '9' || clen > MAX_BODY) {
              clen = MAX_BODY + 1;
              break;
            }
            clen = clen * 10 + (*q - '0');
          }
        } else if (hname(line, nl, "authorization")) {
          if (auth.n < 0) auth = (str_t){v, (int)(ve - v)};
        } else if (hname(line, nl, "connection")) {
          if (hval_has(v, ve - v, "close")) keep = false;
          else if (hval_has(v, ve - v, "keep-alive")) keep = true;
        } else if (hname(line, nl, "transfer-encoding")) {
          chunked = true;
        }
      }
      line = le + 1;
    }
    if (chunked) {
      conn_fail(c, 400);
      break;
    }
    if (clen > MAX_BODY) {
      conn_fail(c, 413);
      break;
    }
    if (n < hlen + clen) break;  // wait for the body
    size_t total = hlen + clen;

    job_t *j = calloc(1, sizeof *j);
    j->L = c->L;
    j->c = c;
    j->keep_alive = keep;
    j->req = malloc(total + 1);
    memcpy(j->req, p, total);
    j->req[total] = 0;
    pos += total;
    char *r = j->req;
    const char *path = r + (target - p);
    int plen = tlen;
    const char *query = NULL;
    int qlen = 0;
    const char *qm = memchr(path, '?', plen);
    if (qm) {
      query = qm + 1;
      qlen = plen - (qm + 1 - path);
      plen = qm - path;
    }
    if (auth.n >= 0) auth.p = r + (auth.p - p);
    c->job = j;
    route(j, r + (method - p), mlen, path, plen, query, qlen, r + hlen, clen, auth);
  }
  if (!c->dead) {
    if (c->close_after) {
      c->in.len = 0;
    } else if (pos) {
      memmove(c->in.p, c->in.p + pos, c->in.len - pos);
      c->in.len -= pos;
    }
    if (c->in.len == 0) buf_free(&c->in);  // an idle connection keeps no buffers
    c->kind = K_CONN;
    conn_send(c);
  } else {
    c->kind = K_CONN;
    if (!c->job) conn_destroy(c);
  }
}

static void conn_read(conn_t *c) {
  for (;;) {
    char *dst = buf_room(&c->in, 16 * 1024);
    size_t room = c->in.cap - c->in.len;
    ssize_t r = read(c->fd, dst, room);
    if (r > 0) {
      c->in.len += r;
      if (c->in.len > MAX_HEAD + MAX_BODY + 65536) break;
      if ((size_t)r < room) break;  // drained: the next byte to arrive raises a new edge
      continue;
    }
    if (r < 0 && errno == EINTR) continue;
    if (r < 0 && errno == EAGAIN) break;
    // EOF or error
    if (c->job) {
      conn_close(c);
      return;
    }
    conn_close(c);
    return;
  }
  if (!c->job) conn_process(c);
}

static void do_accept(loop_t *L) {
  for (;;) {
    int fd = accept4(L->lfd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
    if (fd < 0) {
      if (errno == EINTR || errno == ECONNABORTED) continue;
      if (errno == EMFILE || errno == ENFILE) {
        // out of descriptors: stop watching the listener for a moment instead of spinning on it
        static int once;
        if (!once++) fprintf(stderr, "accept: %s\n", strerror(errno));
        epoll_ctl(L->ep, EPOLL_CTL_DEL, L->lfd, NULL);
        L->paused = time(NULL);
      }
      return;
    }
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    conn_t *c = calloc(1, sizeof *c);
    c->kind = K_CONN;
    c->fd = fd;
    c->L = L;
    struct epoll_event ev = {.events = EPOLLIN | EPOLLOUT | EPOLLRDHUP | EPOLLET, .data.ptr = c};
    if (epoll_ctl(L->ep, EPOLL_CTL_ADD, fd, &ev) < 0) {
      close(fd);
      free(c);
    }
  }
}

static void *loop_main(void *arg) {
  loop_t *L = arg;
  struct epoll_event evs[512];
  long dbg_w = 0, dbg_k[5] = {0}, dbg_out = 0;
  time_t dbg_t = time(NULL);
  bool dbg = getenv("DEBUG_LOOP") != NULL;
  for (;;) {
    int64_t wus = pg_wait_us(L);
    if (L->paused && (wus < 0 || wus > 200000)) wus = 200000;
    struct timespec wts = {wus / 1000000, (wus % 1000000) * 1000};
    int n = epoll_pwait2(L->ep, evs, 512, wus < 0 ? NULL : &wts, NULL);
    if (dbg) {
      dbg_w++;
      for (int i = 0; i < n; i++) {
        dbg_k[*(int *)evs[i].data.ptr & 3]++;
        if (evs[i].events & EPOLLOUT) dbg_out++;
      }
      if (time(NULL) != dbg_t) {
        dbg_t = time(NULL);
        extern long dbg_batches, dbg_batched, dbg_bc_groups, dbg_bc_hashes;
        fprintf(stderr, "loop %d: wakeups %ld listen %ld conn %ld pg %ld ev %ld (out %ld) batches %ld reqs %ld bcrypt %ld/%ld\n",
                L->id, dbg_w, dbg_k[1], dbg_k[2], dbg_k[3], dbg_k[0], dbg_out, dbg_batches, dbg_batched,
                __atomic_load_n(&dbg_bc_hashes, __ATOMIC_RELAXED), __atomic_load_n(&dbg_bc_groups, __ATOMIC_RELAXED));
        if (L->id == 0) {
          dbg_batches = dbg_batched = 0;
          __atomic_store_n(&dbg_bc_hashes, 0, __ATOMIC_RELAXED);
          __atomic_store_n(&dbg_bc_groups, 0, __ATOMIC_RELAXED);
        }
        dbg_w = dbg_out = 0;
        memset(dbg_k, 0, sizeof dbg_k);
      }
    }
    if (n < 0) {
      if (errno == EINTR) continue;
      die("epoll_wait: %s", strerror(errno));
    }
    for (int i = 0; i < n; i++) {
      int *kind = evs[i].data.ptr;
      uint32_t e = evs[i].events;
      switch (*kind) {
        case K_LISTEN:
          do_accept(L);
          break;
        case K_EVENT: {
          uint64_t v;
          if (read(L->evfd, &v, 8) < 0) {}
          mbx_drain(L);
          break;
        }
        case K_PG:
          pg_event((pgc_t *)kind, e);
          break;
        case K_CONN: {
          conn_t *c = (conn_t *)kind;
          if (e & (EPOLLIN | EPOLLRDHUP | EPOLLHUP | EPOLLERR)) {
            conn_read(c);
            if (c->dead) break;
          }
          if ((e & EPOLLOUT) && c->outoff < c->out.len) conn_send(c);
          break;
        }
      }
    }
    pg_flush_dirty(L);
    if (unlikely(L->paused) && time(NULL) != L->paused) {
      L->paused = 0;
      struct epoll_event ev = {.events = EPOLLIN, .data.ptr = &L->lfd_kind};
      epoll_ctl(L->ep, EPOLL_CTL_ADD, L->lfd, &ev);
    }
  }
  return NULL;
}

static int make_listener(const char *host, int port) {
  int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
  if (fd < 0) die("socket: %s", strerror(errno));
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
  struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port)};
  if (inet_pton(AF_INET, host, &a.sin_addr) != 1) die("bad HOST %s", host);
  if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0) die("bind %s:%d: %s", host, port, strerror(errno));
  if (listen(fd, 65535) < 0) die("listen: %s", strerror(errno));
  return fd;
}

static int env_int(const char *name, int def) {
  const char *v = getenv(name);
  return v && *v ? atoi(v) : def;
}

int main(int argc, char **argv) {
  if (argc > 1 && !strcmp(argv[1], "--bcrypt-selftest")) return bc_selftest(argc > 2 ? atoi(argv[2]) : 500);
  signal(SIGPIPE, SIG_IGN);
  struct rlimit rl;
  if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur < rl.rlim_max) {
    rl.rlim_cur = rl.rlim_max;
    setrlimit(RLIMIT_NOFILE, &rl);
  }
  setvbuf(stderr, NULL, _IOLBF, 0);
  const char *url = getenv("DATABASE_URL");
  const char *secret = getenv("JWT_SECRET");
  if (!url || !secret) die("DATABASE_URL and JWT_SECRET are required");
  const char *host = getenv("HOST");
  if (!host || !*host) host = "127.0.0.1";
  if (!strcmp(host, "localhost")) host = "127.0.0.1";
  int port = env_int("PORT", 3000);
  cpu_set_t cs;
  int ncpu = sched_getaffinity(0, sizeof cs, &cs) == 0 ? CPU_COUNT(&cs) : (int)sysconf(_SC_NPROCESSORS_ONLN);
  // One event loop per 4 CPUs: fewer loops mean fuller batches (see pg.c), and on this workload a loop
  // serves well over 15k requests/s.
  int nthreads = env_int("THREADS", ncpu / 4 > 0 ? ncpu / 4 : 1);
  extern int pg_depth, batch_max;
  pg_depth = env_int("PG_DEPTH", pg_depth);
  batch_max = env_int("BATCH_MAX", batch_max);
  extern int read_window_us;
  read_window_us = env_int("READ_WINDOW_US", read_window_us);
  extern int bcrypt_nice;
  bcrypt_nice = env_int("BCRYPT_NICE", bcrypt_nice);
  extern int bcrypt_lanes;
  bcrypt_lanes = env_int("BCRYPT_LANES", bcrypt_lanes);
  extern int bcrypt_window_ms;
  bcrypt_window_ms = env_int("BCRYPT_WINDOW_MS", bcrypt_window_ms);
  if (bcrypt_lanes < 1) bcrypt_lanes = 1;
  if (bcrypt_lanes > BC_MAXLANES) bcrypt_lanes = BC_MAXLANES;
  share_reads = env_int("SHARE_READS", share_reads);
  int nread = env_int("PG_READ_PER_LOOP", 3);
  int nwrite = env_int("PG_WRITE_PER_LOOP", 16);
  int nbc = env_int("BCRYPT_THREADS", ncpu);
  if (nthreads < 1) nthreads = 1;
  if (nread < 1) nread = 1;
  if (nwrite < 0) nwrite = 0;
  if (batch_max < 1) batch_max = 1;
  // stay within max_connections (100, of which 95 are ours to use): give up write connections first
  while ((nread + nwrite) * nthreads > 90 && nwrite > 1) nwrite--;
  while ((nread + nwrite) * nthreads > 90 && nread > 1) nread--;
  int npg = (nread + nwrite) * nthreads;
  if (npg > 95) die("too many Postgres connections: %d", npg);

  auth_init(secret);
  bcrypt_start(nbc);

  loop_t *loops = calloc(nthreads, sizeof *loops);
  for (int i = 0; i < nthreads; i++) {
    loop_t *L = &loops[i];
    L->id = i;
    L->ep = epoll_create1(EPOLL_CLOEXEC);
    pthread_mutex_init(&L->mbx_mu, NULL);
    L->ev_kind = K_EVENT;
    L->evfd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    struct epoll_event ev = {.events = EPOLLIN, .data.ptr = &L->ev_kind};
    epoll_ctl(L->ep, EPOLL_CTL_ADD, L->evfd, &ev);
    pg_open(L, url, nread, nwrite);
  }
  for (int i = 0; i < nthreads; i++) {
    loop_t *L = &loops[i];
    L->lfd_kind = K_LISTEN;
    L->lfd = make_listener(host, port);
    struct epoll_event ev = {.events = EPOLLIN, .data.ptr = &L->lfd_kind};
    epoll_ctl(L->ep, EPOLL_CTL_ADD, L->lfd, &ev);
  }
  fprintf(stderr, "listening on %s:%d, %d loops, %d Postgres connections, %d bcrypt threads\n", host, port,
          nthreads, npg, nbc);
  pthread_t *th = calloc(nthreads, sizeof *th);
  for (int i = 1; i < nthreads; i++) pthread_create(&th[i], NULL, loop_main, &loops[i]);
  loop_main(&loops[0]);
  return 0;
}

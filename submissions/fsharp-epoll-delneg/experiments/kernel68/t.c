// Runs native/uring.c (the server's ring code) against the kernel it boots on: PID 1 in a QEMU guest. A ring echo
// server like the I/O loop (own fd table, multishot accept and recv, sends through the ring), forked clients over
// loopback, for each path: buffer ring (default) and classic provided buffers.
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/reboot.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <unistd.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
struct ur; struct ur_cqe { uint64_t ud; int32_t res; uint32_t flags; };
struct ur *ur_open(unsigned, unsigned, unsigned, unsigned, int, int *, int *);
unsigned char *ur_pool(struct ur *); int ur_ms_accept(struct ur *); int ur_ms_recv(struct ur *);
void ur_no_ms_accept(struct ur *); void ur_no_ms_recv(struct ur *);
int ur_accept(struct ur *, int, uint64_t); int ur_recv(struct ur *, int, uint64_t);
int ur_send(struct ur *, int, const void *, unsigned, uint64_t);
void ur_buf_return(struct ur *, int); int ur_wait(struct ur *, struct ur_cqe *, int);
#define KA 1ULL
#define KR 2ULL
#define KS 3ULL
#define NC 500   // connections, more than the fd limit set below would allow in a shared table is checked separately
#define RT 50
static char sb[2048];
static int client(int port, int nc) {
  int *fd = malloc(sizeof(int) * nc); char buf[64]; struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
  for (int i = 0; i < nc; i++) { fd[i] = socket(AF_INET, SOCK_STREAM, 0); if (connect(fd[i], (void *)&a, sizeof a)) { printf("client connect: %s\n", strerror(errno)); return 1; } }
  for (int r = 0; r < RT; r++) for (int i = 0; i < nc; i++) {
    int n = snprintf(buf, sizeof buf, "c%d-r%d", i, r);
    if (write(fd[i], buf, n) != n) { printf("client write: %s\n", strerror(errno)); return 1; }
    char got[64]; int g = 0; while (g < n) { int k = read(fd[i], got + g, sizeof got - g); if (k <= 0) { printf("client read %d: %s\n", k, strerror(errno)); return 1; } g += k; }
    if (memcmp(got, buf, n)) { printf("client: wrong echo\n"); return 1; }
  }
  for (int i = 0; i < nc; i++) {
    if (i % 2) { close(fd[i]); continue; }
    if (write(fd[i], "quit", 4) != 4) { printf("client quit write: %s\n", strerror(errno)); return 1; }
    char e[16]; int k = read(fd[i], e, sizeof e);
    if (k != 0) { printf("client: expected EOF after quit, got %d: %s\n", k, strerror(errno)); return 1; }
    close(fd[i]);
  }
  return 0;
}
static int run(int classic, int port, int own) {
  if (own && unshare(CLONE_FILES)) { printf("unshare: %s\n", strerror(errno)); return 1; }
  int info = 0, err = 0;
  struct ur *u = ur_open(4096, 65536, 8192, 2048, classic, &info, &err);
  if (!u) { printf("ur_open failed: %s\n", strerror(err)); return 1; }
  printf("  ring: info=%#x bufring=%d resv-workaround=%d defer=%d single=%d coop=%d\n", info, info & 1, !!(info & 2), !!(info & 4), !!(info & 8), !!(info & 16));
  int l = socket(AF_INET, SOCK_STREAM, 0), one = 1; setsockopt(l, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
  if (bind(l, (void *)&a, sizeof a) || listen(l, 4096)) { printf("bind: %s\n", strerror(errno)); return 1; }
  pid_t c = fork(); if (c == 0) _exit(client(port, NC));
  ur_accept(u, l, KA << 60);
  unsigned char *pool = ur_pool(u); struct ur_cqe q[256]; static char gone[65536]; memset(gone, 0, sizeof gone); long stale = 0, quits = 0;
  long accepted = 0, recvs = 0, sends = 0, closed = 0, einval_r = 0, einval_a = 0, enobufs = 0, more_recv = 0;
  while (closed < NC || stale < quits) {
    int n = ur_wait(u, q, 256);
    if (n < 0 && n != -EINTR) { printf("ur_wait: %s\n", strerror(-n)); return 1; }
    for (int i = 0; i < n; i++) {
      unsigned k = q[i].ud >> 60; int fd = (int)(uint32_t)q[i].ud; int more = q[i].flags & 2, hasb = q[i].flags & 1, bid = q[i].flags >> 16, res = q[i].res;
      if (k == KA) {
        if (res >= 0) { accepted++; ur_recv(u, res, (KR << 60) | (uint32_t)res); }
        else if (res == -EINVAL && ur_ms_accept(u)) { einval_a++; ur_no_ms_accept(u); }
        else printf("accept res %d\n", res);
        if (!more) ur_accept(u, l, KA << 60);
      } else if (k == KR) {
        if (gone[fd]) { // closed by us (the way the server does: shutdown, close), the pending recv ends here
          stale++; if (hasb) ur_buf_return(u, bid);
        } else if (res == 4 && !memcmp(pool + (size_t)bid * 2048, "quit", 4)) {
          quits++; ur_buf_return(u, bid); gone[fd] = 1; shutdown(fd, 2); close(fd); closed++;
        } else if (res > 0) {
          recvs++; if (more) more_recv++;
          memcpy(sb, pool + (size_t)bid * 2048, res); // the client runs one request at a time per connection
          char *p = malloc(res); memcpy(p, sb, res);
          ur_send(u, fd, p, res, (KS << 60) | (uint32_t)fd);
          ur_buf_return(u, bid);
          if (!more) ur_recv(u, fd, (KR << 60) | (uint32_t)fd);
        } else {
          if (hasb) ur_buf_return(u, bid);
          if (res == -ENOBUFS) { enobufs++; if (!more) ur_recv(u, fd, (KR << 60) | (uint32_t)fd); }
          else if (res == -EINVAL && ur_ms_recv(u)) { einval_r++; ur_no_ms_recv(u); ur_recv(u, fd, (KR << 60) | (uint32_t)fd); }
          else { close(fd); closed++; }
        }
      } else if (k == KS) { if (res <= 0) printf("send res %d\n", res); else sends++; }
    }
  }
  int st = 0; waitpid(c, &st, 0);
  int ok = WIFEXITED(st) && WEXITSTATUS(st) == 0 && recvs == NC * RT && sends == NC * RT && quits == NC / 2 && stale == quits;
  printf("  quits %ld stale cqes %ld accepted %ld recvs %ld (multishot %ld) sends %ld closed %ld enobufs %ld einval accept/recv %ld/%ld client %d => %s\n", quits, stale, accepted, recvs, more_recv, sends, closed, enobufs, einval_a, einval_r, st, ok ? "OK" : "FAIL");
  return ok ? 0 : 1;
}
int main(void) {
  struct utsname un; uname(&un); printf("KERNEL %s %s\n", un.release, un.version); fflush(stdout);
  int s = socket(AF_INET, SOCK_DGRAM, 0); struct ifreq r; memset(&r, 0, sizeof r); strcpy(r.ifr_name, "lo"); ioctl(s, SIOCGIFFLAGS, &r); r.ifr_flags |= IFF_UP; if (ioctl(s, SIOCSIFFLAGS, &r)) printf("lo up: %s\n", strerror(errno)); close(s);
  int fails = 0;
  struct { const char *name; int classic, own; } t[] = {{"buffer ring, own fd table", 0, 1}, {"classic provided buffers, own fd table", 1, 1}, {"buffer ring, shared table", 0, 0}};
  for (int i = 0; i < 3; i++) {
    printf("TEST %s\n", t[i].name); fflush(stdout);
    pid_t p = fork(); if (p == 0) { setvbuf(stdout, NULL, _IONBF, 0); _exit(run(t[i].classic, 9000 + i, t[i].own)); }
    int st; waitpid(p, &st, 0); if (!WIFEXITED(st) || WEXITSTATUS(st)) { fails++; printf("  FAILED status %d\n", st); }
  }
  printf("RESULT %s\n", fails ? "FAIL" : "PASS"); fflush(stdout);
  sync(); reboot(RB_POWER_OFF); return 0;
}

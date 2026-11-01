/* Connection-scale check: opens N keep-alive connections to the server, spread over IPS loopback addresses, and has
 * each send a cheap request (GET /api/user without a token: 401, no database) every INTERVAL seconds, so every
 * connection also sits idle for that long. Reports, every 5 s, how many are open and whether the server refused,
 * closed or failed to answer any. A direct-front server holds every user's connection, so it has to hold
 * well past the user counts the leaderboard reaches.
 *
 *   gcc -O2 -o conns tests/bench/conns.c && ./conns N RATE INTERVAL SECONDS [PORT] [IPS]
 *   (needs ulimit -n above N) */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

struct conn {
    int fd;
    uint8_t state;        /* 0 unused, 1 connecting, 2 open, 3 dead */
    uint8_t waiting;      /* a request is out */
    int next;             /* the next connection in the same timing-wheel slot */
    double sent_at;
};

/* Sends are scheduled on a wheel of 10 ms slots, so a pass touches only the connections that are due. */
#define TICK 0.01
static int *wheel, nslots;

static void schedule(struct conn *c, int i, double t0, double at) {
    int s = (int)((at - t0) / TICK) % nslots;
    c[i].next = wheel[s];
    wheel[s] = i;
}

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static const char REQ[] = "GET /api/user HTTP/1.1\r\nHost: x\r\n\r\n";

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: conns N RATE INTERVAL SECONDS [PORT] [IPS]\n");
        return 2;
    }
    int n = atoi(argv[1]), rate = atoi(argv[2]);
    double interval = atof(argv[3]), seconds = atof(argv[4]);
    int port = argc > 5 ? atoi(argv[5]) : 3110, ips = argc > 6 ? atoi(argv[6]) : 8;
    struct conn *c = calloc((size_t)n, sizeof *c);
    int ep = epoll_create1(0);
    long refused = 0, closed = 0, errors = 0, answers = 0, late = 0;
    double max_wait = 0;
    int opened = 0, open = 0;
    double t0 = now(), report = t0 + 5;
    srand(1);
    static struct epoll_event evs[16384];
    nslots = (int)(interval / TICK) + 2;
    wheel = malloc((size_t)nslots * sizeof *wheel);
    for (int i = 0; i < nslots; i++) wheel[i] = -1;
    long tick = 0;  /* wheel slots handled so far */
    char buf[65536];

    while (now() - t0 < seconds) {
        double t = now();
        /* open new connections at RATE per second */
        int due = (int)((t - t0) * rate);
        while (opened < n && opened < due) {
            int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
            if (fd < 0) { errors++; opened++; continue; }
            /* An explicit, unique source address and port: past ~100k connections the kernel's own port search
             * in connect() gets slow enough to stall this single-threaded client. */
            struct sockaddr_in src = {.sin_family = AF_INET, .sin_port = htons((uint16_t)(10000 + opened % 50000))};
            src.sin_addr.s_addr = htonl(0x7f000101u + (uint32_t)(opened / 50000));  /* 127.0.1.1, .2, ... */
            int one = 1;
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
            if (bind(fd, (struct sockaddr *)&src, sizeof src) < 0) { errors++; close(fd); opened++; continue; }
            struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons((uint16_t)port)};
            a.sin_addr.s_addr = htonl(0x7f000001u + (uint32_t)(opened % ips));
            int r = connect(fd, (struct sockaddr *)&a, sizeof a);
            if (r < 0 && errno != EINPROGRESS) { refused++; close(fd); opened++; continue; }
            struct conn *x = &c[opened];
            x->fd = fd;
            x->state = 1;
            schedule(c, opened, t0, t + (double)rand() / RAND_MAX * interval);  /* spread the first requests */
            struct epoll_event e = {.events = EPOLLIN | EPOLLOUT | EPOLLRDHUP, .data.u32 = (uint32_t)opened};
            epoll_ctl(ep, EPOLL_CTL_ADD, fd, &e);
            opened++;
        }
        int k = epoll_wait(ep, evs, 16384, 5);
        for (int i = 0; i < k; i++) {
            struct conn *x = &c[evs[i].data.u32];
            if (x->state == 3) continue;
            if (evs[i].events & (EPOLLERR | EPOLLHUP | EPOLLRDHUP)) {
                if (x->state == 1) refused++; else closed++;
                if (x->state == 2) open--;
                x->state = 3;
                close(x->fd);
                continue;
            }
            if (x->state == 1 && (evs[i].events & EPOLLOUT)) {
                x->state = 2;
                open++;
                struct epoll_event e = {.events = EPOLLIN | EPOLLRDHUP, .data.u32 = evs[i].data.u32};
                epoll_ctl(ep, EPOLL_CTL_MOD, x->fd, &e);
            }
            if (evs[i].events & EPOLLIN) {
                ssize_t r = read(x->fd, buf, sizeof buf);
                if (r == 0) { closed++; open--; x->state = 3; close(x->fd); continue; }
                if (r > 0 && x->waiting && r >= 12 && memcmp(buf, "HTTP/1.1 401", 12) == 0) {
                    answers++;
                    x->waiting = 0;
                    double w = now() - x->sent_at;
                    if (w > max_wait) max_wait = w;
                }
            }
        }
        /* each open connection sends one request every INTERVAL: run the wheel up to now */
        t = now();
        long target = (long)((t - t0) / TICK);
        for (; tick <= target; tick++) {
            int s = (int)(tick % nslots), i = wheel[s];
            wheel[s] = -1;
            while (i >= 0) {
                struct conn *x = &c[i];
                int next = x->next;
                if (x->state == 1) {
                    schedule(c, i, t0, t + 1);  /* not connected yet: try again in a second */
                } else if (x->state == 2) {
                    if (x->waiting) { late++; x->waiting = 0; }  /* no answer within a whole interval */
                    if (write(x->fd, REQ, sizeof REQ - 1) != (ssize_t)(sizeof REQ - 1)) errors++;
                    else x->waiting = 1, x->sent_at = t;
                    schedule(c, i, t0, t + interval);
                }
                i = next;
            }
        }
        if (t >= report) {
            printf("t=%3.0fs opened %d open %d refused %ld closed_by_server %ld errors %ld answers %ld unanswered %ld "
                   "max_wait %.0f ms\n", t - t0, opened, open, refused, closed, errors, answers, late, max_wait * 1e3);
            fflush(stdout);
            max_wait = 0;
            report += 5;
        }
    }
    return refused || closed || errors || late ? 1 : 0;
}

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
    double next_send, sent_at;
};

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
    struct epoll_event evs[1024];
    char buf[65536];

    while (now() - t0 < seconds) {
        double t = now();
        /* open new connections at RATE per second */
        int due = (int)((t - t0) * rate);
        while (opened < n && opened < due) {
            int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
            if (fd < 0) { errors++; opened++; continue; }
            struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons((uint16_t)port)};
            a.sin_addr.s_addr = htonl(0x7f000001u + (uint32_t)(opened % ips));
            int r = connect(fd, (struct sockaddr *)&a, sizeof a);
            if (r < 0 && errno != EINPROGRESS) { refused++; close(fd); opened++; continue; }
            struct conn *x = &c[opened];
            x->fd = fd;
            x->state = 1;
            x->next_send = t + (double)rand() / RAND_MAX * interval;  /* spread the first requests */
            struct epoll_event e = {.events = EPOLLIN | EPOLLOUT | EPOLLRDHUP, .data.u32 = (uint32_t)opened};
            epoll_ctl(ep, EPOLL_CTL_ADD, fd, &e);
            opened++;
        }
        int k = epoll_wait(ep, evs, 1024, 5);
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
        /* each open connection sends one request every INTERVAL */
        t = now();
        for (int i = 0; i < opened; i++) {
            struct conn *x = &c[i];
            if (x->state != 2 || t < x->next_send) continue;
            if (x->waiting) { late++; x->waiting = 0; }  /* no answer within a whole interval */
            if (write(x->fd, REQ, sizeof REQ - 1) != (ssize_t)(sizeof REQ - 1)) { errors++; continue; }
            x->waiting = 1;
            x->sent_at = t;
            x->next_send = t + interval;
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

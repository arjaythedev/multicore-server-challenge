#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <signal.h>
#include <liburing.h>
#include <sys/resource.h>


#include "conduit.h"
#include "db.h"
#include "http_routes.h"
#include "auth_crypto.h"
#include "json_simd.h"
#include "db_format.h"

#include <sys/eventfd.h>
#include "bcrypt_pool.h"

#define EV_BCRYPT_DONE   5


#define MAX_CONNS 262144
#define RESP_BODY_SIZE 262144
#define HEADER_RESERVE 256
#define TOTAL_RESP_BUF (HEADER_RESERVE + RESP_BODY_SIZE)

#define EV_ACCEPT        1
#define EV_ACCEPT_SINGLE 2
#define EV_RECV          3
#define EV_SEND          4

typedef struct {
    int fd;
    char *rx_buf;
    int rx_len;
    int rx_cap;
    char *tx_buf;
    int tx_len;
    int tx_sent;
    bool keep_alive;
} client_slot_t;

typedef struct {
    int thread_id;
    int listen_fd;
    char db_url[512];
} worker_arg_t;

static const char *get_status_text(int status) {
    switch (status) {
        case 200: return "OK";
        case 201: return "Created";
        case 204: return "No Content";
        case 401: return "Unauthorized";
        case 403: return "Forbidden";
        case 404: return "Not Found";
        case 422: return "Unprocessable Entity";
        case 500: return "Internal Server Error";
        default: return "OK";
    }
}

static inline void parse_and_dispatch(db_conn_t *db, client_slot_t *conn, char *req_bytes, int req_len, int body_start, int content_length) {
    http_req_t req;
    memset(&req, 0, sizeof(req));

    char *p = req_bytes;
    if (strncmp(p, "GET ", 4) == 0) { req.method = HTTP_METHOD_GET; p += 4; }
    else if (strncmp(p, "POST ", 5) == 0) { req.method = HTTP_METHOD_POST; p += 5; }
    else if (strncmp(p, "PUT ", 4) == 0) { req.method = HTTP_METHOD_PUT; p += 4; }
    else if (strncmp(p, "DELETE ", 7) == 0) { req.method = HTTP_METHOD_DELETE; p += 7; }
    else { req.method = HTTP_METHOD_OTHER; while (*p && *p != ' ') p++; if (*p == ' ') p++; }

    char *space = strchr(p, ' ');
    if (!space) return;
    *space = '\0';
    char *q = strchr(p, '?');
    if (q) {
        *q = '\0';
        strncpy(req.path, p, sizeof(req.path) - 1);
        strncpy(req.query, q + 1, sizeof(req.query) - 1);
    } else {
        strncpy(req.path, p, sizeof(req.path) - 1);
        req.query[0] = '\0';
    }
    req.path_len = (int)strlen(req.path);
    req.query_len = (int)strlen(req.query);

    char *headers_start = space + 1;
    char *auth = strcasestr(headers_start, "Authorization:");
    if (auth && (auth - req_bytes) < body_start) {
        req.has_auth_header = true;
        auth += 14;
        while (*auth == ' ' || *auth == '\t' || *auth == ':') auth++;
        char *end_line = strstr(auth, "\r\n");
        if (end_line) {
            int hlen = (int)(end_line - auth);
            if (hlen > 6 && strncmp(auth, "Token ", 6) == 0) {
                auth += 6;
                hlen -= 6;
                if (hlen < (int)sizeof(req.token)) {
                    memcpy(req.token, auth, hlen);
                    req.token[hlen] = '\0';
                    req.viewer_id = jwt_verify(req.token);
                    if (req.viewer_id <= 0) req.auth_invalid = true;
                } else {
                    req.auth_invalid = true;
                }
            } else {
                req.auth_invalid = true;
            }
        }
    }

    char *conn_hdr = strcasestr(headers_start, "Connection:");
    if (conn_hdr && (conn_hdr - req_bytes) < body_start) {
        conn_hdr += 11;
        while (*conn_hdr == ' ' || *conn_hdr == '\t') conn_hdr++;
        if (strncasecmp(conn_hdr, "close", 5) == 0) {
            conn->keep_alive = false;
        } else {
            conn->keep_alive = true;
        }
    } else {
        conn->keep_alive = true;
    }

    if (body_start > 0 && content_length > 0) {
        req.body = req_bytes + body_start;
        req.body_len = content_length;
    } else {
        req.body = "";
        req.body_len = 0;
    }

    static __thread char raw_resp[TOTAL_RESP_BUF];
    char *body_buf = raw_resp + HEADER_RESERVE;
    http_res_t res;
    res_init(&res, body_buf, RESP_BODY_SIZE);

    handle_request(db, &req, &res);

    char hdr[HEADER_RESERVE];
    int hlen = 0;
    if (res.status == 204) {
        hlen = snprintf(hdr, sizeof(hdr),
                        "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: %s\r\n\r\n",
                        conn->keep_alive ? "keep-alive" : "close");
        res.len = 0;
    } else {
        hlen = snprintf(hdr, sizeof(hdr),
                        "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: %s\r\n\r\n",
                        res.status, get_status_text(res.status), res.len,
                        conn->keep_alive ? "keep-alive" : "close");
    }

    char *start_ptr = body_buf - hlen;
    memcpy(start_ptr, hdr, hlen);
    int total_len = hlen + res.len;

    if (!conn->tx_buf) {
        conn->tx_buf = (char *)malloc(TOTAL_RESP_BUF);
    }
    memcpy(conn->tx_buf, start_ptr, total_len);
    conn->tx_len = total_len;
    conn->tx_sent = 0;
}
static void *worker_thread(void *arg) {
    worker_arg_t *w = (worker_arg_t *)arg;

    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(w->thread_id % sysconf(_SC_NPROCESSORS_ONLN), &cpuset);
    pthread_setaffinity_np(pthread_self(), sizeof(cpu_set_t), &cpuset);

    db_conn_t *db = db_connect(w->db_url);
    if (!db) {
        fprintf(stderr, "Worker %d failed to connect to database\n", w->thread_id);
        return NULL;
    }

    struct io_uring ring;
    struct io_uring_params params;
    memset(&params, 0, sizeof(params));
    params.flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_COOP_TASKRUN | IORING_SETUP_DEFER_TASKRUN;
    int ret = io_uring_queue_init_params(4096, &ring, &params);
    if (ret < 0) {
        memset(&params, 0, sizeof(params));
        ret = io_uring_queue_init(4096, &ring, 0);
    }
    if (ret < 0) {
        fprintf(stderr, "io_uring_queue_init failed: %d\n", ret);
        return NULL;
    }

    struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
    io_uring_prep_poll_add(sqe, w->listen_fd, POLLIN);
    io_uring_sqe_set_data64(sqe, ((uint64_t)EV_ACCEPT << 32));
    int efd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    bcrypt_pool_register_worker_efd(w->thread_id, efd);
    uint64_t efd_buf = 0;
    struct io_uring_sqe *esqe = io_uring_get_sqe(&ring);
    io_uring_prep_read(esqe, efd, &efd_buf, sizeof(efd_buf), 0);
    io_uring_sqe_set_data64(esqe, ((uint64_t)EV_BCRYPT_DONE << 32) | (uint32_t)efd);

    io_uring_submit(&ring);

    client_slot_t *conns = (client_slot_t *)calloc(MAX_CONNS, sizeof(client_slot_t));

    while (1) {
        struct io_uring_cqe *cqe;
        ret = io_uring_wait_cqe(&ring, &cqe);
        if (ret < 0) {
            if (ret == -EINTR) continue;
            break;
        }

        unsigned head;
        unsigned count = 0;
        io_uring_for_each_cqe(&ring, head, cqe) {
            uint64_t udata = io_uring_cqe_get_data64(cqe);
            uint32_t ev_type = (uint32_t)(udata >> 32);
            int fd = (int)(udata & 0xFFFFFFFF);
            int res = cqe->res;

            if (ev_type == EV_ACCEPT) {
                while (1) {
                    struct sockaddr_in client_addr;
                    socklen_t client_len = sizeof(client_addr);
                    int cfd = accept4(w->listen_fd, (struct sockaddr *)&client_addr, &client_len, SOCK_NONBLOCK | SOCK_CLOEXEC);
                    if (cfd < 0) break;

                    if (cfd < MAX_CONNS) {
                        conns[cfd].fd = cfd;
                        conns[cfd].rx_buf = (char *)malloc(8192);
                        conns[cfd].rx_cap = 8192;
                        conns[cfd].rx_len = 0;
                        conns[cfd].tx_buf = NULL;
                        conns[cfd].keep_alive = true;

                        struct io_uring_sqe *rsqe = io_uring_get_sqe(&ring);
                        io_uring_prep_recv(rsqe, cfd, conns[cfd].rx_buf, conns[cfd].rx_cap - 1, 0);
                        io_uring_sqe_set_data64(rsqe, ((uint64_t)EV_RECV << 32) | (uint32_t)cfd);
                    } else {
                        close(cfd);
                    }
                }
                struct io_uring_sqe *asqe = io_uring_get_sqe(&ring);
                io_uring_prep_poll_add(asqe, w->listen_fd, POLLIN);
                io_uring_sqe_set_data64(asqe, ((uint64_t)EV_ACCEPT << 32));
            }


            else if (ev_type == EV_RECV) {
                int cfd = fd;
                if (cfd < 0 || cfd >= MAX_CONNS || conns[cfd].fd != cfd) continue;
                client_slot_t *conn = &conns[cfd];
                if (res <= 0) {
                    close(cfd);
                    if (conn->rx_buf) { free(conn->rx_buf); conn->rx_buf = NULL; }
                    if (conn->tx_buf) { free(conn->tx_buf); conn->tx_buf = NULL; }
                    conn->fd = -1;
                } else {
                    conn->rx_len += res;
                    conn->rx_buf[conn->rx_len] = '\0';

                    char *hdr_end = strstr(conn->rx_buf, "\r\n\r\n");
                    if (hdr_end) {
                        int body_start = (int)(hdr_end - conn->rx_buf) + 4;
                        int content_length = 0;
                        char *cl = strcasestr(conn->rx_buf, "Content-Length:");
                        if (cl && (cl - conn->rx_buf) < body_start) {
                            cl += 15;
                            while (*cl == ' ' || *cl == '\t' || *cl == ':') cl++;
                            content_length = atoi(cl);
                        }
                        int total_req_len = body_start + content_length;
                        if (conn->rx_len >= total_req_len) {
                            parse_and_dispatch(db, conn, conn->rx_buf, total_req_len, body_start, content_length);

                            int remaining = conn->rx_len - total_req_len;
                            if (remaining > 0) {
                                memmove(conn->rx_buf, conn->rx_buf + total_req_len, remaining);
                            }
                            conn->rx_len = remaining;
                            conn->rx_buf[conn->rx_len] = '\0';

                            struct io_uring_sqe *ssqe = io_uring_get_sqe(&ring);
                            io_uring_prep_send(ssqe, cfd, conn->tx_buf, conn->tx_len, MSG_NOSIGNAL);
                            io_uring_sqe_set_data64(ssqe, ((uint64_t)EV_SEND << 32) | (uint32_t)cfd);
                        } else {
                            if (conn->rx_len + 4096 >= conn->rx_cap) {
                                conn->rx_cap *= 2;
                                conn->rx_buf = (char *)realloc(conn->rx_buf, conn->rx_cap);
                            }
                            struct io_uring_sqe *rsqe = io_uring_get_sqe(&ring);
                            io_uring_prep_recv(rsqe, cfd, conn->rx_buf + conn->rx_len, conn->rx_cap - 1 - conn->rx_len, 0);
                            io_uring_sqe_set_data64(rsqe, ((uint64_t)EV_RECV << 32) | (uint32_t)cfd);
                        }
                    } else {
                        if (conn->rx_len + 4096 >= conn->rx_cap) {
                            conn->rx_cap *= 2;
                            conn->rx_buf = (char *)realloc(conn->rx_buf, conn->rx_cap);
                        }
                        struct io_uring_sqe *rsqe = io_uring_get_sqe(&ring);
                        io_uring_prep_recv(rsqe, cfd, conn->rx_buf + conn->rx_len, conn->rx_cap - 1 - conn->rx_len, 0);
                        io_uring_sqe_set_data64(rsqe, ((uint64_t)EV_RECV << 32) | (uint32_t)cfd);
                    }
                }
            }
            else if (ev_type == EV_SEND) {
                int cfd = fd;
                if (cfd < 0 || cfd >= MAX_CONNS || conns[cfd].fd != cfd) continue;
                client_slot_t *conn = &conns[cfd];
                if (res <= 0) {
                    close(cfd);
                    if (conn->rx_buf) { free(conn->rx_buf); conn->rx_buf = NULL; }
                    if (conn->tx_buf) { free(conn->tx_buf); conn->tx_buf = NULL; }
                    conn->fd = -1;
                } else {
                    conn->tx_sent += res;
                    if (conn->tx_sent < conn->tx_len) {
                        struct io_uring_sqe *ssqe = io_uring_get_sqe(&ring);
                        io_uring_prep_send(ssqe, cfd, conn->tx_buf + conn->tx_sent, conn->tx_len - conn->tx_sent, MSG_NOSIGNAL);
                        io_uring_sqe_set_data64(ssqe, ((uint64_t)EV_SEND << 32) | (uint32_t)cfd);
                    } else {
                        if (conn->keep_alive) {
                            bool next_sent = false;
                            while (conn->rx_len > 0) {
                                char *hdr_end = strstr(conn->rx_buf, "\r\n\r\n");
                                if (!hdr_end) break;
                                int body_start = (int)(hdr_end - conn->rx_buf) + 4;
                                int content_length = 0;
                                char *cl = strcasestr(conn->rx_buf, "Content-Length:");
                                if (cl && (cl - conn->rx_buf) < body_start) {
                                    cl += 15;
                                    while (*cl == ' ' || *cl == '\t' || *cl == ':') cl++;
                                    content_length = atoi(cl);
                                }
                                int total_req_len = body_start + content_length;
                                if (conn->rx_len < total_req_len) break;

                                parse_and_dispatch(db, conn, conn->rx_buf, total_req_len, body_start, content_length);
                                int remaining = conn->rx_len - total_req_len;
                                if (remaining > 0) {
                                    memmove(conn->rx_buf, conn->rx_buf + total_req_len, remaining);
                                }
                                conn->rx_len = remaining;
                                conn->rx_buf[conn->rx_len] = '\0';

                                struct io_uring_sqe *ssqe = io_uring_get_sqe(&ring);
                                io_uring_prep_send(ssqe, cfd, conn->tx_buf, conn->tx_len, MSG_NOSIGNAL);
                                io_uring_sqe_set_data64(ssqe, ((uint64_t)EV_SEND << 32) | (uint32_t)cfd);
                                next_sent = true;
                                break;
                            }
                            if (!next_sent) {
                                if (conn->rx_len + 4096 >= conn->rx_cap) {
                                    conn->rx_cap *= 2;
                                    conn->rx_buf = (char *)realloc(conn->rx_buf, conn->rx_cap);
                                }
                                struct io_uring_sqe *rsqe = io_uring_get_sqe(&ring);
                                io_uring_prep_recv(rsqe, cfd, conn->rx_buf + conn->rx_len, conn->rx_cap - 1 - conn->rx_len, 0);
                                io_uring_sqe_set_data64(rsqe, ((uint64_t)EV_RECV << 32) | (uint32_t)cfd);
                            }
                        } else {
                            close(cfd);
                            if (conn->rx_buf) { free(conn->rx_buf); conn->rx_buf = NULL; }
                            if (conn->tx_buf) { free(conn->tx_buf); conn->tx_buf = NULL; }
                            conn->fd = -1;
                        }
                    }
                }
            }
            else if (ev_type == EV_BCRYPT_DONE) {
                bcrypt_task_t *task = bcrypt_pool_pop_completed(w->thread_id);
                while (task) {
                    bcrypt_task_t *next = task->next;
                    int cfd = task->client_fd;
                    if (cfd >= 0 && cfd < MAX_CONNS && conns[cfd].fd == cfd) {
                        client_slot_t *conn = &conns[cfd];
                        char raw_resp[TOTAL_RESP_BUF];
                        char *body_buf = raw_resp + HEADER_RESERVE;
                        http_res_t res;
                        res_init(&res, body_buf, RESP_BODY_SIZE);

                        if (task->op == BCRYPT_OP_VERIFY) {
                            if (!task->success) {
                                res_error(&res, 401, "invalid email or password");
                            } else {
                                char token[512];
                                jwt_issue(task->user_id, token);
                                format_user_json(&res, 200,
                                                 task->email, (int)strlen(task->email),
                                                 token,
                                                 task->username, (int)strlen(task->username),
                                                 task->has_bio ? task->bio : NULL, task->has_bio ? (int)strlen(task->bio) : 0,
                                                 task->has_image ? task->image : NULL, task->has_image ? (int)strlen(task->image) : 0);
                            }
                        }

                        char hdr[HEADER_RESERVE];
                        int hlen = snprintf(hdr, sizeof(hdr),
                                            "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: %s\r\n\r\n",
                                            res.status, get_status_text(res.status), res.len,
                                            conn->keep_alive ? "keep-alive" : "close");
                        char *start_ptr = body_buf - hlen;
                        memcpy(start_ptr, hdr, hlen);
                        int total_len = hlen + res.len;
                        if (!conn->tx_buf) conn->tx_buf = (char *)malloc(TOTAL_RESP_BUF);
                        memcpy(conn->tx_buf, start_ptr, total_len);
                        conn->tx_len = total_len;
                        conn->tx_sent = 0;

                        struct io_uring_sqe *ssqe = io_uring_get_sqe(&ring);
                        io_uring_prep_send(ssqe, cfd, conn->tx_buf, conn->tx_len, MSG_NOSIGNAL);
                        io_uring_sqe_set_data64(ssqe, ((uint64_t)EV_SEND << 32) | (uint32_t)cfd);
                    }
                    free(task);
                    task = next;
                }
                // Re-arm eventfd read
                struct io_uring_sqe *esqe2 = io_uring_get_sqe(&ring);
                io_uring_prep_read(esqe2, fd, &efd_buf, sizeof(efd_buf), 0);
                io_uring_sqe_set_data64(esqe2, ((uint64_t)EV_BCRYPT_DONE << 32) | (uint32_t)fd);
            }

            count++;
        }
        io_uring_cq_advance(&ring, count);
        io_uring_submit(&ring);
    }

    db_close(db);
    io_uring_queue_exit(&ring);
    free(conns);
    return NULL;
}


int main() {
    signal(SIGPIPE, SIG_IGN);

    const char *db_url = getenv("DATABASE_URL");
    const char *secret = getenv("JWT_SECRET");
    const char *host = getenv("HOST");
    const char *port_str = getenv("PORT");

    if (!db_url || !secret) {
        fprintf(stderr, "DATABASE_URL and JWT_SECRET are required\n");
        return 1;
    }
    if (!host) host = "127.0.0.1";
    int port = port_str ? atoi(port_str) : 3000;

    auth_init(secret);
    struct rlimit rlim;
    if (getrlimit(RLIMIT_NOFILE, &rlim) == 0) {
        rlim.rlim_cur = rlim.rlim_max;
        setrlimit(RLIMIT_NOFILE, &rlim);
    }


    bcrypt_pool_init(4);

    int num_cores = (int)sysconf(_SC_NPROCESSORS_ONLN);
    if (num_cores <= 0) num_cores = 8;

    printf("Starting c-iouring-27bhd server on %s:%d with %d worker threads\n", host, port, num_cores);

    pthread_t *threads = (pthread_t *)malloc(num_cores * sizeof(pthread_t));
    worker_arg_t *args = (worker_arg_t *)malloc(num_cores * sizeof(worker_arg_t));

    for (int i = 0; i < num_cores; i++) {
        int lfd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
        int opt = 1;
        setsockopt(lfd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));
        setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
        setsockopt(lfd, IPPROTO_TCP, TCP_NODELAY, &opt, sizeof(opt));
        int defer = 1;
        setsockopt(lfd, IPPROTO_TCP, TCP_DEFER_ACCEPT, &defer, sizeof(defer));

        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_port = htons(port);
        inet_pton(AF_INET, host, &addr.sin_addr);

        if (bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
            perror("bind");
            return 1;
        }
        if (listen(lfd, 65535) < 0) {
            perror("listen");
            return 1;
        }

        args[i].thread_id = i;
        args[i].listen_fd = lfd;
        strncpy(args[i].db_url, db_url, sizeof(args[i].db_url) - 1);

        pthread_create(&threads[i], NULL, worker_thread, &args[i]);
    }

    for (int i = 0; i < num_cores; i++) {
        pthread_join(threads[i], NULL);
    }

    free(threads);
    free(args);
    return 0;
}

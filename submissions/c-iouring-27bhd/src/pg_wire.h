#ifndef PG_WIRE_H
#define PG_WIRE_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <errno.h>
#include <poll.h>


#define PG_RX_BUF_SIZE 131072
#define PG_TX_BUF_SIZE 131072

typedef struct {
    int fd;
    uint8_t rx_buf[PG_RX_BUF_SIZE];
    int rx_pos;
    int rx_len;
    uint8_t tx_buf[PG_TX_BUF_SIZE];
    int tx_len;
} pg_wire_conn_t;

typedef struct {
    int col_count;
    const char *col_vals[32];
    int col_lens[32];
} pg_row_t;

static inline void pg_wire_init_conn(pg_wire_conn_t *c, int fd) {
    c->fd = fd;
    c->rx_pos = 0;
    c->rx_len = 0;
    c->tx_len = 0;
}

static inline void pg_append_bind(pg_wire_conn_t *c, const char *portal, const char *stmt,
                                  int num_params, const char **params, const int *param_lens) {
    int portal_len = portal ? (int)strlen(portal) : 0;
    int stmt_len = stmt ? (int)strlen(stmt) : 0;

    int p = c->tx_len;
    c->tx_buf[p++] = 'B';
    int len_pos = p;
    p += 4; // reserve 4 bytes for length

    // Portal name + \0
    if (portal_len > 0) { memcpy(c->tx_buf + p, portal, portal_len); p += portal_len; }
    c->tx_buf[p++] = '\0';

    // Stmt name + \0
    if (stmt_len > 0) { memcpy(c->tx_buf + p, stmt, stmt_len); p += stmt_len; }
    c->tx_buf[p++] = '\0';

    // Parameter formats: 0 (all text)
    *(uint16_t *)(c->tx_buf + p) = htons(0); p += 2;

    // Number of parameters
    *(uint16_t *)(c->tx_buf + p) = htons((uint16_t)num_params); p += 2;

    for (int i = 0; i < num_params; i++) {
        if (!params || !params[i]) {
            // NULL parameter is represented by length -1
            *(int32_t *)(c->tx_buf + p) = (int32_t)htonl((uint32_t)-1);
            p += 4;
        } else {
            int len = param_lens ? param_lens[i] : (int)strlen(params[i]);
            *(int32_t *)(c->tx_buf + p) = (int32_t)htonl((uint32_t)len);
            p += 4;
            if (len > 0) {
                memcpy(c->tx_buf + p, params[i], len);
                p += len;
            }
        }
    }

    // Result formats: 0 (all text format)
    *(uint16_t *)(c->tx_buf + p) = htons(0); p += 2;

    // Set length
    int msg_len = p - len_pos;
    *(uint32_t *)(c->tx_buf + len_pos) = htonl((uint32_t)msg_len);

    c->tx_len = p;
}

static inline void pg_append_exec(pg_wire_conn_t *c, const char *portal, int32_t max_rows) {
    int portal_len = portal ? (int)strlen(portal) : 0;
    int p = c->tx_len;
    c->tx_buf[p++] = 'E';
    int len_pos = p;
    p += 4;

    if (portal_len > 0) { memcpy(c->tx_buf + p, portal, portal_len); p += portal_len; }
    c->tx_buf[p++] = '\0';

    *(int32_t *)(c->tx_buf + p) = (int32_t)htonl((uint32_t)max_rows); p += 4;

    int msg_len = p - len_pos;
    *(uint32_t *)(c->tx_buf + len_pos) = htonl((uint32_t)msg_len);

    c->tx_len = p;
}

static inline void pg_append_sync(pg_wire_conn_t *c) {
    int p = c->tx_len;
    c->tx_buf[p++] = 'S';
    *(uint32_t *)(c->tx_buf + p) = htonl(4); p += 4;
    c->tx_len = p;
}

static inline bool pg_flush_sync(pg_wire_conn_t *c) {
    int sent = 0;
    while (sent < c->tx_len) {
        ssize_t n = send(c->fd, c->tx_buf + sent, c->tx_len - sent, MSG_NOSIGNAL);
        if (n <= 0) return false;
        sent += (int)n;
    }
    c->tx_len = 0;
    return true;
}

static inline void pg_compact_rx(pg_wire_conn_t *c) {
    if (c->rx_pos > 0) {
        int rem = c->rx_len - c->rx_pos;
        if (rem > 0) {
            memmove(c->rx_buf, c->rx_buf + c->rx_pos, rem);
        }
        c->rx_len = rem;
        c->rx_pos = 0;
    }
}

static inline bool pg_read_frame(pg_wire_conn_t *c, char *type, uint32_t *msg_len, const uint8_t **payload) {
    int avail = c->rx_len - c->rx_pos;
    if (avail < 5) return false;
    const uint8_t *cur = c->rx_buf + c->rx_pos;
    *type = (char)cur[0];
    *msg_len = ntohl(*(uint32_t *)(cur + 1));
    uint32_t total = 1 + *msg_len;
    if ((uint32_t)avail < total) return false;
    *payload = cur + 5;
    return true;
}

static inline void pg_consume_frame(pg_wire_conn_t *c, uint32_t total_len) {
    c->rx_pos += (int)total_len;
    if (c->rx_pos >= c->rx_len) {
        c->rx_pos = 0;
        c->rx_len = 0;
    }
}

static inline void pg_parse_row(const uint8_t *payload, uint32_t len, pg_row_t *row) {
    uint16_t cols = ntohs(*(uint16_t *)payload);
    row->col_count = cols;
    int p = 2;
    for (int i = 0; i < cols && i < 32; i++) {
        int32_t col_len = (int32_t)ntohl(*(uint32_t *)(payload + p));
        p += 4;
        if (col_len < 0) {
            row->col_vals[i] = NULL;
            row->col_lens[i] = 0;
        } else {
            row->col_vals[i] = (const char *)(payload + p);
            row->col_lens[i] = col_len;
            p += col_len;
        }
    }
}

static inline void pg_extract_error_sqlstate(const uint8_t *payload, uint32_t len, char *sqlstate_out) {
    sqlstate_out[0] = '\0';
    int p = 0;
    while (p < (int)len - 4) {
        char code = (char)payload[p++];
        if (code == '\0') break;
        const char *val = (const char *)(payload + p);
        int vlen = (int)strlen(val);
        if (code == 'C') {
            strncpy(sqlstate_out, val, 5);
            sqlstate_out[5] = '\0';
            return;
        }
        p += vlen + 1;
    }
}

static inline bool pg_wire_exec_query(pg_wire_conn_t *w, const char *stmt, int n_params, const char **params,
                                       pg_row_t *rows_out, int max_rows, int *row_count_out, char *sqlstate_out) {
    if (sqlstate_out) sqlstate_out[0] = '\0';
    if (row_count_out) *row_count_out = 0;

    pg_compact_rx(w);
    pg_append_bind(w, "", stmt, n_params, params, NULL);
    pg_append_exec(w, "", 0);
    pg_append_sync(w);

    if (!pg_flush_sync(w)) return false;

    char type;
    uint32_t len;
    const uint8_t *payload;

    while (1) {
        while (!pg_read_frame(w, &type, &len, &payload)) {
            pg_compact_rx(w);
            ssize_t n = recv(w->fd, w->rx_buf + w->rx_len, sizeof(w->rx_buf) - w->rx_len, 0);
            if (n < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    struct pollfd pfd = { .fd = w->fd, .events = POLLIN };
                    poll(&pfd, 1, 1000);
                    continue;
                }
                return false;
            } else if (n == 0) {
                return false;
            }
            w->rx_len += (int)n;
        }

        if (type == 'D') {
            if (rows_out && row_count_out && *row_count_out < max_rows) {
                pg_parse_row(payload, len - 4, &rows_out[*row_count_out]);
                (*row_count_out)++;
            }
        } else if (type == 'E') {
            if (sqlstate_out) {
                pg_extract_error_sqlstate(payload, len - 4, sqlstate_out);
            }
        } else if (type == 'Z') {
            pg_consume_frame(w, 1 + len);
            break;
        }

        pg_consume_frame(w, 1 + len);
    }
    return true;
}

#endif // PG_WIRE_H

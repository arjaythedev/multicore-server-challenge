#include "worker.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <string_view>

#include "json_out.h"
#include "picohttpparser.h"

namespace {

enum Op : uint64_t { kAccept, kRecv, kSend, kPgIn, kPgOut, kIgnore };

// user_data: op in bits 0..3, slot index in bits 4..35, generation in bits 36..63
constexpr uint64_t pack(Op op, uint32_t idx, uint32_t gen = 0) {
    return uint64_t(op) | (uint64_t(idx) << 4) | (uint64_t(gen) << 36);
}
constexpr Op op_of(uint64_t u) { return Op(u & 15); }
constexpr uint32_t idx_of(uint64_t u) { return uint32_t(u >> 4); }
constexpr uint32_t gen_of(uint64_t u) { return uint32_t(u >> 36); }

constexpr size_t kMaxRequest = 1 << 20;

const char *reason(int status) {
    switch (status) {
    case 200: return "OK";
    case 201: return "Created";
    case 204: return "No Content";
    case 400: return "Bad Request";
    case 404: return "Not Found";
    case 413: return "Payload Too Large";
    default: return "Internal Server Error";
    }
}

bool ieq(const char *a, size_t n, const char *lit) {
    return n == strlen(lit) && strncasecmp(a, lit, n) == 0;
}

}  // namespace

Worker::Worker(const Config &cfg, int id) : cfg_(cfg), id_(id) {
    for (int i = 0; i < cfg_.read_conns; i++) {
        auto pg = std::make_unique<PgConn>();
        pg->connect(cfg_.database_url.c_str());
        pgs_.push_back(std::move(pg));
    }
}

Worker::~Worker() {
    for (auto &pg : pgs_) pg->close();
}

io_uring_sqe *Worker::sqe() {
    io_uring_sqe *s = io_uring_get_sqe(&ring_);
    if (!s) {
        io_uring_submit(&ring_);
        s = io_uring_get_sqe(&ring_);
    }
    return s;
}

void Worker::arm_accept() {
    io_uring_sqe *s = sqe();
    io_uring_prep_multishot_accept(s, listen_fd_, nullptr, nullptr, 0);
    io_uring_sqe_set_data64(s, pack(kAccept, 0));
}

void Worker::arm_recv(uint32_t idx) {
    Conn &c = conns_[idx];
    io_uring_sqe *s = sqe();
    io_uring_prep_recv_multishot(s, c.fd, nullptr, 0, 0);
    s->flags |= IOSQE_BUFFER_SELECT;
    s->buf_group = kBgid;
    io_uring_sqe_set_data64(s, pack(kRecv, idx, c.gen));
    c.recv_active = true;
}

void Worker::arm_pg(uint32_t pg_idx) {
    io_uring_sqe *s = sqe();
    io_uring_prep_poll_multishot(s, pgs_[pg_idx]->sock, POLLIN);
    io_uring_sqe_set_data64(s, pack(kPgIn, pg_idx));
}

void Worker::arm_pg_out(uint32_t pg_idx) {
    PgConn &pg = *pgs_[pg_idx];
    if (pg.want_out) return;
    pg.want_out = true;
    io_uring_sqe *s = sqe();
    io_uring_prep_poll_add(s, pg.sock, POLLOUT);
    io_uring_sqe_set_data64(s, pack(kPgOut, pg_idx));
}

void Worker::on_accept(int fd) {
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    uint32_t idx;
    if (!free_.empty()) {
        idx = free_.back();
        free_.pop_back();
    } else {
        idx = uint32_t(conns_.size());
        conns_.emplace_back();
    }
    Conn &c = conns_[idx];
    c.fd = fd;
    c.recv_active = c.sending = c.busy = c.closing = c.close_after = false;
    c.in.clear();
    c.out.clear();
    c.sendbuf.clear();
    arm_recv(idx);
}

void Worker::maybe_free(uint32_t idx) {
    Conn &c = conns_[idx];
    if (!c.closing || c.recv_active || c.sending) return;
    close(c.fd);
    c.fd = -1;
    c.gen++;
    c.in.clear();
    c.out.clear();
    c.sendbuf.clear();
    free_.push_back(idx);
}

// shutdown() makes the pending multishot recv complete with 0, which lets the slot go once nothing is in flight.
void Worker::kill(uint32_t idx) {
    Conn &c = conns_[idx];
    if (!c.closing) {
        c.closing = true;
        shutdown(c.fd, SHUT_RDWR);
    }
    maybe_free(idx);
}

void Worker::on_recv(uint32_t idx, uint32_t gen, io_uring_cqe *cqe) {
    Conn &c = conns_[idx];
    if (c.gen != gen) {  // stale completion for a reused slot: only give the buffer back
        if (cqe->flags & IORING_CQE_F_BUFFER) {
            unsigned bid = cqe->flags >> IORING_CQE_BUFFER_SHIFT;
            io_uring_buf_ring_add(br_, &bufs_[size_t(bid) * kBufSize], kBufSize, bid,
                                  io_uring_buf_ring_mask(kBufCount), 0);
            io_uring_buf_ring_advance(br_, 1);
        }
        return;
    }
    if (!(cqe->flags & IORING_CQE_F_MORE)) c.recv_active = false;
    if (cqe->flags & IORING_CQE_F_BUFFER) {
        unsigned bid = cqe->flags >> IORING_CQE_BUFFER_SHIFT;
        if (cqe->res > 0 && !c.closing) c.in.append(&bufs_[size_t(bid) * kBufSize], size_t(cqe->res));
        io_uring_buf_ring_add(br_, &bufs_[size_t(bid) * kBufSize], kBufSize, bid, io_uring_buf_ring_mask(kBufCount), 0);
        io_uring_buf_ring_advance(br_, 1);
    }
    if (cqe->res <= 0 && cqe->res != -ENOBUFS) {
        kill(idx);
        return;
    }
    if (!c.recv_active && !c.closing) arm_recv(idx);
    if (cqe->res > 0 && !c.closing) process(idx);
    maybe_free(idx);
}

void Worker::start_send(uint32_t idx) {
    Conn &c = conns_[idx];
    if (c.sending || c.out.empty()) return;
    c.sendbuf.swap(c.out);
    c.sending = true;
    io_uring_sqe *s = sqe();
    io_uring_prep_send(s, c.fd, c.sendbuf.data(), c.sendbuf.size(), MSG_NOSIGNAL);
    io_uring_sqe_set_data64(s, pack(kSend, idx, c.gen));
}

void Worker::on_send(uint32_t idx, uint32_t gen, int res) {
    Conn &c = conns_[idx];
    if (c.gen != gen) return;
    c.sending = false;
    if (res <= 0) {
        kill(idx);
        return;
    }
    c.sendbuf.erase(0, size_t(res));
    if (!c.sendbuf.empty()) {  // partial send: keep the rest ahead of anything newer
        c.out.insert(0, c.sendbuf);
        c.sendbuf.clear();
    }
    if (!c.out.empty()) {
        start_send(idx);
    } else if (c.close_after) {
        kill(idx);
    }
}

void Worker::respond(Conn &c, uint32_t idx, int status, const std::string &body) {
    char head[160];
    int n = snprintf(head, sizeof head, "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n%s\r\n",
                     status, reason(status), body.size(), c.close_after ? "Connection: close\r\n" : "");
    c.out.append(head, size_t(n));
    c.out += body;
    start_send(idx);
}

// Parses and routes as many buffered requests as it can, strictly in order: while one waits on Postgres the rest stay
// buffered.
void Worker::process(uint32_t idx) {
    for (;;) {
        Conn &c = conns_[idx];
        if (c.busy || c.closing || c.in.empty()) return;
        const char *method, *path;
        size_t mlen, plen;
        int minor;
        phr_header hdrs[64];
        size_t nh = 64;
        int pr = phr_parse_request(c.in.data(), c.in.size(), &method, &mlen, &path, &plen, &minor, hdrs, &nh, 0);
        if (pr == -2) {
            if (c.in.size() > kMaxRequest) {
                c.close_after = true;
                respond(c, idx, 413, R"({"errors":{"body":["request too large"]}})");
            }
            return;
        }
        if (pr < 0) {
            c.close_after = true;
            c.in.clear();
            respond(c, idx, 400, R"({"errors":{"body":["bad request"]}})");
            return;
        }
        size_t content_len = 0;
        bool close_hdr = minor == 0;
        for (size_t i = 0; i < nh; i++) {
            if (ieq(hdrs[i].name, hdrs[i].name_len, "content-length")) {
                content_len = strtoull(std::string(hdrs[i].value, hdrs[i].value_len).c_str(), nullptr, 10);
            } else if (ieq(hdrs[i].name, hdrs[i].name_len, "connection")) {
                close_hdr = ieq(hdrs[i].value, hdrs[i].value_len, "close");
            }
        }
        if (content_len > kMaxRequest) {
            c.close_after = true;
            c.in.clear();
            respond(c, idx, 413, R"({"errors":{"body":["request too large"]}})");
            return;
        }
        if (c.in.size() < size_t(pr) + content_len) return;  // body still arriving
        if (close_hdr) c.close_after = true;

        // route before erasing: method and path point into c.in
        bool is_tags = std::string_view(method, mlen) == "GET" && std::string_view(path, plen) == "/api/tags";
        c.in.erase(0, size_t(pr) + content_len);
        if (is_tags) {
            c.busy = true;
            waitq_.push_back({idx, c.gen});
            dispatch();
        } else {
            respond(c, idx, 404, R"({"errors":{"body":["not found"]}})");
        }
    }
}

void Worker::dispatch() {
    while (!waitq_.empty()) {
        uint32_t pi = 0;
        for (; pi < pgs_.size(); pi++)
            if (pgs_[pi]->inflight.empty()) break;
        if (pi == pgs_.size()) return;
        Waiting w = waitq_.front();
        waitq_.pop_front();
        if (conns_[w.idx].gen != w.gen) continue;  // client went away while queued
        PgConn &pg = *pgs_[pi];
        if (!pg.send_prepared(pack(kIgnore, w.idx, w.gen), "tags", 0, nullptr, nullptr, nullptr)) {
            Conn &c = conns_[w.idx];
            c.busy = false;
            respond(c, w.idx, 500, R"({"errors":{"body":["database error"]}})");
            continue;
        }
        if (pg.flush()) arm_pg_out(pi);
    }
}

void Worker::finish_tags(uint32_t idx, uint32_t gen, PGresult *res) {
    Conn &c = conns_[idx];
    if (c.gen != gen) return;
    c.busy = false;
    if (!res || PQresultStatus(res) != PGRES_TUPLES_OK) {
        respond(c, idx, 500, R"({"errors":{"body":["database error"]}})");
    } else {
        std::string body = R"({"tags":[)";
        int n = PQntuples(res);
        for (int i = 0; i < n; i++) {
            if (i) body.push_back(',');
            json::str(body, PQgetvalue(res, i, 0), size_t(PQgetlength(res, i, 0)));
        }
        body += "]}";
        respond(c, idx, 200, body);
    }
    process(idx);
}

void Worker::on_pg(uint32_t pg_idx) {
    pgs_[pg_idx]->drain([&](uint64_t tag, PGresult *res) {
        finish_tags(idx_of(tag), gen_of(tag), res);
        if (res) PQclear(res);
    });
    dispatch();
}

void Worker::run() {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(uint16_t(cfg_.port));
    if (inet_pton(AF_INET, cfg_.host.c_str(), &addr.sin_addr) != 1) {
        fprintf(stderr, "bad HOST %s\n", cfg_.host.c_str());
        exit(1);
    }
    if (bind(fd, reinterpret_cast<sockaddr *>(&addr), sizeof addr) != 0 || listen(fd, 65535) != 0) {
        perror("bind/listen");
        exit(1);
    }
    listen_fd_ = fd;

    // The ring is created here so that this thread is its single issuer.
    io_uring_params params{};
    params.flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN;
    int rc = io_uring_queue_init_params(4096, &ring_, &params);
    if (rc < 0) {
        fprintf(stderr, "io_uring_queue_init_params: %s\n", strerror(-rc));
        exit(1);
    }
    int err = 0;
    br_ = io_uring_setup_buf_ring(&ring_, kBufCount, kBgid, 0, &err);
    if (!br_) {
        fprintf(stderr, "io_uring_setup_buf_ring: %s\n", strerror(-err));
        exit(1);
    }
    bufs_.resize(size_t(kBufCount) * kBufSize);
    for (unsigned i = 0; i < kBufCount; i++)
        io_uring_buf_ring_add(br_, &bufs_[size_t(i) * kBufSize], kBufSize, uint16_t(i), io_uring_buf_ring_mask(kBufCount), int(i));
    io_uring_buf_ring_advance(br_, int(kBufCount));

    arm_accept();
    for (uint32_t i = 0; i < pgs_.size(); i++) arm_pg(i);

    io_uring_cqe *cqes[256];
    for (;;) {
        int w = io_uring_submit_and_wait(&ring_, 1);
        if (w < 0 && w != -EINTR && w != -EBUSY) {
            fprintf(stderr, "worker %d: io_uring_submit_and_wait: %s\n", id_, strerror(-w));
            exit(1);
        }
        unsigned n = io_uring_peek_batch_cqe(&ring_, cqes, 256);
        for (unsigned i = 0; i < n; i++) {
            io_uring_cqe *cqe = cqes[i];
            uint64_t u = cqe->user_data;
            switch (op_of(u)) {
            case kAccept:
                if (cqe->res >= 0) on_accept(cqe->res);
                if (!(cqe->flags & IORING_CQE_F_MORE)) arm_accept();
                break;
            case kRecv: on_recv(idx_of(u), gen_of(u), cqe); break;
            case kSend: on_send(idx_of(u), gen_of(u), cqe->res); break;
            case kPgIn: {
                on_pg(idx_of(u));
                if (!(cqe->flags & IORING_CQE_F_MORE)) arm_pg(idx_of(u));
                break;
            }
            case kPgOut: {
                PgConn &pg = *pgs_[idx_of(u)];
                pg.want_out = false;
                if (pg.flush()) arm_pg_out(idx_of(u));
                break;
            }
            case kIgnore: break;
            }
        }
        io_uring_cq_advance(&ring_, n);
    }
}

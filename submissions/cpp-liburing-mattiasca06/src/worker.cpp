#include "worker.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <string_view>

#include "picohttpparser.h"
#include "prof.h"

namespace {

enum Op : uint64_t { kAccept, kRecv, kSend, kPgIn, kPgOut, kEfd };

// user_data: op in bits 0..3, slot index in bits 4..35, generation in bits 36..63
constexpr uint64_t pack(Op op, uint32_t idx, uint32_t gen = 0) {
    return uint64_t(op) | (uint64_t(idx) << 4) | (uint64_t(gen) << 36);
}
constexpr Op op_of(uint64_t u) { return Op(u & 15); }
constexpr uint32_t idx_of(uint64_t u) { return uint32_t((u >> 4) & 0xffffffffu); }
constexpr uint32_t gen_of(uint64_t u) { return uint32_t(u >> 36); }

constexpr size_t kMaxRequest = 1 << 20;

const char *reason(int status) {
    switch (status) {
    case 200: return "OK";
    case 201: return "Created";
    case 204: return "No Content";
    case 400: return "Bad Request";
    case 401: return "Unauthorized";
    case 403: return "Forbidden";
    case 404: return "Not Found";
    case 413: return "Payload Too Large";
    case 422: return "Unprocessable Entity";
    default: return "Internal Server Error";
    }
}

bool ieq(const char *a, size_t n, const char *lit) { return n == strlen(lit) && strncasecmp(a, lit, n) == 0; }

}  // namespace

void DbAwait::await_suspend(std::coroutine_handle<> c) {
    h = c;
    w.enqueue(this);
}

Worker::Worker(const Config &cfg, int id) : cfg_(cfg), id_(id) {
    for (int i = 0; i < cfg_.read_conns; i++) {
        auto pg = std::make_unique<PgConn>();
        pg->connect(cfg_.database_url.c_str());
        pgs_.push_back(std::move(pg));
    }
    {  // the dedicated write connection is always the last one
        auto pg = std::make_unique<PgConn>();
        pg->connect(cfg_.database_url.c_str());
        pgs_.push_back(std::move(pg));
    }
    efd_ = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    if (efd_ < 0) throw std::runtime_error("eventfd");
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

// One-shot (level-checked at arm time) rather than multishot: a multishot poll can miss data that was already
// readable, which left requests waiting forever. Armed whenever a segment is in flight.
void Worker::arm_pg(uint32_t pg_idx) {
    PgConn &pg = *pgs_[pg_idx];
    if (pg.in_armed) return;
    pg.in_armed = true;
    io_uring_sqe *s = sqe();
    io_uring_prep_poll_add(s, pg.sock, POLLIN);
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

void Worker::arm_efd() {
    io_uring_sqe *s = sqe();
    io_uring_prep_poll_multishot(s, efd_, POLLIN);
    io_uring_sqe_set_data64(s, pack(kEfd, 0));
}

void Worker::on_accept(int fd) {
    PROF_SCOPE(kAccept);
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
    PROF_SCOPE(kRecv);
    Conn &c = conns_[idx];
    unsigned bid = cqe->flags >> IORING_CQE_BUFFER_SHIFT;
    bool has_buf = cqe->flags & IORING_CQE_F_BUFFER;
    auto give_back = [&] {
        io_uring_buf_ring_add(br_, &bufs_[size_t(bid) * kBufSize], kBufSize, uint16_t(bid),
                              io_uring_buf_ring_mask(kBufCount), 0);
        io_uring_buf_ring_advance(br_, 1);
    };
    if (c.gen != gen) {  // stale completion for a reused slot: only give the buffer back
        if (has_buf) give_back();
        return;
    }
    if (!(cqe->flags & IORING_CQE_F_MORE)) c.recv_active = false;
    if (has_buf) {
        if (cqe->res > 0 && !c.closing) c.in.append(&bufs_[size_t(bid) * kBufSize], size_t(cqe->res));
        give_back();
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
    PROF_SCOPE(kSendDone);
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
    } else {
        maybe_free(idx);
    }
}

void Worker::respond(Conn &c, uint32_t idx, int status, const std::string &body) {
    PROF_SCOPE(kRespond);
    char head[192];
    int n;
    if (status == 204) {
        n = snprintf(head, sizeof head, "HTTP/1.1 204 No Content\r\n%s\r\n", c.close_after ? "Connection: close\r\n" : "");
    } else {
        n = snprintf(head, sizeof head,
                     "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n%s\r\n", status,
                     reason(status), body.size(), c.close_after ? "Connection: close\r\n" : "");
    }
    c.out.append(head, size_t(n));
    if (status != 204) c.out += body;
    start_send(idx);
}

// Handlers may complete synchronously (inside process_one) or later from the event loop. `in_process_` keeps a
// completion that happens inside process_one from starting a nested parse; those connections are revisited afterwards.
void Worker::process(uint32_t idx) {
    if (in_process_) {
        deferred_.push_back(idx);
        return;
    }
    in_process_ = true;
    process_one(idx);
    while (!deferred_.empty()) {
        uint32_t d = deferred_.back();
        deferred_.pop_back();
        process_one(d);
    }
    in_process_ = false;
}

// Parses and starts as many buffered requests as it can, strictly in order: while one is running the rest stay
// buffered.
void Worker::process_one(uint32_t idx) {
    PROF_SCOPE(kHttp);
    for (;;) {
        Conn &c = conns_[idx];
        if (c.fd < 0 || c.busy || c.closing || c.in.empty()) return;
        const char *method, *path;
        size_t mlen, plen;
        int minor;
        phr_header hdrs[64];
        size_t nh = 64;
        int pr = phr_parse_request(c.in.data(), c.in.size(), &method, &mlen, &path, &plen, &minor, hdrs, &nh, 0);
        if (pr == -2) {
            if (c.in.size() > kMaxRequest) {
                c.close_after = true;
                c.in.clear();
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
        Request rq;
        size_t content_len = 0;
        bool close_hdr = minor == 0;
        for (size_t i = 0; i < nh; i++) {
            const phr_header &h = hdrs[i];
            if (ieq(h.name, h.name_len, "content-length")) {
                content_len = strtoull(std::string(h.value, h.value_len).c_str(), nullptr, 10);
            } else if (ieq(h.name, h.name_len, "connection")) {
                close_hdr = ieq(h.value, h.value_len, "close");
            } else if (ieq(h.name, h.name_len, "authorization")) {
                rq.has_auth = true;
                rq.auth.assign(h.value, h.value_len);
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

        rq.method.assign(method, mlen);
        std::string_view target(path, plen);
        size_t q = target.find('?');
        rq.path.assign(target.substr(0, q));
        if (q != std::string_view::npos) rq.query.assign(target.substr(q + 1));
        rq.body.assign(c.in, size_t(pr), content_len);
        c.in.erase(0, size_t(pr) + content_len);
        c.busy = true;
        {
            PROF_SCOPE(kHandler);
            serve(idx, c.gen, std::move(rq));
        }
    }
}

Detached Worker::serve(uint32_t idx, uint32_t gen, Request rq) {
    Reply r;
    try {
        r = co_await route(rq);
    } catch (const std::exception &) {
        r = {500, R"({"errors":{"body":["internal error"]}})"};
    }
    finish(idx, gen, std::move(r));
}

void Worker::finish(uint32_t idx, uint32_t gen, Reply r) {
    PROF_REQUEST_DONE();
    Conn &c = conns_[idx];
    if (c.gen != gen) return;  // client went away while the request ran
    c.busy = false;
    respond(c, idx, r.status, r.body);
    process(idx);
}

void Worker::enqueue(DbAwait *a) {
    if (a->write) {
        writeq_.push_back(a);
        dispatch_writes();
    } else {
        waitq_.push_back(a);
        dispatch();
    }
}

// Natural group commit: while a write segment is in flight, writes queue; the queue then goes out as one segment
// with a single Sync (one implicit transaction). Solo requests always travel alone.
void Worker::dispatch_writes() {
    PROF_SCOPE(kPgSend);
    const uint32_t wi = uint32_t(cfg_.read_conns);
    PgConn &pg = *pgs_[wi];
    if (writeq_.empty()) return;
    if (pg.dead) {
        std::deque<DbAwait *> q;
        q.swap(writeq_);
        for (DbAwait *a : q) a->rows.ok = false;
        for (DbAwait *a : q) a->h.resume();
        return;
    }
    if (!pg.inflight.empty()) return;
    auto *g = new Group;
    g->members.push_back(writeq_.front());
    writeq_.pop_front();
    if (!g->members[0]->solo)
        while (!writeq_.empty() && !writeq_.front()->solo && g->members.size() < kMaxGroup) {
            g->members.push_back(writeq_.front());
            writeq_.pop_front();
        }
    std::vector<Query> all;
    for (DbAwait *a : g->members) all.insert(all.end(), a->qs.begin(), a->qs.end());
    if (!pg.send_segment(g, all)) {
        std::vector<DbAwait *> ms = std::move(g->members);
        delete g;
        for (DbAwait *a : ms) a->rows.ok = false;
        for (DbAwait *a : ms) a->h.resume();
        return;
    }
    {
        PROF_SCOPE(kPgFlush);
        if (pg.flush()) arm_pg_out(wi);
    }
}

// Hands queued segments to idle Postgres connections (one segment in flight per connection).
void Worker::dispatch() {
    PROF_SCOPE(kPgSend);
    std::vector<DbAwait *> failed;
    while (!waitq_.empty()) {
        PgConn *pg = nullptr;
        uint32_t pi = 0;
        bool any_alive = false;
        for (uint32_t i = 0; i < uint32_t(cfg_.read_conns); i++) {
            if (pgs_[i]->dead) continue;
            any_alive = true;
            if (pgs_[i]->inflight.empty()) {
                pg = pgs_[i].get();
                pi = i;
                break;
            }
        }
        if (!any_alive) {
            for (DbAwait *a : waitq_) {
                a->rows.ok = false;
                failed.push_back(a);
            }
            waitq_.clear();
            break;
        }
        if (!pg) break;
        // Natural batching: everything that queued while the connections were busy goes out as one segment
        // (one Sync, one implicit read-only transaction).
        auto *g = new Group;
        g->members.push_back(waitq_.front());
        waitq_.pop_front();
        if (!g->members[0]->solo)
            while (!waitq_.empty() && !waitq_.front()->solo && g->members.size() < kMaxReadGroup) {
                g->members.push_back(waitq_.front());
                waitq_.pop_front();
            }
        std::vector<Query> all;
        for (DbAwait *m : g->members) all.insert(all.end(), m->qs.begin(), m->qs.end());
        if (!pg->send_segment(g, all)) {
            for (DbAwait *m : g->members) {
                m->rows.ok = false;
                failed.push_back(m);
            }
            delete g;
            continue;
        }
        {
            PROF_SCOPE(kPgFlush);
            if (pg->flush()) arm_pg_out(pi);
        }
    }
    for (DbAwait *a : failed) a->h.resume();
}

void Worker::on_pg(uint32_t pg_idx) {
    std::vector<PgConn::Seg> done;
    {
        PROF_SCOPE(kPgRecv);
        pgs_[pg_idx]->drain(done);
    }
    PROF_SCOPE(kPgDone);
    std::vector<std::coroutine_handle<>> ready;
    const bool is_write = pg_idx == uint32_t(cfg_.read_conns);
    for (PgConn::Seg &s : done) {
        std::unique_ptr<Group> g(static_cast<Group *>(s.tag));
        size_t total = 0;
        for (DbAwait *a : g->members) total += a->qs.size();
        bool clean = !s.failed && s.res.size() == total;
        for (PGresult *r : s.res) {
            ExecStatusType st = PQresultStatus(r);
            if (st != PGRES_TUPLES_OK && st != PGRES_COMMAND_OK) clean = false;
        }
        if (s.failed) {  // connection lost: the commit may or may not have happened, so never retry
            for (PGresult *r : s.res) PQclear(r);
            for (DbAwait *a : g->members) {
                a->rows.ok = false;
                ready.push_back(a->h);
            }
        } else if (!clean && g->members.size() > 1) {  // the group failed (writes: rolled back): replay each alone
            for (PGresult *r : s.res) PQclear(r);
            std::deque<DbAwait *> &q = is_write ? writeq_ : waitq_;
            for (auto it = g->members.rbegin(); it != g->members.rend(); ++it) {
                (*it)->solo = true;
                q.push_front(*it);
            }
        } else {
            size_t pos = 0;
            for (DbAwait *a : g->members) {
                size_t n = a->qs.size();
                if (pos + n <= s.res.size())
                    a->rows.r.assign(s.res.begin() + long(pos), s.res.begin() + long(pos + n));
                a->rows.ok = true;
                pos += n;
                ready.push_back(a->h);
            }
        }
    }
    for (auto h : ready) {
        PROF_SCOPE(kHandler);
        h.resume();
    }
    if (is_write) dispatch_writes();
    dispatch();
}

void Worker::post_done(BcryptAwait *j) {
    {
        std::lock_guard lk(done_mu_);
        done_.push_back(j);
    }
    uint64_t one = 1;
    if (write(efd_, &one, sizeof one) < 0) {}
}

void Worker::on_efd() {
    PROF_SCOPE(kEfd);
    uint64_t v;
    if (read(efd_, &v, sizeof v) < 0) {}
    std::vector<BcryptAwait *> js;
    {
        std::lock_guard lk(done_mu_);
        js.swap(done_);
    }
    std::vector<std::coroutine_handle<>> hs;
    for (BcryptAwait *j : js) hs.push_back(j->h);
    for (auto h : hs) {
        PROF_SCOPE(kHandler);
        h.resume();
    }
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
        io_uring_buf_ring_add(br_, &bufs_[size_t(i) * kBufSize], kBufSize, uint16_t(i),
                              io_uring_buf_ring_mask(kBufCount), int(i));
    io_uring_buf_ring_advance(br_, int(kBufCount));

    arm_accept();
    arm_efd();
#ifdef PROF
    prof::attach();
    prof::enter(prof::kLoop);
#endif

    io_uring_cqe *cqes[256];
    for (;;) {
        int w;
        {
            PROF_SCOPE(kWait);
            w = io_uring_submit_and_wait(&ring_, 1);
        }
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
            case kPgIn:
                pgs_[idx_of(u)]->in_armed = false;
                on_pg(idx_of(u));
                break;
            case kPgOut: {
                PgConn &pg = *pgs_[idx_of(u)];
                pg.want_out = false;
                PROF_SCOPE(kPgFlush);
                if (pg.flush()) arm_pg_out(idx_of(u));
                break;
            }
            case kEfd:
                on_efd();
                if (!(cqe->flags & IORING_CQE_F_MORE)) arm_efd();
                break;
            }
        }
        io_uring_cq_advance(&ring_, n);
        // libpq may have read results into its own buffer while sending; no socket event follows for those.
        for (uint32_t i = 0; i < pgs_.size(); i++) {
            PgConn &pg = *pgs_[i];
            if (pg.dead || pg.inflight.empty()) continue;
            if (!PQisBusy(pg.c)) on_pg(i);
            if (!pg.inflight.empty()) arm_pg(i);
        }
    }
}

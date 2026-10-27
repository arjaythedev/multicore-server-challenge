#include "worker.h"
#include "bufpool.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <string_view>

#include "picohttpparser.h"
#include "codec.h"
#include "diag.h"
#include "prof.h"

namespace {

enum Op : uint64_t { kAccept, kRecv, kSend, kPgIn, kPgOut, kEfd, kTimer };

// user_data: op in bits 0..3, slot index in bits 4..35, generation in bits 36..63
constexpr uint64_t pack(Op op, uint32_t idx, uint32_t gen = 0) {
    return uint64_t(op) | (uint64_t(idx) << 4) | (uint64_t(gen) << 36);
}
constexpr Op op_of(uint64_t u) { return Op(u & 15); }
constexpr uint32_t idx_of(uint64_t u) { return uint32_t((u >> 4) & 0xffffffffu); }
constexpr uint32_t gen_of(uint64_t u) { return uint32_t(u >> 36); }

constexpr size_t kMaxRequest = 1 << 20;

// Reads that can travel as one batched statement: the single statement, its batched twin, and the parameter kinds
// (b = number, t = text) so that the arrays can be written as Postgres array literals.
struct BatchSpec {
    const char *single, *batch, *kinds;
};
constexpr BatchSpec kBatch[] = {
    {"article_by_slug", "article_by_slug_b", "bt"},
    {"comments_by_slug", "comments_by_slug_b", "bt"},
    {"list_all", "list_all_b", "bbb"},
    {"list_tag", "list_tag_b", "bbbt"},
    {"feed", "feed_b", "bbb"},
    {"list_author", "list_author_b", "bbbt"},
    {"list_fav", "list_fav_b", "bbbt"},
    {"count_tag", "count_tag_b", "t"},
    {"count_author", "count_author_b", "t"},
    {"count_fav", "count_fav_b", "t"},
    {"profile", "profile_b", "bt"},
};
inline int batch_of(const char *stmt) {
    for (size_t i = 0; i < sizeof kBatch / sizeof kBatch[0]; i++)
        if (strcmp(kBatch[i].single, stmt) == 0) return int(i);
    return -1;
}


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
    if (cfg_.read_total > 0)
        cfg_.read_conns = std::max(1, cfg_.read_total / cfg_.workers + (id < cfg_.read_total % cfg_.workers ? 1 : 0));
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
    if (!s) [[unlikely]] {
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
    DIAG_ASSERT(!pg.dead, "arm_pg on dead connection", pg_idx);
    if (pg.in.size() - pg.in_len < 4096) pg.in.resize(pg.in.size() * 2);
    DIAG_EV("arm_pg", pg_idx, pg.in_len, pg.in.size());
    pg.in_armed = true;
    io_uring_sqe *s = sqe();
    io_uring_prep_recv(s, pg.sock, pg.in.data() + pg.in_len, pg.in.size() - pg.in_len, 0);
    io_uring_sqe_set_data64(s, pack(kPgIn, pg_idx));
}

// Queues the unsent part of the connection's output as an io_uring send (no syscall of its own: it goes out with the
// next submit, together with the recv armed for the answer).
void Worker::arm_pg_out(uint32_t pg_idx) {
    PgConn &pg = *pgs_[pg_idx];
    if (pg.sending || pg.out_off >= pg.out_len) return;
    DIAG_EV("arm_pg_out", pg_idx, pg.out_off, pg.out_len);
    pg.sending = true;
    io_uring_sqe *s = sqe();
    io_uring_prep_send(s, pg.sock, pg.out.data() + pg.out_off, pg.out_len - pg.out_off, MSG_NOSIGNAL);
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
    if (c.gen != gen) [[unlikely]] {  // stale completion for a reused slot: only give the buffer back
        if (has_buf) give_back();
        return;
    }
    if (!(cqe->flags & IORING_CQE_F_MORE)) c.recv_active = false;
    if (has_buf) {
        if (cqe->res > 0 && !c.closing) take_buf(c.in), c.in.append(&bufs_[size_t(bid) * kBufSize], size_t(cqe->res));
        give_back();
    }
    if (cqe->res <= 0 && cqe->res != -ENOBUFS) [[unlikely]] {
        kill(idx);
        return;
    }
    if (!c.recv_active && !c.closing) arm_recv(idx);
    if (cqe->res > 0 && !c.closing) process(idx);
    release_big(conns_[idx].in);
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
    if (c.gen != gen) [[unlikely]] return;
    c.sending = false;
    if (res <= 0) [[unlikely]] {
        kill(idx);
        return;
    }
    c.sendbuf.erase(0, size_t(res));
    if (!c.sendbuf.empty()) [[unlikely]] {  // partial send: keep the rest ahead of anything newer
        c.out.insert(0, c.sendbuf);
        c.sendbuf.clear();
    }
    // An idle keep-alive connection must not hold on to its largest response: with ~100k connections the retained
    // capacity of sendbuf/out (swapped back and forth) added up to over a gigabyte.
    release_big(c.sendbuf);
    if (c.out.empty()) release_big(c.out);
    if (!c.out.empty()) {
        start_send(idx);
    } else if (c.close_after) {
        kill(idx);
    } else {
        maybe_free(idx);
    }
}

// Response head by hand: no format-string parsing on the hot path. Same bytes the snprintf version produced.
static inline char *put(char *p, std::string_view s) {
    memcpy(p, s.data(), s.size());
    return p + s.size();
}
static inline char *put_uint(char *p, size_t v) {
    char t[20];
    int n = 0;
    do {
        t[n++] = char('0' + v % 10);
        v /= 10;
    } while (v);
    while (n) *p++ = t[--n];
    return p;
}

void Worker::respond(Conn &c, uint32_t idx, int status, const std::string &body) {
    PROF_SCOPE(kRespond);
    char head[192];
    char *p = head;
    if (status == 204) [[unlikely]] {
        p = put(p, "HTTP/1.1 204 No Content\r\n");
    } else {
        p = put(p, "HTTP/1.1 ");
        p = put_uint(p, size_t(status));
        *p++ = ' ';
        p = put(p, reason(status));
        p = put(p, "\r\nContent-Type: application/json\r\nContent-Length: ");
        p = put_uint(p, body.size());
        p = put(p, "\r\n");
    }
    if (c.close_after) p = put(p, "Connection: close\r\n");
    p = put(p, "\r\n");
    const size_t n = size_t(p - head);
    take_buf(c.out);
    c.out.reserve(c.out.size() + n + body.size());
    c.out.append(head, n);
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
        if (pr == -2) [[unlikely]] {
            if (c.in.size() > kMaxRequest) {
                c.close_after = true;
                c.in.clear();
                respond(c, idx, 413, R"({"errors":{"body":["request too large"]}})");
            }
            return;
        }
        if (pr < 0) [[unlikely]] {
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
                take_buf(rq.auth);
                rq.auth.assign(h.value, h.value_len);
            }
        }
        if (content_len > kMaxRequest) [[unlikely]] {
            c.close_after = true;
            c.in.clear();
            respond(c, idx, 413, R"({"errors":{"body":["request too large"]}})");
            return;
        }
        if (c.in.size() < size_t(pr) + content_len) [[unlikely]] return;  // body still arriving
        if (close_hdr) c.close_after = true;

        rq.method.assign(method, mlen);
        std::string_view target(path, plen);
        size_t q = target.find('?');
        take_buf(rq.path);
        rq.path.assign(target.substr(0, q));
        if (q != std::string_view::npos) rq.query.assign(target.substr(q + 1));
        if (content_len) take_buf(rq.body);
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
    recycle(rq.auth);
    recycle(rq.path);
    recycle(rq.body);
    finish(idx, gen, std::move(r));
}

void Worker::finish(uint32_t idx, uint32_t gen, Reply r) {
    PROF_REQUEST_DONE();
    Conn &c = conns_[idx];
    if (c.gen != gen) [[unlikely]] return;  // client went away while the request ran
    c.busy = false;
    respond(c, idx, r.status, r.body);
    recycle(r.body);
    process(idx);
}

void Worker::enqueue(DbAwait *a) {
    if (a->write) {
        writeq_.push_back(a);
        dispatch_writes();
    } else {
        waitq_.push_back(a);
        // Hold the read briefly so concurrent requests share one segment (and identical statements merge).
        if (cfg_.read_batch_us <= 0 || a->solo || waitq_.size() >= size_t(cfg_.read_group_max)) {
            dispatch();
        } else if (!timer_armed_) {
            io_uring_sqe *s = sqe();
            io_uring_prep_timeout(s, &batch_ts_, 0, 0);
            io_uring_sqe_set_data64(s, pack(kTimer, 0));
            timer_armed_ = true;
        }
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
    Group *g = new_group();
    g->members.push_back(writeq_.front());
    writeq_.pop_front();
    if (!g->members[0]->solo)
        while (!writeq_.empty() && !writeq_.front()->solo && g->members.size() < kMaxGroup) {
            g->members.push_back(writeq_.front());
            writeq_.pop_front();
        }
    std::vector<Query> &all = all_;
    all.clear();
    for (DbAwait *a : g->members) all.insert(all.end(), a->qs.begin(), a->qs.end());
    if (!pg.send_segment(g, all)) {
        std::vector<DbAwait *> ms = std::move(g->members);
        g->members.clear();
        free_group(g);
        for (DbAwait *a : ms) a->rows.ok = false;
        for (DbAwait *a : ms) a->h.resume();
        return;
    }
    {
        PROF_SCOPE(kPgFlush);
        arm_pg_out(wi);
    }
}

// Read segments shrink in two ways before they are sent:
//  - requests of one kind that wait together (e.g. several article pages) go out as ONE batched statement whose
//    parameters are arrays (see sql.h); the answer comes back in one result that is split by request position;
//  - other requests that ask the very same question (same statement, same parameters, e.g. the capped count every list
//    page needs) are answered by one statement.
// Everything runs in one snapshot, and every request still gets its data from Postgres while it is being served.
void Worker::build_read(Group &g, std::vector<Query> &all) {
    constexpr size_t kN = sizeof kBatch / sizeof kBatch[0];
    struct Open {
        uint32_t at = 0;
        std::vector<const Query *> qs;
    };
    uint32_t count[kN] = {};
    for (DbAwait *m : g.members)
        for (const Query &q : m->qs)
            if (int b = batch_of(q.stmt); b >= 0) count[b]++;
    Open open[kN];
    bool is_open[kN] = {};
    for (DbAwait *m : g.members) {
        for (const Query &q : m->qs) {
            int b = batch_of(q.stmt);
            if (b >= 0 && count[b] >= 2) {
                Open &o = open[b];
                if (!is_open[b]) {
                    is_open[b] = true;
                    o.at = uint32_t(all.size());
                    all.push_back(Query(kBatch[b].batch, {}));
                }
                uint32_t k = uint32_t(o.qs.size());
                for (uint32_t i = 0; i < o.qs.size() && k == o.qs.size(); i++) {  // the same request twice: one row range
                    bool same = true;
                    for (size_t p = 0; p < q.params.size() && same; p++) same = o.qs[i]->params[p].v == q.params[p].v;
                    if (same) k = i;
                }
                if (k == o.qs.size()) o.qs.push_back(&q);
                g.map.push_back({o.at, int32_t(k)});
                continue;
            }
            uint32_t at = uint32_t(all.size());
            for (uint32_t i = 0; i < all.size(); i++) {
                if (all[i].stmt != q.stmt || all[i].params.size() != q.params.size()) continue;
                bool same = true;
                for (size_t p = 0; p < q.params.size() && same; p++) same = all[i].params[p].v == q.params[p].v;
                if (same) {
                    at = i;
                    break;
                }
            }
            if (at == all.size()) all.push_back(q);
            g.map.push_back({at, -1});
        }
    }
    for (size_t b = 0; b < kN; b++) {
        if (!is_open[b]) continue;
        Open &o = open[b];
        for (size_t p = 0; kBatch[b].kinds[p]; p++) {
            const bool is_text = kBatch[b].kinds[p] == 't';
            std::string lit = "{";
            for (size_t i = 0; i < o.qs.size(); i++) {
                if (i) lit += ',';
                const std::string &v = *o.qs[i]->params[p].v;
                if (!is_text) {
                    lit += v;
                    continue;
                }
                lit += '"';
                for (char ch : v) {
                    if (ch == '"' || ch == '\\') lit += '\\';
                    lit += ch;
                }
                lit += '"';
            }
            lit += '}';
            all[o.at].params.push_back(Param(lit));
        }
        g.batches.push_back({o.at, uint32_t(o.qs.size())});
    }
    g.sent = all.size();
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
        Group *g = new_group();
        g->members.push_back(waitq_.front());
        waitq_.pop_front();
        if (!g->members[0]->solo)
            while (!waitq_.empty() && !waitq_.front()->solo && g->members.size() < size_t(cfg_.read_group_max)) {
                g->members.push_back(waitq_.front());
                waitq_.pop_front();
            }
        std::vector<Query> &all = all_;
        all.clear();
        build_read(*g, all);
        PROF_READ_GROUP(g->members.size(), all.size());
        if (!pg->send_segment(g, all)) {
            for (DbAwait *m : g->members) {
                m->rows.ok = false;
                failed.push_back(m);
            }
            free_group(g);
            continue;
        }
        {
            PROF_SCOPE(kPgFlush);
            arm_pg_out(pi);
        }
    }
    for (DbAwait *a : failed) a->h.resume();
}

void Worker::on_pg(uint32_t pg_idx, long res) {
    std::vector<PgConn::Seg> &done = seg_done_;
    done.clear();
    {
        PROF_SCOPE(kPgRecv);
        pgs_[pg_idx]->on_data(res, done);
    }
    PROF_SCOPE(kPgDone);
    std::vector<std::coroutine_handle<>> &ready = ready_;
    ready.clear();
    const bool is_write = pg_idx == uint32_t(cfg_.read_conns);
    for (PgConn::Seg &s : done) {
        Group *g = static_cast<Group *>(s.tag);
        struct Free { Worker *w; Group *g; ~Free() { w->free_group(g); } } free_g{this, g};
        size_t total = 0;
        for (DbAwait *a : g->members) total += a->qs.size();
        if (g->sent) total = g->sent;
        bool clean = !s.failed && s.res.size() == total;
        for (PgResult *r : s.res)
            if (r->status != PgStatus::Ok) clean = false;
        if (s.failed) {  // connection lost: the commit may or may not have happened, so never retry
            for (PgResult *r : s.res) pgres_free(r);
            for (DbAwait *a : g->members) {
                a->rows.ok = false;
                ready.push_back(a->h);
            }
        } else if (!clean && g->members.size() > 1) {  // the group failed (writes: rolled back): replay each alone
            for (PgResult *r : s.res) pgres_free(r);
            std::deque<DbAwait *> &q = is_write ? writeq_ : waitq_;
            for (auto it = g->members.rbegin(); it != g->members.rend(); ++it) {
                (*it)->solo = true;
                q.push_front(*it);
            }
        } else if (g->sent) {  // read segment: members may share a result
            auto set = std::make_shared<ResultSet>(std::move(s.res));
            const bool whole = set->r.size() == g->sent;
            // A batched result holds every request's rows, ordered by position; find where each request's rows start.
            if (starts_.size() < g->batches.size()) starts_.resize(g->batches.size());
            std::vector<std::vector<int>> &starts = starts_;
            bool split_ok = whole;
            for (size_t b = 0; b < g->batches.size() && split_ok; b++) {
                PgResult *pr = set->r[g->batches[b].first];
                std::vector<int> &st = starts[b];
                st.assign(g->batches[b].second + 1, 0);
                int prev = 0;
                for (int i = 0, rows = pr->nrows; i < rows && split_ok; i++) {
                    int ord = codec::be32(pr->value(i, 0)) - 1;
                    if (ord < prev || ord >= int(g->batches[b].second)) split_ok = false;
                    else st[size_t(ord) + 1]++, prev = ord;
                }
                for (size_t k = 1; k < st.size(); k++) st[k] += st[k - 1];
            }
            size_t pos = 0;
            for (DbAwait *a : g->members) {
                size_t n = a->qs.size();
                if (split_ok)
                    for (size_t i = 0; i < n; i++) {
                        const Group::Slot &sl = g->map[pos + i];
                        PgResult *pr = set->r[sl.res];
                        if (sl.ord < 0) {
                            a->rows.r.push_back(Res(pr));
                            continue;
                        }
                        size_t b = 0;
                        while (g->batches[b].first != sl.res) b++;
                        int lo = starts[b][size_t(sl.ord)];
                        a->rows.r.push_back(Res(pr, lo, starts[b][size_t(sl.ord) + 1] - lo, 1));
                    }
                a->rows.shared = set;
                a->rows.ok = true;
                pos += n;
                ready.push_back(a->h);
            }
        } else {
            size_t pos = 0;
            for (DbAwait *a : g->members) {
                size_t n = a->qs.size();
                if (pos + n <= s.res.size())
                    for (size_t i = pos; i < pos + n; i++) a->rows.r.push_back(Res(s.res[i]));
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
    if (cfg_.read_batch_us > 0 && !waitq_.empty()) {
        // keep gathering: what queued while the connections were busy goes out together at the next tick
        if (!timer_armed_) {
            io_uring_sqe *s = sqe();
            io_uring_prep_timeout(s, &batch_ts_, 0, 0);
            io_uring_sqe_set_data64(s, pack(kTimer, 0));
            timer_armed_ = true;
        }
    } else {
        dispatch();
    }
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

// Registers the provided-buffer ring. Ubuntu 24.04 kernels 6.8.0-1xx carry a backport whose reserved-field check is
// inverted (`if (!memchr_inv(reg.resv, 0, ...)) return -EINVAL`), so every registration with zeroed reserved fields
// fails with EINVAL, liburing's included. On EINVAL, register again by hand with a non-zero reserved byte, which that
// kernel accepts. A correct kernel never reaches the retry: it accepts the first call.
static io_uring_buf_ring *setup_buf_ring(io_uring *ring, unsigned entries, int bgid, int *err) {
    if (io_uring_buf_ring *br = io_uring_setup_buf_ring(ring, entries, bgid, 0, err)) return br;
    if (*err != -EINVAL) return nullptr;
    const size_t sz = size_t(entries) * sizeof(io_uring_buf);
    void *m = mmap(nullptr, sz, PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
    if (m == MAP_FAILED) {
        *err = -errno;
        return nullptr;
    }
    io_uring_buf_reg reg{};
    reg.ring_addr = reinterpret_cast<uintptr_t>(m);
    reg.ring_entries = entries;
    reg.bgid = uint16_t(bgid);
    reg.resv[0] = 1;
    int rc = io_uring_register_buf_ring(ring, &reg, 0);
    if (rc < 0) {
        munmap(m, sz);
        *err = rc;
        return nullptr;
    }
    auto *br = static_cast<io_uring_buf_ring *>(m);
    io_uring_buf_ring_init(br);
    *err = 0;
    return br;
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
    params.flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN | IORING_SETUP_COOP_TASKRUN;
    int rc = io_uring_queue_init_params(4096, &ring_, &params);
    if (rc < 0) {
        fprintf(stderr, "io_uring_queue_init_params: %s\n", strerror(-rc));
        exit(1);
    }
    int err = 0;
    br_ = setup_buf_ring(&ring_, kBufCount, kBgid, &err);
    if (!br_) {
        fprintf(stderr, "io_uring_setup_buf_ring: %s\n", strerror(-err));
        exit(1);
    }
    bufs_.resize(size_t(kBufCount) * kBufSize);
    for (unsigned i = 0; i < kBufCount; i++)
        io_uring_buf_ring_add(br_, &bufs_[size_t(i) * kBufSize], kBufSize, uint16_t(i),
                              io_uring_buf_ring_mask(kBufCount), int(i));
    io_uring_buf_ring_advance(br_, int(kBufCount));

    batch_ts_.tv_sec = cfg_.read_batch_us / 1000000;
    batch_ts_.tv_nsec = (cfg_.read_batch_us % 1000000) * 1000L;
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
        if (w < 0 && w != -EINTR && w != -EBUSY) [[unlikely]] {
            fprintf(stderr, "worker %d: io_uring_submit_and_wait: %s\n", id_, strerror(-w));
            exit(1);
        }
        unsigned n = io_uring_peek_batch_cqe(&ring_, cqes, 256);
        // With ~100k connections a connection's state is almost never in cache when its completion arrives. The whole
        // batch is known up front, so start loading all of those lines now and the misses overlap instead of queueing.
        for (unsigned i = 0; i < n; i++) {
            uint64_t u = cqes[i]->user_data;
            if (op_of(u) == kRecv || op_of(u) == kSend) {
                size_t k = idx_of(u);
                if (k < conns_.size()) {
                    __builtin_prefetch(&conns_[k]);
                    __builtin_prefetch(reinterpret_cast<const char *>(&conns_[k]) + 64);
                }
            }
        }
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
                DIAG_EV("cqe_pg_in", idx_of(u), cqe->res, pgs_[idx_of(u)]->inflight.empty() ? 0 : 1);
                DIAG_ASSERT(pgs_[idx_of(u)]->in_armed, "recv CQE without an armed recv", idx_of(u), cqe->res);
                if (cqe->res < 0 && cqe->res != -EINTR && cqe->res != -EAGAIN)
                    DIAG_WARN(50, "PG recv CQE error", idx_of(u), cqe->res);
                pgs_[idx_of(u)]->in_armed = false;
                on_pg(idx_of(u), cqe->res);
                break;
            case kPgOut: {
                PgConn &pg = *pgs_[idx_of(u)];
                DIAG_EV("cqe_pg_out", idx_of(u), cqe->res, pg.out_len);
                DIAG_ASSERT(pg.sending, "send CQE without a send in flight", idx_of(u), cqe->res);
                if (cqe->res <= 0) DIAG_WARN(50, "PG send CQE not positive", idx_of(u), cqe->res);
                pg.sending = false;
                if (cqe->res > 0) {
                    pg.out_off += size_t(cqe->res);
                    if (pg.out_off >= pg.out_len) pg.out_len = pg.out_off = 0;
                    else arm_pg_out(idx_of(u));
                } else if (cqe->res != -EINTR && cqe->res != -EAGAIN) {
                    pg.dead = true;
                } else {
                    arm_pg_out(idx_of(u));
                }
                break;
            }
            case kTimer:
                timer_armed_ = false;
                dispatch();
                break;
            case kEfd:
                on_efd();
                if (!(cqe->flags & IORING_CQE_F_MORE)) arm_efd();
                break;
            }
        }
        io_uring_cq_advance(&ring_, n);
        for (uint32_t i = 0; i < pgs_.size(); i++) {
            PgConn &pg = *pgs_[i];
            if (pg.inflight.empty()) continue;
            if (pg.dead) {
                DIAG_EV("dead_on_pg", i, pg.in_armed, pg.sending);
                on_pg(i, 0);  // a failed send: on_data() fails the segments in flight
            } else arm_pg(i);
        }
    }
}

Worker::Group *Worker::new_group() {
    if (group_pool_.empty()) return new Group;
    Group *g = group_pool_.back();
    group_pool_.pop_back();
    return g;
}

void Worker::free_group(Group *g) {
    g->members.clear();
    g->map.clear();
    g->batches.clear();
    g->sent = 0;
    if (group_pool_.size() < 64) group_pool_.push_back(g);
    else delete g;
}

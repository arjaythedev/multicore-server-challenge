// One event loop: its own io_uring, SO_REUSEPORT listener, connection slab and Postgres connections.
// Each request runs as a coroutine that awaits Postgres segments and bcrypt jobs.
#pragma once
#include <liburing.h>

#include <coroutine>
#include <cstdint>
#include <cstdlib>
#include <new>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "bcrypt.h"
#include "coro.h"
#include "pg.h"

// Allocator for page-aligned storage.
template <class T> struct Aligned4k {
    using value_type = T;
    Aligned4k() = default;
    template <class U> Aligned4k(const Aligned4k<U> &) {}
    T *allocate(size_t n) {
        void *p = std::aligned_alloc(4096, (n * sizeof(T) + 4095) / 4096 * 4096);
        if (!p) throw std::bad_alloc();
        return static_cast<T *>(p);
    }
    void deallocate(T *p, size_t) { std::free(p); }
    template <class U> bool operator==(const Aligned4k<U> &) const { return true; }
};

struct Config {
    std::string host, database_url, jwt_secret;
    int port = 3000, workers = 4, read_conns = 2, bcrypt_threads = 2;
    int read_total = 0;       // if > 0: this many read connections in all, spread over the workers (overrides read_conns)
    int read_batch_us = 20000;  // reads wait this long for company before going out (0 = send at once)
    int read_group_max = 512;  // most requests one read segment carries; a full queue goes out without waiting for the timer
};

struct Request {
    std::string method, path, query, body, auth;
    bool has_auth = false;
};

struct Reply {
    int status = 200;
    std::string body;
};

struct Worker;

// co_await'ed from a request coroutine: one pipeline segment on any free Postgres connection.
struct DbAwait {
    DbAwait(Worker &w, QVec qs) : w(w), qs(std::move(qs)) {}
    bool await_ready() const noexcept { return false; }
    void await_suspend(std::coroutine_handle<> c);
    Rows await_resume() { return std::move(rows); }

    Worker &w;
    QVec qs;
    bool write = false;  // goes to the dedicated write connection
    bool solo = false;   // never shares a segment with other requests
    Rows rows;
    std::coroutine_handle<> h;
};

struct alignas(64) Worker {
    Worker(const Config &cfg, int id);
    ~Worker();
    void run();

    // used by awaitables
    void enqueue(DbAwait *a);
    void post_done(BcryptAwait *j);  // called from bcrypt threads

  private:
    struct alignas(64) Conn {  // two cache lines per connection, never straddling a third
        int fd = -1;
        uint32_t gen = 0;
        bool recv_active = false, sending = false, busy = false, closing = false, close_after = false;
        std::string in, out, sendbuf;
    };

    // event loop and HTTP
    io_uring_sqe *sqe();
    void arm_accept();
    void arm_recv(uint32_t idx);
    void arm_pg(uint32_t pg_idx);
    void arm_pg_out(uint32_t pg_idx);
    void arm_efd();
    void on_accept(int fd);
    void on_recv(uint32_t idx, uint32_t gen, io_uring_cqe *cqe);
    void on_send(uint32_t idx, uint32_t gen, int res);
    void on_pg(uint32_t pg_idx, long res);
    void on_efd();
    void process(uint32_t idx);
    void process_one(uint32_t idx);
    void respond(Conn &c, uint32_t idx, int status, const std::string &body);
    void start_send(uint32_t idx);
    void kill(uint32_t idx);
    void maybe_free(uint32_t idx);
    void dispatch();
    void dispatch_writes();
    struct Group;
    void build_read(Group &g, std::vector<Query> &all);
    Detached serve(uint32_t idx, uint32_t gen, Request rq);
    void finish(uint32_t idx, uint32_t gen, Reply r);

    // request handlers (handlers.cpp)
    Task<Reply> route(const Request &rq);
    Task<Reply> h_register(const Request &rq);
    Task<Reply> h_login(const Request &rq);
    Task<Reply> h_get_user(const Request &rq, int64_t viewer);
    Task<Reply> h_put_user(const Request &rq, int64_t viewer);
    Task<Reply> h_profile(const Request &rq, std::string name, int64_t viewer);
    Task<Reply> h_follow(const Request &rq, std::string name, int64_t viewer, bool follow);
    Task<Reply> h_list(const Request &rq, int64_t viewer, bool feed);
    Task<Reply> h_article(std::string slug, int64_t viewer);
    Task<Reply> h_create_article(const Request &rq, int64_t viewer);
    Task<Reply> h_update_article(const Request &rq, std::string slug, int64_t viewer);
    Task<Reply> h_delete_article(std::string slug, int64_t viewer);
    Task<Reply> h_favorite(std::string slug, int64_t viewer, bool add);
    Task<Reply> h_comments(std::string slug, int64_t viewer);
    Task<Reply> h_add_comment(const Request &rq, std::string slug, int64_t viewer);
    Task<Reply> h_delete_comment(std::string slug, std::string id, int64_t viewer);
    Task<Reply> h_tags();

    DbAwait db(QVec qs) { return DbAwait(*this, std::move(qs)); }
    // Writes commit before the awaiting request resumes. Group-able ones share one Sync with their neighbours.
    DbAwait db_write(QVec qs, bool solo = false) {
        DbAwait a(*this, std::move(qs));
        a.write = true;
        a.solo = solo;
        return a;
    }
    BcryptAwait bcrypt_hash(std::string pw) { return BcryptAwait(*this, true, std::move(pw)); }
    BcryptAwait bcrypt_verify(std::string pw, std::string stored) {
        return BcryptAwait(*this, false, std::move(pw), std::move(stored));
    }

    Config cfg_;
    int id_;
    int listen_fd_ = -1, efd_ = -1;
    io_uring ring_{};
    io_uring_buf_ring *br_ = nullptr;
    std::vector<char, Aligned4k<char>> bufs_;  // page-aligned: every 4 KiB receive buffer starts on a cache line
    std::vector<Conn> conns_;
    std::vector<uint32_t> free_;
    std::vector<std::unique_ptr<PgConn>> pgs_;
    std::deque<DbAwait *> waitq_, writeq_;
    struct Group {
        std::vector<DbAwait *> members;
        struct Slot {
            uint32_t res;  // index of the sent statement that answers this member query
            int32_t ord;   // batched statement: the request's 0-based position in its arrays; -1: the whole result
        };
        std::vector<Slot> map;  // reads: one per member query, in member order
        std::vector<std::pair<uint32_t, uint32_t>> batches;  // reads: (sent statement index, requests in it)
        size_t sent = 0;        // reads: statements actually sent (after merging and batching)
    };
    static constexpr size_t kMaxGroup = 48;  // stays well below 64 in-flight xids per transaction
    std::vector<Group *> group_pool_;  // spare Groups with their vectors' capacity
    std::vector<Query> all_;           // scratch: statements of the segment being built
    std::vector<PgConn::Seg> seg_done_;  // scratch for on_pg
    std::vector<std::coroutine_handle<>> ready_;
    std::vector<std::vector<int>> starts_;
    Group *new_group();
    void free_group(Group *g);
    bool timer_armed_ = false;
    __kernel_timespec batch_ts_{};
    bool in_process_ = false;
    std::vector<uint32_t> deferred_;
    // Written by the bcrypt threads, so on a cache line of their own (mutex 40 B + vector 24 B = exactly one line).
    alignas(64) std::mutex done_mu_;
    std::vector<BcryptAwait *> done_;
    static constexpr unsigned kBufCount = 4096, kBufSize = 4096, kBgid = 1;
};

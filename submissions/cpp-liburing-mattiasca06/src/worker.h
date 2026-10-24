// One event loop: its own io_uring, SO_REUSEPORT listener, connection slab and Postgres connections.
#pragma once
#include <liburing.h>

#include <cstdint>
#include <deque>
#include <memory>
#include <string>
#include <vector>

#include "pg.h"

struct Config {
    std::string host, database_url, jwt_secret;
    int port = 3000, workers = 4, read_conns = 3;
};

struct alignas(64) Worker {
    Worker(const Config &cfg, int id);
    ~Worker();
    void run();

  private:
    struct Conn {
        int fd = -1;
        uint32_t gen = 0;
        bool recv_active = false, sending = false, busy = false, closing = false, close_after = false;
        std::string in, out, sendbuf;
    };
    struct Waiting {
        uint32_t idx, gen;
    };

    io_uring_sqe *sqe();
    void arm_accept();
    void arm_recv(uint32_t idx);
    void arm_pg(uint32_t pg_idx);
    void arm_pg_out(uint32_t pg_idx);
    void on_accept(int fd);
    void on_recv(uint32_t idx, uint32_t gen, io_uring_cqe *cqe);
    void on_send(uint32_t idx, uint32_t gen, int res);
    void on_pg(uint32_t pg_idx);
    void process(uint32_t idx);
    void respond(Conn &c, uint32_t idx, int status, const std::string &body);
    void start_send(uint32_t idx);
    void kill(uint32_t idx);
    void maybe_free(uint32_t idx);
    void dispatch();
    void finish_tags(uint32_t idx, uint32_t gen, PGresult *res);

    Config cfg_;
    int id_;
    int listen_fd_ = -1;
    io_uring ring_{};
    io_uring_buf_ring *br_ = nullptr;
    std::vector<char> bufs_;
    std::vector<Conn> conns_;
    std::vector<uint32_t> free_;
    std::vector<std::unique_ptr<PgConn>> pgs_;
    std::deque<Waiting> waitq_;
    static constexpr unsigned kBufCount = 4096, kBufSize = 4096, kBgid = 1;
};

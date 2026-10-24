#include <pthread.h>
#include <signal.h>
#include <sys/resource.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "worker.h"

static const char *env(const char *k, const char *def) {
    const char *v = getenv(k);
    return v && *v ? v : def;
}

int main() {
    signal(SIGPIPE, SIG_IGN);
    rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0) {
        rl.rlim_cur = rl.rlim_max;
        setrlimit(RLIMIT_NOFILE, &rl);
    }

    Config cfg;
    cfg.host = env("HOST", "0.0.0.0");
    cfg.port = atoi(env("PORT", "3000"));
    cfg.database_url = env("DATABASE_URL", "postgres://conduit:conduit@127.0.0.1:5432/conduit");
    cfg.jwt_secret = env("JWT_SECRET", "multicore-server-challenge");
    cfg.workers = atoi(env("WORKERS", "4"));
    cfg.read_conns = atoi(env("DB_CONNS", "3"));

    // Postgres allows 100 connections in total; the rules cap us at 95.
    constexpr int kWriteConnsPerWorker = 1, kMaxConns = 95;
    if (cfg.workers < 1 || cfg.read_conns < 1 || cfg.workers * (cfg.read_conns + kWriteConnsPerWorker) > kMaxConns) {
        fprintf(stderr, "WORKERS x (DB_CONNS + %d) must be in 1..%d\n", kWriteConnsPerWorker, kMaxConns);
        return 1;
    }

    std::vector<std::unique_ptr<Worker>> workers;
    std::vector<std::thread> threads;
    try {
        for (int i = 0; i < cfg.workers; i++) workers.push_back(std::make_unique<Worker>(cfg, i));
    } catch (const std::exception &e) {
        fprintf(stderr, "startup failed: %s\n", e.what());
        return 1;
    }
    fprintf(stderr, "listening on %s:%d with %d workers\n", cfg.host.c_str(), cfg.port, cfg.workers);
    for (auto &w : workers) threads.emplace_back([&w] { w->run(); });
    for (auto &t : threads) t.join();
    return 0;
}

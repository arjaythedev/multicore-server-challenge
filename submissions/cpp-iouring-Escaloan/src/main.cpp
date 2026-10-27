// Startup: environment, limits, signals, JWT key setup, bcrypt pool, Postgres reconnect thread, event loops.
// Configuration comes only from DATABASE_URL, JWT_SECRET, HOST and PORT; tunables live in config.hpp.
#include <sched.h>
#include <signal.h>
#include <sys/resource.h>
#include <unistd.h>

#include <condition_variable>
#include <cstdlib>
#include <deque>
#include <thread>

#include "auth.hpp"
#include "loop.hpp"
#include "util.hpp"

std::vector<Loop*> g_loops;
pg::ConnInfo g_conninfo;

namespace {

std::string env_or(const char* name, const char* def) {
  const char* v = std::getenv(name);
  return v && *v ? std::string(v) : std::string(def ? def : "");
}

int usable_cpus() {
  cpu_set_t set;
  if (sched_getaffinity(0, sizeof set, &set) == 0) return CPU_COUNT(&set);
  long n = sysconf(_SC_NPROCESSORS_ONLN);
  return n > 0 ? int(n) : 0;
}

// ---- reconnect thread: blocking connects off the event loops ----
std::mutex g_rc_mu;
std::condition_variable g_rc_cv;
std::deque<std::pair<int, int>> g_rc_queue;

void reconnect_thread() {
  for (;;) {
    std::pair<int, int> job;
    {
      std::unique_lock<std::mutex> lk(g_rc_mu);
      g_rc_cv.wait(lk, [] { return !g_rc_queue.empty(); });
      job = g_rc_queue.front();
      g_rc_queue.pop_front();
    }
    int backoff = cfg::kPgReconnectMinMs;
    for (;;) {
      std::string err;
      int fd = pg::connect_blocking(g_conninfo, err);
      if (fd >= 0) {
        InboxMsg m{};
        m.kind = InboxMsg::PgReady;
        m.pg_index = job.second;
        m.pg_fd = fd;
        post_to_loop(job.first, m);
        break;
      }
      util::log("reconnect loop %d conn %d failed: %s (retry in %d ms)", job.first, job.second, err.c_str(), backoff);
      std::this_thread::sleep_for(std::chrono::milliseconds(backoff));
      backoff = std::min(backoff * 2, cfg::kPgReconnectMaxMs);
    }
  }
}

// Opens one Postgres connection at startup, retrying while the server comes up (bounded so start fails loudly).
int connect_startup() {
  int backoff = cfg::kPgReconnectMinMs;
  std::int64_t deadline = util::now_mono_ms() + 50000;
  for (;;) {
    std::string err;
    int fd = pg::connect_blocking(g_conninfo, err);
    if (fd >= 0) return fd;
    if (util::now_mono_ms() > deadline) util::die("cannot connect to postgres: %s", err.c_str());
    util::log("postgres not ready: %s (retry in %d ms)", err.c_str(), backoff);
    std::this_thread::sleep_for(std::chrono::milliseconds(backoff));
    backoff = std::min(backoff * 2, cfg::kPgReconnectMaxMs);
  }
}

}  // namespace

void request_reconnect(int loop_id, int pg_index) {
  {
    std::lock_guard<std::mutex> g(g_rc_mu);
    g_rc_queue.emplace_back(loop_id, pg_index);
  }
  g_rc_cv.notify_one();
}

int main() {
  signal(SIGPIPE, SIG_IGN);
  rlimit rl;
  if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur < rl.rlim_max) {
    rl.rlim_cur = rl.rlim_max;
    setrlimit(RLIMIT_NOFILE, &rl);
  }
  getrlimit(RLIMIT_NOFILE, &rl);

  std::string db_url = env_or("DATABASE_URL", nullptr);
  std::string secret = env_or("JWT_SECRET", nullptr);
  std::string host = env_or("HOST", "0.0.0.0");
  int port = std::atoi(env_or("PORT", "3000").c_str());
  if (db_url.empty() || secret.empty()) util::die("DATABASE_URL and JWT_SECRET must be set");
  if (!pg::parse_url(db_url, g_conninfo)) util::die("cannot parse DATABASE_URL");
  if (port <= 0 || port > 65535) util::die("bad PORT");
  auth::init(secret);

  int cpus = usable_cpus();
  int n_loops = cpus > 0 ? cpus / cfg::kCpusPerEventLoop : cfg::kEventLoopsFallback;
  if (n_loops < 1) n_loops = 1;
  if (n_loops > cfg::kMaxEventLoops) n_loops = cfg::kMaxEventLoops;
  int pg_total = n_loops * (cfg::kReadConnsPerLoop + cfg::kWriteConnsPerLoop);
  if (pg_total > 95) util::die("config uses %d postgres connections (limit 95)", pg_total);
  util::log("starting: %d cpus, %d event loops, %d postgres connections, nofile=%llu, listen %s:%d", cpus, n_loops,
            pg_total, (unsigned long long)rl.rlim_cur, host.c_str(), port);

  bcrypt_pool_start();
  std::thread(reconnect_thread).detach();

  for (int i = 0; i < n_loops; ++i) g_loops.push_back(new Loop());
  std::vector<std::thread> threads;
  std::atomic<int> ready{0};
  for (int i = 0; i < n_loops; ++i) {
    threads.emplace_back([i, &host, port, &ready] {
      Loop& L = *g_loops[std::size_t(i)];
      // Postgres first: the listener opens only once this loop can serve requests.
      std::vector<std::pair<int, bool>> fds;
      for (int k = 0; k < cfg::kReadConnsPerLoop; ++k) fds.emplace_back(connect_startup(), false);
      for (int k = 0; k < cfg::kWriteConnsPerLoop; ++k) fds.emplace_back(connect_startup(), true);
      loop_init(L, i, host.c_str(), port);
      for (auto& [fd, w] : fds) loop_add_pg(L, fd, w);
      if (++ready == int(g_loops.size())) util::log("ready");
      loop_run(L);
    });
  }
  for (auto& t : threads) t.join();
  return 0;
}

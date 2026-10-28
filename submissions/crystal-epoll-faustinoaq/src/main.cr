require "./sys"
require "./buf"
require "./json"
require "./jwt"
require "./http"
require "./net"
require "./uring"
require "./sql"
require "./pg"
require "./bcrypt"
require "./app"
require "./router"

# Up to two worker processes by default, leaving CPU time for Postgres. Each has its own
# SO_REUSEPORT listener (the kernel spreads connections over them), io_uring, Postgres
# connections and bcrypt threads; they share nothing. The parent starts and watches them.
secret = Sys.env("JWT_SECRET") || Sys.die("JWT_SECRET is required")
url = Sys.env("DATABASE_URL") || Sys.die("DATABASE_URL is required")
host = Sys.env("HOST") || "127.0.0.1"
port = (Sys.env("PORT") || "3000").to_i
workers = (Sys.env("WORKERS") || Sys.ncpu.clamp(1, 2).to_s).to_i
# Small pools keep read batches large. Respect the shared 95-connection budget by default.
per_worker = (Sys.env("PG_CONNS") || (95 // workers).clamp(1, 4).to_s).to_i
bcrypt_threads = (Sys.env("BCRYPT_THREADS") || "2").to_i
depth = (Sys.env("PG_DEPTH") || "2").to_i
window = (Sys.env("BATCH_WINDOW_US") || "50000").to_i
Jwt.init(secret)
nofile = Sys.raise_nofile
nofile = 1_u64 << 21 if nofile > (1_u64 << 21)
started = Sys.now_ns(Sys::CLOCK_MONOTONIC) // 1_000_000_000

pids = Pointer(Int32).malloc(workers)
workers.times do |i|
  pid = LibC.fork
  if pid == 0
    LibSys.prctl(1, 15_u64) # PR_SET_PDEATHSIG = SIGTERM: go when the parent goes
    Server.init(started)
    App.init(depth, window)
    Router.init
    Pg.connect_all(url, per_worker)
    Bcrypt.start(bcrypt_threads)
    lfds = Pointer(Int32).malloc(1)
    lfds[0] = Sys.listen_tcp(host, port, true)
    one = 1
    LibC.setsockopt(lfds[0], Sys::IPPROTO_TCP, Sys::TCP_NODELAY, pointerof(one).as(Void*), 4)
    Sys.die("io_uring is not available (Linux 6.1+ needed)") unless Uring.setup(lfds, 1, nofile, workers)
    STDERR.puts "worker #{i}: #{host}:#{port}, #{per_worker} Postgres connections, #{bcrypt_threads} bcrypt threads, #{Uring.describe}" if i == 0
    Uring.run
  end
  Sys.die("fork failed") if pid < 0
  pids[i] = pid
end

# A worker that dies takes the server down (the challenge doesn't restart crashed servers
# anyway): no half-capacity zombie.
status = 0
dead = LibC.waitpid(-1, pointerof(status), 0)
STDERR.puts "worker #{dead} exited (status #{status}), stopping"
workers.times { |i| LibC.kill(pids[i], 15) unless pids[i] == dead }
LibC.exit(1)

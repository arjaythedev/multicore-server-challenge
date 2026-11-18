# frozen_string_literal: true

require "async"
require "etc"
require_relative "conduit"
require_relative "http"
require_relative "bcrypt_service"
require_relative "remote_planner"

# Ruby runs one thread at a time per process, so the server is one process per core. The master loads
# the code, warms YJIT on the whole request path (the compiled code is shared with the workers through
# fork), then forks WORKERS processes. Each worker opens its own Postgres connections, io_uring rings
# and SO_REUSEPORT listeners; the kernel spreads connections over them. If a worker dies, the master
# stops the others and exits: the box doesn't restart a crashed server, and a partly dead one would
# just be slower.
HOST = ENV.fetch("HOST", "127.0.0.1")
PORT = Integer(ENV.fetch("PORT", "3000"))
DATABASE_URL = ENV.fetch("DATABASE_URL")
SECRET = ENV.fetch("JWT_SECRET")
# Workers: three quarters of the cores by default. Postgres runs on the same box, and fewer workers make
# bigger read batches (locally 6 of 8 passed 20,000 users where 8 failed).
WORKERS = Integer(ENV.fetch("WORKERS", [Etc.nprocessors * 3 / 4, 1].max.to_s))
# Per worker. Postgres used less CPU per query the fewer connections it had (1 instead of 3: -11% at
# 4,000 local users); pipelining keeps one busy.
# WORKERS x PG_CONNECTIONS must stay at 95 or below.
PG_CONNECTIONS = Integer(ENV.fetch("PG_CONNECTIONS", "2")) # one per read lane (planner.rb)
# Planner processes (remote_planner.rb): batched reads for the whole server, taking turns by window. 0 (the
# default) runs a planner inside each worker instead. Locally 2 planners cut Postgres CPU per request by a
# third (45 to 31 us) and added about as much in the workers and planners (socket framing, copies), so the
# simpler layout stays the default until a run on the 8-core box says otherwise.
PLANNERS = Integer(ENV.fetch("PLANNERS", "0"))
PLANNER_CONNECTIONS = Integer(ENV.fetch("PLANNER_CONNECTIONS", "2")) # per planner
total = (WORKERS * PG_CONNECTIONS) + (PLANNERS * PLANNER_CONNECTIONS)
abort "#{total} Postgres connections is over 95" if total > 95

# The warm-up drives requests through http.rb's parser and the app over a socket pair; it never listens.
class WarmServer < HTTPServer
  def initialize(app) = super(app, nil, nil, 1 << 20)

  private

  def listen(_host, _port) = nil

  def write(socket, data) = socket.write(data)
end

# Warm YJIT before forking: every read endpoint, a JWT verification, and the write endpoints up to
# validation (their bodies fail it after they are parsed), 30 times each. Nothing is written.
def warm_up
  Sync do |task|
    warm_up_in(task)
  ensure
    task.children&.each(&:stop) # the DB fibers; without this an error would leave Sync waiting on them
  end
end

def warm_up_in(task)
  begin
    db = DB.new(DATABASE_URL, 1, SQL::ALL, setup: SQL::SETUP)
    db.start
    app = Conduit.new(db, SECRET)
    pg = PG.connect(DATABASE_URL)
    id, username = pg.exec("SELECT id, username FROM users ORDER BY id LIMIT 1").values.first
    slug = pg.exec("SELECT slug FROM articles ORDER BY id DESC LIMIT 1").getvalue(0, 0)
    tag = pg.exec("SELECT name FROM tags ORDER BY id LIMIT 1").getvalue(0, 0)
    pg.close
    auth = "Authorization: Token #{Tokens.new(SECRET).issue(id)}\r\n"
    get = ->(target, extra = "") { "GET #{target} HTTP/1.1\r\nHost: x\r\n#{extra}\r\n" }
    send = ->(method, target, body) { "#{method} #{target} HTTP/1.1\r\nHost: x\r\n#{auth}Content-Length: #{body.bytesize}\r\n\r\n#{body}" }
    WarmServer.new(app).warm([
      get.("/api/tags"),
      get.("/api/articles?limit=10"),
      get.("/api/articles?limit=10", auth),
      get.("/api/articles?tag=#{tag}&limit=10&offset=0", auth),
      get.("/api/articles?author=#{username}&limit=10"),
      get.("/api/articles?favorited=#{username}&limit=10", auth),
      get.("/api/articles/feed?limit=10", auth),
      get.("/api/articles/#{slug}", auth),
      get.("/api/articles/#{slug}/comments", auth),
      get.("/api/profiles/#{username}", auth),
      get.("/api/user", auth),
      send.("POST", "/api/articles/#{slug}/comments", %({"comment":{"body":""}})),
      send.("POST", "/api/users/login", %({"user":{"email":"","password":"x"}})),
      send.("PUT", "/api/articles/#{slug}", %({"article":{"title":""}})),
      send.("POST", "/api/articles", %({"article":{"title":"t","description":"d","body":""}}))
    ], 30)
  ensure
    db&.close
  end
end

# The master, which only runs bcrypt, runs at MASTER_NICE (default 10), so a login never delays a request.
# Workers at nice 5 (as some C/Rust entries run theirs) were slower here: at 52,000 users on the rig p95 was
# 608 ms against 544 ms at 0, and 501 ms with only the master at 10. Raising one's own niceness needs no
# privilege.
WORKER_NICE = Integer(ENV.fetch("WORKER_NICE", "0"))
MASTER_NICE = Integer(ENV.fetch("MASTER_NICE", "10"))

def serve(index, bcrypt, planners)
  Process.setpriority(Process::PRIO_PROCESS, 0, WORKER_NICE)
  Async do |task|
    Bcrypt.client = BcryptService::Client.new(bcrypt)
    db = DB.new(DATABASE_URL, PG_CONNECTIONS, SQL::ALL, setup: SQL::SETUP)
    db.start
    unless planners.empty?
      planner = RemotePlanner::Client.new(planners, Planner::WINDOW)
      planner = RemotePlanner::Split.new(Planner.new(db), planner) unless ENV["PLANNER_LOCAL"] == "0"
    end
    app = Conduit.new(db, SECRET, planner: planner)
    # Client connections as io_uring direct descriptors, driven from C, where the kernel allows it, else
    # in epoll. CONNECTIONS=epoll forces the fallback.
    server = begin
      raise LoadError, "CONNECTIONS=epoll" if ENV["CONNECTIONS"] == "epoll"

      require_relative "cring_server"
      CringServer.new(app, HOST, PORT)
    rescue LoadError, SystemCallError => error
      warn "worker #{index}: io_uring connections unavailable (#{error.message}); using epoll" if index.zero?
      require_relative "epoll_server"
      EpollServer.new(app, HOST, PORT)
    end
    # No automatic full GCs while serving: little survives a request, and a full GC stops this worker's
    # loop for tens of milliseconds. Old objects are never freed without them, so a full GC still runs
    # if they grow past three times what the start left.
    GC.config(rgengc_allow_full_mark: false)
    old_objects_cap = GC.stat(:old_objects) * 3
    task.async do
      loop do
        sleep 10
        next if GC.stat(:old_objects) < old_objects_cap

        GC.start
        old_objects_cap = GC.stat(:old_objects) * 3
      end
    end
    server.run(task)
    if index.zero?
      compiled = RubyVM::YJIT.enabled? ? "#{RubyVM::YJIT.runtime_stats[:compiled_iseq_count]} iseqs compiled" : "YJIT off"
      warn "listening on #{HOST}:#{PORT} (#{WORKERS} workers, #{server.class}, #{PG_CONNECTIONS} Postgres connections each, " \
           "#{PLANNERS} planners with #{PLANNER_CONNECTIONS}, #{compiled})"
    end
  end
end

warm_up
GC.compact
Process.warmup

# A planner process: Planner over its own Postgres connections, serving every worker's socket.
def plan(links)
  Async do |task|
    db = DB.new(DATABASE_URL, PLANNER_CONNECTIONS, SQL::ALL, setup: SQL::SETUP)
    db.start
    RemotePlanner::Server.new(Planner.new(db), links).run(task)
    GC.config(rgengc_allow_full_mark: false)
  end
end

lanes = BcryptService.calibrate
# Socketpairs, made before the fork: one per worker for bcrypt (the master keeps the other end), and one per
# (worker, planner) for reads.
pairs = Array.new(WORKERS) { UNIXSocket.pair(:SEQPACKET) }
# Shared-memory rings (remote_planner.rb) for reads: links[planner][worker].
links = Array.new(PLANNERS) { Array.new(WORKERS) { RemotePlanner::Link.make } }
close_all_but = lambda do |keep|
  pairs.flatten.each { |socket| socket.close unless keep.include?(socket) || socket.closed? }
end
pids = []
PLANNERS.times do |p|
  pids << fork do
    %w[TERM INT].each { |signal| trap(signal) { exit!(0) } }
    close_all_but.call([])
    plan(links[p])
  end
end
WORKERS.times do |index|
  pids << fork do
    %w[TERM INT].each { |signal| trap(signal) { exit!(0) } }
    planners = links.map { |row| row[index] }
    close_all_but.call([pairs[index][1]])
    serve(index, pairs[index][1], planners)
  end
end
pairs.each { |_, worker_end| worker_end.close }

stop = lambda do |signal|
  pids.each do |pid|
    Process.kill(signal, pid)
  rescue Errno::ESRCH
    nil
  end
end
%w[TERM INT].each { |signal| trap(signal) { stop.call("TERM") } }

# The first worker to exit stops the rest, and the master with them.
Thread.new do
  pid, status = Process.wait2
  warn "worker #{pid} exited (#{status}); stopping the others" unless status.success?
  stop.call("TERM")
  Process.waitall
  exit!(status.success? ? 0 : 1)
end

Process.setpriority(Process::PRIO_PROCESS, 0, MASTER_NICE)
warn "bcrypt: #{lanes} lanes per set, #{BcryptService::THREADS} threads in the master"
BcryptService::Server.new(pairs.map(&:first), lanes).run

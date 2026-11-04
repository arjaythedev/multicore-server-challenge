# frozen_string_literal: true

require "async"
require "etc"
require_relative "conduit"
require_relative "http"

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
WORKERS = Integer(ENV.fetch("WORKERS", Etc.nprocessors.to_s))
# Per worker. Postgres used less CPU per query the fewer connections it had (1 instead of 3: -11% at
# 4,000 local users); pipelining keeps one busy.
# WORKERS x PG_CONNECTIONS must stay at 95 or below.
PG_CONNECTIONS = Integer(ENV.fetch("PG_CONNECTIONS", "1"))
abort "WORKERS x PG_CONNECTIONS = #{WORKERS * PG_CONNECTIONS} is over 95" if WORKERS * PG_CONNECTIONS > 95

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
    db = DB.new(DATABASE_URL, 1, SQL::STATEMENTS, setup: SQL::SETUP)
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

def serve(index)
  Async do |task|
    db = DB.new(DATABASE_URL, PG_CONNECTIONS, SQL::STATEMENTS, setup: SQL::SETUP)
    db.start
    app = Conduit.new(db, SECRET)
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
      warn "listening on #{HOST}:#{PORT} (#{WORKERS} workers, #{server.class}, #{PG_CONNECTIONS} Postgres connections each, #{compiled})"
    end
  end
end

warm_up
GC.compact
Process.warmup

pids = Array.new(WORKERS) do |index|
  fork do
    %w[TERM INT].each { |signal| trap(signal) { exit!(0) } }
    serve(index)
  end
end

stop = lambda do |signal|
  pids.each do |pid|
    Process.kill(signal, pid)
  rescue Errno::ESRCH
    nil
  end
end
%w[TERM INT].each { |signal| trap(signal) { stop.call("TERM") } }

pid, status = Process.wait2
unless status.success? && status.exitstatus.zero?
  warn "worker #{pid} exited (#{status}); stopping the others"
end
stop.call("TERM")
Process.waitall
exit(status.success? ? 0 : 1)

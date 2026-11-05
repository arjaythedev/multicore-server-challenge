# frozen_string_literal: true

require "socket"
require_relative "ext/bcrypt/bcrypt_lanes"

# bcrypt for the whole server, in the master process. Interleaving several hashes (BcryptLanes) costs a
# fraction of the CPU per hash, but only when several are waiting at once, and each worker alone sees a
# few logins a second. So workers send every hash to the master over a socketpair made before the fork
# (no file on disk), and the master runs them in sets: a set starts when it holds LANES hashes or WAIT
# after its first one arrived, on one of THREADS helper threads with the GVL released. Every hash runs all
# 2^10 rounds with its own salt; logins always verify against the stored hash.
module BcryptService
  # How long a set waits for company. At 100 ms sets averaged ~1.2 hashes on the rig and bcrypt took ~15% of
  # the box; at 300 ms p95 at 50,000 users went from 451 to 301 ms.
  WAIT = Float(ENV.fetch("BCRYPT_WAIT_MS", "300")) / 1000
  THREADS = Integer(ENV.fetch("BCRYPT_THREADS", "2"))
  HEADER = "N"

  # The fastest lane count on this CPU (time per hash of a short run of each).
  def self.calibrate
    lanes = ENV["BCRYPT_LANES"]&.to_i
    return lanes if lanes&.between?(1, 6)

    BcryptLanes.calibrate(1) # warm
    (1..6).min_by { |n| BcryptLanes.calibrate(n) }
  end

  # Master side: serves the workers' ends of the socketpairs until the process exits.
  class Server
    def initialize(sockets, lanes)
      @sockets = sockets
      @lanes = lanes
      @pending = [] # [socket, id, password, setting]
      @signal = Thread::Queue.new
      @slots = Thread::Queue.new
      THREADS.times { @slots.push(true) }
    end

    def run
      Sync do |task|
        @sockets.each { |socket| task.async { read(socket) } }
        task.async { dispatch(task) }
        task.async { stats } if ENV["BCRYPT_STATS"]
      end
    end

    # BCRYPT_STATS=1: every 10 s, hashes, sets and the CPU they took.
    def stats
      @hashes = @sets = 0
      loop do
        h0 = @hashes
        s0 = @sets
        c0 = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
        sleep 10
        c = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - c0
        hashes = @hashes - h0
        sets = @sets - s0
        warn format("bcrypt: %d hashes in %d sets (%.2f per set), %.0f ms CPU per hash", hashes, sets,
                    sets.zero? ? 0 : hashes.to_f / sets, hashes.zero? ? 0 : c * 1000 / hashes)
      end
    end

    private

    def read(socket)
      loop do
        message = socket.recv(256)
        return if message.empty? # the worker is gone

        id = message.unpack1(HEADER)
        setting, password = message.byteslice(4, message.bytesize - 4).split("\0", 2)
        @pending << [socket, id, password || "", setting]
        @signal.push(Process.clock_gettime(Process::CLOCK_MONOTONIC)) if @pending.size == 1
      end
    end

    def dispatch(task)
      loop do
        opened = @signal.pop
        wait = opened + WAIT - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        # A full set goes at once; otherwise wait for company until WAIT has passed.
        while @pending.size < @lanes && wait.positive?
          sleep([wait, 0.005].min)
          wait = opened + WAIT - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
        until @pending.empty?
          set = @pending.shift(@lanes)
          @slots.pop
          task.async { hash(set) }
        end
      end
    end

    def hash(set)
      if @hashes
        @hashes += set.size
        @sets += 1
      end
      results = Thread.new(set) do |jobs|
        BcryptLanes.run(jobs.map { _1[2] }, jobs.map { _1[3] })
      rescue ArgumentError, RuntimeError
        # A set with a password BcryptLanes refuses (NUL, too long) or mixed costs: one at a time.
        jobs.map { |job| (BcryptLanes.run([job[2]], [job[3]])[0] rescue nil) }
      end.value
      set.each_with_index do |(socket, id), i|
        socket.send([id].pack(HEADER) + (results[i] || ""), 0)
      rescue IOError, SystemCallError
        nil
      end
    ensure
      @slots.push(true)
    end
  end

  # Worker side: one per process, used from request fibers.
  class Client
    def initialize(socket)
      @socket = socket
      @next = 0
      @waiting = {}
      Fiber.schedule { read }
    end

    # The hash of `password` with `setting` (a salt or a stored hash), or nil.
    def hash(password, setting)
      id = (@next += 1) & 0xFFFFFFFF
      queue = (Thread.current[:bcrypt_queue] ||= Thread::Queue.new)
      @waiting[id] = queue
      message = [id].pack(HEADER) << setting.b << "\0" << password.b
      @socket.send(message, 0)
      result = queue.pop
      result.empty? ? nil : result
    end

    private

    def read
      loop do
        message = @socket.recv(128)
        break if message.empty?

        id = message.unpack1(HEADER)
        @waiting.delete(id)&.push(message.byteslice(4, message.bytesize - 4))
      end
      @waiting.each_value { |queue| queue.push("") } # the master is gone: every hash fails
      @waiting.clear
    end
  end
end

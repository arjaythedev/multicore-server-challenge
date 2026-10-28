# Bcrypt stays off the event loop. Pthreads gather independent jobs, interleave
# cost-10 EksBlowfish states, and return job pointers through an io_uring socket.
# libcrypt supplies random salts and handles formats outside the fast path.
require "./bcrypt_lanes"
require "c/poll"

@[Link("crypt")]
lib LibCrypt
  fun crypt_rn(phrase : UInt8*, setting : UInt8*, data : Void*, size : LibC::Int) : UInt8*
  fun crypt_gensalt_rn(prefix : UInt8*, count : LibC::ULong, rbytes : UInt8*, nrbytes : LibC::Int,
                       output : UInt8*, size : LibC::Int) : UInt8*
end

module Passwords
  COST       =    10
  DATA_SIZE  = 32768 # struct crypt_data
  HASH_MAX   =   128
  MODE_HASH  =  1_u8
  MODE_CHECK =  2_u8

  @@gather = LibC::PthreadMutexT.new
  @@window_ms = 200
  @@lanes = true
  @@to_threads = -1
  @@from_threads = -1
  @@thread_side = -1
  @@pending = Pointer(UInt8).null # a partial pointer from the result socket
  @@npending = 0

  def self.fd : Int32
    @@from_threads
  end

  def self.start(threads : Int32) : Nil
    LibC.pthread_mutex_init(pointerof(@@gather), Pointer(LibC::PthreadMutexattrT).null)
    @@window_ms = (ENV["BCRYPT_WINDOW_MS"]? || "200").to_i.clamp(0, 400)
    @@lanes = ENV["BCRYPT_LANES"]? != "1"
    p = uninitialized Int32[2]
    raise "pipe failed" if LibC.pipe(p) != 0
    s = uninitialized Int32[2]
    raise "socketpair failed" if LibC.socketpair(LibC::AF_UNIX, LibC::SOCK_STREAM, 0, s) != 0
    @@to_threads = p[1]
    @@from_threads = s[0]
    @@thread_side = s[1]
    @@pending = LibC.malloc(8).as(UInt8*)
    args = LibC.malloc(8).as(Int32*)
    args[0] = p[0]
    args[1] = s[1]
    threads.times do
      tid = uninitialized LibC::PthreadT
      fn = ->(arg : Void*) { Passwords.thread(arg.as(Int32*)); Pointer(Void).null }
      LibC.pthread_create(pointerof(tid), Pointer(LibC::PthreadAttrT).null, fn, args.as(Void*))
    end
  end

  # Queues the job: its password (and, to check, the stored hash) are already on it.
  def self.submit(job : Job) : Nil
    v = job.as(Void*).address
    LibC.write(@@to_threads, pointerof(v).as(Void*), 8)
  end

  # Threads serialize collection, then compute independently. A sparse login stream
  # therefore fills one set instead of being split among waiting workers.
  def self.thread(fds : Int32*) : Nil
    input = fds[0]
    output = fds[1]
    data = Rayo::LibSys.calloc(1, DATA_SIZE)
    salt = LibC.malloc(64).as(UInt8*)
    jobs = uninitialized UInt64[6]
    passwords = uninitialized Pointer(UInt8)[6]
    settings = uninitialized Pointer(UInt8)[6]
    lengths = uninitialized Int32[6]
    hashes = uninitialized UInt8[366]
    e1 = BcryptLanes::Engine(1).new
    e2 = BcryptLanes::Engine(2).new
    e3 = BcryptLanes::Engine(3).new
    e4 = BcryptLanes::Engine(4).new
    e5 = BcryptLanes::Engine(5).new
    e6 = BcryptLanes::Engine(6).new
    loop do
      LibC.pthread_mutex_lock(pointerof(@@gather))
      n = 0
      deadline = 0_i64
      loop do
        if n > 0
          remaining = ((deadline - Rayo::Sys.now_ns(Rayo::Sys::CLOCK_MONOTONIC)) // 1_000_000).to_i32
          break if remaining <= 0
          pollfd = Rayo::PG::LibPoll::Event.new(fd: input, events: 1_i16, revents: 0_i16)
          break if Rayo::PG::LibPoll.poll(pointerof(pollfd), 1, remaining) <= 0
        end
        got = 0
        while got < 8
          r = LibC.read(input, jobs.to_unsafe.as(UInt8*) + n * 8 + got, 8 - got)
          LibC._exit(1) if r <= 0
          got += r
        end
        n += 1
        deadline = Rayo::Sys.now_ns(Rayo::Sys::CLOCK_MONOTONIC) + @@window_ms.to_i64 * 1_000_000 if n == 1
        break if n == 6 || !@@lanes
      end
      LibC.pthread_mutex_unlock(pointerof(@@gather))
      fast = 0
      n.times do |i|
        j = Pointer(Void).new(jobs.to_unsafe[i]).as(Job)
        pw = j.ptr(Job::F_PASSWORD)
        if j.bc_mode == MODE_HASH
          if LibCrypt.crypt_gensalt_rn("$2b$".to_unsafe, COST, Pointer(UInt8).null, 0, salt, 64).null?
            j.bc_ok = false
            next
          end
          j.hash_ptr.copy_from(salt, 30)
        end
        h = j.hash_ptr
        valid = @@lanes && j.len[Job::F_PASSWORD] <= 72 &&
                LibC.memchr(pw, 0, j.len[Job::F_PASSWORD]).null? &&
                h[0] == 36 && h[1] == 50 && (h[2] == 97 || h[2] == 98) &&
                h[3] == 36 && h[4] == 49 && h[5] == 48 && h[6] == 36 &&
                (j.bc_mode == MODE_HASH || j.hash_len == 60)
        # libxcrypt's historical $2a$ safety-bit corner cases stay on libcrypt.
        if valid && h[2] == 97
          j.len[Job::F_PASSWORD].times { |k| valid = false if pw[k] >= 128 }
        end
        decoded = uninitialized UInt8[16]
        valid &&= BcryptLanes.decode(h + 7, decoded.to_unsafe, 16)
        if valid
          canonical = uninitialized UInt8[22]
          BcryptLanes.encode(decoded.to_unsafe, 16, canonical.to_unsafe)
          22.times { |k| valid = false if canonical.to_unsafe[k] != h[7 + k] }
        end
        if valid
          # Compact eligible jobs to the front; keep their original order in jobs.
          passwords.to_unsafe[fast] = pw
          settings.to_unsafe[fast] = h
          lengths.to_unsafe[fast] = j.len[Job::F_PASSWORD]
          fast += 1
        else
          legacy(j, data)
        end
      end
      if fast > 0
        case fast
        when 1
          e1.hash(passwords.to_unsafe, lengths.to_unsafe, settings.to_unsafe, hashes.to_unsafe)
        when 2
          e2.hash(passwords.to_unsafe, lengths.to_unsafe, settings.to_unsafe, hashes.to_unsafe)
        when 3
          e3.hash(passwords.to_unsafe, lengths.to_unsafe, settings.to_unsafe, hashes.to_unsafe)
        when 4
          e4.hash(passwords.to_unsafe, lengths.to_unsafe, settings.to_unsafe, hashes.to_unsafe)
        when 5
          e5.hash(passwords.to_unsafe, lengths.to_unsafe, settings.to_unsafe, hashes.to_unsafe)
        when 6
          e6.hash(passwords.to_unsafe, lengths.to_unsafe, settings.to_unsafe, hashes.to_unsafe)
        end
        fast.times do |i|
          n.times do |k|
            j = Pointer(Void).new(jobs.to_unsafe[k]).as(Job)
            next unless j.hash_ptr == settings.to_unsafe[i]
            h = hashes.to_unsafe + i * 61
            if j.bc_mode == MODE_HASH
              j.hash_ptr.copy_from(h, 61)
              j.hash_len = 60
              j.bc_ok = true
            else
              diff = 0_u8
              60.times { |b| diff |= h[b] ^ j.hash_ptr[b] }
              j.bc_ok = diff == 0
            end
          end
        end
      end
      sent = 0
      while sent < n * 8
        r = LibC.write(output, jobs.to_unsafe.as(UInt8*) + sent, n * 8 - sent)
        LibC._exit(1) if r <= 0
        sent += r
      end
    end
  end

  private def self.legacy(j : Job, data : Void*) : Nil
    h = LibCrypt.crypt_rn(j.ptr(Job::F_PASSWORD), j.hash_ptr, data, DATA_SIZE)
    j.bc_ok = false
    return if h.null? || h[0] != 36
    l = LibC.strlen(h).to_i32
    if j.bc_mode == MODE_HASH
      if l < HASH_MAX
        j.hash_ptr.copy_from(h, l + 1)
        j.hash_len = l
        j.bc_ok = true
      end
    elsif l == j.hash_len
      diff = 0_u8
      l.times { |i| diff |= h[i] ^ j.hash_ptr[i] }
      j.bc_ok = diff == 0
    end
  end

  # Bytes from the result socket: whole pointers are finished jobs.
  def self.on_data(p : UInt8*, n : Int32) : Nil
    i = 0
    while i < n
      @@pending[@@npending] = p[i]
      @@npending &+= 1
      i &+= 1
      if @@npending == 8
        @@npending = 0
        Passwords.complete(Pointer(Void).new(@@pending.as(UInt64*).value).as(Job))
      end
    end
  end
end

module Passwords
  class Job
    F_PASSWORD = 0
    getter storage = Rayo::Buf.new(128)

    def password
      @storage.ptr
    end

    getter len = Pointer(Int32).malloc(1, 0)
    getter hash_ptr = Rayo::LibSys.calloc(128, 1).as(UInt8*)
    property hash_len = 0
    property bc_mode = MODE_HASH
    property bc_ok = false
    property handle : Rayo::Context::Deferred? = nil
    property operation = 0 # 0 register, 1 login, 2 update
    property user_id = 0_i64
    property next_free : Job? = nil

    def ptr(field)
      password
    end
  end

  class Receiver
    include Rayo::Uring::Handler

    def on_data(ptr : UInt8*, len : Int32) : Nil
      Passwords.on_data(ptr, len)
    end

    def on_sent(result : Int32) : Nil
    end

    def on_closed : Nil
    end
  end

  @@started = false
  @@free : Job? = nil
  @@jobs = [] of Job

  def self.acquire(ctx, password : Bytes, operation : Int32, hash : Bytes? = nil, user_id = 0_i64)
    raise Conduit::Invalid.new if operation != 1 && password.size > 72
    unless @@started
      start((ENV["BCRYPT_THREADS"]? || "1").to_i)
      Rayo::Uring.watch(fd, Receiver.new)
      @@started = true
    end
    job = @@free || Job.new.tap { |record| @@jobs << record }
    @@free = job.next_free
    job.next_free = nil
    job.storage.reserve(password.size + 1)
    job.password.copy_from(password.to_unsafe, password.size)
    job.password[password.size] = 0
    job.len[0] = password.size
    job.operation = operation
    job.user_id = user_id
    job.hash_len = 0
    job.hash_ptr.clear(128)
    if hash
      raise Conduit::Invalid.new(401) if hash.size > 127
      job.hash_ptr.copy_from(hash.to_unsafe, hash.size)
      job.hash_len = hash.size
    end
    job.bc_mode = hash ? MODE_CHECK : MODE_HASH
    job.handle = ctx.defer
    # Bridge an external deferral with Rayo's database callback completion count.
    ctx.db_pending += 1
    submit(job)
  end

  def self.complete(job : Job) : Nil
    handle = job.handle.not_nil!
    if ctx = handle.context
      begin
        if job.bc_ok
          case job.operation
          when 0
            Conduit.register(ctx, Bytes.new(job.hash_ptr, job.hash_len))
          when 1
            Conduit.state(ctx).fresh = true
            ctx.db.query(Sql::USER_BY_ID, job.user_id) { |res, ctx| Conduit.user(ctx, res) }
          when 2
            Conduit.update_user(ctx, Bytes.new(job.hash_ptr, job.hash_len))
          end
        else
          Conduit.error(ctx, job.operation == 1 ? 401 : 422)
        end
      rescue
        Conduit.error(ctx, 500)
      ensure
        ctx.db_pending -= 1
        handle.finish if ctx.db_pending == 0
      end
    end
    job.handle = nil
    job.next_free = @@free
    @@free = job
  end
end

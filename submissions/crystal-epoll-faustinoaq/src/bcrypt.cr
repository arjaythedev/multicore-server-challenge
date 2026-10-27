# Bcrypt stays off the event loop. Pthreads gather independent jobs, interleave
# cost-10 EksBlowfish states, and return job pointers through an io_uring socket.
# libcrypt supplies random salts and handles formats outside the fast path.
require "./bcrypt_lanes"
require "c/poll"

@[Link("crypt")]
lib LibCrypt
  struct PollFd
    fd : Int32
    events : Int16
    revents : Int16
  end
  fun poll(fds : PollFd*, n : LibC::ULong, timeout : Int32) : Int32
  fun crypt_rn(phrase : UInt8*, setting : UInt8*, data : Void*, size : LibC::Int) : UInt8*
  fun crypt_gensalt_rn(prefix : UInt8*, count : LibC::ULong, rbytes : UInt8*, nrbytes : LibC::Int,
                       output : UInt8*, size : LibC::Int) : UInt8*
end

module Bcrypt
  COST       = 10
  DATA_SIZE  = 32768 # struct crypt_data
  HASH_MAX   = 128
  MODE_HASH  = 1_u8
  MODE_CHECK = 2_u8

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
    @@window_ms = (Sys.env("BCRYPT_WINDOW_MS") || "200").to_i.clamp(0, 400)
    @@lanes = Sys.env("BCRYPT_LANES") != "1"
    p = uninitialized Int32[2]
    Sys.die("pipe failed") if LibC.pipe(p) != 0
    s = uninitialized Int32[2]
    Sys.die("socketpair failed") if LibC.socketpair(LibC::AF_UNIX, LibC::SOCK_STREAM, 0, s) != 0
    @@to_threads = p[1]
    @@from_threads = s[0]
    @@thread_side = s[1]
    @@pending = LibC.malloc(8).as(UInt8*)
    args = LibC.malloc(8).as(Int32*)
    args[0] = p[0]
    args[1] = s[1]
    threads.times do
      tid = uninitialized LibC::PthreadT
      fn = ->(arg : Void*) { Bcrypt.thread(arg.as(Int32*)); Pointer(Void).null }
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
    data = LibSys.calloc(1, DATA_SIZE)
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
          remaining = ((deadline - Sys.now_ns(Sys::CLOCK_MONOTONIC)) // 1_000_000).to_i32
          break if remaining <= 0
          pollfd = LibCrypt::PollFd.new(fd: input, events: 1_i16, revents: 0_i16)
          break if LibCrypt.poll(pointerof(pollfd), 1, remaining) <= 0
        end
        got = 0
        while got < 8
          r = LibC.read(input, jobs.to_unsafe.as(UInt8*) + n * 8 + got, 8 - got)
          LibC._exit(1) if r <= 0
          got += r
        end
        n += 1
        deadline = Sys.now_ns(Sys::CLOCK_MONOTONIC) + @@window_ms.to_i64 * 1_000_000 if n == 1
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
        App.on_bcrypt(Pointer(Void).new(@@pending.as(UInt64*).value).as(Job))
      end
    end
  end
end

# bcrypt off the event loop. A hash at cost 10 is tens of milliseconds of CPU, so each worker
# hands them to a few plain pthreads (libcrypt's bcrypt: no Crystal runtime, no allocation
# in the threads): job pointers go to them through a pipe and come back through a socket
# pair that the worker's ring reads like any other socket.
@[Link("crypt")]
lib LibCrypt
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

  @@to_threads = -1
  @@from_threads = -1
  @@thread_side = -1
  @@pending = Pointer(UInt8).null # a partial pointer from the result socket
  @@npending = 0

  def self.fd : Int32
    @@from_threads
  end

  def self.start(threads : Int32) : Nil
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

  # A thread: hash or check, forever.
  def self.thread(fds : Int32*) : Nil
    input = fds[0]
    output = fds[1]
    data = LibSys.calloc(1, DATA_SIZE) # zeroed once, as crypt_rn wants
    salt = LibC.malloc(64).as(UInt8*)
    loop do
      v = 0_u64
      got = 0
      while got < 8
        r = LibC.read(input, pointerof(v).as(UInt8*) + got, 8 &- got)
        return if r <= 0
        got &+= r
      end
      j = Pointer(Void).new(v).as(Job)
      ok = false
      pw = j.data + j.off[Job::F_PASSWORD]
      if j.bc_mode == MODE_HASH
        if !LibCrypt.crypt_gensalt_rn("$2b$".to_unsafe, COST, Pointer(UInt8).null, 0, salt, 64).null?
          h = LibCrypt.crypt_rn(pw, salt, data, DATA_SIZE)
          if !h.null? && h[0] == '$'.ord
            l = LibC.strlen(h).to_i32
            if l < HASH_MAX
              j.hash_ptr.copy_from(h, l)
              j.hash_ptr[l] = 0_u8
              j.hash_len = l
              ok = true
            end
          end
        end
      else
        h = LibCrypt.crypt_rn(pw, j.hash_ptr, data, DATA_SIZE)
        if !h.null? && h[0] == '$'.ord && LibC.strlen(h) == j.hash_len
          diff = 0_u8
          j.hash_len.times { |i| diff |= h[i] ^ j.hash_ptr[i] }
          ok = diff == 0
        end
      end
      j.bc_ok = ok
      sent = 0
      while sent < 8
        r = LibC.write(output, pointerof(v).as(UInt8*) + sent, 8 &- sent)
        return if r <= 0
        sent &+= r
      end
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

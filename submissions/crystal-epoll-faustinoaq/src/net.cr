# Connection state and request framing. One batch = one wake-up of the loop: requests
# that need no database are answered straight into the batch's output arena; the others
# queue their query on a Postgres connection, and their response is written into the arena
# of whichever batch the reply arrives in. A connection with a query in flight is not read
# further until it is answered, so responses always leave in request order.
module Server
  struct Conn
    property inbuf : UInt8* = Pointer(UInt8).null # partial request carried between reads
    property inlen : Int32 = 0
    property incap : Int32 = 0
    property outbuf : UInt8* = Pointer(UInt8).null # unsent output (socket was full)
    property outlen : Int32 = 0
    property outoff : Int32 = 0
    property outcap : Int32 = 0
    property nextbuf : UInt8* = Pointer(UInt8).null # output queued behind an in-flight send
    property nextlen : Int32 = 0
    property nextcap : Int32 = 0
    property sptr : UInt8* = Pointer(UInt8).null # io_uring: the send in flight
    property slen : Int32 = 0
    property sarena : Int32 = 0 # arena it points into, or OWNED (outbuf)
    property gen : UInt16 = 0
    property sending : Bool = false
    property busy : Bool = false        # a query of this connection is in flight
    property close_after : Bool = false # ...and the client asked to close after it
    property closing : Bool = false
    property open : Bool = false
  end

  # One contiguous run of response bytes for one socket in the batch arena.
  struct Pending
    property fd : Int32 = 0
    property gen : UInt16 = 0
    property start : Int32 = 0
    property stop : Int32 = 0
    property close : Bool = false
  end

  RECV_SIZE = 65536

  @@conns = Pointer(Conn).null
  @@nconns = 0_u64
  @@rbuf = Pointer(UInt8).null
  # Output arenas. A batch writes into one that no send still references (io_uring sends
  # point straight into the arena until they complete; with epoll none ever stays busy).
  MAX_ARENAS = 255
  @@arena = Pointer(Buf).null
  @@refs = Pointer(Int32).null
  @@narena = 0
  @@cur = 0
  @@out = Buf.new(16)
  @@pend = Pointer(Pending).null
  @@npend = 0
  @@pcap = 0
  @@now_s = 0_i64
  @@started = 0_i64
  @@claims = Pointer(Jwt::Claims).null
  @@scratch = Pointer(UInt8).null

  @@cur_fd = 0
  @@cur_gzip = false

  def self.init(started : Int64) : Nil
    @@arena = LibC.malloc(MAX_ARENAS * sizeof(Buf)).as(Buf*)
    @@refs = LibSys.calloc(MAX_ARENAS, 4).as(Int32*)
    @@arena[0] = Buf.new(1 << 20)
    @@narena = 1
    @@out = @@arena[0]
    @@pcap = 4096
    @@pend = LibC.malloc(4096 * sizeof(Pending)).as(Pending*)
    @@scratch = LibC.malloc(Http::MAX_BODY + 64).as(UInt8*)
    @@claims = LibSys.calloc(1, sizeof(Jwt::Claims)).as(Jwt::Claims*)
    @@started = started
  end

  def self.out : Buf
    @@out
  end

  def self.cur_fd : Int32
    @@cur_fd
  end

  def self.cur_gzip : Bool
    @@cur_gzip
  end

  # A query's response was written to the arena from `start`: queue it for the client and
  # go on with what the client sent meanwhile.
  def self.db_done(fd : Int32, gen : UInt16, start : Int32) : Nil
    c = conn(fd)
    cv = c.value
    unless cv.open && cv.gen == gen && cv.busy
      @@out.len = start # the client is gone
      return
    end
    c.value.busy = false
    add_pending(fd, start, @@out.len, cv.close_after)
    process_inbuf(fd) if !cv.close_after && cv.inlen > 0
  end

  # Connection records by id: the fd with epoll, ring * slots + fixed-file slot with
  # io_uring. calloc: pages of the table nobody touched stay unmapped.
  def self.alloc_conns(n : UInt64) : Nil
    @@nconns = n
    @@conns = LibSys.calloc(n, sizeof(Conn)).as(Conn*)
  end

  @[AlwaysInline]
  def self.conn(fd : Int32) : Conn*
    @@conns + fd
  end

  def self.nconns : UInt64
    @@nconns
  end

  # Starts a batch in a free arena (a new one only if every arena has sends in flight).
  def self.begin_batch : Nil
    @@now_s = Sys.now_ns(Sys::CLOCK_REALTIME_COARSE) // 1_000_000_000
    i = @@cur
    @@narena.times do
      break if @@refs[i] == 0
      i &+= 1
      i = 0 if i == @@narena
    end
    if @@refs[i] != 0
      Sys.die("too many output arenas in flight") if @@narena == MAX_ARENAS
      i = @@narena
      @@arena[i] = Buf.new(1 << 20)
      @@narena &+= 1
    end
    @@cur = i
    @@out = @@arena[i]
    @@out.clear
    @@npend = 0
  end

  def self.cur : Int32
    @@cur
  end

  def self.arena(i : Int32) : Buf
    @@arena[i]
  end

  @[AlwaysInline]
  def self.ref(i : Int32) : Nil
    @@refs[i] &+= 1
  end

  @[AlwaysInline]
  def self.unref(i : Int32) : Nil
    @@refs[i] &-= 1
  end

  def self.pend : Pending*
    @@pend
  end

  def self.npend : Int32
    @@npend
  end

  # Data arrived on fd. Answers every complete request; a partial one is kept in inbuf.
  # Returns false when the connection is to be closed once its responses are out.
  def self.on_data(fd : Int32, p : UInt8*, n : Int32) : Bool
    c = conn(fd)
    if c.value.inbuf.null? && !c.value.busy
      used = process(fd, p, n)
      return false if used < 0
      if used < n
        left = n &- used
        cap = left < 4096 ? 4096 : left &* 2
        b = LibC.malloc(cap).as(UInt8*)
        b.copy_from(p + used, left)
        c.value.inbuf = b
        c.value.incap = cap
        c.value.inlen = left
      end
      return true
    end
    cv = c.value
    if cv.incap &- cv.inlen < n
      cv.incap = (cv.inlen &+ n) &* 2
      cv.inbuf = LibC.realloc(cv.inbuf, cv.incap).as(UInt8*)
    end
    (cv.inbuf + cv.inlen).copy_from(p, n)
    cv.inlen &+= n
    c.value = cv
    return true if cv.busy || cv.close_after
    process_inbuf(fd)
  end

  def self.process_inbuf(fd : Int32) : Bool
    c = conn(fd)
    cv = c.value
    used = process(fd, cv.inbuf, cv.inlen)
    return false if used < 0
    cv = c.value
    if used == cv.inlen
      LibC.free(cv.inbuf)
      cv.inbuf = Pointer(UInt8).null
      cv.inlen = cv.incap = 0
    elsif used > 0
      cv.inbuf.move_from(cv.inbuf + used, cv.inlen &- used)
      cv.inlen &-= used
    end
    c.value = cv
    true
  end

  # Answers every complete request in p[0, n). Returns bytes consumed, or -1 when the
  # connection is to be closed after its responses go out.
  def self.process(fd : Int32, p : UInt8*, n : Int32) : Int32
    start = @@out.len
    off = 0
    close = false
    req = Http::Req.new
    c = conn(fd)
    while off < n && !c.value.busy
      r = Http.parse(p + off, n &- off, pointerof(req))
      break if r == Http::NEED_MORE
      if r == Http::BAD
        @@out << Resp::BAD_REQUEST
        close = true
        break
      end
      @@cur_fd = fd
      @@cur_gzip = req.gzip
      Router.handle(pointerof(req), @@out)
      off &+= r
      if req.close
        close = true
        break
      end
    end
    if close && c.value.busy # closes once the query is answered
      c.value.close_after = true
      close = false
    end
    add_pending(fd, start, @@out.len, close) if @@out.len > start || close
    close ? -1 : off
  end

  def self.add_pending(fd : Int32, start : Int32, stop : Int32, close : Bool) : Nil
    if @@npend == @@pcap
      @@pcap &*= 2
      @@pend = LibC.realloc(@@pend, @@pcap * sizeof(Pending)).as(Pending*)
    end
    pe = Pending.new
    pe.fd = fd
    pe.gen = conn(fd).value.gen
    pe.start = start
    pe.stop = stop
    pe.close = close
    @@pend[@@npend] = pe
    @@npend &+= 1
  end

  # Appends bytes to the connection's queued output (outbuf, or nextbuf while a send of
  # outbuf is in flight and its memory must not move).
  def self.queue(fd : Int32, p : UInt8*, n : Int32) : Nil
    c = conn(fd)
    cv = c.value
    if cv.sending
      if cv.nextcap &- cv.nextlen < n
        cv.nextcap = (cv.nextlen &+ n) &* 2
        cv.nextcap = 16384 if cv.nextcap < 16384
        cv.nextbuf = LibC.realloc(cv.nextbuf, cv.nextcap).as(UInt8*)
      end
      (cv.nextbuf + cv.nextlen).copy_from(p, n)
      cv.nextlen &+= n
    else
      if cv.outoff > 0
        cv.outbuf.move_from(cv.outbuf + cv.outoff, cv.outlen &- cv.outoff)
        cv.outlen &-= cv.outoff
        cv.outoff = 0
      end
      if cv.outcap &- cv.outlen < n
        cv.outcap = (cv.outlen &+ n) &* 2
        cv.outcap = 16384 if cv.outcap < 16384
        cv.outbuf = LibC.realloc(cv.outbuf, cv.outcap).as(UInt8*)
      end
      (cv.outbuf + cv.outlen).copy_from(p, n)
      cv.outlen &+= n
    end
    c.value = cv
  end

  def self.free_conn(fd : Int32) : Nil
    c = conn(fd)
    cv = c.value
    LibC.free(cv.inbuf) unless cv.inbuf.null?
    LibC.free(cv.outbuf) unless cv.outbuf.null?
    LibC.free(cv.nextbuf) unless cv.nextbuf.null?
    g = cv.gen &+ 1
    cv = Conn.new
    cv.gen = g
    c.value = cv
  end

  def self.now_s : Int64
    @@now_s
  end

  def self.uptime : Int64
    Sys.now_ns(Sys::CLOCK_MONOTONIC) // 1_000_000_000 &- @@started
  end

  def self.claims : Jwt::Claims*
    @@claims
  end

  def self.scratch : UInt8*
    @@scratch
  end

  def self.rbuf : UInt8*
    @@rbuf
  end
end

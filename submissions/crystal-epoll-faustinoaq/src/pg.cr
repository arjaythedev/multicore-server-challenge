require "c/netdb"
require "c/netinet/in"
require "c/netinet/tcp"
require "uri"
require "base64"
require "openssl"
require "openssl/hmac"
require "openssl/pkcs5"
require "random/secure"

# Postgres v3 prepared statements and pipelining. Reads end with their own Sync.
# The write connection groups a round's Bind/Execute pairs before a single Sync:
# PostgreSQL commits that implicit transaction before sending ReadyForQuery.
# Rows stay buffered until then; failed groups are retried as individual requests.
module Pg
  struct Query
    getter job : Job

    def initialize(@job)
    end
  end

  class Conn
    getter idx : Int32
    getter fd : Int32
    property alive = true
    property inbuf : UInt8*
    property inlen = 0
    property incap = 65536
    property qbuf = Buf.new(65536)   # queries of the current batch
    property sbuf = Buf.new(65536)  # the write in flight
    property soff = 0
    property sending = false
    property q : Query*
    property qhead = 0_u32
    property qtail = 0_u32
    property qcap = 1024_u32
    property group_at = 0_i64
    property group : Job? = nil
    property group_ready = false # a closed write group in qbuf must not wait for a newer group
    property statements = 0
    property set = 0_u8 # result set (statement) of the front job the next DataRow belongs to
    property err = false
    property code = 0_u64          # SQLSTATE, 5 bytes packed
    property raw = Buf.new(65536)  # the front job's DataRows: [set u8][len i32][payload]

    def initialize(@idx, @fd)
      @inbuf = LibC.malloc(@incap).as(UInt8*)
      @q = LibC.malloc(@qcap * sizeof(Query)).as(Query*)
    end

    def pending : UInt32
      @qtail &- @qhead
    end

    def push(qq : Query) : Nil
      if pending == @qcap
        nq = LibC.malloc(@qcap * 2 * sizeof(Query)).as(Query*)
        @qcap.times { |i| nq[i] = @q[(@qhead &+ i) & (@qcap &- 1)] }
        LibC.free(@q)
        @q = nq
        @qhead = 0_u32
        @qtail = @qcap
        @qcap &*= 2
      end
      @q[@qtail & (@qcap &- 1)] = qq
      @qtail &+= 1
    end

    def front : Query*
      @q + (@qhead & (@qcap &- 1))
    end

    def pop : Nil
      @qhead &+= 1
    end
  end

  @@group_commit : Bool = Sys.env("GROUP_COMMIT") == "1"
  @@write_window : Int64 = (Sys.env("WRITE_WINDOW_US") || "20000").to_i64.clamp(0_i64, 50000_i64) * 1000
  @@conns = Pointer(Conn).null
  @@n = 0
  @@rr = 0

  # ---- connecting (blocking, before the event loop starts) ----

  def self.connect_all(url : String, n : Int32) : Nil
    u = URI.parse(url)
    host = u.host.presence || "127.0.0.1"
    host = host[1..-2] if host.starts_with?('[')
    port = u.port || 5432
    user = URI.decode(u.user || "postgres")
    pass = URI.decode(u.password || "")
    db = u.path.lchop('/')
    db = user if db.empty?
    @@conns = LibC.malloc(n * sizeof(Conn)).as(Conn*)
    n.times do |i|
      fd = open_socket(host, port)
      startup(fd, user, pass, db)
      prepare(fd)
      @@conns[i] = Conn.new(i, fd)
      @@n &+= 1
    end
  end

  private def self.open_socket(host : String, port : Int32) : Int32
    hints = LibC::Addrinfo.new
    hints.ai_family = LibC::AF_UNSPEC
    hints.ai_socktype = LibC::SOCK_STREAM
    res = Pointer(LibC::Addrinfo).null
    Sys.die("cannot resolve #{host}") if LibC.getaddrinfo(host, port.to_s, pointerof(hints), pointerof(res)) != 0
    ai = res
    while !ai.null?
      fd = LibC.socket(ai.value.ai_family, LibC::SOCK_STREAM | LibC::SOCK_CLOEXEC, 0)
      if fd >= 0
        if LibC.connect(fd, ai.value.ai_addr, ai.value.ai_addrlen) == 0
          one = 1
          LibC.setsockopt(fd, LibC::IPPROTO_TCP, LibC::TCP_NODELAY, pointerof(one).as(Void*), 4)
          return fd
        end
        LibC.close(fd)
      end
      ai = ai.value.ai_next
    end
    Sys.die("cannot connect to Postgres at #{host}:#{port}")
  end

  private def self.write_all(fd : Int32, b : Bytes) : Nil
    off = 0
    while off < b.size
      r = LibC.write(fd, b.to_unsafe + off, b.size - off)
      Sys.die("Postgres write failed") if r <= 0
      off += r
    end
  end

  private def self.read_full(fd : Int32, n : Int32) : Bytes
    b = Bytes.new(n)
    off = 0
    while off < n
      r = LibC.read(fd, b.to_unsafe + off, n - off)
      Sys.die("Postgres closed the connection") if r <= 0
      off += r
    end
    b
  end

  # One backend message: {type, payload}.
  private def self.read_msg(fd : Int32) : {Char, Bytes}
    h = read_full(fd, 5)
    len = IO::ByteFormat::BigEndian.decode(Int32, h[1, 4])
    {h[0].chr, read_full(fd, len - 4)}
  end

  private def self.msg(type : Char?, & : IO::Memory ->) : Bytes
    body = IO::Memory.new
    yield body
    io = IO::Memory.new
    io.write_byte(type.ord.to_u8) if type
    io.write_bytes(body.size.to_i32 + 4, IO::ByteFormat::BigEndian)
    io.write(body.to_slice)
    io.to_slice
  end

  private def self.cstr(io : IO, s : String) : Nil
    io << s
    io.write_byte(0_u8)
  end

  private def self.fail(payload : Bytes) : NoReturn
    m = String.new(payload).split('\0').select { |f| f.starts_with?('M') }.first?
    Sys.die("Postgres: #{m.try(&.[1..]) || "error"}")
  end

  private def self.startup(fd : Int32, user : String, pass : String, db : String) : Nil
    write_all(fd, msg(nil) { |io|
      io.write_bytes(196608_i32, IO::ByteFormat::BigEndian)
      # session settings: timestamps come back as "YYYY-MM-DD HH:MM:SS.ffffff+00"
      {"user" => user, "database" => db, "client_encoding" => "UTF8", "TimeZone" => "UTC",
       "DateStyle" => "ISO, MDY", "application_name" => "conduit-crystal", "jit" => "off",
       "plan_cache_mode" => "force_generic_plan", "max_parallel_workers_per_gather" => "0",
       "enable_seqscan" => (Sys.env("PG_INDEX_LOOKUPS") == "0" ? "on" : "off")}.each { |k, v| cstr(io, k); cstr(io, v) }
      io.write_byte(0_u8)
    })
    nonce = client_first = ""
    salted = Bytes.empty
    auth_msg = ""
    loop do
      t, p = read_msg(fd)
      case t
      when 'R'
        code = IO::ByteFormat::BigEndian.decode(Int32, p[0, 4])
        case code
        when 0 # ok
        when 3 # cleartext
          write_all(fd, msg('p') { |io| cstr(io, pass) })
        when 5 # md5
          salt = p[4, 4]
          inner = OpenSSL::Digest.new("MD5").update(pass + user).final.hexstring
          outer = OpenSSL::Digest.new("MD5").update(inner.to_slice).update(salt).final.hexstring
          write_all(fd, msg('p') { |io| cstr(io, "md5" + outer) })
        when 10 # SASL: SCRAM-SHA-256
          Sys.die("Postgres wants SASL without SCRAM-SHA-256") unless String.new(p[4..]).includes?("SCRAM-SHA-256")
          nonce = Base64.strict_encode(Random::Secure.random_bytes(18))
          client_first = "n=,r=#{nonce}"
          first = "n,,#{client_first}"
          write_all(fd, msg('p') { |io|
            cstr(io, "SCRAM-SHA-256")
            io.write_bytes(first.bytesize.to_i32, IO::ByteFormat::BigEndian)
            io << first
          })
        when 11 # SASL continue: server-first
          server_first = String.new(p[4..])
          f = server_first.split(',').to_h { |kv| {kv[0], kv[2..]} }
          r = f['r']
          Sys.die("SCRAM nonce mismatch") unless r.starts_with?(nonce)
          salted = OpenSSL::PKCS5.pbkdf2_hmac(pass, Base64.decode(f['s']), f['i'].to_i, OpenSSL::Algorithm::SHA256, 32)
          client_key = OpenSSL::HMAC.digest(:sha256, salted, "Client Key")
          stored_key = OpenSSL::Digest.new("SHA256").update(client_key).final
          without_proof = "c=biws,r=#{r}"
          auth_msg = "#{client_first},#{server_first},#{without_proof}"
          sig = OpenSSL::HMAC.digest(:sha256, stored_key, auth_msg)
          proof = Bytes.new(32) { |i| client_key[i] ^ sig[i] }
          final = "#{without_proof},p=#{Base64.strict_encode(proof)}"
          write_all(fd, msg('p') { |io| io << final })
        when 12 # SASL final: check the server's signature
          server_key = OpenSSL::HMAC.digest(:sha256, salted, "Server Key")
          expect = Base64.strict_encode(OpenSSL::HMAC.digest(:sha256, server_key, auth_msg))
          Sys.die("SCRAM server signature mismatch") unless String.new(p[4..]).includes?("v=#{expect}")
        else
          Sys.die("unsupported Postgres auth method #{code}")
        end
      when 'E' then fail(p)
      when 'Z' then break
      end
    end
  end

  private def self.prepare(fd : Int32) : Nil
    io = IO::Memory.new
    Sql::ALL.each_with_index do |sql, i|
      io.write(msg('P') { |m|
        cstr(m, i.to_s)
        cstr(m, sql)
        m.write_bytes(0_i16, IO::ByteFormat::BigEndian) # let Postgres infer every type
      })
    end
    io.write(msg('S') { })
    write_all(fd, io.to_slice)
    loop do
      t, p = read_msg(fd)
      fail(p) if t == 'E'
      break if t == 'Z'
    end
  end

  def self.count : Int32
    @@n
  end

  def self.conn(i : Int32) : Conn
    @@conns[i]
  end

  # ---- queries ----

  # The next live connection, round-robin. nil when none is left.
  # The live connection with the fewest requests in flight.
  def self.pick : Conn?
    best = nil
    @@n.times do
      c = @@conns[@@rr]
      @@rr &+= 1
      @@rr = 0 if @@rr == @@n
      next unless c.alive
      next if @@group_commit && @@n > 1 && c.idx == 0
      finish_group(c) if @@group_commit && @@n == 1
      best = c if best.nil? || c.pending < best.pending
    end
    best
  end

  # Writes have one connection so a round can share one implicit transaction.
  def self.write_pick : Conn?
    return pick unless @@group_commit
    c = @@conns[0]
    return nil unless c.alive
    finish_group(c) if c.group.try { |g| g.nsub >= 48 }
    c
  end

  private def self.finish_group(c : Conn) : Nil
    if group = c.group
      c.group = nil
      c.qbuf << "S\0\0\0\x04"
      c.push(Query.new(group))
      c.group_ready = true
      c.statements = 0
    end
  end

  @[AlwaysInline]
  private def self.be32(p : UInt8*, v : Int32) : Nil
    p[0] = (v >> 24).to_u8!
    p[1] = (v >> 16).to_u8!
    p[2] = (v >> 8).to_u8!
    p[3] = v.to_u8!
  end

  # Bind: unnamed portal, prepared statement `stmt`, `n` text parameters to follow.
  # Returns where the message starts, for `execute` to fill in its length.
  def self.bind(c : Conn, stmt : Int32, n : Int32) : Int32
    o = c.qbuf
    at = o.len
    o << 'B'.ord.to_u8
    o.reserve(4)
    o.len &+= 4
    o << 0_u8 << stmt << 0_u8 # portal "", statement name = its index
    o << 0_u8 << 0_u8         # parameter formats: all text
    o << (n >> 8).to_u8! << n.to_u8!
    at
  end

  def self.param(c : Conn, p : UInt8*, n : Int32) : Nil
    o = c.qbuf
    if n < 0 || p.null?
      o << 0xFF_u8 << 0xFF_u8 << 0xFF_u8 << 0xFF_u8 # NULL
      return
    end
    o.reserve(4)
    be32(o.ptr + o.len, n)
    o.len &+= 4
    o.write(p, n)
  end

  def self.param(c : Conn, v : Int64) : Nil
    o = c.qbuf
    at = o.len
    o.reserve(4)
    o.len &+= 4
    o << v
    be32(o.ptr + at, o.len &- at &- 4)
  end

  # A text[] literal: {"a","b\"c"}
  def self.param_array(c : Conn, data : UInt8*, offs : Int32*, lens : Int32*, n : Int32) : Nil
    o = c.qbuf
    at = o.len
    o.reserve(4)
    o.len &+= 4
    o << '{'.ord.to_u8
    n.times do |i|
      o << ','.ord.to_u8 if i > 0
      o << '"'.ord.to_u8
      p = data + offs[i]
      lens[i].times do |k|
        ch = p[k]
        o << '\\'.ord.to_u8 if ch == '"'.ord || ch == '\\'.ord
        o << ch
      end
      o << '"'.ord.to_u8
    end
    o << '}'.ord.to_u8
    be32(o.ptr + at, o.len &- at &- 4)
  end

  # Array parameters in text form: {1,2} or {"a","b\"c"}. Elements go between begin and
  # done, `i` being the element's index.
  def self.arr_begin(c : Conn) : Int32
    o = c.qbuf
    at = o.len
    o.reserve(4)
    o.len &+= 4
    o << '{'.ord.to_u8
    at
  end

  @[AlwaysInline]
  def self.arr_int(c : Conn, i : Int32, v : Int64) : Nil
    o = c.qbuf
    o << ','.ord.to_u8 if i > 0
    o << v
  end

  def self.arr_str(c : Conn, i : Int32, p : UInt8*, n : Int32) : Nil
    o = c.qbuf
    o << ','.ord.to_u8 if i > 0
    o << '"'.ord.to_u8
    n.times do |k|
      ch = p[k]
      o << '\\'.ord.to_u8 if ch == '"'.ord || ch == '\\'.ord
      o << ch
    end
    o << '"'.ord.to_u8
  end

  def self.arr_done(c : Conn, at : Int32) : Nil
    o = c.qbuf
    o << '}'.ord.to_u8
    be32(o.ptr + at, o.len &- at &- 4)
  end

  # Result formats (all text), then Execute (all rows); fixes the Bind length.
  def self.execute(c : Conn, at : Int32) : Nil
    c.statements += 1
    o = c.qbuf
    o << 0_u8 << 0_u8
    be32(o.ptr + (at &+ 1), o.len &- at &- 1)
    o << "E\0\0\0\x09\0\0\0\0\0"
  end

  # End a read/retry with Sync, or append a write to this round's transaction.
  def self.sync(c : Conn, job : Job) : Nil
    if @@group_commit && App.write?(job) && !job.solo
      group = c.group
      unless group
        group = Job.new(8)
        group.kind = App::K_WRITE_BATCH
        group.sub = LibC.malloc(48 * sizeof(Job)).as(Job*)
        group.tag_off = LibC.malloc(49 * 4).as(Int32*)
        group.tag_off[0] = 0
        c.group = group
        c.group_at = Sys.now_ns(Sys::CLOCK_MONOTONIC)
      end
      group.sub[group.nsub] = job
      group.nsub += 1
      group.tag_off[group.nsub] = c.statements
      return
    end
    c.qbuf << "S\0\0\0\x04"
    c.push(Query.new(job))
    c.statements = 0
  end

  # End of a batch: each connection's queued queries go out in one send.
  def self.flush : Nil
    @@n.times do |i|
      c = @@conns[i]
      next if c.sending || c.qbuf.len == 0 || !c.alive
      if group = c.group
        remaining = @@write_window - (Sys.now_ns(Sys::CLOCK_MONOTONIC) - c.group_at)
        if remaining > 0 && group.nsub < 48 && !c.group_ready
          Uring.arm_timer(remaining)
          next
        end
        finish_group(c)
      end
      t = c.sbuf
      c.sbuf = c.qbuf
      c.qbuf = t
      c.qbuf.clear
      c.group_ready = false
      c.soff = 0
      c.sending = true
      Uring.pg_send(c.idx, c.fd, c.sbuf.ptr, c.sbuf.len)
    end
  end

  def self.on_sent(i : Int32, res : Int32) : Nil
    c = @@conns[i]
    if res <= 0
      lost(c)
      return
    end
    c.soff &+= res
    if c.soff < c.sbuf.len
      Uring.pg_send(c.idx, c.fd, c.sbuf.ptr + c.soff, c.sbuf.len &- c.soff)
    else
      c.sending = false
      c.sbuf.clear
    end
  end

  # The connection to Postgres broke: everyone waiting on it gets a 500.
  def self.lost(c : Conn) : Nil
    return unless c.alive
    c.alive = false
    if group = c.group
      c.group = nil
      App.fail(group)
    end
    STDERR.puts "postgres connection #{c.idx} lost"
    while c.pending > 0
      job = c.front.value.job
      c.pop
      App.fail(job)
    end
  end

  # ---- replies ----

  def self.on_data(i : Int32, p : UInt8*, n : Int32) : Nil
    c = @@conns[i]
    if c.incap &- c.inlen < n
      c.incap = (c.inlen &+ n) &* 2
      c.inbuf = LibC.realloc(c.inbuf, c.incap).as(UInt8*)
    end
    (c.inbuf + c.inlen).copy_from(p, n)
    c.inlen &+= n
    b = c.inbuf
    off = 0
    while c.inlen &- off >= 5
      len = u32(b + (off &+ 1))
      break if c.inlen &- off < len &+ 1
      message(c, b[off], b + (off &+ 5), len &- 4)
      b = c.inbuf # a job finished in `message` may have queued more on this connection, never on inbuf
      off &+= len &+ 1
    end
    if off > 0
      b.move_from(b + off, c.inlen &- off)
      c.inlen &-= off
    end
  end

  @[AlwaysInline]
  def self.u32(p : UInt8*) : Int32
    (p[0].to_i32 << 24) | (p[1].to_i32 << 16) | (p[2].to_i32 << 8) | p[3].to_i32
  end

  SQLSTATE_UNIQUE = 0x3233353035_u64 # "23505"

  private def self.message(c : Conn, t : UInt8, p : UInt8*, n : Int32) : Nil
    return if c.pending == 0
    case t
    when 'D'.ord
      o = c.raw
      o << c.set
      o.reserve(4)
      (o.ptr + o.len).as(Int32*).value = n
      o.len &+= 4
      o.write(p, n)
    when 'C'.ord then c.set &+= 1
    when 'E'.ord
      c.err = true
      j = 0
      while j < n && p[j] != 0
        f = p[j]
        s = j &+ 1
        e = s
        while e < n && p[e] != 0
          e &+= 1
        end
        if f == 'C'.ord && e &- s == 5
          v = 0_u64
          5.times { |k| v = (v << 8) | p[s &+ k] }
          c.code = v
        elsif f == 'M'.ord && c.code != SQLSTATE_UNIQUE
          STDERR.puts "postgres: #{String.new(p + s, e &- s)}" if Sys.env("PG_DEBUG")
        end
        j = e &+ 1
      end
    when 'Z'.ord
      job = c.front.value.job
      c.pop
      res = Result.new(c.raw.ptr, c.raw.len, c.err, c.code)
      App.on_result(job, pointerof(res))
      c.set = 0_u8
      c.err = false
      c.code = 0_u64
      c.raw.clear
    end
  end

  # What a job gets back: its rows, or the error that stopped it.
  struct Result
    getter err : Bool
    getter code : UInt64

    def initialize(@p : UInt8*, @n : Int32, @err : Bool, @code : UInt64)
    end

    def ptr : UInt8*
      @p
    end

    def size : Int32
      @n
    end

    def unique? : Bool
      @err && @code == SQLSTATE_UNIQUE
    end

    # Rows of result set `set` (the set-th statement of the job), in order.
    def each(set : Int32, & : Row ->) : Nil
      off = 0
      while off < @n
        s = @p[off]
        len = (@p + (off &+ 1)).as(Int32*).value
        yield Row.new(@p + (off &+ 7)) if s == set # past the column count
        off &+= 5 &+ len
      end
    end

    def count(set : Int32) : Int32
      k = 0
      each(set) { k &+= 1 }
      k
    end

    def first(set : Int32) : Row?
      each(set) { |r| return r }
      nil
    end
  end

  # A cursor over one DataRow's columns, in order. NULL is length -1. Rows are read one
  # at a time, so the position lives in one shared cell: a Row can be passed around by
  # value and every reader still advances the same cursor.
  struct Row
    @@cur = Pointer(UInt8).null

    def initialize(p : UInt8*)
      @@cur = p
    end

    def ptr : UInt8*
      @@cur
    end

    @[AlwaysInline]
    def next : {UInt8*, Int32}
      p = @@cur
      l = Pg.u32(p)
      @@cur = p + 4 + (l < 0 ? 0 : l)
      {p + 4, l}
    end

    def skip : Nil
      self.next
    end

    def int : Int64
      v, l = self.next
      x = 0_i64
      neg = l > 0 && v[0] == '-'.ord
      i = neg ? 1 : 0
      while i < l
        x = x &* 10 &+ (v[i] &- 0x30)
        i &+= 1
      end
      neg ? -x : x
    end

    def bool : Bool
      v, l = self.next
      l > 0 && v[0] == 't'.ord
    end
  end
end

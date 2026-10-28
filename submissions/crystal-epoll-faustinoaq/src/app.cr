# The API: routing, validation, and the jobs that take a request through Postgres (and
# bcrypt) to its response.
module Resp
  JSON_HDR = "\r\nContent-Type: application/json\r\nContent-Length:       \r\n\r\n"
  GZIP_HDR = "\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\nVary: Accept-Encoding\r\nContent-Length:       \r\n\r\n"

  macro fixed(status, message)
    "HTTP/1.1 " + {{status}} + "\r\nContent-Type: application/json\r\nContent-Length: " +
      %({"errors":{"body":[") .bytesize.+({{message}}.bytesize + 4).to_s + "\r\n\r\n" +
      %({"errors":{"body":[") + {{message}} + %("]}})
  end

  NOT_FOUND        = fixed("404 Not Found", "not found")
  ARTICLE_404      = fixed("404 Not Found", "article not found")
  PROFILE_404      = fixed("404 Not Found", "profile not found")
  COMMENT_404      = fixed("404 Not Found", "comment not found")
  UNAUTHORIZED     = fixed("401 Unauthorized", "unauthorized")
  BAD_LOGIN        = fixed("401 Unauthorized", "invalid email or password")
  FORBIDDEN        = fixed("403 Forbidden", "not the author")
  INVALID          = fixed("422 Unprocessable Entity", "invalid body")
  BAD_PAGE         = fixed("422 Unprocessable Entity", "limit must be 1-100 and offset >= 0")
  TAKEN            = fixed("422 Unprocessable Entity", "username or email is already taken")
  INTERNAL         = fixed("500 Internal Server Error", "internal error")
  NO_CONTENT       = "HTTP/1.1 204 No Content\r\n\r\n"
  BAD_REQUEST      = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"

  # Writes the status line and headers with a blank Content-Length; returns the body start.
  @[AlwaysInline]
  def self.open(o : Buf, status : String) : Int32
    o << "HTTP/1.1 " << status << JSON_HDR
    o.len
  end

  @[AlwaysInline]
  def self.close(o : Buf, body_start : Int32) : Nil
    n = o.len &- body_start
    p = o.ptr + body_start - 4 - 1 # last pad byte
    loop do
      p.value = 48_u8 &+ (n % 10).to_u8!
      n //= 10
      break if n == 0
      p -= 1
    end
  end
end

# One request on its way through Postgres and bcrypt. Lives from the request to its
# response (malloc'd: with -Dgc_none `new` is malloc, and `App.finish` frees it).
class Job
  # string slots
  F_A        = 0 # username / slug / email / title
  F_B        = 1 # email / description / comment body
  F_C        = 2 # username / body
  F_PASSWORD = 3
  F_BIO      = 4
  F_IMAGE    = 5
  F_TOKEN    = 6 # the token the request presented
  F_FILTER   = 7 # list filter value
  NF         = 8

  property fd = 0
  property gen = 0_u16
  property kind = 0
  property step = 0
  property gzip = false
  property viewer = 0_i64
  property id = 0_i64
  property limit = 20_i64
  property offset = 0_i64
  property filter = 0 # 0 none, 1 tag, 2 author, 3 favorited
  property data : UInt8*
  property dlen = 0
  property off = StaticArray(Int32, 8).new(0)
  property len = StaticArray(Int32, 8).new(-1) # -1: absent or null
  property ntags = 0
  property tag_off = Pointer(Int32).null
  property tag_len = Pointer(Int32).null
  property hash = StaticArray(UInt8, 128).new(0_u8)
  property hash_len = 0
  property bc_mode = 0_u8
  property bc_ok = false
  property row = Pointer(UInt8).null # login: the user row, kept across the bcrypt check
  property sub = Pointer(Job).null    # a read batch: its requests
  property nsub = 0
  property ids = Pointer(Int64).null
  property nids = 0
  property solo = false
  property read = false # a read sent on its own: counts as a read batch in flight

  def initialize(cap : Int32)
    @data = LibC.malloc(cap).as(UInt8*)
  end

  # The hash's bytes in place (the `hash` getter would hand out a copy).
  def hash_ptr : UInt8*
    pointerof(@hash).as(UInt8*)
  end

  def unset(f : Int32) : Nil
    @len[f] = -1
  end

  def has?(f : Int32) : Bool
    @len[f] >= 0
  end

  def ptr(f : Int32) : UInt8*
    @len[f] < 0 ? Pointer(UInt8).null : @data + @off[f]
  end

  # Copies a string in (JSON-unescaped or percent-decoded as asked), NUL-terminated.
  def put(f : Int32, p : UInt8*, n : Int32, json_escaped : Bool = false, url : Int32 = 0) : Nil
    d = @data + @dlen
    l = if json_escaped
          Json.unescape(p, n, d)
        elsif url > 0
          App.url_decode(p, n, d, url == 2)
        else
          d.copy_from(p, n)
          n
        end
    d[l] = 0_u8
    @off[f] = @dlen
    @len[f] = l
    @dlen &+= l &+ 1
  end

  def free : Nil
    LibC.free(@data)
    LibC.free(@tag_off) unless @tag_off.null?
    LibC.free(@tag_len) unless @tag_len.null?
    LibC.free(@row) unless @row.null?
    LibC.free(@ids) unless @ids.null?
    LibC.free(@sub.as(Void*)) unless @sub.null?
    GC.free(self.as(Void*))
  end
end

module App
  K_TAGS             =  1
  K_USER_GET         =  2
  K_USER_PUT         =  3
  K_REGISTER         =  4
  K_LOGIN            =  5
  K_PROFILE          =  6
  K_FOLLOW           =  7
  K_UNFOLLOW         =  8
  K_LIST             =  9
  K_FEED             = 10
  K_ARTICLE          = 11
  K_CREATE_ARTICLE   = 12
  K_UPDATE_ARTICLE   = 13
  K_DELETE_ARTICLE   = 14
  K_FAVORITE         = 15
  K_UNFAVORITE       = 16
  K_COMMENTS         = 17
  K_ADD_COMMENT      = 18
  K_DELETE_COMMENT   = 19
  K_WRITE_BATCH      = 21
  K_BATCH            = 20

  # Read batch classes: reads of one class share statements.
  B_TAGS     = 0
  B_USER     = 1
  B_PROFILE  = 2
  B_LIST     = 3 # + filter
  B_FEED     = 7
  B_ARTICLE  = 8
  B_COMMENTS = 9
  B_MIXED    = 10
  NB         = 11
  BATCH_MAX  = 1024

  GZIP_MIN = 1024

  @@body = Buf.new(16)
  @@deflate = Pointer(Void).null

  @@shared : Bool = Sys.env("SHARED_READS") != "0"
  @@synth = Buf.new(16)
  @@bq = Pointer(Pointer(Job)).null # per class, the reads waiting for a connection
  @@bn = Pointer(Int32).null
  @@bcap = Pointer(Int32).null
  @@rr = 0
  @@depth = 2
  @@clock : Bool = Sys.env("READ_CLOCK") != "0"
  @@window = 0_i64 # ns
  @@last = 0_i64
  @@rinf = 0       # read batches in flight

  @@dbg = false
  @@gzip = true

  def self.init(depth : Int32, window_us : Int32) : Nil
    @@window = window_us.to_i64 &* 1000
    @@dbg = !Sys.env("BATCH_DEBUG").nil?
    @@gzip = Sys.env("GZIP") != "0"
    @@depth = depth
    @@synth = Buf.new(65536)
    @@bq = LibC.malloc(NB * sizeof(Pointer(Job))).as(Pointer(Job)*)
    @@bn = LibC.malloc(NB * 4).as(Int32*)
    @@bcap = LibC.malloc(NB * 4).as(Int32*)
    NB.times do |i|
      @@bcap[i] = 64
      @@bn[i] = 0
      @@bq[i] = LibC.malloc(64 * sizeof(Job)).as(Job*)
    end
    @@body = Buf.new(65536)
    @@deflate = LibDeflate.alloc_compressor(1)
  end

  # ---- starting a job ----

  def self.new_job(kind : Int32, r : Http::Req*) : Job
    rv = r.value
    cap = rv.body_len &+ rv.path_len &+ rv.query_len &+ (rv.auth_len > 0 ? rv.auth_len : 0) &+ 64
    j = Job.new(cap)
    j.kind = kind
    j.fd = Server.cur_fd
    j.gen = Server.conn(j.fd).value.gen
    j.gzip = rv.gzip
    j
  end

  # Sends the job's next statements (or hands it to bcrypt) and marks the client busy.
  def self.go(j : Job) : Nil
    Server.conn(j.fd).value.busy = true
    b = bclass(j)
    if b < 0
      step(j)
      return
    end
    n = @@bn[b]
    if n == @@bcap[b]
      @@bcap[b] = n &* 2
      @@bq[b] = LibC.realloc(@@bq[b].as(Void*), n &* 2 &* sizeof(Job)).as(Job*)
    end
    @@bq[b][n] = j
    @@bn[b] = n &+ 1
  end

  private def self.bclass(j : Job) : Int32
    if @@shared && (j.kind == K_LIST || j.kind == K_FEED || j.kind == K_ARTICLE)
      return B_MIXED
    end
    case j.kind
    when K_TAGS     then B_TAGS
    when K_USER_GET then B_USER
    when K_PROFILE  then B_PROFILE
    when K_LIST     then B_LIST &+ j.filter
    when K_FEED     then B_FEED
    when K_ARTICLE  then B_ARTICLE
    when K_COMMENTS then B_COMMENTS
    else                 -1
    end
  end

  # End of an event-loop round: dispatch the waiting reads on one process clock.
  # The clock also runs when Postgres is idle, allowing larger batches after a
  # fast query. READ_CLOCK=0 restores the earlier in-flight-only collection window.
  # Each connection takes at most `depth` requests at a time.
  def self.dispatch : Nil
    any = false
    NB.times { |b| any = true if @@bn[b] > 0 }
    return unless any
    now = Sys.now_ns(Sys::CLOCK_MONOTONIC)
    if (@@clock || @@rinf > 0) && now &- @@last < @@window
      Uring.arm_timer(@@last &+ @@window &- now)
      return
    end
    sent = false
    NB.times do
      b = @@rr
      @@rr = @@rr == NB &- 1 ? 0 : @@rr &+ 1
      n = @@bn[b]
      next if n == 0
      c = Pg.pick
      unless c
        n.times { |i| fail(@@bq[b][i]) }
        @@bn[b] = 0
        next
      end
      break if c.pending >= @@depth
      take = n > BATCH_MAX ? BATCH_MAX : n
      q = @@bq[b]
      sent = true
      @@rinf &+= 1
      if take == 1 && b != B_MIXED
        q[0].read = true
        step(q[0])
      else
        bj = Job.new(8)
        bj.kind = K_BATCH
        bj.step = b
        bj.sub = LibC.malloc(take &* sizeof(Job)).as(Job*)
        bj.sub.copy_from(q, take)
        bj.nsub = take
        STDERR.puts "batch class #{b} x#{take}" if @@dbg
        send_batch(c, bj)
      end
      q.move_from(q + take, n &- take) if take < n
      @@bn[b] = n &- take
    end
    @@last = now if sent
  end

  # A read batch (or lone read) is done.
  @[AlwaysInline]
  private def self.read_done(j : Job) : Nil
    if j.kind == K_BATCH || j.read
      @@rinf &-= 1
      j.read = false
    end
  end

  private def self.arr_viewers(c : Pg::Conn, s : Job*, n : Int32) : Nil
    at = Pg.arr_begin(c)
    n.times { |i| Pg.arr_int(c, i, s[i].viewer) }
    Pg.arr_done(c, at)
  end

  private def self.arr_field(c : Pg::Conn, s : Job*, n : Int32, f : Int32) : Nil
    at = Pg.arr_begin(c)
    n.times { |i| Pg.arr_str(c, i, s[i].ptr(f), s[i].len[f]) }
    Pg.arr_done(c, at)
  end

  private def self.arr_pages(c : Pg::Conn, s : Job*, n : Int32) : Nil
    arr_viewers(c, s, n)
    at = Pg.arr_begin(c)
    n.times { |i| Pg.arr_int(c, i, s[i].limit) }
    Pg.arr_done(c, at)
    at = Pg.arr_begin(c)
    n.times { |i| Pg.arr_int(c, i, s[i].offset) }
    Pg.arr_done(c, at)
  end

  private def self.send_batch(c : Pg::Conn, bj : Job) : Nil
    s = bj.sub
    n = bj.nsub
    b = bj.step
    case b
    when B_MIXED
      at = Pg.bind(c, Sql::B_MIXED, 5)
      arr_pages(c, s, n)
      key = Pg.arr_begin(c)
      n.times do |i|
        j = s[i]
        if j.kind == K_LIST && j.filter == 0 || j.kind == K_FEED
          Pg.arr_str(c, i, "".to_unsafe, 0)
        else
          Pg.arr_str(c, i, j.ptr(Job::F_FILTER), j.len[Job::F_FILTER])
        end
      end
      Pg.arr_done(c, key)
      key = Pg.arr_begin(c)
      n.times do |i|
        j = s[i]
        Pg.arr_int(c, i, j.kind == K_FEED ? 4_i64 : j.kind == K_ARTICLE ? 5_i64 : j.filter.to_i64)
      end
      Pg.arr_done(c, key)
      Pg.execute(c, at)
    when B_TAGS
      Pg.execute(c, Pg.bind(c, Sql::TAGS, 0))
    when B_USER
      at = Pg.bind(c, Sql::B_USER, 1)
      arr_viewers(c, s, n)
      Pg.execute(c, at)
    when B_PROFILE
      at = Pg.bind(c, Sql::B_PROFILE, 2)
      arr_viewers(c, s, n)
      arr_field(c, s, n, Job::F_A)
      Pg.execute(c, at)
    when B_FEED
      at = Pg.bind(c, Sql::B_FEED, 3)
      arr_pages(c, s, n)
      Pg.execute(c, at)
      at = Pg.bind(c, Sql::B_FEED_COUNT, 1)
      arr_viewers(c, s, n)
      Pg.execute(c, at)
    when B_ARTICLE
      at = Pg.bind(c, Sql::B_ARTICLE, 2)
      arr_viewers(c, s, n)
      arr_field(c, s, n, Job::F_FILTER)
      Pg.execute(c, at)
    when B_COMMENTS
      at = Pg.bind(c, Sql::B_ARTICLE_ID, 1)
      arr_field(c, s, n, Job::F_FILTER)
      Pg.execute(c, at)
      at = Pg.bind(c, Sql::B_COMMENTS, 2)
      arr_viewers(c, s, n)
      arr_field(c, s, n, Job::F_FILTER)
      Pg.execute(c, at)
    else # the lists
      f = b &- B_LIST
      at = Pg.bind(c, Sql::B_LIST &+ f, f == 0 ? 3 : 4)
      arr_pages(c, s, n)
      arr_field(c, s, n, Job::F_FILTER) if f > 0
      Pg.execute(c, at)
      at = Pg.bind(c, Sql::B_COUNT &+ f, 1)
      if f == 0
        Pg.param(c, n.to_i64)
      else
        arr_field(c, s, n, Job::F_FILTER)
      end
      Pg.execute(c, at)
    end
    Pg.sync(c, bj)
  end

  # A batch's rows, split back into each request's own result (the ordinal column taken
  # off), and each request answered exactly as if it had run alone. If the batch failed
  # (a key Postgres rejects, say), its requests run again one by one.
  private def self.on_batch(bj : Job, res : Pg::Result*) : Nil
    r = res.value
    s = bj.sub
    n = bj.nsub
    if r.err
      n.times do |i|
        @@rinf &+= 1
        s[i].read = true
        step(s[i])
      end
    elsif bj.step == B_MIXED
      on_shared(bj, r)
      return
    elsif bj.step == B_TAGS
      n.times { |i| on_result(s[i], res) }
    else
      p = r.ptr
      len = r.size
      cur0 = 0
      cur1 = 0
      sy = @@synth
      n.times do |i|
        sy.clear
        cur0 = take_rows(p, len, cur0, 0_u8, i &+ 1, sy)
        cur1 = take_rows(p, len, cur1, 1_u8, i &+ 1, sy)
        sub = Pg::Result.new(sy.ptr, sy.len, false, 0_u64)
        on_result(s[i], pointerof(sub))
      end
    end
    bj.free
  end

  private def self.shared_ids(c : Pg::Conn, bj : Job) : Nil
    at = Pg.arr_begin(c)
    bj.nids.times { |i| Pg.arr_int(c, i, bj.ids[i]) }
    Pg.arr_done(c, at)
  end

  # The (article, viewer) pairs of signed-in requests: article ids, or with `viewers` their viewers.
  private def self.flag_pairs(c : Pg::Conn, bj : Job, r : Pg::Result, viewers : Bool) : Nil
    at = Pg.arr_begin(c)
    n = 0
    r.each(0) do |row|
      v = bj.sub[row.int.to_i32 - 1].viewer
      id = row.int
      if v > 0 && id > 0
        Pg.arr_int(c, n, viewers ? v : id)
        n += 1
      end
    end
    Pg.arr_done(c, at)
  end

  # Phase A keeps only the request/page mapping and counts. Phase B reads the
  # union once, then the application assembles each request's normal result rows.
  private def self.on_shared(bj : Job, r : Pg::Result) : Nil
    if bj.id == 0
      c = Pg.pick
      unless c
        bj.nsub.times { |i| fixed(bj.sub[i], Resp::INTERNAL) }
        bj.free
        return
      end
      bj.row = LibC.malloc(r.size).as(UInt8*)
      bj.row.copy_from(r.ptr, r.size)
      bj.id = r.size.to_i64
      # ANY scans must receive the distinct union too. Sending repeated page IDs
      # makes PostgreSQL sort a large duplicate array again for every viewer.
      nrows = r.count(0)
      bj.ids = LibC.malloc((nrows + 1) * 8).as(Int64*)
      cap = 8_u64
      while cap < nrows * 2
        cap *= 2
      end
      seen = LibSys.calloc(cap, 8).as(Int64*)
      r.each(0) do |row|
        row.skip
        id = row.int
        if id > 0
          slot = (id.to_u64! &* 0x9e3779b97f4a7c15_u64) & (cap - 1)
          while seen[slot] != 0 && seen[slot] != id
            slot = (slot + 1) & (cap - 1)
          end
          if seen[slot] == 0
            seen[slot] = id
            bj.ids[bj.nids] = id
            bj.nids += 1
          end
        end
      end
      LibC.free(seen)
      at = Pg.bind(c, Sql::SHARED_ARTICLES, 2)
      shared_ids(c, bj)
      full = Pg.arr_begin(c)
      n = 0
      r.each(0) do |row|
        ord = row.int.to_i32 - 1
        id = row.int
        if id > 0 && bj.sub[ord].kind == K_ARTICLE
          Pg.arr_int(c, n, id)
          n += 1
        end
      end
      Pg.arr_done(c, full)
      Pg.execute(c, at)
      {Sql::SHARED_FAV, Sql::SHARED_FOLLOW}.each do |stmt|
        at = Pg.bind(c, stmt, 2)
        flag_pairs(c, bj, r, false)
        flag_pairs(c, bj, r, true)
        Pg.execute(c, at)
      end
      @@rinf += 1
      Pg.sync(c, bj)
      return
    end

    count = r.count(0)
    ids = LibC.malloc((count + 1) * 8).as(Int64*)
    authors = LibC.malloc((count + 1) * 8).as(Int64*)
    rows = LibC.malloc((count + 1) * sizeof(Pointer(UInt8))).as(UInt8**)
    idx = 0
    r.each(0) do |row|
      rows[idx] = row.ptr
      ids[idx] = row.int
      13.times { row.skip }
      authors[idx] = row.int
      idx += 1
    end
    fav = FlagSet.new(r, 1)
    follows = FlagSet.new(r, 2)
    off = 0
    bj.nsub.times do |i|
      sy = @@synth
      sy.clear
      j = bj.sub[i]
      list = j.kind != K_ARTICLE
      countptr = Pointer(UInt8).null
      while off < bj.id
        size = (bj.row + off + 1).as(Int32*).value
        row = Pg::Row.new(bj.row + off + 7)
        ord = row.int.to_i32
        break if ord != i + 1
        id = row.int
        countptr = row.ptr
        # Phase-B rows are ordered by id; a binary search avoids a mutable cache.
        lo = 0
        hi = count
        while lo < hi
          mid = (lo + hi) // 2
          if ids[mid] < id
            lo = mid + 1
          else
            hi = mid
          end
        end
        if lo < count && ids[lo] == id
          p = rows[lo]
          start = sy.len
          sy << 0_u8
          sy.reserve(6)
          sy.len += 4
          sy << 0_u8 << (list ? 13_u8 : 14_u8)
          14.times do |col|
            len = Pg.u32(p)
            bytes = 4 + (len < 0 ? 0 : len)
            if col == 9 || col == 13
              flag = col == 9 ? fav.has?(j.viewer, id) : follows.has?(j.viewer, authors[lo])
              sy << 0_u8 << 0_u8 << 0_u8 << 1_u8 << (flag ? 116_u8 : 102_u8)
            elsif !(list && col == 4)
              sy.write(p, bytes)
            end
            p += bytes
          end
          (sy.ptr + start + 1).as(Int32*).value = sy.len - start - 5
        end
        off += size + 5
      end
      if list && !countptr.null?
        start = sy.len
        sy << 1_u8
        sy.reserve(6)
        sy.len += 4
        sy << 0_u8 << 1_u8
        sy.write(countptr, 4 + Pg.u32(countptr))
        (sy.ptr + start + 1).as(Int32*).value = sy.len - start - 5
      end
      sub = Pg::Result.new(sy.ptr, sy.len, false, 0_u64)
      on_result(j, pointerof(sub))
    end
    fav.free
    follows.free
    LibC.free(ids)
    LibC.free(authors)
    LibC.free(rows)
    bj.free
  end

  # From `off`, the rows of `set` whose ordinal is `ord`, copied to `sy` without it;
  # returns where the next ordinal's rows start.
  private def self.take_rows(p : UInt8*, len : Int32, off : Int32, set : UInt8, ord : Int32, sy : Buf) : Int32
    while off < len
      rl = (p + (off &+ 1)).as(Int32*).value
      if p[off] != set
        off &+= 5 &+ rl
        next
      end
      q = p + (off &+ 5)
      nc = (q[0].to_i32 << 8) | q[1].to_i32
      l1 = Pg.u32(q + 2)
      v = 0
      l1.times { |k| v = v &* 10 &+ (q[6 &+ k] &- 0x30) }
      break if v != ord
      rest = rl &- 6 &- l1
      sy << set
      sy.reserve(4)
      (sy.ptr + sy.len).as(Int32*).value = rest &+ 2
      sy.len &+= 4
      sy << ((nc &- 1) >> 8).to_u8! << (nc &- 1).to_u8!
      sy.write(q + (6 &+ l1), rest)
      off &+= 5 &+ rl
    end
    off
  end

  def self.write?(j : Job) : Bool
    case j.kind
    when K_USER_PUT, K_REGISTER, K_FOLLOW, K_UNFOLLOW, K_CREATE_ARTICLE,
         K_UPDATE_ARTICLE, K_DELETE_ARTICLE, K_FAVORITE, K_UNFAVORITE,
         K_ADD_COMMENT, K_DELETE_COMMENT
      true
    else
      false
    end
  end

  private def self.on_write_batch(group : Job, res : Pg::Result*) : Nil
    r = res.value
    if r.err
      # A Sync closes the failed implicit transaction: all its writes rolled back.
      # Retry each request alone, preserving ordinary per-request errors.
      group.nsub.times do |i|
        j = group.sub[i]
        j.solo = true
        step(j)
      end
    else
      off = 0
      group.nsub.times do |i|
        sy = @@synth
        sy.clear
        lo = group.tag_off[i]
        hi = group.tag_off[i + 1]
        while off < r.size
          set = r.ptr[off].to_i32
          break if set >= hi
          len = (r.ptr + off + 1).as(Int32*).value
          sy << (set - lo).to_u8
          sy.write(r.ptr + off + 1, len + 4)
          off += len + 5
        end
        sub = Pg::Result.new(sy.ptr, sy.len, false, 0_u64)
        on_result(group.sub[i], pointerof(sub))
      end
    end
    group.free
  end

  private def self.step(j : Job) : Nil
    if j.kind == K_REGISTER || (j.kind == K_USER_PUT && j.step == 0 && j.has?(Job::F_PASSWORD))
      if j.step == 0
        j.bc_mode = Bcrypt::MODE_HASH
        j.step = 1
        Bcrypt.submit(j)
        return
      end
    end
    c = write?(j) && !j.solo ? Pg.write_pick : Pg.pick
    unless c
      fail(j)
      return
    end
    v = j.viewer
    case j.kind
    when K_TAGS
      Pg.execute(c, Pg.bind(c, Sql::TAGS, 0))
    when K_USER_GET
      at = Pg.bind(c, Sql::USER_BY_ID, 1)
      Pg.param(c, v)
      Pg.execute(c, at)
    when K_USER_PUT
      at = Pg.bind(c, Sql::UPDATE_USER, 6)
      Pg.param(c, v)
      str(c, j, Job::F_B) # email
      str(c, j, Job::F_A) # username
      if j.hash_len > 0
        Pg.param(c, j.hash_ptr, j.hash_len)
      else
        Pg.param(c, Pointer(UInt8).null, -1)
      end
      str(c, j, Job::F_BIO)
      str(c, j, Job::F_IMAGE)
      Pg.execute(c, at)
    when K_REGISTER
      at = Pg.bind(c, Sql::REGISTER, 3)
      str(c, j, Job::F_A)
      str(c, j, Job::F_B)
      Pg.param(c, j.hash_ptr, j.hash_len)
      Pg.execute(c, at)
    when K_LOGIN
      at = Pg.bind(c, Sql::LOGIN, 1)
      str(c, j, Job::F_B)
      Pg.execute(c, at)
    when K_PROFILE, K_FOLLOW, K_UNFOLLOW
      at = Pg.bind(c, j.kind == K_PROFILE ? Sql::PROFILE : j.kind == K_FOLLOW ? Sql::FOLLOW : Sql::UNFOLLOW, 2)
      Pg.param(c, v)
      str(c, j, Job::F_A)
      Pg.execute(c, at)
    when K_LIST
      f = j.filter
      at = Pg.bind(c, Sql::LIST_ALL &+ f, f == 0 ? 3 : 4)
      Pg.param(c, v)
      Pg.param(c, j.limit)
      Pg.param(c, j.offset)
      str(c, j, Job::F_FILTER) if f > 0
      Pg.execute(c, at)
      at = Pg.bind(c, Sql::COUNT_ALL &+ f, f == 0 ? 0 : 1)
      str(c, j, Job::F_FILTER) if f > 0
      Pg.execute(c, at)
    when K_FEED
      at = Pg.bind(c, Sql::FEED, 3)
      Pg.param(c, v)
      Pg.param(c, j.limit)
      Pg.param(c, j.offset)
      Pg.execute(c, at)
      at = Pg.bind(c, Sql::FEED_COUNT, 1)
      Pg.param(c, v)
      Pg.execute(c, at)
    when K_ARTICLE
      by_slug(c, j)
    when K_CREATE_ARTICLE
      at = Pg.bind(c, Sql::INSERT_ARTICLE, 4)
      Pg.param(c, v)
      str(c, j, Job::F_A)
      str(c, j, Job::F_B)
      str(c, j, Job::F_C)
      Pg.execute(c, at)
      if j.ntags > 0
        {Sql::INSERT_TAGS, Sql::INSERT_ART_TAGS}.each do |s|
          at = Pg.bind(c, s, 1)
          Pg.param_array(c, j.data, j.tag_off, j.tag_len, j.ntags)
          Pg.execute(c, at)
        end
      end
      at = Pg.bind(c, Sql::ARTICLE_NEW, 1)
      Pg.param(c, v)
      Pg.execute(c, at)
    when K_UPDATE_ARTICLE
      if j.step == 0
        at = Pg.bind(c, Sql::UPDATE_ARTICLE, 5)
        str(c, j, Job::F_FILTER) # slug
        str(c, j, Job::F_A)
        str(c, j, Job::F_B)
        str(c, j, Job::F_C)
        Pg.param(c, v)
        Pg.execute(c, at)
      else
        at = Pg.bind(c, Sql::ARTICLE_BY_ID, 2)
        Pg.param(c, v)
        Pg.param(c, j.id)
        Pg.execute(c, at)
      end
    when K_DELETE_ARTICLE
      at = Pg.bind(c, Sql::DELETE_ARTICLE, 2)
      str(c, j, Job::F_FILTER)
      Pg.param(c, v)
      Pg.execute(c, at)
    when K_FAVORITE, K_UNFAVORITE
      at = Pg.bind(c, j.kind == K_FAVORITE ? Sql::FAVORITE : Sql::UNFAVORITE, 2)
      Pg.param(c, v)
      str(c, j, Job::F_FILTER)
      Pg.execute(c, at)
      by_slug(c, j)
    when K_COMMENTS
      at = Pg.bind(c, Sql::ARTICLE_ID, 1)
      str(c, j, Job::F_FILTER)
      Pg.execute(c, at)
      at = Pg.bind(c, Sql::COMMENTS, 2)
      Pg.param(c, v)
      str(c, j, Job::F_FILTER)
      Pg.execute(c, at)
    when K_ADD_COMMENT
      at = Pg.bind(c, Sql::ADD_COMMENT, 3)
      str(c, j, Job::F_FILTER)
      Pg.param(c, v)
      str(c, j, Job::F_B)
      Pg.execute(c, at)
    when K_DELETE_COMMENT
      at = Pg.bind(c, Sql::DELETE_COMMENT, 3)
      Pg.param(c, j.id)
      str(c, j, Job::F_FILTER)
      Pg.param(c, v)
      Pg.execute(c, at)
    end
    Pg.sync(c, j)
  end

  private def self.by_slug(c : Pg::Conn, j : Job) : Nil
    at = Pg.bind(c, Sql::ARTICLE_BY_SLUG, 2)
    Pg.param(c, j.viewer)
    str(c, j, Job::F_FILTER)
    Pg.execute(c, at)
  end

  @[AlwaysInline]
  private def self.str(c : Pg::Conn, j : Job, f : Int32) : Nil
    Pg.param(c, j.ptr(f), j.len[f])
  end

  # ---- results ----

  def self.on_bcrypt(j : Job) : Nil
    if j.kind == K_LOGIN
      if j.bc_ok
        b = @@body
        b.clear
        b << %({"user":)
        user(b, Pg::Row.new(j.row), j, true)
        b << '}'.ord.to_u8
        reply(j, "200 OK", b)
      else
        fixed(j, Resp::BAD_LOGIN)
      end
      return
    end
    unless j.bc_ok
      fixed(j, Resp::INVALID) # password bcrypt can't take
      return
    end
    step(j)
  end

  def self.on_result(j : Job, res : Pg::Result*) : Nil
    read_done(j)
    if j.kind == K_WRITE_BATCH
      on_write_batch(j, res)
      return
    end
    if j.kind == K_BATCH
      on_batch(j, res)
      return
    end
    r = res.value
    if r.err
      if r.unique? && (j.kind == K_REGISTER || j.kind == K_USER_PUT)
        fixed(j, Resp::TAKEN)
      else
        fail(j)
      end
      return
    end
    b = @@body
    b.clear
    case j.kind
    when K_TAGS
      b << %({"tags":[)
      k = 0
      r.each(0) do |row|
        b << ','.ord.to_u8 if k > 0
        k &+= 1
        p, l = row.next
        str(b, p, l)
      end
      b << "]}"
      reply(j, "200 OK", b)
    when K_USER_GET, K_USER_PUT, K_REGISTER
      row = r.first(0)
      unless row
        fixed(j, j.kind == K_REGISTER ? Resp::INTERNAL : Resp::UNAUTHORIZED)
        return
      end
      b << %({"user":)
      user(b, row, j, j.kind == K_REGISTER)
      b << '}'.ord.to_u8
      reply(j, j.kind == K_REGISTER ? "201 Created" : "200 OK", b)
    when K_LOGIN
      row = r.first(0)
      unless row
        fixed(j, Resp::BAD_LOGIN)
        return
      end
      # keep the row; the stored hash is its 6th column
      start = row.ptr
      5.times { row.skip }
      hp, hl = row.next
      if hl <= 0 || hl >= Bcrypt::HASH_MAX || j.len[Job::F_PASSWORD] > 72 ||
         !LibC.memchr(j.ptr(Job::F_PASSWORD), 0, j.len[Job::F_PASSWORD]).null?
        fixed(j, Resp::BAD_LOGIN)
        return
      end
      j.hash_ptr.copy_from(hp, hl)
      j.hash_ptr[hl] = 0_u8
      j.hash_len = hl
      n = (hp + hl - start).to_i32
      j.row = LibC.malloc(n).as(UInt8*)
      j.row.copy_from(start, n)
      j.bc_mode = Bcrypt::MODE_CHECK
      Bcrypt.submit(j)
    when K_PROFILE, K_FOLLOW, K_UNFOLLOW
      row = r.first(0)
      unless row
        fixed(j, Resp::PROFILE_404)
        return
      end
      b << %({"profile":)
      row.skip if j.kind == K_PROFILE # id
      profile(b, row, j.kind == K_PROFILE ? 0 : j.kind == K_FOLLOW ? 1 : 2)
      b << '}'.ord.to_u8
      reply(j, "200 OK", b)
    when K_LIST, K_FEED
      b << %({"articles":[)
      k = 0
      r.each(0) do |row|
        b << ','.ord.to_u8 if k > 0
        k &+= 1
        article(b, row, false)
      end
      b << %(],"articlesCount":)
      if cr = r.first(1)
        b << cr.int
      else
        b << '0'.ord.to_u8
      end
      b << '}'.ord.to_u8
      reply(j, "200 OK", b)
    when K_ARTICLE, K_CREATE_ARTICLE, K_FAVORITE, K_UNFAVORITE
      set = case j.kind
            when K_ARTICLE        then 0
            when K_CREATE_ARTICLE then j.ntags > 0 ? 3 : 1
            else                       1
            end
      one_article(j, r, set, j.kind == K_CREATE_ARTICLE ? "201 Created" : "200 OK")
    when K_UPDATE_ARTICLE
      if j.step == 1
        one_article(j, r, 0, "200 OK")
        return
      end
      row = r.first(0)
      unless row
        fixed(j, Resp::ARTICLE_404)
        return
      end
      j.id = row.int
      if row.int != j.viewer
        fixed(j, Resp::FORBIDDEN)
        return
      end
      j.step = 1
      step(j)
    when K_DELETE_ARTICLE, K_DELETE_COMMENT
      row = r.first(0)
      unless row
        fixed(j, j.kind == K_DELETE_ARTICLE ? Resp::ARTICLE_404 : Resp::COMMENT_404)
        return
      end
      fixed(j, row.int == j.viewer ? Resp::NO_CONTENT : Resp::FORBIDDEN)
    when K_COMMENTS
      unless r.first(0)
        fixed(j, Resp::ARTICLE_404)
        return
      end
      b << %({"comments":[)
      k = 0
      r.each(1) do |row|
        b << ','.ord.to_u8 if k > 0
        k &+= 1
        comment(b, row, true)
      end
      b << "]}"
      reply(j, "200 OK", b)
    when K_ADD_COMMENT
      row = r.first(0)
      unless row
        fixed(j, Resp::ARTICLE_404)
        return
      end
      b << %({"comment":)
      comment(b, row, false)
      b << '}'.ord.to_u8
      reply(j, "201 Created", b)
    else
      fail(j)
    end
  end

  private def self.one_article(j : Job, r : Pg::Result, set : Int32, status : String) : Nil
    row = r.first(set)
    unless row
      fixed(j, Resp::ARTICLE_404)
      return
    end
    b = @@body
    b << %({"article":)
    article(b, row, true)
    b << '}'.ord.to_u8
    reply(j, status, b)
  end

  # ---- JSON from rows ----

  @[AlwaysInline]
  def self.str(b : Buf, p : UInt8*, l : Int32) : Nil
    if l < 0
      b << "null"
    else
      b << '"'.ord.to_u8
      b.json_escape(p, l)
      b << '"'.ord.to_u8
    end
  end

  @[AlwaysInline]
  private def self.str(b : Buf, row : Pg::Row) : Nil
    p, l = row.next
    str(b, p, l)
  end

  # "2025-04-01 12:00:00.123456+00" -> "2025-04-01T12:00:00.123Z" (UTC session, truncated)
  private def self.timestamp(b : Buf, row : Pg::Row) : Nil
    p, n = row.next
    b << '"'.ord.to_u8
    if n < 19
      b.write(p, n) if n > 0
    else
      b.write(p, 10)
      b << 'T'.ord.to_u8
      b.write(p + 11, 8)
      b << '.'.ord.to_u8
      i = 19
      d = 0
      if i < n && p[i] == '.'.ord
        i &+= 1
        while d < 3 && i < n && p[i] >= 0x30 && p[i] <= 0x39
          b << p[i]
          i &+= 1
          d &+= 1
        end
      end
      while d < 3
        b << 0x30_u8
        d &+= 1
      end
      b << 'Z'.ord.to_u8
    end
    b << '"'.ord.to_u8
  end

  # A text[] in Postgres' text form ({a,"b c","d\"e"}) as a JSON array of strings.
  private def self.text_array(b : Buf, row : Pg::Row) : Nil
    p, n = row.next
    b << '['.ord.to_u8
    i = 1 # past '{'
    first = true
    while i < n &- 1
      b << ','.ord.to_u8 unless first
      first = false
      b << '"'.ord.to_u8
      if p[i] == '"'.ord
        i &+= 1
        s = i
        while i < n && p[i] != '"'.ord
          if p[i] == '\\'.ord
            b.json_escape(p + s, i &- s) if i > s
            i &+= 1
            s = i
          end
          i &+= 1
        end
        b.json_escape(p + s, i &- s) if i > s
        i &+= 1 # closing quote
      else
        s = i
        while i < n &- 1 && p[i] != ','.ord
          i &+= 1
        end
        b.json_escape(p + s, i &- s)
      end
      b << '"'.ord.to_u8
      i &+= 1 # the comma
    end
    b << ']'.ord.to_u8
  end

  @[AlwaysInline]
  private def self.bool(b : Buf, v : Bool) : Nil
    b << (v ? "true" : "false")
  end

  # username, bio, image, then following: 0 from the row, 1 true, 2 false.
  private def self.profile(b : Buf, row : Pg::Row, following : Int32) : Nil
    b << %({"username":)
    str(b, row)
    b << %(,"bio":)
    str(b, row)
    b << %(,"image":)
    str(b, row)
    b << %(,"following":)
    bool(b, following == 0 ? row.bool : following == 1)
    b << '}'.ord.to_u8
  end

  # id, slug, title, description, [body], created_at, updated_at, tag_list, favorites_count,
  # favorited, username, bio, image, following
  private def self.article(b : Buf, row : Pg::Row, full : Bool) : Nil
    row.skip
    b << %({"slug":)
    str(b, row)
    b << %(,"title":)
    str(b, row)
    b << %(,"description":)
    str(b, row)
    if full
      b << %(,"body":)
      str(b, row)
    end
    b << %(,"createdAt":)
    timestamp(b, row)
    b << %(,"updatedAt":)
    timestamp(b, row)
    b << %(,"tagList":)
    text_array(b, row)
    count = row.int
    b << %(,"favorited":)
    bool(b, row.bool)
    b << %(,"favoritesCount":) << count
    b << %(,"author":)
    profile(b, row, 0)
    b << '}'.ord.to_u8
  end

  # id, body, created_at, updated_at, username, bio, image, [following]
  private def self.comment(b : Buf, row : Pg::Row, following : Bool) : Nil
    b << %({"id":) << row.int
    b << %(,"body":)
    str(b, row)
    b << %(,"createdAt":)
    timestamp(b, row)
    b << %(,"updatedAt":)
    timestamp(b, row)
    b << %(,"author":)
    profile(b, row, following ? 0 : 2)
    b << '}'.ord.to_u8
  end

  # id, username, email, bio, image; the token presented, or a fresh one.
  private def self.user(b : Buf, row : Pg::Row, j : Job, fresh : Bool) : Nil
    id = row.int
    un, ul = row.next
    b << %({"email":)
    str(b, row)
    b << %(,"token":")
    if fresh
      Jwt.sign(b, id, Server.now_s)
    else
      b.write(j.ptr(Job::F_TOKEN), j.len[Job::F_TOKEN])
    end
    b << %(","username":)
    str(b, un, ul)
    b << %(,"bio":)
    str(b, row)
    b << %(,"image":)
    str(b, row)
    b << '}'.ord.to_u8
  end

  # ---- responses ----

  def self.fail(j : Job) : Nil
    read_done(j)
    if j.kind == K_BATCH || j.kind == K_WRITE_BATCH
      j.nsub.times { |i| fixed(j.sub[i], Resp::INTERNAL) }
      j.free
      return
    end
    fixed(j, Resp::INTERNAL)
  end

  private def self.fixed(j : Job, r : String) : Nil
    o = Server.out
    start = o.len
    o << r
    finish(j, start)
  end

  # The HTTP response into the batch arena, gzipped when the client takes it and the body
  # is big enough to be worth it.
  private def self.reply(j : Job, status : String, b : Buf) : Nil
    o = Server.out
    start = o.len
    if @@gzip && j.gzip && b.len >= GZIP_MIN
      bound = LibDeflate.gzip_bound(@@deflate, b.len).to_i32
      o << "HTTP/1.1 " << status << Resp::GZIP_HDR
      body = o.len
      o.reserve(bound)
      z = LibDeflate.gzip_compress(@@deflate, b.ptr, b.len, o.ptr + body, bound).to_i32
      if z > 0
        o.len &+= z
        Resp.close(o, body)
        finish(j, start)
        return
      end
      o.len = start
    end
    body = Resp.open(o, status)
    o.write(b.ptr, b.len)
    Resp.close(o, body)
    finish(j, start)
  end

  private def self.finish(j : Job, start : Int32) : Nil
    fd = j.fd
    gen = j.gen
    j.free
    Server.db_done(fd, gen, start)
  end

  # ---- request helpers ----

  @[AlwaysInline]
  def self.hexval(c : UInt8) : Int32
    Json.hexval(c)
  end

  # Percent-decoding (and '+' as space in query strings). Returns the decoded length.
  def self.url_decode(p : UInt8*, n : Int32, d : UInt8*, plus : Bool) : Int32
    i = 0
    o = 0
    while i < n
      c = p[i]
      if c == '%'.ord && i &+ 2 < n && (h = hexval(p[i &+ 1])) >= 0 && (l = hexval(p[i &+ 2])) >= 0
        d[o] = ((h << 4) | l).to_u8!
        i &+= 3
      elsif c == '+'.ord && plus
        d[o] = 0x20_u8
        i &+= 1
      else
        d[o] = c
        i &+= 1
      end
      o &+= 1
    end
    o
  end
end

@[Link("deflate")]
lib LibDeflate
  fun alloc_compressor = libdeflate_alloc_compressor(level : LibC::Int) : Void*
  fun gzip_compress = libdeflate_gzip_compress(c : Void*, input : Void*, n : LibC::SizeT, output : Void*, avail : LibC::SizeT) : LibC::SizeT
  fun gzip_bound = libdeflate_gzip_compress_bound(c : Void*, n : LibC::SizeT) : LibC::SizeT
end

struct FlagSet
  @pairs : Int64*
  @mask : UInt64
  def initialize(r : Pg::Result, set : Int32)
    cap = 8_u64
    n = r.count(set)
    while cap < n * 4
      cap *= 2
    end
    @mask = cap - 1
    @pairs = LibSys.calloc(cap * 2, 8).as(Int64*)
    r.each(set) do |row|
      viewer = row.int
      target = row.int
      at = slot(viewer, target)
      @pairs[at * 2] = viewer
      @pairs[at * 2 + 1] = target
    end
  end

  private def slot(viewer : Int64, target : Int64) : UInt64
    at = ((viewer.to_u64! &* 0x9e3779b97f4a7c15_u64) ^ (target.to_u64! &* 0xbf58476d1ce4e5b9_u64)) & @mask
    while @pairs[at * 2] != 0 && (@pairs[at * 2] != viewer || @pairs[at * 2 + 1] != target)
      at = (at + 1) & @mask
    end
    at
  end

  def has?(viewer : Int64, target : Int64) : Bool
    return false if viewer == 0
    at = slot(viewer, target)
    @pairs[at * 2] == viewer && @pairs[at * 2 + 1] == target
  end

  def free : Nil
    LibC.free(@pairs)
  end
end

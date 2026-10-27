# Routing and request validation. Anything that can be answered without the database
# (404, 401, 422) is answered here, straight into the batch arena; the rest becomes a Job.
module Router
  @@f = Pointer(Json::Field).null
  @@g = Pointer(Json::Field).null

  def self.init : Nil
    @@f = LibC.malloc(5 * sizeof(Json::Field)).as(Json::Field*)
    @@g = LibC.malloc(sizeof(Json::Field)).as(Json::Field*)
  end

  @[AlwaysInline]
  private def self.eq(p : UInt8*, n : Int32, s : String) : Bool
    n == s.bytesize && p.memcmp(s.to_unsafe, n) == 0
  end

  # Segment ends at '/' or the end.
  @[AlwaysInline]
  private def self.seg(p : UInt8*, n : Int32) : Int32
    q = LibC.memchr(p, '/'.ord, n).as(UInt8*)
    q.null? ? n : (q - p).to_i32
  end

  # Authorization: -1 when a 401 was written; 0 anonymous (optional auth only).
  private def self.viewer(rv : Http::Req, o : Buf, required : Bool) : Int64
    if rv.auth_len < 0
      return 0_i64 unless required
      o << Resp::UNAUTHORIZED
      return -1_i64
    end
    if Jwt.verify(rv.auth, rv.auth_len, Server.now_s, Server.claims) != Jwt::OK
      o << Resp::UNAUTHORIZED
      return -1_i64
    end
    Server.claims.value.uid
  end

  private def self.not_found(o : Buf) : Nil
    o << Resp::NOT_FOUND
  end

  def self.handle(r : Http::Req*, o : Buf) : Nil
    rv = r.value
    p = rv.path
    n = rv.path_len
    m = rv.method
    unless n > 5 && p.memcmp("/api/".to_unsafe, 5) == 0
      return not_found(o)
    end
    p += 5
    n &-= 5
    s0 = seg(p, n)
    a = p
    p += s0
    n &-= s0
    # a[0, s0] is the first segment; p/n what follows (starting with '/' if anything)
    if eq(a, s0, "tags")
      return not_found(o) unless n == 0 && m == Http::GET
      App.go(App.new_job(App::K_TAGS, r))
    elsif eq(a, s0, "user")
      return not_found(o) unless n == 0 && (m == Http::GET || m == Http::PUT)
      v = viewer(rv, o, true)
      return if v < 0
      j = App.new_job(m == Http::GET ? App::K_USER_GET : App::K_USER_PUT, r)
      j.viewer = v
      token(j, rv)
      if m == Http::PUT
        unless user_fields(j, rv, false)
          j.free
          return o << Resp::INVALID
        end
      end
      App.go(j)
    elsif eq(a, s0, "users")
      return not_found(o) unless m == Http::POST
      login = eq(p, n, "/login")
      return not_found(o) unless n == 0 || login
      j = App.new_job(login ? App::K_LOGIN : App::K_REGISTER, r)
      unless user_fields(j, rv, true)
        j.free
        return o << Resp::INVALID
      end
      App.go(j)
    elsif eq(a, s0, "profiles")
      return not_found(o) unless n > 1
      p += 1
      n &-= 1
      s1 = seg(p, n)
      return not_found(o) if s1 == 0
      rest = n &- s1
      follow = rest == 7 && (p + s1).memcmp("/follow".to_unsafe, 7) == 0
      if rest == 0 && m == Http::GET
        v = viewer(rv, o, false)
        return if v < 0
        j = App.new_job(App::K_PROFILE, r)
      elsif follow && (m == Http::POST || m == Http::DELETE)
        v = viewer(rv, o, true)
        return if v < 0
        j = App.new_job(m == Http::POST ? App::K_FOLLOW : App::K_UNFOLLOW, r)
      else
        return not_found(o)
      end
      j.viewer = v
      j.put(Job::F_A, p, s1, url: 1)
      App.go(j)
    elsif eq(a, s0, "articles")
      articles(r, rv, o, p, n, m)
    else
      not_found(o)
    end
  end

  private def self.articles(r : Http::Req*, rv : Http::Req, o : Buf, p : UInt8*, n : Int32, m : Int32) : Nil
    if n == 0
      if m == Http::GET
        v = viewer(rv, o, false)
        return if v < 0
        j = App.new_job(App::K_LIST, r)
        j.viewer = v
        return o << Resp::BAD_PAGE unless query(j, rv, true) || free(j)
        App.go(j)
      elsif m == Http::POST
        v = viewer(rv, o, true)
        return if v < 0
        j = App.new_job(App::K_CREATE_ARTICLE, r)
        j.viewer = v
        return o << Resp::INVALID unless article_fields(j, rv, true) || free(j)
        App.go(j)
      else
        not_found(o)
      end
      return
    end
    return not_found(o) if n == 1
    p += 1
    n &-= 1
    s1 = seg(p, n)
    return not_found(o) if s1 == 0
    slug = p
    p += s1
    n &-= s1
    if n == 0
      if m == Http::GET && eq(slug, s1, "feed")
        v = viewer(rv, o, true)
        return if v < 0
        j = App.new_job(App::K_FEED, r)
        j.viewer = v
        return o << Resp::BAD_PAGE unless query(j, rv, false) || free(j)
        return App.go(j)
      end
      kind = case m
             when Http::GET    then App::K_ARTICLE
             when Http::PUT    then App::K_UPDATE_ARTICLE
             when Http::DELETE then App::K_DELETE_ARTICLE
             else                   return not_found(o)
             end
      v = viewer(rv, o, kind != App::K_ARTICLE)
      return if v < 0
      j = App.new_job(kind, r)
      j.viewer = v
      if kind == App::K_UPDATE_ARTICLE
        return o << Resp::INVALID unless article_fields(j, rv, false) || free(j)
      end
      j.put(Job::F_FILTER, slug, s1, url: 1)
      return App.go(j)
    end
    if eq(p, n, "/favorite")
      return not_found(o) unless m == Http::POST || m == Http::DELETE
      v = viewer(rv, o, true)
      return if v < 0
      j = App.new_job(m == Http::POST ? App::K_FAVORITE : App::K_UNFAVORITE, r)
      j.viewer = v
      j.put(Job::F_FILTER, slug, s1, url: 1)
      return App.go(j)
    end
    if eq(p, n, "/comments")
      if m == Http::GET
        v = viewer(rv, o, false)
        return if v < 0
        j = App.new_job(App::K_COMMENTS, r)
      elsif m == Http::POST
        v = viewer(rv, o, true)
        return if v < 0
        j = App.new_job(App::K_ADD_COMMENT, r)
        return o << Resp::INVALID unless comment_fields(j, rv) || free(j)
      else
        return not_found(o)
      end
      j.viewer = v
      j.put(Job::F_FILTER, slug, s1, url: 1)
      return App.go(j)
    end
    if n > 10 && p.memcmp("/comments/".to_unsafe, 10) == 0
      return not_found(o) unless m == Http::DELETE
      idp = p + 10
      idn = n &- 10
      return not_found(o) unless LibC.memchr(idp, '/'.ord, idn).null?
      v = viewer(rv, o, true)
      return if v < 0
      j = App.new_job(App::K_DELETE_COMMENT, r)
      j.viewer = v
      j.put(Job::F_A, idp, idn, url: 1)
      id = digits(j.ptr(Job::F_A), j.len[Job::F_A])
      if id < 0
        j.free
        return o << Resp::COMMENT_404
      end
      j.id = id
      j.put(Job::F_FILTER, slug, s1, url: 1)
      return App.go(j)
    end
    not_found(o)
  end

  # Frees the job and answers false, for `ok || free(j)`.
  private def self.free(j : Job) : Bool
    j.free
    false
  end

  private def self.token(j : Job, rv : Http::Req) : Nil
    t = rv.auth + 6 # "Token "
    l = rv.auth_len &- 6
    while l > 0 && t.value == 0x20
      t += 1
      l &-= 1
    end
    while l > 0 && t[l &- 1] == 0x20
      l &-= 1
    end
    j.put(Job::F_TOKEN, t, l)
  end

  # Only ASCII digits, fitting in an int64 (18 digits is plenty for ids). -1 otherwise.
  private def self.digits(p : UInt8*, n : Int32) : Int64
    return -1_i64 if n == 0 || n > 18
    v = 0_i64
    n.times do |i|
      c = p[i]
      return -1_i64 unless c >= 0x30 && c <= 0x39
      v = v &* 10 &+ (c &- 0x30)
    end
    v
  end

  # limit (1..100, default 20), offset (>= 0, default 0); for the list, the first of tag,
  # author, favorited that is non-empty. A parameter that is present must be valid. The
  # first occurrence of a key counts.
  private def self.query(j : Job, rv : Http::Req, filters : Bool) : Bool
    q = rv.query
    n = rv.query_len
    seen = 0
    tmp = Server.scratch
    fbest = 4
    i = 0
    while i < n
      e = i
      while e < n && q[e] != '&'.ord
        e &+= 1
      end
      eqp = LibC.memchr(q + i, '='.ord, e &- i).as(UInt8*)
      kend = eqp.null? ? e : (eqp - q).to_i32
      kl = App.url_decode(q + i, kend &- i, tmp, true)
      vs = eqp.null? ? e : kend &+ 1
      if kl > 0
        bit, fi = if eq(tmp, kl, "limit")
                    {1, 0}
                  elsif eq(tmp, kl, "offset")
                    {2, 0}
                  elsif eq(tmp, kl, "tag")
                    {4, 1}
                  elsif eq(tmp, kl, "author")
                    {8, 2}
                  elsif eq(tmp, kl, "favorited")
                    {16, 3}
                  else
                    {0, 0}
                  end
        if bit != 0 && seen & bit == 0
          seen |= bit
          if bit <= 2
            vl = App.url_decode(q + vs, e &- vs, tmp, true)
            v = digits(tmp, vl)
            return false if v < 0
            if bit == 1
              return false unless v >= 1 && v <= 100
              j.limit = v
            else
              j.offset = v
            end
          elsif filters && fi < fbest && e > vs
            vl = App.url_decode(q + vs, e &- vs, tmp, true)
            if vl > 0
              fbest = fi
              j.filter = fi
              j.put(Job::F_FILTER, tmp, vl)
            end
          end
        end
      end
      i = e &+ 1
    end
    true
  end

  # The fields of {"<wrap>": {...}}: f[0..4] for k0..k4 of the inner object. Returns the
  # inner object's base pointer, or null when the body isn't that shape.
  private def self.fields(rv : Http::Req, wrap : String, k0 : String, k1 : String, k2 : String,
                          k3 : String = "", k4 : String = "") : UInt8*
    f = @@f
    5.times { |i| f[i] = Json::Field.new }
    pr = Json::Parser.new(rv.body, rv.body_len)
    return Pointer(UInt8).null if pr.top(wrap, "", "", f) != Json::OK
    w = f[0]
    return Pointer(UInt8).null unless w.kind == Json::KIND_OBJECT
    base = rv.body + w.start
    5.times { |i| f[i] = Json::Field.new }
    pr = Json::Parser.new(base, w.len)
    return Pointer(UInt8).null if pr.top(k0, k1, k2, f, k3, k4) != Json::OK
    base
  end

  # Field i into slot `slot`: absent/null leaves it unset (true). A string is copied in
  # (false if empty and `non_empty`); anything else is false.
  private def self.opt(j : Job, base : UInt8*, i : Int32, slot : Int32, non_empty : Bool) : Bool
    fl = @@f[i]
    return true if fl.kind == Json::KIND_NONE || fl.kind == Json::KIND_NULL
    return false unless fl.kind == Json::KIND_STRING
    j.put(slot, base + fl.start, fl.len, json_escaped: fl.escaped)
    !(non_empty && j.len[slot] == 0)
  end

  private def self.req(j : Job, base : UInt8*, i : Int32, slot : Int32) : Bool
    opt(j, base, i, slot, true) && j.has?(slot)
  end

  # register: username, email, password; login: email, password; update: any of them plus bio, image.
  private def self.user_fields(j : Job, rv : Http::Req, required : Bool) : Bool
    base = fields(rv, "user", "username", "email", "password", "bio", "image")
    return false if base.null?
    if j.kind == App::K_LOGIN
      return false unless req(j, base, 1, Job::F_B) && req(j, base, 2, Job::F_PASSWORD)
      return true
    end
    if required
      return false unless req(j, base, 0, Job::F_A) && req(j, base, 1, Job::F_B) && req(j, base, 2, Job::F_PASSWORD)
    else
      return false unless opt(j, base, 0, Job::F_A, true) && opt(j, base, 1, Job::F_B, true) &&
                          opt(j, base, 2, Job::F_PASSWORD, true) && opt(j, base, 3, Job::F_BIO, false) &&
                          opt(j, base, 4, Job::F_IMAGE, false)
    end
    if j.has?(Job::F_PASSWORD) # bcrypt takes at most 72 bytes, and no NUL
      l = j.len[Job::F_PASSWORD]
      return false if l > 72 || !LibC.memchr(j.ptr(Job::F_PASSWORD), 0, l).null?
    end
    true
  end

  private def self.article_fields(j : Job, rv : Http::Req, create : Bool) : Bool
    base = fields(rv, "article", "title", "description", "body", "tagList")
    return false if base.null?
    unless create
      return opt(j, base, 0, Job::F_A, true) && opt(j, base, 1, Job::F_B, true) && opt(j, base, 2, Job::F_C, true)
    end
    return false unless req(j, base, 0, Job::F_A) && req(j, base, 1, Job::F_B) && req(j, base, 2, Job::F_C)
    tl = @@f[3]
    return true if tl.kind == Json::KIND_NONE || tl.kind == Json::KIND_NULL
    return false unless tl.kind == Json::KIND_ARRAY
    g = @@g
    # count, checking every element is a non-empty string
    k = 0
    pr = Json::Parser.new(base + tl.start, tl.len)
    while pr.next_elem(g)
      e = g.value
      return false unless e.kind == Json::KIND_STRING && e.len > 0
      k &+= 1
    end
    return true if k == 0
    j.tag_off = LibC.malloc(k * 4).as(Int32*)
    j.tag_len = LibC.malloc(k * 4).as(Int32*)
    pr = Json::Parser.new(base + tl.start, tl.len)
    i = 0
    while pr.next_elem(g)
      e = g.value
      j.put(Job::F_FILTER, base + tl.start + e.start, e.len, json_escaped: e.escaped)
      return false if j.len[Job::F_FILTER] == 0
      j.tag_off[i] = j.off[Job::F_FILTER]
      j.tag_len[i] = j.len[Job::F_FILTER]
      i &+= 1
    end
    j.ntags = k
    j.unset(Job::F_FILTER)
    true
  end

  private def self.comment_fields(j : Job, rv : Http::Req) : Bool
    base = fields(rv, "comment", "body", "", "")
    return false if base.null?
    req(j, base, 0, Job::F_B)
  end
end

# PostgreSQL wire protocol v3 client, in Mojo: SCRAM-SHA-256 login, prepared statements, pipelined
# Bind/Execute/Sync batches, and in-place reading of results in text format.
#
# Startup (connect, login, Parse every statement) is blocking and runs once per connection before the event loop.
# After that the socket is non-blocking and owned by the worker's event loop (server.mojo).

from std.memory.alloc import unsafe_alloc
from linux import *
from buf import BytePtr, ByteBuf, to_string
from crypto import HmacKey, sha256, pbkdf2_sha256, base64_encode, base64_decode
from http import eq_lit

comptime F_GETFL = 3
comptime F_SETFL = 4
comptime O_NONBLOCK = 0x800

# Backend message types
comptime MSG_AUTH: UInt8 = 82  # 'R'
comptime MSG_ERROR: UInt8 = 69  # 'E'
comptime MSG_NOTICE: UInt8 = 78  # 'N'
comptime MSG_READY: UInt8 = 90  # 'Z'
comptime MSG_PARAM_STATUS: UInt8 = 83  # 'S'
comptime MSG_KEY_DATA: UInt8 = 75  # 'K'
comptime MSG_PARSE_COMPLETE: UInt8 = 49  # '1'
comptime MSG_BIND_COMPLETE: UInt8 = 50  # '2'
comptime MSG_DATA_ROW: UInt8 = 68  # 'D'
comptime MSG_COMMAND_COMPLETE: UInt8 = 67  # 'C'
comptime MSG_EMPTY_QUERY: UInt8 = 73  # 'I'
comptime MSG_NO_DATA: UInt8 = 110  # 'n'
comptime MSG_NOTIFICATION: UInt8 = 65  # 'A'


@inline(.always)
def be32(p: BytePtr) -> Int:
    return (
        (Int(p[unsafe_offset=0]) << 24)
        | (Int(p[unsafe_offset=1]) << 16)
        | (Int(p[unsafe_offset=2]) << 8)
        | Int(p[unsafe_offset=3])
    )


@inline(.always)
def be16(p: BytePtr) -> Int:
    return (Int(p[unsafe_offset=0]) << 8) | Int(p[unsafe_offset=1])


@inline(.always)
def put_be32(mut b: ByteBuf, v: Int):
    b.put(UInt8((v >> 24) & 0xFF))
    b.put(UInt8((v >> 16) & 0xFF))
    b.put(UInt8((v >> 8) & 0xFF))
    b.put(UInt8(v & 0xFF))


@inline(.always)
def put_be16(mut b: ByteBuf, v: Int):
    b.put(UInt8((v >> 8) & 0xFF))
    b.put(UInt8(v & 0xFF))


@inline(.always)
def patch_be32(b: ByteBuf, at: Int, v: Int):
    b.ptr[unsafe_offset=at] = UInt8((v >> 24) & 0xFF)
    b.ptr[unsafe_offset=at + 1] = UInt8((v >> 16) & 0xFF)
    b.ptr[unsafe_offset=at + 2] = UInt8((v >> 8) & 0xFF)
    b.ptr[unsafe_offset=at + 3] = UInt8(v & 0xFF)


@inline(.always)
def begin_msg(mut b: ByteBuf, kind: UInt8) -> Int:
    """Starts a frontend message; returns where its length goes. Close it with end_msg."""
    b.put(kind)
    var at = b.len
    put_be32(b, 0)
    return at


@inline(.always)
def end_msg(b: ByteBuf, at: Int):
    patch_be32(b, at, b.len - at)


def put_cstr(mut b: ByteBuf, s: StringSlice):
    b.put_str(s)
    b.put(0)


# --- DATABASE_URL ------------------------------------------------------------------------------------------


struct PgConfig(Copyable):
    var user: String
    var password: String
    var host: String
    var port: Int
    var database: String
    var generic_plans: Bool  # session jit=off + plan_cache_mode=force_generic_plan (see pg_connect)

    def __init__(out self):
        self.user = "postgres"
        self.password = ""
        self.host = "127.0.0.1"
        self.port = 5432
        self.database = "postgres"
        self.generic_plans = True


def percent_decode(s: String) -> String:
    var b = ByteBuf(s.byte_length() + 1)
    var p = BytePtr(unsafe_from_address=Int(s.unsafe_ptr()))
    var n = s.byte_length()
    var i = 0
    while i < n:
        var c = p[unsafe_offset=i]
        if c == 37 and i + 2 < n:  # '%'
            var hi = hex_digit(p[unsafe_offset=i + 1])
            var lo = hex_digit(p[unsafe_offset=i + 2])
            if hi >= 0 and lo >= 0:
                b.put(UInt8(hi * 16 + lo))
                i += 3
                continue
        b.put(c)
        i += 1
    var out = to_string(b.ptr, b.len)
    b.free()
    return out


def hex_digit(c: UInt8) -> Int:
    if c >= 48 and c <= 57:
        return Int(c) - 48
    if c >= 97 and c <= 102:
        return Int(c) - 87
    if c >= 65 and c <= 70:
        return Int(c) - 55
    return -1


def parse_database_url(url: String) -> PgConfig:
    """postgres://user:password@host:port/database[?...]"""
    var cfg = PgConfig()
    # [start, end) is the part still to parse
    var start = 0
    var end = url.byte_length()
    if url.startswith("postgres://"):
        start = 11
    elif url.startswith("postgresql://"):
        start = 13
    var q = url.find("?", start)
    if q >= 0:
        end = q
    var body = String(url[byte=start:end])
    var at = body.rfind("@")
    var host_from = 0
    if at >= 0:
        var cred = String(body[byte=:at])
        host_from = at + 1
        var colon = cred.find(":")
        if colon >= 0:
            cfg.user = percent_decode(String(cred[byte=:colon]))
            cfg.password = percent_decode(String(cred[byte=colon + 1 :]))
        else:
            cfg.user = percent_decode(cred)
    var slash = body.find("/", host_from)
    var hostport = String(body[byte=host_from:])
    if slash >= 0:
        hostport = String(body[byte=host_from:slash])
        var db = String(body[byte=slash + 1 :])
        if db.byte_length() > 0:
            cfg.database = percent_decode(db)
    var colon = hostport.rfind(":")
    if colon >= 0:
        cfg.host = String(hostport[byte=:colon])
        try:
            cfg.port = Int(String(hostport[byte=colon + 1 :]))
        except:
            cfg.port = 5432
    elif hostport.byte_length() > 0:
        cfg.host = hostport
    return cfg^


# --- results -----------------------------------------------------------------------------------------------


struct Results(ImplicitlyCopyable):
    """Walks the backend messages of one Sync batch in place: for each statement, its rows, then its
    CommandComplete or ErrorResponse. Column values are (pointer, length), length -1 for NULL."""

    var p: BytePtr
    var n: Int
    var pos: Int
    var row: BytePtr  # body of the current DataRow
    var row_len: Int
    var ncols: Int
    var error_state: Int  # SQLSTATE of the last ErrorResponse seen, as 5 chars packed, or 0

    def __init__(out self, p: BytePtr, n: Int):
        self.p = p
        self.n = n
        self.pos = 0
        self.row = p
        self.row_len = 0
        self.ncols = 0
        self.error_state = 0

    def next_row(mut self) -> Bool:
        """Advances to the next DataRow of the current statement. False at the statement's end (its
        CommandComplete or ErrorResponse, which is consumed) or at the end of the batch."""
        while self.pos + 5 <= self.n:
            var kind = self.p[unsafe_offset=self.pos]
            var body = self.p.unsafe_offset(self.pos + 5)
            var blen = be32(self.p.unsafe_offset(self.pos + 1)) - 4
            self.pos += 5 + blen
            if kind == MSG_DATA_ROW:
                self.row = body
                self.row_len = blen
                self.ncols = be16(body)
                return True
            if kind == MSG_COMMAND_COMPLETE or kind == MSG_EMPTY_QUERY:
                return False
            if kind == MSG_ERROR:
                self.error_state = sqlstate(body, blen)
                return False
            # BindComplete, ParseComplete, NoData, notices, parameter status: skip
        return False

    def skip_statement(mut self):
        while self.next_row():
            pass

    def column(self, idx: Int, mut out_len: Int) -> BytePtr:
        var off = 2
        for _ in range(idx):
            var l = be32(self.row.unsafe_offset(off))
            off += 4
            if l < 0x80000000:  # 0xFFFFFFFF is NULL and has no bytes
                off += l
        out_len = be32(self.row.unsafe_offset(off))
        if out_len >= 0x80000000:
            out_len = -1
        return self.row.unsafe_offset(off + 4)

    def column_int(self, idx: Int) -> Int:
        var l = 0
        var p = self.column(idx, l)
        var v = 0
        var neg = False
        for i in range(l):
            var c = p[unsafe_offset=i]
            if c == 45:
                neg = True
            else:
                v = v * 10 + Int(c) - 48
        return -v if neg else v

    def column_bool(self, idx: Int) -> Bool:
        var l = 0
        var p = self.column(idx, l)
        return l == 1 and p[] == 116  # 't'


def sqlstate(body: BytePtr, n: Int) -> Int:
    """Packs the ErrorResponse 'C' field (SQLSTATE) into an Int, e.g. sqlstate_code("23505")."""
    var i = 0
    while i < n and body[unsafe_offset=i] != 0:
        var field = body[unsafe_offset=i]
        i += 1
        var start = i
        while i < n and body[unsafe_offset=i] != 0:
            i += 1
        if field == 67 and i - start == 5:  # 'C'
            var v = 0
            for k in range(5):
                v = (v << 8) | Int(body[unsafe_offset=start + k])
            return v
        i += 1
    return 1


def sqlstate_code(s: StaticString) -> Int:
    var v = 0
    var p = s.unsafe_ptr()
    for k in range(5):
        v = (v << 8) | Int(p[unsafe_offset=k])
    return v


def error_message(body: BytePtr, n: Int) -> String:
    var i = 0
    while i < n and body[unsafe_offset=i] != 0:
        var field = body[unsafe_offset=i]
        i += 1
        var start = i
        while i < n and body[unsafe_offset=i] != 0:
            i += 1
        if field == 77:  # 'M'
            return to_string(body.unsafe_offset(start), i - start)
        i += 1
    return "unknown error"


# --- the connection ----------------------------------------------------------------------------------------


struct Pending(ImplicitlyCopyable):
    """A request waiting for its Sync batch: who to answer and how."""

    var fd: Int
    var gen: Int
    var kind: Int
    var keep_alive: Bool
    var a0: Int
    var a1: Int

    def __init__(out self, fd: Int, gen: Int, kind: Int, keep_alive: Bool):
        self.fd = fd
        self.gen = gen
        self.kind = kind
        self.keep_alive = keep_alive
        self.a0 = 0
        self.a1 = 0


struct PgConn(Copyable):
    var fd: Int
    var out: ByteBuf  # frontend messages not yet sent
    var inb: ByteBuf  # backend bytes not yet dispatched
    var queue: List[Pending]  # one entry per Sync in flight, in order
    var head: Int
    var want_out: Bool
    var broken: Bool
    var _bind_at: Int  # length slot of the Bind being written

    def __init__(out self):
        self.fd = -1
        self.out = ByteBuf(16 * 1024)
        self.inb = ByteBuf(64 * 1024)
        self.queue = List[Pending]()
        self.head = 0
        self.want_out = False
        self.broken = False
        self._bind_at = 0

    def in_flight(self) -> Int:
        return len(self.queue) - self.head

    def push(mut self, p: Pending):
        if self.head > 0 and self.head == len(self.queue):
            self.queue.clear()
            self.head = 0
        self.queue.append(p)

    def pop(mut self) -> Pending:
        var p = self.queue[self.head]
        self.head += 1
        return p

    # Frontend messages for a request: bind(...) and execute() per statement, then sync().

    def bind_begin(mut self, stmt: Int, nparams: Int):
        var at = begin_msg(self.out, 66)  # 'B'
        self.out.put(0)  # unnamed portal
        self.out.put(115)  # 's'
        self.out.put_uint(stmt)
        self.out.put(0)
        put_be16(self.out, 0)  # all parameters in text format
        put_be16(self.out, nparams)
        self._bind_at = at

    def param_text(mut self, p: BytePtr, n: Int):
        put_be32(self.out, n)
        self.out.put_bytes(p, n)

    def param_str(mut self, s: StringSlice):
        put_be32(self.out, s.byte_length())
        self.out.put_str(s)

    def param_int(mut self, v: Int):
        var at = self.out.len
        put_be32(self.out, 0)
        var start = self.out.len
        self.out.put_int(v)
        patch_be32(self.out, at, self.out.len - start)

    def param_null(mut self):
        put_be32(self.out, -1 & 0xFFFFFFFF)

    def bind_end(mut self):
        put_be16(self.out, 0)  # all results in text format
        end_msg(self.out, self._bind_at)
        # Execute the unnamed portal, all rows
        self.out.put(69)  # 'E'
        put_be32(self.out, 9)
        self.out.put(0)
        put_be32(self.out, 0)

    def sync(mut self):
        self.out.put(83)  # 'S'
        put_be32(self.out, 4)


def set_nonblocking(fd: Int) -> Int:
    var flags = syscall3(SYS_FCNTL, fd, F_GETFL, 0)
    if flags < 0:
        return flags
    return syscall3(SYS_FCNTL, fd, F_SETFL, flags | O_NONBLOCK)


def resolve_ipv4(host: String) -> Int:
    if host == "localhost" or host == "":
        return 0x7F000001
    var parts = host.split(".")
    if len(parts) != 4:
        return -1
    var addr = 0
    for i in range(4):
        try:
            var o = Int(parts[i])
            if o < 0 or o > 255:
                return -1
            addr = (addr << 8) | o
        except:
            return -1
    return addr


def send_all_blocking(fd: Int, b: ByteBuf) -> Bool:
    var sent = 0
    while sent < b.len:
        var r = sys_send(fd, Int(b.ptr.unsafe_offset(sent)), b.len - sent)
        if r == -EINTR:
            continue
        if r <= 0:
            return False
        sent += r
    return True


def read_message_blocking(fd: Int, mut inb: ByteBuf, mut kind: UInt8, mut body_len: Int) -> Bool:
    """Reads until inb starts with one whole message. The caller consumes 5 + body_len bytes after use."""
    while True:
        if inb.len >= 5:
            var total = 1 + be32(inb.ptr.unsafe_offset(1))
            if inb.len >= total:
                kind = inb.ptr[]
                body_len = total - 5
                return True
            inb.reserve(total - inb.len)
        inb.reserve(4096)
        var r = sys_recv(fd, Int(inb.tail()), inb.cap - inb.len)
        if r == -EINTR:
            continue
        if r <= 0:
            return False
        inb.len += r


def scram_login(fd: Int, password: String, mut inb: ByteBuf) -> String:
    """Runs SCRAM-SHA-256 after AuthenticationSASL. Returns "" on success, else an error message."""
    var out = ByteBuf(512)
    var rnd = unsafe_alloc[UInt8](64)
    var got = 0
    while got < 18:
        var r = sys_getrandom(Int(rnd.unsafe_offset(got)), 18 - got)
        if r <= 0:
            return "getrandom failed"
        got += r
    var nb = ByteBuf(64)
    base64_encode(rnd, 18, nb, False, True)
    var cnonce = to_string(nb.ptr, nb.len)
    nb.free()
    var client_first_bare = "n=,r=" + cnonce

    var at = begin_msg(out, 112)  # 'p' SASLInitialResponse
    put_cstr(out, "SCRAM-SHA-256")
    put_be32(out, 3 + client_first_bare.byte_length())
    out.put_str("n,,")
    out.put_str(client_first_bare)
    end_msg(out, at)
    if not send_all_blocking(fd, out):
        return "send failed"

    var kind: UInt8 = 0
    var blen = 0
    if not read_message_blocking(fd, inb, kind, blen):
        return "connection closed during SCRAM"
    if kind == MSG_ERROR:
        return error_message(inb.ptr.unsafe_offset(5), blen)
    if kind != MSG_AUTH or be32(inb.ptr.unsafe_offset(5)) != 11:
        return "expected AuthenticationSASLContinue"
    var server_first = to_string(inb.ptr.unsafe_offset(9), blen - 4)
    inb.consume(5 + blen)

    var nonce = String("")
    var salt_b64 = String("")
    var iterations = 0
    for part in server_first.split(","):
        var s = String(part)
        if s.startswith("r="):
            nonce = String(s[byte=2:])
        elif s.startswith("s="):
            salt_b64 = String(s[byte=2:])
        elif s.startswith("i="):
            try:
                iterations = Int(String(s[byte=2:]))
            except:
                iterations = 0
    if not nonce.startswith(cnonce) or iterations <= 0:
        return "bad server-first-message"
    var salt = ByteBuf(64)
    if not base64_decode(salt_b64, salt, False):
        return "bad salt"

    var salted = rnd  # reuse: 32 bytes salted password, then keys at +32
    pbkdf2_sha256(
        BytePtr(unsafe_from_address=Int(password.unsafe_ptr())), password.byte_length(), salt.ptr, salt.len,
        iterations, salted, 32,
    )
    salt.free()
    var client_key = unsafe_alloc[UInt8](128)
    var stored_key = client_key.unsafe_offset(32)
    var client_sig = client_key.unsafe_offset(64)
    var server_sig = client_key.unsafe_offset(96)
    var sk = HmacKey(salted, 32)
    sk.mac("Client Key", client_key)
    sha256(client_key, 32, stored_key)
    var without_proof = "c=biws,r=" + nonce
    var auth_message = client_first_bare + "," + server_first + "," + without_proof
    HmacKey(stored_key, 32).mac(auth_message, client_sig)
    for i in range(32):
        client_sig[unsafe_offset=i] ^= client_key[unsafe_offset=i]  # now the proof
    var proof = ByteBuf(64)
    base64_encode(client_sig, 32, proof, False, True)

    out.len = 0
    at = begin_msg(out, 112)  # 'p' SASLResponse
    out.put_str(without_proof)
    out.put_str(",p=")
    out.put_bytes(proof.ptr, proof.len)
    end_msg(out, at)
    proof.free()
    if not send_all_blocking(fd, out):
        return "send failed"
    out.free()

    if not read_message_blocking(fd, inb, kind, blen):
        return "connection closed during SCRAM"
    if kind == MSG_ERROR:
        return error_message(inb.ptr.unsafe_offset(5), blen)
    if kind != MSG_AUTH or be32(inb.ptr.unsafe_offset(5)) != 12:
        return "expected AuthenticationSASLFinal"
    var server_final = to_string(inb.ptr.unsafe_offset(9), blen - 4)
    inb.consume(5 + blen)

    # Check the server knows the password too (mutual authentication).
    sk.mac("Server Key", client_key)
    HmacKey(client_key, 32).mac(auth_message, server_sig)
    var expect = ByteBuf(64)
    base64_encode(server_sig, 32, expect, False, True)
    var ok = server_final == "v=" + to_string(expect.ptr, expect.len)
    expect.free()
    client_key.unsafe_free()
    rnd.unsafe_free()
    return "" if ok else "server signature mismatch"


def pg_connect(cfg: PgConfig, statements: List[String], mut conn: PgConn) -> String:
    """Connects, logs in, sets session parameters and prepares `statements` as s0, s1, ...
    Returns "" on success, else an error message. The socket is non-blocking afterwards."""
    var addr = resolve_ipv4(cfg.host)
    if addr < 0:
        return "DATABASE_URL host must be an IPv4 address or localhost: " + cfg.host
    var fd = sys_socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0)
    if fd < 0:
        return "socket failed"
    var sa = unsafe_alloc[UInt8](32)
    for i in range(16):
        sa[unsafe_offset=i] = 0
    sa[unsafe_offset=0] = UInt8(AF_INET)
    sa[unsafe_offset=2] = UInt8((cfg.port >> 8) & 0xFF)
    sa[unsafe_offset=3] = UInt8(cfg.port & 0xFF)
    sa[unsafe_offset=4] = UInt8((addr >> 24) & 0xFF)
    sa[unsafe_offset=5] = UInt8((addr >> 16) & 0xFF)
    sa[unsafe_offset=6] = UInt8((addr >> 8) & 0xFF)
    sa[unsafe_offset=7] = UInt8(addr & 0xFF)
    var r = sys_connect(fd, Int(sa), 16)
    sa.unsafe_offset(16).unsafe_bitcast[Int32]().unsafe_store(Int32(1))
    _ = sys_setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, Int(sa.unsafe_offset(16)), 4)
    sa.unsafe_free()
    if r < 0:
        _ = sys_close(fd)
        return "connect to " + cfg.host + ":" + String(cfg.port) + " failed: errno " + String(-r)

    var out = ByteBuf(512)
    put_be32(out, 0)
    put_be32(out, 196608)  # protocol 3.0
    put_cstr(out, "user")
    put_cstr(out, cfg.user)
    put_cstr(out, "database")
    put_cstr(out, cfg.database)
    put_cstr(out, "client_encoding")
    put_cstr(out, "UTF8")
    put_cstr(out, "DateStyle")
    put_cstr(out, "ISO")
    put_cstr(out, "TimeZone")
    put_cstr(out, "UTC")
    put_cstr(out, "application_name")
    put_cstr(out, "conduit-mojo")
    if cfg.generic_plans:
        # Session settings on our own connections (rule 2). A generic plan can't know LIMIT $2 is at most 100, so
        # it costs the list queries at ~50k rows: above jit_above_cost, so each execution would JIT-compile for
        # ~136 ms, and plan_cache_mode=auto avoids that by re-planning them on every call (~0.25 ms, as much as
        # executing them). With JIT off, the generic plans run as fast as custom ones and cost nothing to plan.
        put_cstr(out, "jit")
        put_cstr(out, "off")
        put_cstr(out, "plan_cache_mode")
        put_cstr(out, "force_generic_plan")
    out.put(0)
    patch_be32(out, 0, out.len)
    if not send_all_blocking(fd, out):
        _ = sys_close(fd)
        return "send failed"

    var inb = ByteBuf(8192)
    var kind: UInt8 = 0
    var blen = 0
    while True:
        if not read_message_blocking(fd, inb, kind, blen):
            _ = sys_close(fd)
            return "connection closed during startup"
        var body = inb.ptr.unsafe_offset(5)
        if kind == MSG_ERROR:
            var m = error_message(body, blen)
            _ = sys_close(fd)
            return m
        if kind == MSG_AUTH:
            var code = be32(body)
            inb.consume(5 + blen)
            if code == 0:
                continue
            if code == 10:
                var err = scram_login(fd, cfg.password, inb)
                if err != "":
                    _ = sys_close(fd)
                    return err
                continue
            if code == 3:  # cleartext password
                out.len = 0
                var at = begin_msg(out, 112)
                put_cstr(out, cfg.password)
                end_msg(out, at)
                if not send_all_blocking(fd, out):
                    _ = sys_close(fd)
                    return "send failed"
                continue
            _ = sys_close(fd)
            return "unsupported authentication method " + String(code)
        if kind == MSG_READY:
            inb.consume(5 + blen)
            break
        inb.consume(5 + blen)  # ParameterStatus, BackendKeyData, notices

    # Prepare every statement, then one Sync.
    out.len = 0
    for i in range(len(statements)):
        var at = begin_msg(out, 80)  # 'P'
        out.put(115)  # 's'
        out.put_uint(i)
        out.put(0)
        put_cstr(out, statements[i])
        put_be16(out, 0)  # let the server infer parameter types
        end_msg(out, at)
    out.put(83)  # 'S'
    put_be32(out, 4)
    if not send_all_blocking(fd, out):
        _ = sys_close(fd)
        return "send failed"
    out.free()
    var parsed = 0
    var failure = String("")
    while True:
        if not read_message_blocking(fd, inb, kind, blen):
            _ = sys_close(fd)
            return "connection closed while preparing"
        if kind == MSG_ERROR and failure == "":
            failure = "preparing s" + String(parsed) + ": " + error_message(inb.ptr.unsafe_offset(5), blen)
        if kind == MSG_PARSE_COMPLETE:
            parsed += 1
        var done = kind == MSG_READY
        inb.consume(5 + blen)
        if done:
            break
    inb.free()
    if failure != "":
        _ = sys_close(fd)
        return failure
    _ = set_nonblocking(fd)
    conn.fd = fd
    return ""

# HS256 JWTs: claims {"sub": "<user id>", "iat": now, "exp": now + 30 days}. Every request verifies the signature
# and exp; nothing is cached (rule 7).

from std.memory.alloc import unsafe_alloc
from linux import syscall3, SYS_CLOCK_GETTIME
from buf import BytePtr, ByteBuf
from crypto import HmacKey, base64_encode, base64_decode
from jsonin import Json, T_STRING, T_NUMBER

comptime TOKEN_LIFETIME = 30 * 24 * 3600
comptime CLOCK_REALTIME = 0
comptime MAX_TOKEN_BYTES = 2048


def unix_now(scratch: BytePtr) -> Int:
    """Seconds since the epoch. `scratch` is 16 bytes of heap for the timespec."""
    _ = syscall3(SYS_CLOCK_GETTIME, CLOCK_REALTIME, Int(scratch), 0)
    return Int(scratch.unsafe_bitcast[Int64]()[])


struct Jwt(Movable):
    var key: HmacKey
    var header: ByteBuf  # base64url of the fixed header
    var tmp: ByteBuf  # decode scratch
    var mac: BytePtr  # 32 bytes + 16 bytes timespec scratch

    def __init__(out self, secret: String):
        self.key = HmacKey(secret)
        self.header = ByteBuf(64)
        base64_encode('{"alg":"HS256","typ":"JWT"}', self.header, True, False)
        self.tmp = ByteBuf(512)
        self.mac = unsafe_alloc[UInt8](64)

    def now(self) -> Int:
        return unix_now(self.mac.unsafe_offset(32))

    def sign(mut self, user_id: Int, mut out: ByteBuf):
        """Appends a fresh token for `user_id` to `out`."""
        var now = self.now()
        var start = out.len
        out.put_bytes(self.header.ptr, self.header.len)
        out.put(46)  # .
        self.tmp.len = 0
        self.tmp.put_str('{"sub":"')
        self.tmp.put_int(user_id)
        self.tmp.put_str('","iat":')
        self.tmp.put_int(now)
        self.tmp.put_str(',"exp":')
        self.tmp.put_int(now + TOKEN_LIFETIME)
        self.tmp.put(125)  # }
        base64_encode(self.tmp.ptr, self.tmp.len, out, True, False)
        self.key.mac(out.ptr.unsafe_offset(start), out.len - start, self.mac)
        out.put(46)
        base64_encode(self.mac, 32, out, True, False)

    def verify(mut self, p: BytePtr, n: Int) -> Int:
        """The user id of a valid token, or -1. Valid: three base64url segments, a header with alg HS256, the
        right HMAC-SHA256 signature, `sub` a decimal string and `exp` an integer in the future."""
        if n < 5 or n > MAX_TOKEN_BYTES:
            return -1
        var d1 = -1
        var d2 = -1
        for i in range(n):
            if p[unsafe_offset=i] == 46:
                if d1 < 0:
                    d1 = i
                elif d2 < 0:
                    d2 = i
                else:
                    return -1
        if d1 <= 0 or d2 <= d1 + 1 or d2 >= n - 1:
            return -1

        # Signature first: it's cheap, and nothing else in the token is trusted until it matches.
        self.key.mac(p, d2, self.mac)
        self.tmp.len = 0
        if not base64_decode(p.unsafe_offset(d2 + 1), n - d2 - 1, self.tmp, True) or self.tmp.len != 32:
            return -1
        var diff: UInt8 = 0
        for i in range(32):
            diff |= self.tmp.ptr[unsafe_offset=i] ^ self.mac[unsafe_offset=i]
        if diff != 0:
            return -1

        self.tmp.len = 0
        if not base64_decode(p, d1, self.tmp, True):
            return -1
        var header = Json(self.tmp.ptr, self.tmp.len)
        if not header.ok:
            return -1
        var alg = header.get(0, "alg")
        if header.kind(alg) != T_STRING:
            return -1
        var at = header.toks[alg]
        if at.escaped or at.end - at.start != 5:
            return -1
        var a = self.tmp.ptr.unsafe_offset(at.start)
        if not (a[unsafe_offset=0] == 72 and a[unsafe_offset=1] == 83 and a[unsafe_offset=2] == 50
                and a[unsafe_offset=3] == 53 and a[unsafe_offset=4] == 54):  # "HS256"
            return -1

        self.tmp.len = 0
        if not base64_decode(p.unsafe_offset(d1 + 1), d2 - d1 - 1, self.tmp, True):
            return -1
        var claims = Json(self.tmp.ptr, self.tmp.len)
        if not claims.ok:
            return -1
        var exp_ok = False
        var exp = claims.int_value(claims.get(0, "exp"), exp_ok)
        if not exp_ok or exp <= self.now():
            return -1
        var sub = claims.get(0, "sub")
        if claims.kind(sub) != T_STRING:
            return -1
        var st = claims.toks[sub]
        var len = st.end - st.start
        if st.escaped or len == 0 or len > 18:
            return -1
        var id = 0
        for i in range(len):
            var c = self.tmp.ptr[unsafe_offset=st.start + i]
            if c < 48 or c > 57:
                return -1
            id = id * 10 + Int(c) - 48
        return id if id > 0 else -1

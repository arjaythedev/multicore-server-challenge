# SHA-256, HMAC-SHA256, PBKDF2-HMAC-SHA256 and base64, in Mojo. Used by the Postgres SCRAM login and by JWT.

from std.bit import rotate_bits_right
from std.memory.alloc import unsafe_alloc
from buf import BytePtr, ByteBuf

comptime State = SIMD[DType.uint32, 8]

comptime IV = State(
    0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
)

comptime K = SIMD[DType.uint32, 64](
    0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
    0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
    0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
    0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
    0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
    0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
    0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
    0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
)


@inline(.always)
def rotr[n: Int](x: UInt32) -> UInt32:
    return rotate_bits_right[n](x)


@inline(.always)
def load_be32(p: BytePtr) -> UInt32:
    return (
        (UInt32(p[unsafe_offset=0]) << 24)
        | (UInt32(p[unsafe_offset=1]) << 16)
        | (UInt32(p[unsafe_offset=2]) << 8)
        | UInt32(p[unsafe_offset=3])
    )


@inline(.always)
def store_be32(p: BytePtr, v: UInt32):
    p[unsafe_offset=0] = UInt8(v >> 24)
    p[unsafe_offset=1] = UInt8((v >> 16) & 0xFF)
    p[unsafe_offset=2] = UInt8((v >> 8) & 0xFF)
    p[unsafe_offset=3] = UInt8(v & 0xFF)


def compress(state: State, block: BytePtr) -> State:
    """One SHA-256 compression of a 64-byte block. The rounds are unrolled at compile time."""
    var w = Array[UInt32, 64](fill=0)
    comptime for i in range(16):
        w[i] = load_be32(block.unsafe_offset(i * 4))
    comptime for i in range(16, 64):
        var s0 = rotr[7](w[i - 15]) ^ rotr[18](w[i - 15]) ^ (w[i - 15] >> 3)
        var s1 = rotr[17](w[i - 2]) ^ rotr[19](w[i - 2]) ^ (w[i - 2] >> 10)
        w[i] = w[i - 16] + s0 + w[i - 7] + s1
    var a = state[0]
    var b = state[1]
    var c = state[2]
    var d = state[3]
    var e = state[4]
    var f = state[5]
    var g = state[6]
    var h = state[7]
    comptime for i in range(64):
        var t1 = h + (rotr[6](e) ^ rotr[11](e) ^ rotr[25](e)) + ((e & f) ^ (~e & g)) + K[i] + w[i]
        var t2 = (rotr[2](a) ^ rotr[13](a) ^ rotr[22](a)) + ((a & b) ^ (a & c) ^ (b & c))
        h = g
        g = f
        f = e
        e = d + t1
        d = c
        c = b
        b = a
        a = t1 + t2
    return state + State(a, b, c, d, e, f, g, h)


struct Sha256(Movable):
    """Streaming SHA-256. Can resume from a saved state (HMAC keys keep their padded-key states)."""

    var state: State
    var block: Array[UInt8, 64]
    var fill: Int
    var total: Int  # bytes hashed so far, including those in `block`

    def __init__(out self):
        self.state = IV
        self.block = Array[UInt8, 64](fill=0)
        self.fill = 0
        self.total = 0

    def __init__(out self, state: State, total: Int):
        """Resumes after `total` bytes (a multiple of 64) whose hash state is `state`."""
        self.state = state
        self.block = Array[UInt8, 64](fill=0)
        self.fill = 0
        self.total = total

    def update(mut self, p: BytePtr, n: Int):
        var i = 0
        self.total += n
        if self.fill > 0:
            while i < n and self.fill < 64:
                self.block[self.fill] = p[unsafe_offset=i]
                self.fill += 1
                i += 1
            if self.fill < 64:
                return
            self.state = compress(self.state, BytePtr(unsafe_from_address=Int(self.block.unsafe_ptr())))
            self.fill = 0
        while i + 64 <= n:
            self.state = compress(self.state, p.unsafe_offset(i))
            i += 64
        while i < n:
            self.block[self.fill] = p[unsafe_offset=i]
            self.fill += 1
            i += 1

    def update(mut self, s: StringSlice):
        self.update(BytePtr(unsafe_from_address=Int(s.unsafe_ptr())), s.byte_length())

    def finish(mut self, out_digest: BytePtr):
        """Writes the 32-byte digest."""
        var bits = UInt64(self.total) * 8
        var bp = BytePtr(unsafe_from_address=Int(self.block.unsafe_ptr()))
        self.block[self.fill] = 0x80
        self.fill += 1
        if self.fill > 56:
            while self.fill < 64:
                self.block[self.fill] = 0
                self.fill += 1
            self.state = compress(self.state, bp)
            self.fill = 0
        while self.fill < 56:
            self.block[self.fill] = 0
            self.fill += 1
        for i in range(8):
            self.block[56 + i] = UInt8((bits >> UInt64(56 - 8 * i)) & 0xFF)
        self.state = compress(self.state, bp)
        for i in range(8):
            store_be32(out_digest.unsafe_offset(i * 4), self.state[i])


def sha256(p: BytePtr, n: Int, out_digest: BytePtr):
    var h = Sha256()
    h.update(p, n)
    h.finish(out_digest)


struct HmacKey(ImplicitlyCopyable):
    """An HMAC-SHA256 key, kept as the hash states after the ipad and opad blocks, so each MAC costs only the
    message blocks plus two compressions."""

    var inner: State
    var outer: State

    def __init__(out self, key: BytePtr, key_len: Int):
        # Heap scratch, not local Arrays: a raw pointer into a local Array may see a stale copy of it.
        var k = unsafe_alloc[UInt8](128)
        var pad = k.unsafe_offset(64)
        for i in range(64):
            k[unsafe_offset=i] = 0
        if key_len > 64:
            sha256(key, key_len, k)
        else:
            for i in range(key_len):
                k[unsafe_offset=i] = key[unsafe_offset=i]
        for i in range(64):
            pad[unsafe_offset=i] = k[unsafe_offset=i] ^ 0x36
        self.inner = compress(IV, pad)
        for i in range(64):
            pad[unsafe_offset=i] = k[unsafe_offset=i] ^ 0x5C
        self.outer = compress(IV, pad)
        k.unsafe_free()

    def __init__(out self, key: StringSlice):
        self = HmacKey(BytePtr(unsafe_from_address=Int(key.unsafe_ptr())), key.byte_length())

    def start(self) -> Sha256:
        """A hash that has absorbed the inner padded key; feed it the message, then call `end`."""
        return Sha256(self.inner, 64)

    def end(self, mut inner: Sha256, out_mac: BytePtr):
        inner.finish(out_mac)
        var o = Sha256(self.outer, 64)
        o.update(out_mac, 32)
        o.finish(out_mac)

    def mac(self, p: BytePtr, n: Int, out_mac: BytePtr):
        var h = self.start()
        h.update(p, n)
        self.end(h, out_mac)

    def mac(self, s: StringSlice, out_mac: BytePtr):
        # Taking the slice keeps its String borrowed, so alive, for the whole call. Converting a local String to
        # a raw pointer at the call site doesn't: Mojo may free it before the callee runs.
        self.mac(BytePtr(unsafe_from_address=Int(s.unsafe_ptr())), s.byte_length(), out_mac)


def pbkdf2_sha256(password: BytePtr, password_len: Int, salt: BytePtr, salt_len: Int, iterations: Int,
                  out_key: BytePtr, key_len: Int):
    var key = HmacKey(password, password_len)
    var scratch = unsafe_alloc[UInt8](96)
    var u = scratch
    var t = scratch.unsafe_offset(32)
    var ctr = scratch.unsafe_offset(64)
    var block = 1
    var done = 0
    while done < key_len:
        store_be32(ctr, UInt32(block))
        var h = key.start()
        h.update(salt, salt_len)
        h.update(ctr, 4)
        key.end(h, u)
        for i in range(32):
            t[unsafe_offset=i] = u[unsafe_offset=i]
        for _ in range(1, iterations):
            key.mac(u, 32, u)
            for i in range(32):
                t[unsafe_offset=i] ^= u[unsafe_offset=i]
        var take = min(32, key_len - done)
        for i in range(take):
            out_key[unsafe_offset=done + i] = t[unsafe_offset=i]
        done += take
        block += 1
    scratch.unsafe_free()


# --- base64 ------------------------------------------------------------------------------------------------

comptime B64_STD = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
comptime B64_URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"


def base64_encode(src: BytePtr, n: Int, mut dst: ByteBuf, url: Bool, pad: Bool):
    var alphabet = B64_URL.ptr() if url else B64_STD.ptr()
    dst.reserve((n + 2) // 3 * 4)
    var i = 0
    while i + 3 <= n:
        var v = (UInt32(src[unsafe_offset=i]) << 16) | (UInt32(src[unsafe_offset=i + 1]) << 8) | UInt32(
            src[unsafe_offset=i + 2]
        )
        dst.put(alphabet[unsafe_offset=Int(v >> 18)])
        dst.put(alphabet[unsafe_offset=Int((v >> 12) & 63)])
        dst.put(alphabet[unsafe_offset=Int((v >> 6) & 63)])
        dst.put(alphabet[unsafe_offset=Int(v & 63)])
        i += 3
    var rest = n - i
    if rest == 1:
        var v = UInt32(src[unsafe_offset=i]) << 16
        dst.put(alphabet[unsafe_offset=Int(v >> 18)])
        dst.put(alphabet[unsafe_offset=Int((v >> 12) & 63)])
        if pad:
            dst.put_str("==")
    elif rest == 2:
        var v = (UInt32(src[unsafe_offset=i]) << 16) | (UInt32(src[unsafe_offset=i + 1]) << 8)
        dst.put(alphabet[unsafe_offset=Int(v >> 18)])
        dst.put(alphabet[unsafe_offset=Int((v >> 12) & 63)])
        dst.put(alphabet[unsafe_offset=Int((v >> 6) & 63)])
        if pad:
            dst.put_str("=")


@inline(.always)
def b64_value(c: UInt8, url: Bool) -> Int:
    if c >= 65 and c <= 90:
        return Int(c) - 65
    if c >= 97 and c <= 122:
        return Int(c) - 71
    if c >= 48 and c <= 57:
        return Int(c) + 4
    if url:
        if c == 45:  # '-'
            return 62
        if c == 95:  # '_'
            return 63
    else:
        if c == 43:  # '+'
            return 62
        if c == 47:  # '/'
            return 63
    return -1


def base64_decode(src: BytePtr, n: Int, mut dst: ByteBuf, url: Bool) -> Bool:
    """Decodes standard (padding optional) or URL-safe (no padding) base64. Returns False on invalid input,
    including non-zero leftover bits, so every byte string has exactly one accepted encoding."""
    var m = n
    if not url:
        while m > 0 and src[unsafe_offset=m - 1] == 61:  # '='
            m -= 1
        if n - m > 2 or (n - m > 0 and n % 4 != 0):
            return False
    if m % 4 == 1:
        return False
    dst.reserve(m * 3 // 4 + 3)
    var acc: UInt32 = 0
    var bits = 0
    for i in range(m):
        var v = b64_value(src[unsafe_offset=i], url)
        if v < 0:
            return False
        acc = (acc << 6) | UInt32(v)
        bits += 6
        if bits >= 8:
            bits -= 8
            dst.put(UInt8((acc >> UInt32(bits)) & 0xFF))
    if bits > 0 and (acc & ((UInt32(1) << UInt32(bits)) - 1)) != 0:
        return False
    return True


def hex_encode(src: BytePtr, n: Int, mut dst: ByteBuf):
    var digits = "0123456789abcdef".ptr()
    for i in range(n):
        dst.put(digits[unsafe_offset=Int(src[unsafe_offset=i] >> 4)])
        dst.put(digits[unsafe_offset=Int(src[unsafe_offset=i] & 15)])


def base64_encode(s: StringSlice, mut dst: ByteBuf, url: Bool, pad: Bool):
    """For a String: the slice keeps it alive for the call (see HmacKey.mac)."""
    base64_encode(BytePtr(unsafe_from_address=Int(s.unsafe_ptr())), s.byte_length(), dst, url, pad)


def base64_decode(s: StringSlice, mut dst: ByteBuf, url: Bool) -> Bool:
    return base64_decode(BytePtr(unsafe_from_address=Int(s.unsafe_ptr())), s.byte_length(), dst, url)

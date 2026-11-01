# bcrypt ($2a$/$2b$/$2y$, any cost), following OpenBSD's bcrypt.c: EksBlowfish key setup, then 64 encryptions
# of "OrpheanBeholderScryDoubt". Scalar for now; it runs in the bcrypt worker processes (bcrypt_worker.mojo).

from std.memory.alloc import unsafe_alloc
from buf import BytePtr, ByteBuf
from blowfish_pi import BLOWFISH_PI, BLOWFISH_WORDS

comptime P_WORDS = 18
comptime BCRYPT_ALPHABET = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
comptime HASH_LEN = 60  # "$2b$10$" + 22 salt chars + 31 hash chars
comptime MAX_PASSWORD_BYTES = 72


struct Blowfish:
    """The Blowfish state on the heap: P-array (18 words), then the four S-boxes (256 words each)."""

    var s: Pointer[UInt32, MutUntrackedOrigin]
    # One base pointer per S-box, so each lookup is a single register-offset load. Indexing all four from `s`
    # made LLVM add each box's offset first, an extra instruction on bcrypt's latency-bound critical path
    # (13% slower per hash).
    var b0: Pointer[UInt32, MutUntrackedOrigin]
    var b1: Pointer[UInt32, MutUntrackedOrigin]
    var b2: Pointer[UInt32, MutUntrackedOrigin]
    var b3: Pointer[UInt32, MutUntrackedOrigin]

    def __init__(out self):
        self.s = unsafe_alloc[UInt32](BLOWFISH_WORDS)
        self.b0 = self.s.unsafe_offset(P_WORDS)
        self.b1 = self.s.unsafe_offset(P_WORDS + 256)
        self.b2 = self.s.unsafe_offset(P_WORDS + 512)
        self.b3 = self.s.unsafe_offset(P_WORDS + 768)
        self.reset()

    def reset(mut self):
        for i in range(BLOWFISH_WORDS):
            self.s[unsafe_offset=i] = BLOWFISH_PI[i]

    def free(mut self):
        self.s.unsafe_free()

    @inline(.always)
    def f(self, x: UInt32) -> UInt32:
        var a = self.b0.unsafe_load(Int(x >> 24))
        var b = self.b1.unsafe_load(Int((x >> 16) & 0xFF))
        var c = self.b2.unsafe_load(Int((x >> 8) & 0xFF))
        var d = self.b3.unsafe_load(Int(x & 0xFF))
        return ((a + b) ^ c) + d

    @inline(.always)
    def encipher(self, mut xl: UInt32, mut xr: UInt32):
        var p = self.s
        var l = xl ^ p[unsafe_offset=0]
        var r = xr
        comptime for i in range(1, 17, 2):
            r ^= self.f(l) ^ p[unsafe_offset=i]
            l ^= self.f(r) ^ p[unsafe_offset=i + 1]
        xl = r ^ p[unsafe_offset=17]
        xr = l

    def expand(mut self, salt: BytePtr, key: BytePtr, key_len: Int):
        """Blowfish_expandstate: mix the key into P, then re-encrypt the whole state with the salt mixed in."""
        var j = 0
        for i in range(P_WORDS):
            self.s[unsafe_offset=i] ^= stream2word(key, key_len, j)
        var l: UInt32 = 0
        var r: UInt32 = 0
        var k = 0
        var i = 0
        while i < BLOWFISH_WORDS:
            l ^= stream2word(salt, 16, k)
            r ^= stream2word(salt, 16, k)
            self.encipher(l, r)
            self.s[unsafe_offset=i] = l
            self.s[unsafe_offset=i + 1] = r
            i += 2

    def expand0(mut self, key: BytePtr, key_len: Int):
        """Blowfish_expand0state: mix the key into P, then re-encrypt the whole state."""
        var j = 0
        for i in range(P_WORDS):
            self.s[unsafe_offset=i] ^= stream2word(key, key_len, j)
        var l: UInt32 = 0
        var r: UInt32 = 0
        var i = 0
        while i < BLOWFISH_WORDS:
            self.encipher(l, r)
            self.s[unsafe_offset=i] = l
            self.s[unsafe_offset=i + 1] = r
            i += 2


@inline(.always)
def stream2word(data: BytePtr, n: Int, mut j: Int) -> UInt32:
    var w: UInt32 = 0
    for _ in range(4):
        if j >= n:
            j = 0
        w = (w << 8) | UInt32(data[unsafe_offset=j])
        j += 1
    return w


def bcrypt_raw(mut bf: Blowfish, password: BytePtr, password_len: Int, salt: BytePtr, cost: Int, out24: BytePtr):
    """The 24-byte bcrypt output for (password, 16-byte salt, cost). Uses `bf` as scratch."""
    # The key is the password plus its NUL terminator; only its first 72 bytes are ever read.
    var key_len = min(password_len, MAX_PASSWORD_BYTES) + 1
    var key = unsafe_alloc[UInt8](key_len)
    for i in range(key_len - 1):
        key[unsafe_offset=i] = password[unsafe_offset=i]
    key[unsafe_offset=key_len - 1] = 0

    bf.reset()
    bf.expand(salt, key, key_len)
    var rounds = 1 << cost
    for _ in range(rounds):
        bf.expand0(key, key_len)
        bf.expand0(salt, 16)
    key.unsafe_free()

    var magic = "OrpheanBeholderScryDoubt".ptr()
    var c = unsafe_alloc[UInt32](6)
    var j = 0
    for i in range(6):
        c[unsafe_offset=i] = stream2word(BytePtr(unsafe_from_address=Int(magic)), 24, j)
    for _ in range(64):
        for b in range(3):
            var l = c[unsafe_offset=2 * b]
            var r = c[unsafe_offset=2 * b + 1]
            bf.encipher(l, r)
            c[unsafe_offset=2 * b] = l
            c[unsafe_offset=2 * b + 1] = r
    for i in range(6):
        var w = c[unsafe_offset=i]
        out24[unsafe_offset=4 * i] = UInt8(w >> 24)
        out24[unsafe_offset=4 * i + 1] = UInt8((w >> 16) & 0xFF)
        out24[unsafe_offset=4 * i + 2] = UInt8((w >> 8) & 0xFF)
        out24[unsafe_offset=4 * i + 3] = UInt8(w & 0xFF)
    c.unsafe_free()


def bcrypt_b64_encode(src: BytePtr, n: Int, mut out: ByteBuf):
    """bcrypt's base64: its own alphabet, no padding."""
    var a = BCRYPT_ALPHABET.ptr()
    var i = 0
    while i < n:
        var c1 = Int(src[unsafe_offset=i])
        i += 1
        out.put(a[unsafe_offset=c1 >> 2])
        c1 = (c1 & 0x03) << 4
        if i >= n:
            out.put(a[unsafe_offset=c1])
            break
        var c2 = Int(src[unsafe_offset=i])
        i += 1
        c1 |= c2 >> 4
        out.put(a[unsafe_offset=c1])
        c1 = (c2 & 0x0F) << 2
        if i >= n:
            out.put(a[unsafe_offset=c1])
            break
        c2 = Int(src[unsafe_offset=i])
        i += 1
        c1 |= c2 >> 6
        out.put(a[unsafe_offset=c1])
        out.put(a[unsafe_offset=c2 & 0x3F])


@inline(.always)
def b64_index(c: UInt8) -> Int:
    if c == 46:
        return 0
    if c == 47:
        return 1
    if c >= 65 and c <= 90:
        return Int(c) - 63
    if c >= 97 and c <= 122:
        return Int(c) - 69
    if c >= 48 and c <= 57:
        return Int(c) + 6
    return -1


def bcrypt_b64_decode(src: BytePtr, n_out: Int, dst: BytePtr) -> Bool:
    """Decodes `n_out` bytes (16 for a salt) from bcrypt base64."""
    var got = 0
    var i = 0
    while got < n_out:
        var c1 = b64_index(src[unsafe_offset=i])
        var c2 = b64_index(src[unsafe_offset=i + 1])
        if c1 < 0 or c2 < 0:
            return False
        dst[unsafe_offset=got] = UInt8(((c1 << 2) | ((c2 & 0x30) >> 4)) & 0xFF)
        got += 1
        if got >= n_out:
            break
        var c3 = b64_index(src[unsafe_offset=i + 2])
        if c3 < 0:
            return False
        dst[unsafe_offset=got] = UInt8((((c2 & 0x0F) << 4) | ((c3 & 0x3C) >> 2)) & 0xFF)
        got += 1
        if got >= n_out:
            break
        var c4 = b64_index(src[unsafe_offset=i + 3])
        if c4 < 0:
            return False
        dst[unsafe_offset=got] = UInt8((((c3 & 0x03) << 6) | c4) & 0xFF)
        got += 1
        i += 4
    return True


def bcrypt_hash(mut bf: Blowfish, password: BytePtr, password_len: Int, salt16: BytePtr, cost: Int,
                mut out: ByteBuf):
    """Appends the 60-character "$2b$<cost>$<salt><hash>" string."""
    out.put_str("$2b$")
    out.put(UInt8(48 + cost // 10))
    out.put(UInt8(48 + cost % 10))
    out.put(36)
    bcrypt_b64_encode(salt16, 16, out)
    var raw = unsafe_alloc[UInt8](24)
    bcrypt_raw(bf, password, password_len, salt16, cost, raw)
    bcrypt_b64_encode(raw, 23, out)
    raw.unsafe_free()


def bcrypt_verify(mut bf: Blowfish, password: BytePtr, password_len: Int, hash: BytePtr, hash_len: Int) -> Bool:
    """Checks a password against a "$2a$"/"$2b$"/"$2y$" hash, comparing in constant time."""
    if hash_len != HASH_LEN or hash[unsafe_offset=0] != 36 or hash[unsafe_offset=1] != 50:
        return False
    var v = hash[unsafe_offset=2]
    if (v != 97 and v != 98 and v != 121) or hash[unsafe_offset=3] != 36 or hash[unsafe_offset=6] != 36:
        return False
    var d1 = Int(hash[unsafe_offset=4]) - 48
    var d2 = Int(hash[unsafe_offset=5]) - 48
    if d1 < 0 or d1 > 9 or d2 < 0 or d2 > 9:
        return False
    var cost = d1 * 10 + d2
    if cost < 4 or cost > 31:
        return False
    var salt = unsafe_alloc[UInt8](16 + 24)
    var raw = salt.unsafe_offset(16)
    if not bcrypt_b64_decode(hash.unsafe_offset(7), 16, salt):
        salt.unsafe_free()
        return False
    bcrypt_raw(bf, password, password_len, salt, cost, raw)
    var mine = ByteBuf(32)
    bcrypt_b64_encode(raw, 23, mine)
    salt.unsafe_free()
    var diff: UInt8 = 0
    for i in range(31):
        diff |= mine.ptr[unsafe_offset=i] ^ hash[unsafe_offset=29 + i]
    mine.free()
    return diff == 0


def bcrypt_verify(mut bf: Blowfish, password: StringSlice, hash: StringSlice) -> Bool:
    """For Strings: the slices keep them alive for the call."""
    return bcrypt_verify(
        bf, BytePtr(unsafe_from_address=Int(password.unsafe_ptr())), password.byte_length(),
        BytePtr(unsafe_from_address=Int(hash.unsafe_ptr())), hash.byte_length(),
    )

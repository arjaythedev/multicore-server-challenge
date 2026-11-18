# Prints SHA-256 / HMAC / PBKDF2 / base64 results for generated inputs; tests/check_crypto.py computes the same
# lines with Python's hashlib, hmac and base64 and compares.
#
#   mojo build -I src tests/test_crypto.mojo -o /tmp/test_crypto && /tmp/test_crypto | python3 tests/check_crypto.py

from std.memory.alloc import unsafe_alloc
from buf import BytePtr, ByteBuf, to_string
from crypto import sha256, Sha256, HmacKey, pbkdf2_sha256, base64_encode, base64_decode, hex_encode
from linux import log


def fill(p: BytePtr, n: Int, seed: Int):
    for i in range(n):
        p[unsafe_offset=i] = UInt8((i * 31 + seed * 7 + n) & 0xFF)


def hex(p: BytePtr, n: Int) -> String:
    var b = ByteBuf(64)
    hex_encode(p, n, b)
    var s = to_string(b.ptr, b.len)
    b.free()
    return s


def text(b: ByteBuf) -> String:
    return to_string(b.ptr, b.len)


def main():
    var a = unsafe_alloc[UInt8](1_000_000)
    var k = unsafe_alloc[UInt8](256)
    var d = unsafe_alloc[UInt8](64)

    for n in range(201):
        fill(a, n, 1)
        sha256(a, n, d)
        log("sha " + String(n) + " " + hex(d, 32))
    for n in [1000, 4096, 100_000]:
        fill(a, n, 1)
        sha256(a, n, d)
        log("sha " + String(n) + " " + hex(d, 32))
    # streaming in odd-sized pieces must match one-shot
    fill(a, 100_000, 1)
    var h = Sha256()
    var off = 0
    var step = 1
    while off < 100_000:
        var take = min(step, 100_000 - off)
        h.update(a.unsafe_offset(off), take)
        off += take
        step = step * 3 % 97 + 1
    h.finish(d)
    log("sha 100000 " + hex(d, 32))
    for i in range(1_000_000):
        a[unsafe_offset=i] = 97
    sha256(a, 1_000_000, d)
    log("sha_a 1000000 " + hex(d, 32))

    for kl in [0, 1, 20, 32, 63, 64, 65, 131]:
        for ml in [0, 1, 55, 56, 63, 64, 65, 200]:
            fill(k, kl, 2)
            fill(a, ml, 3)
            var key = HmacKey(k, kl)
            key.mac(a, ml, d)
            log("hmac " + String(kl) + " " + String(ml) + " " + hex(d, 32))

    var cases = [(8, 16, 1, 32), (8, 16, 2, 32), (8, 16, 4096, 32), (5, 4, 1, 64), (12, 20, 10, 40), (70, 9, 3, 32)]
    for c in cases:
        fill(k, c[0], 4)
        fill(a, c[1], 5)
        pbkdf2_sha256(k, c[0], a, c[1], c[2], d, c[3])
        log("pbkdf2 " + String(c[0]) + " " + String(c[1]) + " " + String(c[2]) + " " + String(c[3]) + " "
            + hex(d, c[3]))

    for n in range(70):
        fill(a, n, 6)
        var s1 = ByteBuf(128)
        var s2 = ByteBuf(128)
        var s3 = ByteBuf(128)
        base64_encode(a, n, s1, False, True)
        base64_encode(a, n, s2, False, False)
        base64_encode(a, n, s3, True, False)
        var r1 = ByteBuf(128)
        var r2 = ByteBuf(128)
        var r3 = ByteBuf(128)
        var ok1 = base64_decode(s1.ptr, s1.len, r1, False)
        var ok2 = base64_decode(s2.ptr, s2.len, r2, False)
        var ok3 = base64_decode(s3.ptr, s3.len, r3, True)
        var round = ok1 and ok2 and ok3 and r1.len == n and r2.len == n and r3.len == n
        for i in range(r1.len if round else 0):
            if r1.ptr[unsafe_offset=i] != a[unsafe_offset=i] or r3.ptr[unsafe_offset=i] != a[unsafe_offset=i]:
                round = False
        log("b64 " + String(n) + " " + text(s1) + " " + text(s2) + " " + text(s3) + " "
            + ("roundtrip" if round else "BROKEN"))
        s1.free()
        s2.free()
        s3.free()
        r1.free()
        r2.free()
        r3.free()

    # inputs that must be rejected: bad chars, wrong alphabet, bad padding, dangling bits, impossible lengths
    for bad in ["a", "ab=c", "abc*", "a+b/", "YQ===", "YR", "YQ=x", "Zm9vYg="]:
        var r = ByteBuf(16)
        var url = bad == "a+b/"
        var s = String(bad)
        var ok = base64_decode(s, r, url)
        log("b64bad " + bad + " " + ("accepted" if ok else "rejected"))
        r.free()

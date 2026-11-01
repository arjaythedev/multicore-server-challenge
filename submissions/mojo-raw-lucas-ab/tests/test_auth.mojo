# Reads one command per line on stdin and prints one result line each; tests/check_auth.py drives it.
#   verify <password hex> <hash>        -> ok | bad
#   hash <password hex> <$2b$NN$salt>   -> the 60-char hash
#   json <hex>                          -> valid | invalid
#   jstr <hex>                          -> hex of the decoded root string | invalid
#   jwt <secret>                        -> lines of "jwt <case> <pass|FAIL>"
#   bench <cost>                        -> milliseconds for one hash at that cost

from std.memory.alloc import unsafe_alloc
from buf import BytePtr, ByteBuf, to_string
from linux import sys_read, log, sys_clock_gettime, CLOCK_MONOTONIC
from bcrypt import Blowfish, bcrypt_hash, bcrypt_verify, bcrypt_b64_decode
from crypto import hex_encode, base64_encode, HmacKey
from jsonin import Json, T_STRING
from jwt import Jwt


def unhex(s: StringSlice, mut out: ByteBuf):
    var p = s.unsafe_ptr()
    for i in range(0, s.byte_length() - 1, 2):
        out.put(UInt8(hexd(p[unsafe_offset=i]) * 16 + hexd(p[unsafe_offset=i + 1])))


def hexd(c: UInt8) -> Int:
    return Int(c) - 48 if c <= 57 else Int(c | 0x20) - 87


def as_hex(p: BytePtr, n: Int) -> String:
    var b = ByteBuf(2 * n + 2)
    hex_encode(p, n, b)
    var s = to_string(b.ptr, b.len)
    b.free()
    return s


def monotonic_ms(ts: BytePtr) -> Float64:
    _ = sys_clock_gettime(CLOCK_MONOTONIC, Int(ts))
    var t = ts.unsafe_bitcast[Int64]()
    return Float64(Int(t[unsafe_offset=0])) * 1000.0 + Float64(Int(t[unsafe_offset=1])) / 1_000_000.0


def check(name: String, ok: Bool):
    log("jwt " + name + " " + ("pass" if ok else "FAIL"))


def jwt_cases(secret: String):
    var j = Jwt(secret)
    var tok = ByteBuf(256)
    j.sign(4242, tok)
    check("roundtrip", j.verify(tok.ptr, tok.len) == 4242)
    var t2 = ByteBuf(256)
    t2.put_bytes(tok.ptr, tok.len)
    t2.ptr[unsafe_offset=t2.len - 3] ^= 1
    check("tampered-signature", j.verify(t2.ptr, t2.len) == -1)
    var other = Jwt(secret + "x")
    check("wrong-secret", other.verify(tok.ptr, tok.len) == -1)
    check("truncated", j.verify(tok.ptr, tok.len - 1) == -1)
    check("garbage", j.verify(BytePtr(unsafe_from_address=Int("not.a.jwt".ptr())), 9) == -1)

    # Hand-built tokens signed with the right key, to check the claim rules.
    var key = HmacKey(secret)
    var now = j.now()
    var cases = List[String]()
    var want = List[Int]()
    cases.append('{"sub":"77","iat":' + String(now) + ',"exp":' + String(now + 60) + "}")
    want.append(77)
    cases.append('{"sub":"77","iat":' + String(now - 100) + ',"exp":' + String(now - 1) + "}")  # expired
    want.append(-1)
    cases.append('{"sub":"77","iat":' + String(now) + "}")  # no exp
    want.append(-1)
    cases.append('{"sub":77,"iat":' + String(now) + ',"exp":' + String(now + 60) + "}")  # numeric sub
    want.append(-1)
    cases.append('{"sub":"abc","iat":' + String(now) + ',"exp":' + String(now + 60) + "}")
    want.append(-1)
    cases.append('{"sub":"","exp":' + String(now + 60) + "}")
    want.append(-1)
    cases.append('{"sub":"9","exp":"' + String(now + 60) + '"}')  # exp as a string
    want.append(-1)
    var headers = List[String]()
    headers.append('{"alg":"HS256","typ":"JWT"}')
    headers.append('{"alg":"none","typ":"JWT"}')
    headers.append('{"typ":"JWT"}')
    headers.append('{"alg":"HS512"}')
    for h in range(len(headers)):
        for c in range(len(cases)):
            var t = ByteBuf(512)
            var hs = headers[h]
            var cs = cases[c]
            base64_encode(hs, t, True, False)
            t.put(46)
            base64_encode(cs, t, True, False)
            var mac = unsafe_alloc[UInt8](32)
            key.mac(t.ptr, t.len, mac)
            t.put(46)
            base64_encode(mac, 32, t, True, False)
            mac.unsafe_free()
            var expect = want[c] if h == 0 else -1
            check("header" + String(h) + "-claims" + String(c), j.verify(t.ptr, t.len) == expect)
            t.free()


def main():
    var input = ByteBuf(1 << 20)
    while True:
        input.reserve(1 << 16)
        var r = sys_read(0, Int(input.tail()), input.cap - input.len)
        if r <= 0:
            break
        input.len += r
    var text = to_string(input.ptr, input.len)
    var bf = Blowfish()
    var ts = unsafe_alloc[UInt8](16)
    for line in text.split("\n"):
        var parts = String(line).split(" ")
        if len(parts) == 0 or parts[0] == "":
            continue
        var cmd = String(parts[0])
        if cmd == "verify":
            var pw = ByteBuf(128)
            unhex(parts[1], pw)
            var h = String(parts[2])
            var ok = bcrypt_verify(bf, pw.ptr, pw.len, BytePtr(unsafe_from_address=Int(h.unsafe_ptr())), h.byte_length())
            _ = h^  # keep h alive past the raw-pointer call
            log("ok" if ok else "bad")
            pw.free()
        elif cmd == "hash":
            var pw = ByteBuf(128)
            unhex(parts[1], pw)
            var s = String(parts[2])
            var cost = Int(s.as_bytes()[4] - 48) * 10 + Int(s.as_bytes()[5] - 48)
            var salt = unsafe_alloc[UInt8](16)
            _ = bcrypt_b64_decode(BytePtr(unsafe_from_address=Int(s.unsafe_ptr())).unsafe_offset(7), 16, salt)
            _ = s^  # keep s alive past the raw-pointer call
            var out = ByteBuf(64)
            bcrypt_hash(bf, pw.ptr, pw.len, salt, cost, out)
            log(to_string(out.ptr, out.len))
            out.free()
            salt.unsafe_free()
            pw.free()
        elif cmd == "json" or cmd == "jstr":
            var raw = ByteBuf(256)
            if len(parts) > 1:
                unhex(parts[1], raw)
            var j = Json(raw.ptr, raw.len)
            if cmd == "json":
                log("valid" if j.ok else "invalid")
            else:
                var out = ByteBuf(256)
                if j.ok and j.kind(0) == T_STRING and j.string_value(0, out):
                    log("hex:" + as_hex(out.ptr, out.len))
                else:
                    log("invalid")
                out.free()
            raw.free()
        elif cmd == "jwt":
            jwt_cases(String(parts[1]))
        elif cmd == "bench":
            var cost = 10
            try:
                cost = Int(String(parts[1]))
            except:
                pass
            var salt = unsafe_alloc[UInt8](16)
            for i in range(16):
                salt[unsafe_offset=i] = UInt8(i * 17)
            var out = ByteBuf(64)
            var pw = String("password123")
            var t0 = monotonic_ms(ts)
            bcrypt_hash(bf, BytePtr(unsafe_from_address=Int(pw.unsafe_ptr())), 11, salt, cost, out)
            _ = pw^
            var t1 = monotonic_ms(ts)
            log("bench " + String(cost) + " " + String(t1 - t0))
            out.free()
            salt.unsafe_free()

"""Reads tests/test_crypto.mojo's output on stdin and checks every line against Python's hashlib/hmac/base64.

    /tmp/test_crypto 2>&1 | python3 tests/check_crypto.py
"""
import base64
import hashlib
import hmac
import sys


def fill(n, seed):
    return bytes((i * 31 + seed * 7 + n) & 0xFF for i in range(n))


def expect(fields):
    kind = fields[0]
    if kind == "sha":
        return hashlib.sha256(fill(int(fields[1]), 1)).hexdigest()
    if kind == "sha_a":
        return hashlib.sha256(b"a" * int(fields[1])).hexdigest()
    if kind == "hmac":
        return hmac.new(fill(int(fields[1]), 2), fill(int(fields[2]), 3), hashlib.sha256).hexdigest()
    if kind == "pbkdf2":
        pw, salt, it, dk = map(int, fields[1:5])
        return hashlib.pbkdf2_hmac("sha256", fill(pw, 4), fill(salt, 5), it, dk).hex()
    if kind == "b64":
        data = fill(int(fields[1]), 6)
        std = base64.b64encode(data).decode()
        url = base64.urlsafe_b64encode(data).decode().rstrip("=")
        return " ".join((std, std.rstrip("="), url, "roundtrip"))
    if kind == "b64bad":
        return "rejected"
    raise ValueError(kind)


known = {  # the standard published vectors, as a sanity check on the generator itself
    hashlib.sha256(b"a" * 1000000).hexdigest(): "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
}
for got, want in known.items():
    assert got == want, "python hashlib itself disagrees with the published vector?"

lines = [l.rstrip("\n") for l in sys.stdin if l.strip()]
bad = 0
for line in lines:
    f = line.split(" ")
    kind = f[0]
    n_key = {"sha": 2, "sha_a": 2, "hmac": 3, "pbkdf2": 5, "b64": 2, "b64bad": 2}[kind]
    got = " ".join(f[n_key:])
    want = expect(f)
    if got != want:
        bad += 1
        print("MISMATCH", " ".join(f[:n_key]), "\n  got ", got, "\n  want", want)
counts = {}
for line in lines:
    counts[line.split(" ")[0]] = counts.get(line.split(" ")[0], 0) + 1
print("checked", len(lines), "lines", counts)
print("CRYPTO PASS" if bad == 0 and len(lines) > 300 else f"CRYPTO FAIL ({bad} mismatches)")
sys.exit(1 if bad else 0)

"""Drives tests/test_auth.mojo: bcrypt against Python's bcrypt package and real seed hashes, the JSON tokenizer
against Python's json module, and the JWT claim rules.

    python3 tests/check_auth.py /tmp/test_auth [seed-hashes-file]

seed-hashes-file: lines "<hash>" for seeded users (password "password123"), e.g. from
    psql -At -d conduit_dev -c "select password_hash from users order by id limit 8"
Needs the bcrypt package (pip install bcrypt).
"""
import json
import os
import random
import subprocess
import sys

import bcrypt

binary = sys.argv[1]
seed_hashes = open(sys.argv[2]).read().split() if len(sys.argv) > 2 else []
rnd = random.Random(7)
cmds, checks = [], []


def add(cmd, check):
    cmds.append(cmd)
    checks.append(check)


# bcrypt: hashes must equal Python's, byte for byte, for the same salt
for i in range(60):
    n = rnd.choice([0, 1, 2, 3, 7, 11, 20, 31, 32, 55, 64, 71, 72]) if i < 50 else rnd.randint(1, 72)
    pw = bytes(rnd.choice(range(1, 256)) for _ in range(n))  # no NUL: C bcrypt stops there
    cost = 4 if i < 55 else 6
    salt = bcrypt.gensalt(cost).decode()
    expect = bcrypt.hashpw(pw, salt.encode()).decode()
    add(f"hash {pw.hex()} {salt}", ("hash", expect))
    add(f"verify {pw.hex()} {expect}", ("verify", "ok"))
    # change a byte rather than append one: bcrypt reads only the first 72 bytes
    wrong = pw[:-1] + bytes([pw[-1] % 255 + 1]) if pw else b"x"
    add(f"verify {wrong.hex()} {expect}", ("verify-wrong", "bad"))
# one at the real cost
salt = bcrypt.gensalt(10).decode()
add(f"hash {b'conformance-pass-1'.hex()} {salt}", ("hash10", bcrypt.hashpw(b"conformance-pass-1", salt.encode()).decode()))
# $2a$ hashes made by Go's bcrypt (the seed) and Python's $2b$, both verify; wrong passwords don't
for h in seed_hashes:
    add(f"verify {b'password123'.hex()} {h}", ("seed", "ok"))
    add(f"verify {b'password124'.hex()} {h}", ("seed-wrong", "bad"))
add(f"verify {b'x'.hex()} $2b$10$tooshort", ("malformed-hash", "bad"))

# JSON validity must match Python's strict parser (no NaN/Infinity in our inputs)
docs = [
    '{"user":{"username":"a","email":"b","password":"c"}}', '{}', '[]', '""', '0', '-0', '1.5e3', 'true', 'null',
    '{"a":[1,2,{"b":null}],"c":"\\u00e9\\n"}', '  {"a" : 1 }  ', '{"user": {"username": "u_x",', '', ' ',
    '{"a":1,}', '[1,]', '{"a" 1}', '{a:1}', "{'a':1}", '01', '1.', '.5', '-', '1e', '"\\x"', '"\\u12"', '"a\nb"',
    'tru', 'nul', '{"a":1}x', '[1 2]', '{"a":"b"}}', '"\\ud83d\\ude00"', '[[[[[[[[[[[[[[[[[[[[1]]]]]]]]]]]]]]]]]]]]',
    '{"user":"u_x"}', '{"n":-12.5e-3}', '"tab\there"', '"\\/"',
]
for d in docs:
    try:
        json.loads(d)
        valid = "valid"
    except ValueError:
        valid = "invalid"
    add("json " + d.encode().hex(), ("json " + repr(d), valid))
for s in ['"plain"', '"\\u00e9t\\u00e9"', '"\\ud83d\\ude00!"', '"a\\"b\\\\c\\/d\\b\\f\\n\\r\\t"', '"\\ud83d"', '"\\ude00"']:
    try:
        value = json.loads(s).encode("utf-8")
        expect = "hex:" + value.hex()
    except (ValueError, UnicodeEncodeError):
        expect = "invalid"  # lone surrogates can't become UTF-8
    add("jstr " + s.encode().hex(), ("jstr " + s, expect))

add("jwt multicore-server-challenge", ("jwt", None))
add("bench 10", ("bench", None))

out = subprocess.run([binary], input="\n".join(cmds) + "\n", capture_output=True, text=True, timeout=600)
lines = (out.stdout + out.stderr).splitlines()
bad = 0
i = 0
for cmd, (what, expect) in zip(cmds, checks):
    if what == "jwt":
        while i < len(lines) and lines[i].startswith("jwt "):
            if not lines[i].endswith(" pass"):
                bad += 1
                print("FAIL", lines[i])
            i += 1
        continue
    got = lines[i] if i < len(lines) else "<missing>"
    i += 1
    if what == "bench":
        print(got.replace("bench 10", "one bcrypt hash at cost 10:") + " ms")
        continue
    if got != expect:
        bad += 1
        print("FAIL", what, "\n  cmd ", cmd[:120], "\n  got ", got, "\n  want", expect)
print(f"{len(cmds)} commands, {len(seed_hashes)} seed hashes")
print("AUTH PASS" if bad == 0 else f"AUTH FAIL ({bad})")
sys.exit(1 if bad else 0)

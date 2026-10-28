"""Check libcrypt compatibility fallbacks against a running isolated server."""
import ctypes
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

crypt = ctypes.CDLL('libcrypt.so.1')
crypt.crypt_rn.restype = ctypes.c_char_p
crypt.crypt_gensalt_rn.restype = ctypes.c_char_p
prefix = 'fallback_' + str(time.time_ns())
base = sys.argv[1]
cases = [(b'$2a$', 'é'), (b'$2a$', 'ÿ£'), (b'$2a$', 'A🙂Z'),
         (b'$2b$', 'é'), (b'$2b$', 'a' * 72), (b'$2y$', 'password123')]
for i, (version, password) in enumerate(cases):
    salt = ctypes.create_string_buffer(64)
    assert crypt.crypt_gensalt_rn(version, 10, None, 0, salt, 64)
    data = ctypes.create_string_buffer(32768)
    hashed = crypt.crypt_rn(password.encode(), salt, data, 32768).decode()
    name = prefix + str(i)
    email = name + '@example.com'
    sql = "INSERT INTO users (username,email,password_hash) VALUES ('%s','%s','%s')" % (name, email, hashed)
    subprocess.run(['psql', os.environ['DATABASE_URL'], '-Xq', '-v', 'ON_ERROR_STOP=1', '-c', sql], check=True)
    for candidate, expected in [(password, 200), (password[:-1] + '!', 401)]:
        body = json.dumps({'user': {'email': email, 'password': candidate}}).encode()
        req = urllib.request.Request(base + '/api/users/login', body, {'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                status = response.status
        except urllib.error.HTTPError as error:
            status = error.code
        assert status == expected, (version, i, status, expected)
print('libcrypt $2a$ high-bit / $2y$ fallbacks and $2b$ inputs: matching passwords accepted, wrong passwords rejected')

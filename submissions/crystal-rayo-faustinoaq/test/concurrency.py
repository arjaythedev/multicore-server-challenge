"""Exercise deferred bcrypt callbacks, disconnects, pipelines and gzip middleware."""
import concurrent.futures
import gzip
import json
import socket
import sys
import time
import urllib.parse
import urllib.request

base = sys.argv[1]
name = 'rayo_mc_' + str(time.time_ns())
user = {'username': name, 'email': name + '@example.com', 'password': 'a secure test password'}


def request(path, method='GET', body=None, encoding='identity'):
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(base + path, data, method=method,
                                 headers={'Content-Type': 'application/json', 'Accept-Encoding': encoding})
    with urllib.request.urlopen(req, timeout=30) as response:
        raw = response.read()
        compressed = response.headers.get('Content-Encoding') == 'gzip'
        return json.loads(gzip.decompress(raw) if compressed else raw), compressed


request('/api/users', 'POST', {'user': user})
login = {'user': {'email': user['email'], 'password': user['password']}}
with concurrent.futures.ThreadPoolExecutor(max_workers=24) as pool:
    responses = list(pool.map(lambda _: request('/api/users/login', 'POST', login)[0], range(24)))
assert all(r['user']['username'] == name for r in responses)

url = urllib.parse.urlsplit(base)
body = json.dumps(login).encode()
wire = (b'POST /api/users/login HTTP/1.1\r\nHost: test\r\nContent-Type: application/json\r\n'
        + b'Content-Length: ' + str(len(body)).encode() + b'\r\n\r\n' + body)
# Close while bcrypt is pending; its completion must not target a reused connection.
for _ in range(12):
    with socket.create_connection((url.hostname, url.port), timeout=30) as sock:
        sock.sendall(wire)
with socket.create_connection((url.hostname, url.port), timeout=30) as sock:
    sock.sendall(wire + b'GET /api/tags HTTP/1.1\r\nHost: test\r\n\r\n')
    stream = sock.makefile('rb')
    for expected in ('user', 'tags'):
        assert stream.readline().startswith(b'HTTP/1.1 200 ')
        headers = {}
        while (line := stream.readline()) != b'\r\n':
            key, value = line.decode().split(':', 1)
            headers[key.lower()] = value.strip()
        result = json.loads(stream.read(int(headers['content-length'])))
        assert expected in result

# Repeated concurrent result serialization also exercises collection after fork.
def articles(_):
    for _ in range(20):
        page, _ = request('/api/articles?limit=20')
        assert len(page['articles']) == 20


with concurrent.futures.ThreadPoolExecutor(max_workers=40) as pool:
    list(pool.map(articles, range(40)))

plain, compressed = request('/api/articles?limit=20')
assert not compressed
zipped, compressed = request('/api/articles?limit=20', encoding='gzip')
assert compressed and plain == zipped
for encoding in ('gzip;q=0', 'gzip;q=0.000', 'br, gzip; q=0'):
    same, compressed = request('/api/articles?limit=20', encoding=encoding)
    assert not compressed and same == plain
print('PASS: 24 concurrent logins, pending-job disconnects, ordered pipeline, 800 article requests, gzip and q=0')

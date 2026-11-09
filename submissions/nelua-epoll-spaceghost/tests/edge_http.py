#!/usr/bin/env python3
"""Nondestructive HTTP framing, auth, keep-alive and pipeline checks.

Run against a disposable, already-running Conduit test instance. BASE_URL defaults
http://127.0.0.1:3000. No valid create/update/delete operation is issued.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import http.client
import json
import os
import socket
import time
from urllib.parse import urlsplit


class Reader:
    def __init__(self, connection):
        self.connection = connection
        self.pending = b''

    def read(self):
        while b'\r\n\r\n' not in self.pending:
            block = self.connection.recv(65536)
            if not block:
                raise AssertionError('connection closed before response headers')
            self.pending += block
            assert len(self.pending) <= 2 * 1024 * 1024
        raw, self.pending = self.pending.split(b'\r\n\r\n', 1)
        lines = raw.decode('ascii').split('\r\n')
        version, status, _ = lines[0].split(' ', 2)
        assert version == 'HTTP/1.1'
        headers = {}
        for line in lines[1:]:
            name, value = line.split(':', 1)
            name = name.lower()
            assert name not in headers, f'duplicate response header {name}'
            headers[name] = value.strip()
        assert 'content-length' in headers, 'response has no explicit framing'
        length = int(headers['content-length'])
        assert 0 <= length <= 16 * 1024 * 1024
        while len(self.pending) < length:
            block = self.connection.recv(65536)
            assert block, 'connection closed before complete response body'
            self.pending += block
        body, self.pending = self.pending[:length], self.pending[length:]
        status = int(status)
        if status == 204:
            assert not body
        else:
            assert headers.get('content-type', '').split(';')[0] == 'application/json'
            decoded = json.loads(body)
            if status >= 400:
                assert isinstance(decoded.get('errors', {}).get('body'), list)
        return status, headers, body


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', default=os.environ.get('BASE_URL', 'http://127.0.0.1:3000'))
    parser.add_argument('--idle-connections', type=int, default=64)
    parser.add_argument('--idle-seconds', type=float, default=0.25,
                        help='set 66 to verify the nginx keep-alive compatibility window')
    args = parser.parse_args()
    base = urlsplit(args.base)
    if base.scheme != 'http' or not base.hostname or base.path not in ('', '/'):
        parser.error('base must be an HTTP origin without a path')
    if not 1 <= args.idle_connections <= 1024 or not 0 <= args.idle_seconds <= 70:
        parser.error('idle connections must be1..1024 and idle seconds0..70')
    address = (base.hostname, base.port or 80)
    checks = 0

    def done(label):
        nonlocal checks
        checks += 1
        print(f'ok {checks}: {label}', flush=True)

    def connect():
        result = socket.create_connection(address, timeout=5)
        result.settimeout(5)
        return result

    def request(path=b'/api/tags', headers=b'', body=b'', method=b'GET', close=False):
        return (method+b' '+path+b' HTTP/1.1\r\nHost: test\r\n'+headers+
                (b'Connection: close\r\n' if close else b'')+
                b'Content-Length: '+str(len(body)).encode()+b'\r\n\r\n'+body)

    with connect() as connection:
        reader = Reader(connection)
        connection.sendall(request())
        status, headers, body = reader.read()
        assert status == 200 and isinstance(json.loads(body)['tags'], list)
        assert headers['connection'] == 'keep-alive'
        done('valid JSON health response and explicit keep-alive framing')
        connection.sendall(request()+request())
        first, second = reader.read(), reader.read()
        assert first[0] == second[0] == 200 and json.loads(first[2]) == json.loads(second[2])
        done('two pipelined requests retain boundaries and response order')
        connection.sendall(request(close=True))
        assert reader.read()[0] == 200
        assert not reader.pending and connection.recv(1) == b''
        done('Connection close completes the body then closes the socket')

    with connect() as connection:
        reader = Reader(connection)
        raw = request(body=b'{}')
        split = raw.index(b'\r\n\r\n')+4
        connection.sendall(raw[:split])
        connection.settimeout(0.05)
        try:
            assert connection.recv(1) == b'', 'server responded before Content-Length body arrived'
            raise AssertionError('server closed a valid partial request')
        except socket.timeout:
            pass
        connection.settimeout(5)
        connection.sendall(raw[split:])
        assert reader.read()[0] == 200
        done('partial request waits for the entire framed body')

    with connect() as connection:
        connection.sendall(request())
        connection.shutdown(socket.SHUT_WR)
        reader = Reader(connection)
        assert reader.read()[0] == 200
        assert not reader.pending and connection.recv(1) == b''
        done('read-half-closed peer receives a complete response')

    malformed = [
        ('conflicting content lengths', b'Content-Length: 0\r\nContent-Length: 4\r\n'),
        ('transfer encoding', b'Transfer-Encoding: chunked\r\n'),
        ('transfer encoding plus content length', b'Transfer-Encoding: chunked\r\nContent-Length: 0\r\n'),
        ('negative content length', b'Content-Length: -1\r\n'),
        ('invalid header field', b'Bad Header: x\r\n'),
        ('NUL in header value', b'X-Test: x\x00y\r\n'),
    ]
    for label, headers in malformed:
        with connect() as connection:
            connection.sendall(b'GET /api/tags HTTP/1.1\r\nHost: test\r\n'+headers+b'\r\n'+request())
            reader = Reader(connection)
            status, response_headers, _ = reader.read()
            assert status == 400, (label, status)
            assert response_headers['connection'] == 'close'
            assert not reader.pending and connection.recv(1) == b''
        done(label+' rejected without accepting a smuggled successor')

    for label, raw in [
        ('oversized declared body', b'GET /api/tags HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n'),
        ('oversized headers', b'GET /api/tags HTTP/1.1\r\nX-Test: '+b'x'*32768+b'\r\n\r\n'),
    ]:
        with connect() as connection:
            connection.sendall(raw)
            assert Reader(connection).read()[0] in (413,431)
        done(label+' bounded before allocation')

    def single(path, headers=None, body=b'', method='GET'):
        connection = http.client.HTTPConnection(*address, timeout=5)
        try:
            values = {'Content-Type': 'application/json'}
            values.update(headers or {})
            connection.request(method,path,body,values)
            response = connection.getresponse()
            data = response.read()
            if data:
                assert response.getheader('Content-Type').split(';')[0] == 'application/json'
                json.loads(data)
            return response.status, data
        finally:
            connection.close()

    for header in ('Bearer x','Token invalid','Token a.b.c',''):
        status, body = single('/api/profiles/edge-check-absent', {'Authorization': header})
        assert status == 401 and isinstance(json.loads(body)['errors']['body'],list)
    done('malformed optional authentication rejects before profile lookup')
    assert single('/api/tags', {'Authorization':'Token invalid'})[0] == 200
    done('public tags route remains independent of optional-auth routes')

    for body in (b'{',b'null',b'[]',b'{"user":null}',b'{"user":{"username":"\\ud800"}}',
                 b'{"user":{"username":"\\u0000"}}',b'{"User":{"username":"x"}}'):
        assert single('/api/users', {}, body, 'POST')[0] == 422
    done('malformed, invalid-Unicode, NUL and wrong-wrapper JSON rejected without writes')
    for path in ('/api/articles?limit=0','/api/articles?limit=101','/api/articles?limit=',
                 '/api/articles?offset=-1','/api/articles?offset=9223372036854775808'):
        assert single(path)[0] == 422
    done('pagination rejects invalid ranges and integer overflow')
    for path in ('/api/profiles/%00','/api/profiles/%zz','/api/profiles/%'):
        assert single(path)[0] == 400
    done('invalid URL escapes and embedded NUL rejected')

    idle = []
    try:
        for _ in range(args.idle_connections):
            idle.append(connect())
        deadline = time.monotonic()+args.idle_seconds
        while time.monotonic() < deadline:
            time.sleep(min(1, max(0,deadline-time.monotonic())))
        def probe(connection):
            connection.sendall(request(close=True))
            return Reader(connection).read()[0]
        with ThreadPoolExecutor(max_workers=16) as pool:
            assert all(status == 200 for status in pool.map(probe,idle))
        done(f'{len(idle)} idle connections remain usable after {args.idle_seconds:g}s')
    finally:
        for connection in idle:
            connection.close()
    assert single('/api/tags')[0] == 200
    done('server remains healthy after malformed frames and connection pressure')
    print(f'PASS: {checks} HTTP edge checks',flush=True)


if __name__ == '__main__':
    main()

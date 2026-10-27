#!/usr/bin/env python3
"""Check users/auth against the unchanged suite and a disposable PostgreSQL clone."""
import base64
import concurrent.futures
import hmac
import http.client
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import threading
import time

submission = Path(__file__).resolve().parents[1]
repo = submission.parents[1]
work = Path(os.environ['CHALLENGE_WORK'])
results = work / 'results' / 'milestone2'
results.mkdir(parents=True, exist_ok=True)
database = f'challenge_auth_{os.getpid()}'
secret = 'milestone-auth-test-only'
checks = []


def sql(statement, target='postgres'):
    return subprocess.check_output(['psql', '-X', '-v', 'ON_ERROR_STOP=1', '-At',
                                    '-d', target, '-c', statement], text=True).strip()


def request(method='GET', path='/api/tags', body=None, token=None, headers=None, target_port=None):
    fields = dict(headers or {})
    if token is not None:
        fields['Authorization'] = 'Token ' + token
    if body is not None:
        fields['Content-Type'] = 'application/json'
        if not isinstance(body, (bytes, str)):
            body = json.dumps(body).encode()
    connection = http.client.HTTPConnection('127.0.0.1', target_port or port, timeout=10)
    try:
        connection.request(method, path, body=body, headers=fields)
        response = connection.getresponse()
        assert response.getheader('Content-Type') == 'application/json'
        data = json.loads(response.read())
        if response.status >= 400:
            assert list(data) == ['errors'] and isinstance(data['errors']['body'][0], str)
        return response.status, data
    finally:
        connection.close()


def raw_response(reader):
    line = reader.readline()
    assert line, 'connection closed before response'
    status = int(line.split()[1])
    headers = {}
    while True:
        line = reader.readline()
        if line == b'\r\n':
            break
        assert line
        key, value = line.decode().split(':', 1)
        headers[key.lower()] = value.strip()
    return status, json.loads(reader.read(int(headers['content-length'])))


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=')


def mint(claims, header=None):
    data = b'.'.join(b64(json.dumps(v, separators=(',', ':')).encode())
                     for v in (header or {'alg': 'HS256'}, claims))
    return (data + b'.' + b64(hmac.digest(secret.encode(), data, 'sha256'))).decode()


def claims_of(token):
    header, claims, signature = token.encode().split(b'.')
    assert hmac.compare_digest(base64.urlsafe_b64decode(signature + b'=='),
                               hmac.digest(secret.encode(), header + b'.' + claims, 'sha256'))
    assert json.loads(base64.urlsafe_b64decode(header + b'=='))['alg'] == 'HS256'
    fields = json.loads(base64.urlsafe_b64decode(claims + b'=='))
    assert set(fields) == {'sub', 'iat', 'exp'}
    assert isinstance(fields['sub'], str) and fields['sub'].isdigit()
    assert type(fields['iat']) is int and type(fields['exp']) is int
    assert abs(fields['iat'] - int(time.time())) < 10
    assert fields['exp'] - fields['iat'] == 30 * 24 * 3600
    return fields


def passed(name):
    checks.append(name)


with socket.socket() as probe:
    probe.bind(('127.0.0.1', 0))
    port = probe.getsockname()[1]

sql(f'CREATE DATABASE {database} TEMPLATE conduit_dev')
process = None
try:
    environment = dict(os.environ, HOST='127.0.0.1', PORT=str(port), JWT_SECRET=secret,
                       DATABASE_URL=f"postgres://conduit:conduit@127.0.0.1:{os.environ['PGPORT']}/{database}")
    process = subprocess.Popen([str(submission / 'zig-out/bin/conduit')], env=environment,
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    deadline = time.monotonic() + 10
    while True:
        try:
            assert request()[0] == 200
            break
        except OSError:
            if process.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError('server did not become healthy')
            time.sleep(0.05)

    # Run upstream without editing, filtering or suppressing any of its checks.
    conformance = work / 'tools' / 'conformance'
    subprocess.run(['go', 'build', '-o', str(conformance), './cmd/conformance'],
                   cwd=repo / 'bench', check=True)
    suite = subprocess.run([str(conformance), '-base', f'http://127.0.0.1:{port}',
                            '-secret', secret, '-transcript', str(results / 'upstream.jsonl')],
                           text=True, capture_output=True, timeout=90)
    (results / 'upstream.log').write_text(suite.stdout + suite.stderr)
    auth_lines = [line for line in suite.stdout.splitlines()
                  if re.match(r'^(PASS|FAIL) (users\.|user\.)', line)]
    assert len(auth_lines) == 50 and all(line.startswith('PASS ') for line in auth_lines), '\n'.join(auth_lines)
    assert any('user.get.after-update ' in line for line in auth_lines)
    assert not any(line.startswith('FAIL tags.') for line in suite.stdout.splitlines())
    passed(f'unchanged upstream users/auth: {len(auth_lines)} steps passed')
    summary = next(line for line in suite.stdout.splitlines() if re.match(r'^\d+ steps,', line))
    print('Upstream full run: ' + summary, flush=True)

    user = {'username': "m2_quote_'_é", 'email': "m2_'_é@example.com", 'password': 'p' * 72}
    status, result = request('POST', '/api/users', {'user': user}, headers={'Authorization': 'bad'})
    assert status == 201, result
    token = result['user']['token']
    fields = claims_of(token)
    identifier = int(fields['sub'])
    stored = sql(f'SELECT password_hash FROM users WHERE id={identifier}', database)
    assert stored.startswith(('$2b$10$', '$2a$10$')) and len(stored) == 60
    assert result['user']['username'] == user['username'] and result['user']['bio'] is None
    assert request('POST', '/api/users/login', {'user': user})[0] == 200
    passed('parameterized Unicode/quote input, 72-byte bcrypt cost 10 and JWT claims/signature')

    assert request('POST', '/api/users', {'user': dict(user, username='long', password='é' * 37)})[0] == 422
    assert request('POST', '/api/users', {'user': dict(user, username='nul\0text')})[0] == 422
    assert request('PUT', '/api/user', {'user': {'password': 'x' * 73}}, token)[0] == 422
    passed('password byte limit and text NUL validation')

    changed = {'bio': "A 'quoted' biography ☕", 'image': ''}
    status, updated = request('PUT', '/api/user', {'user': changed}, token)
    assert status == 200 and updated['user']['token'] == token
    assert updated['user']['bio'] == changed['bio'] and updated['user']['image'] == ''
    assert sql(f'SELECT bio FROM users WHERE id={identifier}', database) == changed['bio']
    assert request('GET', '/api/user', token=token)[1] == updated
    passed('committed updates visible through a separate database session')

    # Hold a row lock through another session. No success may arrive before commit.
    locker = subprocess.Popen(['psql', '-X', '-v', 'ON_ERROR_STOP=1', '-At', '-d', database,
                               '-c', f'BEGIN; SELECT id FROM users WHERE id={identifier} FOR UPDATE; SELECT pg_sleep(1.5); COMMIT;'],
                              env=dict(os.environ, PGAPPNAME='milestone-auth-lock'),
                              stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 3
        while sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{database}' AND application_name='milestone-auth-lock' AND wait_event='PgSleep'") != '1':
            assert time.monotonic() < deadline
            time.sleep(0.01)
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(request, 'PUT', '/api/user', {'user': {'bio': 'after-lock'}}, token)
            deadline = time.monotonic() + 1
            while sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{database}' AND usename='conduit' AND wait_event_type='Lock'") != '1':
                assert time.monotonic() < deadline
                time.sleep(0.01)
            assert not future.done()
            assert sql(f'SELECT bio FROM users WHERE id={identifier}', database) == changed['bio']
            assert future.result(timeout=5)[0] == 200
            assert sql(f'SELECT bio FROM users WHERE id={identifier}', database) == 'after-lock'
        passed('write response withheld during a row lock, then committed before success')
    finally:
        if locker.poll() is None:
            locker.terminate()
        locker.wait(timeout=5)

    now = int(time.time())
    for claims in [
        {'sub': fields['sub'], 'exp': str(now + 60)},
        {'sub': fields['sub'], 'exp': now + 60.5},
        {'sub': '0', 'exp': now + 60},
        {'sub': '9223372036854775808', 'exp': now + 60},
        {'sub': '+1', 'exp': now + 60},
        {'sub': fields['sub'], 'exp': now},
        {'sub': fields['sub'], 'exp': now + 60, 'iat': 'yesterday'},
    ]:
        assert request('GET', '/api/user', token=mint(claims))[0] == 401
    assert request('GET', '/api/user', token=mint({'sub': fields['sub'], 'exp': now + 60}, {'alg': 'HS384'}))[0] == 401
    assert request('GET', '/api/user', headers={'Authorization': ''})[0] == 401
    passed('additional signed invalid-claim, algorithm and empty-header cases')

    # Out-of-band hash replacement must affect the next verification; no login cache.
    sql(f'UPDATE users SET password_hash=(SELECT password_hash FROM users WHERE id=1) WHERE id={identifier}', database)
    assert request('POST', '/api/users/login', {'user': user})[0] == 401
    login = {'user': {'email': user['email'], 'password': 'password123'}}
    assert request('POST', '/api/users/login', login)[0] == 200
    assert request('GET', '/api/user', token=token)[0] == 200
    passed('every login verifies the current stored hash; existing token still valid')

    # Cross-check both directions with upstream's unmodified Go application.
    reference = work / 'tools' / 'reference-go'
    subprocess.run(['go', 'build', '-o', str(reference), '.'], cwd=repo / 'examples/go', check=True)
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        reference_port = probe.getsockname()[1]
    with (results / 'reference.log').open('w') as reference_log:
        reference_process = subprocess.Popen([str(reference)], env=dict(environment, PORT=str(reference_port)),
                                             stdout=reference_log, stderr=reference_log)
        try:
            deadline = time.monotonic() + 10
            while True:
                try:
                    assert request(target_port=reference_port)[0] == 200
                    break
                except OSError:
                    if reference_process.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError('reference server did not become healthy')
                    time.sleep(0.05)
            for i, password in enumerate(['z' * 72, 'é' * 36, 'a\0b']):
                for label, registration_port, verification_port in [('zig', port, reference_port), ('go', reference_port, port)]:
                    account = {'username': f'm2_interop_{label}_{i}',
                               'email': f'm2_interop_{label}_{i}@example.com', 'password': password}
                    assert request('POST', '/api/users', {'user': account}, target_port=registration_port)[0] == 201
                    assert request('POST', '/api/users/login', {'user': account}, target_port=verification_port)[0] == 200
            # Go's login path retains bcrypt's 72-byte truncation; creation rejects >72 bytes.
            longer = {'user': {'email': 'm2_interop_zig_0@example.com', 'password': 'z' * 72 + 'extra'}}
            expected = request('POST', '/api/users/login', longer, target_port=reference_port)[0]
            assert request('POST', '/api/users/login', longer)[0] == expected == 200
            passed('bcrypt interoperability in both directions with unchanged Go: 72 bytes, UTF-8, NUL and long login')
        finally:
            reference_process.terminate()
            reference_process.wait(timeout=5)

    # Split a JSON body, then pipeline a second request on the same connection.
    payload = json.dumps({'user': {'username': 'm2_pipeline', 'email': 'm2_pipeline@example.com', 'password': 'body-pass'}}).encode()
    with socket.create_connection(('127.0.0.1', port), timeout=10) as client:
        client.sendall(b'POST /api/users HTTP/1.1\r\nHost: x\r\nContent-Length: ' + str(len(payload)).encode() + b'\r\n\r\n' + payload[:20])
        time.sleep(0.02)
        client.sendall(payload[20:] + b'GET /api/tags HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n')
        with client.makefile('rb') as reader:
            assert raw_response(reader)[0] == 201
            assert raw_response(reader)[0] == 200
            assert reader.read(1) == b''
    with socket.create_connection(('127.0.0.1', port), timeout=10) as client:
        client.sendall(f'GET /api/user HTTP/1.1\r\nHost: x\r\nAuthorization: Token {token}\r\n\r\nGET /api/user HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n'.encode())
        with client.makefile('rb') as reader:
            assert raw_response(reader)[0] == 200
            assert raw_response(reader)[0] == 401
    passed('split body, ordered pipelining and no identity carried between requests')

    concurrency = 160
    barrier = threading.Barrier(concurrency)
    def parallel_login(_):
        barrier.wait(timeout=10)
        return request('POST', '/api/users/login', login)[0]
    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [pool.submit(parallel_login, i) for i in range(concurrency)]
        deadline = time.monotonic() + 5
        while barrier.n_waiting < concurrency - 1 and not barrier.broken and time.monotonic() < deadline:
            # The barrier releases itself when all client threads arrive.
            if any(f.done() for f in futures):
                break
            time.sleep(0.001)
        assert request()[0] == 200
        assert any(not f.done() for f in futures), 'tags did not progress alongside password work'
        statuses = [f.result() for f in futures]
    assert set(statuses) == {200, 503}, statuses
    assert request('POST', '/api/users/login', login)[0] == 200
    passed(f'bounded overload: {statuses.count(200)} accepted, {statuses.count(503)} rejected; tags progressed during bcrypt')

    # A completion after disconnect cannot become a response on a recycled slot.
    disconnected = []
    for _ in range(8):
        client = socket.create_connection(('127.0.0.1', port), timeout=5)
        payload = json.dumps(login).encode()
        client.sendall(b'POST /api/users/login HTTP/1.1\r\nHost: x\r\nContent-Length: ' + str(len(payload)).encode() + b'\r\n\r\n' + payload)
        disconnected.append(client)
    for client in disconnected:
        client.close()
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
        assert all(status == 200 and 'tags' in body for status, body in pool.map(lambda _: request(), range(64)))
    time.sleep(0.5)
    assert request('GET', '/api/user', token=token)[0] == 200
    passed('disconnected bcrypt recipients followed by 64 concurrent tags requests')

    def duplicate(_):
        return request('POST', '/api/users', {'user': {'username': 'm2_unique', 'email': 'm2_unique@example.com', 'password': 'same'}})[0]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        assert sorted(pool.map(duplicate, range(2))) == [201, 422]
    assert sql("SELECT count(*) FROM users WHERE username='m2_unique'", database) == '1'
    passed('concurrent duplicate writes: one committed row, one 422')

    sql('ALTER TABLE users RENAME TO users_unavailable', database)
    try:
        assert request('POST', '/api/users/login', login)[0] == 503
    finally:
        sql('ALTER TABLE users_unavailable RENAME TO users', database)
    assert request('POST', '/api/users/login', login)[0] == 200
    passed('database SQL error drained before connection reuse')

    assert process.poll() is None
    evidence = {'milestone': 2, 'checks': checks, 'upstream_users_auth_steps': len(auth_lines),
                'upstream_full_summary': summary, 'upstream_exit_status': suite.returncode,
                'scope': 'native Mac correctness; no Linux runtime or capacity claim'}
    (results / 'results.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print(f'PASS: {len(checks)} auth scenarios, including {len(auth_lines)} unchanged upstream users/auth steps', flush=True)
finally:
    if process is not None:
        process.terminate()
        try:
            _, error_log = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            _, error_log = process.communicate()
        if process.returncode not in (-15, 0):
            print(error_log.decode(errors='replace'))
    sql(f'DROP DATABASE IF EXISTS {database} WITH (FORCE)')

"""Cross-check parallel bcrypt jobs against Go, fresh hashes and exact recipients."""
import concurrent.futures
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import subprocess
import threading
import time

from support import Server, free_port, literal

work = Path(os.environ['CHALLENGE_WORK'])
submission = Path(__file__).resolve().parents[1]
results = work / 'results/password-batch'
results.mkdir(parents=True, exist_ok=True)


@contextmanager
def reference(server):
    peer = Server(results, server.secret, 'unused', 'unused', work / 'tools/reference-go')
    peer.database, peer.port = server.database, free_port()
    environment = dict(os.environ, HOST='127.0.0.1', PORT=str(peer.port), JWT_SECRET=server.secret,
                       DATABASE_URL=f"postgres://conduit:conduit@127.0.0.1:{os.environ['PGPORT']}/{server.database}")
    with (results / 'reference.log').open('w') as log:
        process = subprocess.Popen([str(work / 'tools/reference-go')], env=environment, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 10
            while True:
                try:
                    if peer.request('GET', '/api/tags')[0] == 200: break
                except OSError:
                    pass
                assert process.poll() is None and time.monotonic() < deadline
                time.sleep(0.02)
            yield peer
        finally:
            process.terminate()
            process.wait(timeout=5)


with Server(results, 'password-batch-test-only', 'passwordbatch', 'focus', submission / 'zig-out/bin/conduit') as server:
    existing = [f'lanes_existing_{index}' for index in range(4)]
    for name in existing: server.fixture(name)
    passwords = ['different password', 'é' * 36, 'x' * 71, 'y' * 72]
    created = [(f'lanes_created_{index}', passwords[index % len(passwords)]) for index in range(8)]
    cases = []
    for name, password in created:
        cases.append(('/api/users', {'user': {'username': name, 'email': name+'@example.com', 'password': password}}, 201))
    for index in range(24):
        cases.append(('/api/users/login', {'user': {'email': existing[index % 4]+'@example.com',
                         'password': 'incorrect' if index % 3 == 0 else 'password123'}}, 401 if index % 3 == 0 else 200))

    def run_concurrent(cases):
        barrier = threading.Barrier(len(cases))
        def call(case):
            path, body, expected = case
            barrier.wait(timeout=10)
            status, data = server.request('POST', path, body=body)
            assert status == expected, (path, expected, status)
            if status < 400: assert data['user']['email'] == body['user']['email']
            return status
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(cases)) as pool:
            return list(pool.map(call, cases))

    run_concurrent(cases)
    hashes = [server.sql('SELECT password_hash FROM users WHERE username='+literal(name)) for name, _ in created]
    assert all(value.startswith('$2b$10$') for value in hashes)
    assert len({value[7:29] for value in hashes}) == len(created), 'fresh registration salts must stay independent'
    with reference(server) as go:
        for name, password in created:
            assert go.request('POST', '/api/users/login', body={'user': {'email': name+'@example.com', 'password': password}})[0] == 200
            assert go.request('POST', '/api/users/login', body={'user': {'email': name+'@example.com', 'password': 'wrong-'+password}})[0] == 401
    # Existing requests have completed. Subsequent logins must read the new hash.
    server.sql('UPDATE users SET password_hash='+literal(hashes[0])+' WHERE username='+literal(existing[0]))
    fresh = [('/api/users/login', {'user': {'email': existing[0]+'@example.com', 'password': password}}, expected)
             for password, expected in [('password123', 401), (created[0][1], 200)] for _ in range(4)]
    run_concurrent(fresh)
    log = results / f'{server.database}.log'
    deadline = time.monotonic() + 12
    while True:
        stats = []
        for line in log.read_text().splitlines():
            if 'password_stats ' in line:
                stats.append({key: int(value) for key, value in re.findall(r'(\w+)=([0-9]+)', line)})
        if any(s['batches_2']+s['batches_3']+s['batches_4'] > 0 for s in stats): break
        assert time.monotonic() < deadline, 'no actual parallel password batch was observed'
        server.request('GET', '/api/tags')
        time.sleep(0.05)
    (results / 'results.json').write_text(json.dumps({'mixed_concurrent_requests': len(cases), 'independent_salts': len(hashes),
        'go_verifies_each_created_hash': True, 'fresh_stored_hash_requests': len(fresh), 'password_stats': stats}, indent=2)+'\n')
    print('PASS: mixed cost-ten jobs, unique salts, Go cross-verification, exact recipients and fresh stored hashes', flush=True)

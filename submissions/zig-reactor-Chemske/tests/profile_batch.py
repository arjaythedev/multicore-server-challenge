"""Exercise grouped profiles, viewer flags, fresh changes and recipient loss."""
import concurrent.futures
import json
import os
from pathlib import Path
import socket
import threading
import time
from urllib.parse import quote

from recovery import Proxy, eventually, lock_tags
from support import Server, literal, mint

submission = Path(__file__).resolve().parents[1]
results = Path(os.environ['CHALLENGE_WORK']) / 'results/profile-batch'
results.mkdir(parents=True, exist_ok=True)
secret = 'profile-batch-test-only'
with Proxy() as proxy, Server(results, secret, 'profilebatch', 'focus', submission / 'zig-out/bin/conduit', database_port=proxy.port) as server:
    author = server.fixture('profile_batch_author')
    other = server.fixture('profile_batch_other')
    name = 'profile,"quote\\é'
    server.sql(f'UPDATE users SET username={literal(name)},bio={literal("escaped bio "+chr(10)+chr(34))} WHERE id={author}')
    server.sql(f'INSERT INTO follows(follower_id,followee_id) VALUES(1,{author})')
    names = (name, 'profile_batch_other', 'profile-batch-missing')
    inputs = [(names[i % 3], [None, mint(1, secret), mint(2, secret)][(i // 3) % 3]) for i in range(64)]
    endpoint = lambda username: '/api/profiles/' + quote(username, safe='')
    owners = int(server.sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{server.database}' AND usename='conduit'"))
    def counts():
        return tuple(sum(s[key] for s in proxy.sessions) for key in ('profile_groups', 'profile_single'))
    def queued(fault=False):
        barrier = threading.Barrier(len(inputs) + 1)
        def read(item):
            barrier.wait(timeout=10)
            return server.request('GET', endpoint(item[0]), item[1])
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(inputs) + owners) as pool:
            try:
                with lock_tags(server, mode='ACCESS EXCLUSIVE', table='users'):
                    blockers = [pool.submit(server.request, 'GET', '/api/user', mint(1, secret)) for _ in range(owners)]
                    eventually(lambda: int(server.sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{server.database}' AND usename='conduit' AND wait_event_type='Lock'")) == owners)
                    pending = [pool.submit(read, item) for item in inputs]
                    barrier.wait(timeout=10)
                    time.sleep(.2)
                    if fault:
                        server.sql('REVOKE SELECT ON follows FROM conduit')
                assert all(item.result(timeout=12)[0] == 200 for item in blockers)
                return [item.result(timeout=12) for item in pending]
            finally:
                if fault:
                    server.sql('GRANT SELECT ON follows TO conduit')
    expected = [server.request('GET', endpoint(username), token) for username, token in inputs]
    before = counts()
    assert queued() == expected
    delta = [b - a for a, b in zip(before, counts())]
    assert delta[0] > 0 and sum(delta) < 16, delta
    server.sql(f'INSERT INTO follows(follower_id,followee_id) VALUES(2,{author})')
    server.sql(f"UPDATE users SET bio='fresh profile' WHERE id={author}")
    assert server.request('GET', endpoint(name), mint(2, secret))[1]['profile']['following']
    assert server.request('GET', endpoint(name))[1]['profile'] == {'username': name, 'bio': 'fresh profile', 'image': None, 'following': False}
    expected = [server.request('GET', endpoint(username), token) for username, token in inputs]
    primary = socket.create_connection(('127.0.0.1', server.port), timeout=5)
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(inputs)+owners) as pool:
            with lock_tags(server, mode='ACCESS EXCLUSIVE', table='follows'):
                with lock_tags(server, mode='ACCESS EXCLUSIVE', table='users'):
                    blockers = [pool.submit(server.request, 'GET', '/api/user', mint(1, secret)) for _ in range(owners)]
                    eventually(lambda: int(server.sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{server.database}' AND usename='conduit' AND wait_event_type='Lock'")) == owners)
                    primary.sendall(('GET '+endpoint(name)+' HTTP/1.1\r\nHost: test\r\n\r\n').encode())
                    time.sleep(.05)
                    before_disconnect = counts()[0]
                    pending = [pool.submit(server.request, 'GET', endpoint(username), token) for username, token in inputs]
                    time.sleep(.2)
                eventually(lambda: counts()[0] > before_disconnect)
                primary.close()
            assert all(item.result(timeout=12)[0] == 200 for item in blockers)
            assert [item.result(timeout=12) for item in pending] == expected
    finally:
        primary.close()
    assert all(code == 503 for code, _ in queued(fault=True))
    assert server.request('GET', endpoint(name))[0] == 200
    evidence = {'requests': len(inputs), 'group_queries': delta[0], 'individual_queries': delta[1],
                'escaping_and_viewer_isolation': True, 'fresh_profile_and_follow': True,
                'primary_disconnect_safe': True, 'sql_error_reuse': True}
    (results / 'results.json').write_text(json.dumps(evidence, indent=2)+'\n')
    print('PASS: 64 mixed profiles, quoted/Unicode names, viewer flags, 404, fresh changes, primary disconnect and SQL-error recovery', flush=True)

"""Fault-inject connection loss, withheld COMMIT acknowledgement and slow reconnects.

The optional cluster restart is restricted to this workspace's native dev cluster.
The wire proxy stores message names only, never credentials or parameter values.
"""
import argparse
import concurrent.futures
from contextlib import contextmanager
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import threading
import time
import uuid

from support import Server, mint, sql, upstream

work = Path(os.environ['CHALLENGE_WORK'])
submission = Path(__file__).resolve().parents[1]
results = work / 'results/recovery'
results.mkdir(parents=True, exist_ok=True)
secret = 'recovery-test-only'


def eventually(predicate, timeout=12):
    deadline = time.monotonic() + timeout
    while not predicate():
        assert time.monotonic() < deadline, 'recovery deadline exceeded'
        time.sleep(0.02)


def receive(sock, size):
    data = bytearray()
    while len(data) < size:
        part = sock.recv(size - len(data))
        if not part:
            raise EOFError
        data.extend(part)
    return bytes(data)


class Proxy:
    def __init__(self):
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', 0))
        self.port = self.listener.getsockname()[1]
        self.listener.listen(128)
        self.listener.settimeout(0.1)
        self.stopping = False
        self.pause_new = False
        self.reject_new = False
        self.rejected = 0
        self.release_new = threading.Event()
        self.release_new.set()
        self.drop_commit = threading.Event()
        self.commit_dropped = threading.Event()
        self.drop_favorite = threading.Event()
        self.favorite_dropped = threading.Event()
        self.sessions = []
        self.hold_counts = False
        self.count_seen = threading.Event()
        self.release_counts = threading.Event()
        self.release_counts.set()
        self.threads = []

    def launch(self, function, *args):
        thread = threading.Thread(target=function, args=args, daemon=True)
        self.threads.append(thread)
        thread.start()

    def __enter__(self):
        self.launch(self.accept)
        return self

    def accept(self):
        while not self.stopping:
            client = None
            try:
                client, _ = self.listener.accept()
                if self.reject_new:
                    self.rejected += 1
                    client.close()
                    continue
                backend = socket.create_connection(('127.0.0.1', int(os.environ['PGPORT'])), timeout=3)
                backend.settimeout(None)
                # Forward protocol messages immediately; Nagle plus delayed ACKs
                # must not turn preparation into an artificial startup stall.
                for peer in (client, backend):
                    peer.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            except (OSError, socket.timeout):
                if client is not None:
                    client.close()
                continue
            session = {'sockets': (client, backend), 'prepared': set(), 'settings': 0, 'tuning': set(), 'tags': 0, 'article_groups': 0, 'article_single': 0, 'comment_groups': 0, 'compact_comment_groups': 0, 'comment_single': 0, 'page_groups': 0, 'count_groups': 0, 'page_queries': 0, 'count_queries': 0, 'pause': self.pause_new}
            session.update(favorite_groups=0, favorite_single=0, favorite_pending=False, favorite_executions=[], feed_hub_preparations=0, profile_groups=0, profile_single=0)
            self.sessions.append(session)
            self.launch(self.frontend, session)
            self.launch(self.backend, session)

    def close_session(self, session):
        for sock in session['sockets']:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            sock.close()

    def frontend(self, session):
        client, backend = session['sockets']
        try:
            header = receive(client, 4)
            backend.sendall(header + receive(client, struct.unpack('!I', header)[0] - 4))
            while not self.stopping:
                header = receive(client, 5)
                body = receive(client, struct.unpack('!I', header[1:])[0] - 4)
                if header[:1] == b'P':
                    name, statement = body.split(b'\0', 1)
                    if name:
                        session['prepared'].add(name.decode('ascii'))
                        if b'shared_feed_hubs AS MATERIALIZED' in statement:
                            session['feed_hub_preparations'] += 1
                    elif statement.startswith(b"SET statement_timeout = '8s'\0"):
                        session['settings'] += 1
                    elif statement.startswith(b'SET jit = off\0') or statement.startswith(b'SET plan_cache_mode = '):
                        session['tuning'].add(statement.split(b'\0', 1)[0])
                elif header[:1] == b'B':
                    name = body.split(b'\0', 2)[1]
                    if name in (b'batch_favorite', b'batch_unfavorite', b'op_favorite', b'op_unfavorite'):
                        # Track original request identities, including legitimate
                        # singleton groups, rather than treating every single
                        # statement after an injected disconnect as a replay.
                        parameters = body.split(b'\0', 2)[2]
                        formats = struct.unpack_from('!H', parameters)[0]
                        assert all(struct.unpack_from('!H', parameters, 2 + 2*i)[0] == 0 for i in range(formats))
                        offset = 2 + 2*formats
                        count = struct.unpack_from('!H', parameters, offset)[0]
                        offset += 2
                        values = []
                        for _ in range(count):
                            length = struct.unpack_from('!i', parameters, offset)[0]
                            offset += 4
                            assert length >= 0 and offset + length <= len(parameters)
                            values.append(parameters[offset:offset+length])
                            offset += length
                        assert len(values) == 2
                        viewers = tuple(map(int, values[0][1:-1].split(b','))) if name.startswith(b'batch_') else (int(values[0]),)
                        session['favorite_executions'].append((name.decode('ascii'), viewers))
                    if name in (b'batch_favorite', b'batch_unfavorite'):
                        session['favorite_groups'] += 1
                        session['favorite_pending'] = True
                    elif name in (b'op_favorite', b'op_unfavorite'):
                        session['favorite_single'] += 1
                    if name == b'tags': session['tags'] += 1
                    elif name == b'batch_single': session['article_groups'] += 1
                    elif name == b'page_single': session['article_single'] += 1
                    elif name == b'batch_profiles': session['profile_groups'] += 1
                    elif name == b'profile': session['profile_single'] += 1
                    elif name in (b'batch_comments', b'batch_comments_compact'):
                        session['comment_groups'] += 1
                        if name == b'batch_comments_compact': session['compact_comment_groups'] += 1
                    elif name == b'comments': session['comment_single'] += 1
                    elif name.startswith(b'batch_page_'): session['page_groups'] += 1
                    elif name.startswith(b'batch_count_'): session['count_groups'] += 1
                    elif name.startswith(b'page_'): session['page_queries'] += 1
                    elif name.startswith(b'count_'): session['count_queries'] += 1
                    if self.hold_counts and name.startswith(b'batch_count_'):
                        self.count_seen.set()
                        while not self.stopping and not self.release_counts.wait(0.1):
                            pass
                backend.sendall(header + body)
        except (OSError, EOFError):
            pass
        finally:
            self.close_session(session)

    def backend(self, session):
        client, backend = session['sockets']
        try:
            while not self.stopping:
                header = receive(backend, 5)
                body = receive(backend, struct.unpack('!I', header[1:])[0] - 4)
                while session['pause'] and not self.release_new.wait(0.1):
                    if self.stopping:
                        return
                if header[:1] == b'C' and body == b'COMMIT\0' and self.drop_commit.is_set():
                    self.drop_commit.clear()
                    self.commit_dropped.set()
                    return  # PostgreSQL committed, but libpq receives no acknowledgement.
                if header[:1] == b'Z' and session['favorite_pending']:
                    session['favorite_pending'] = False
                    if self.drop_favorite.is_set():
                        self.drop_favorite.clear()
                        self.favorite_dropped.set()
                        return  # Drop the implicit commit's ReadyForQuery, never replay it.
                client.sendall(header + body)
        except (OSError, EOFError):
            pass
        finally:
            self.close_session(session)

    def __exit__(self, *_):
        self.stopping = True
        self.release_new.set()
        self.listener.close()
        for session in self.sessions:
            self.close_session(session)
        for thread in self.threads:
            thread.join(timeout=2)
            assert not thread.is_alive(), 'proxy thread did not stop'


@contextmanager
def lock_tags(server, mode='SHARE', table='tags'):
    assert mode in ('SHARE', 'ACCESS EXCLUSIVE') and table in ('tags', 'articles', 'users', 'comments', 'follows')
    application = 'recovery-lock-' + uuid.uuid4().hex
    with (results / 'locker.log').open('a') as log:
        process = subprocess.Popen(['psql', '-X', '-v', 'ON_ERROR_STOP=1', '-d', server.database,
                                    '-c', f'BEGIN; LOCK TABLE {table} IN {mode} MODE; SELECT pg_sleep(30); ROLLBACK'],
                                   env=dict(os.environ, PGAPPNAME=application), stdout=log, stderr=log)
        try:
            eventually(lambda: sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{server.database}' AND application_name='{application}' AND wait_event='PgSleep'") == '1')
            yield
        finally:
            sql(f"SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE datname='{server.database}' AND application_name='{application}'")
            process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--restart-cluster', action='store_true')
    parser.add_argument('--connections', type=int, help='Expected total pool size for multi-reactor tests')
    args = parser.parse_args()
    checks = []
    with Proxy() as proxy, Server(results, secret, 'recovery', 'focus', submission / 'zig-out/bin/conduit', database_port=proxy.port) as server:
        count_query = f"SELECT count(*) FROM pg_stat_activity WHERE datname='{server.database}' AND usename='conduit' AND state='idle' AND xact_start IS NULL"
        connection_count = args.connections or int(sql(count_query))
        assert 1 <= connection_count <= 95

        def ready():
            return server.request('GET', '/api/tags')[0] == 200

        def idle():
            eventually(lambda: sql(count_query) == str(connection_count))

        def kill(one=False):
            server.sql(f"SELECT pg_terminate_backend(pid) FROM (SELECT pid FROM pg_stat_activity WHERE datname='{server.database}' AND usename='conduit' ORDER BY pid {'LIMIT 1' if one else ''}) s")

        def rebuilt(after):
            eventually(lambda: len(proxy.sessions) >= after)
            eventually(ready)
            idle()
            eventually(lambda: all(len(s['prepared']) == 48 and s['settings'] == 1 and len(s['tuning']) == 2 for s in proxy.sessions[-connection_count:]))

        rebuilt(connection_count)
        checks.append('all owners finish session setup and forty-seven named preparations before use')
        accepted = len(proxy.sessions)
        kill(one=True)
        rebuilt(accepted + 1)
        checks.append('one idle backend is replaced without restarting the server; its statements and settings are rebuilt')

        proxy.pause_new = True
        proxy.release_new.clear()
        accepted = len(proxy.sessions)
        kill()
        eventually(lambda: len(proxy.sessions) >= accepted + connection_count)
        started = time.monotonic()
        for _ in range(3):
            assert server.request('GET', '/api/tags')[0] == 503
        assert server.request('GET', '/api/profiles/anything', 'invalid-token')[0] == 401
        assert time.monotonic() - started < 1, 'reconnect blocked HTTP progress'
        assert len(proxy.sessions) == accepted + connection_count, 'duplicate reconnect attempts'
        proxy.pause_new = False
        proxy.release_new.set()
        rebuilt(accepted + connection_count)
        checks.append('stalled authentication leaves HTTP responsive, fails unsent work and keeps one attempt per owner')

        accepted = len(proxy.sessions)
        proxy.reject_new = True
        kill()
        eventually(lambda: server.request('GET', '/api/tags')[0] == 503)
        started = time.monotonic()
        while time.monotonic() - started < 2.2:
            assert server.request('GET', '/api/tags')[0] == 503
            time.sleep(0.05)
        assert 1 <= proxy.rejected <= 4 * connection_count, 'reconnect retries spun without backoff'
        proxy.reject_new = False
        rebuilt(accepted + connection_count)
        checks.append('refused reconnects use bounded backoff instead of spinning; service resumes when admission returns')

        author = server.fixture('recovery_author')
        token = mint(author, secret)
        def create(title):
            return server.request('POST', '/api/articles', token, {'article': {
                'title': title, 'description': 'recovery', 'body': 'body', 'tagList': ['recovery-test-tag']}})

        accepted = len(proxy.sessions)
        proxy.drop_commit.set()
        assert create('recovery committed without acknowledgement')[0] == 503
        assert proxy.commit_dropped.wait(1)
        rebuilt(accepted + 1)
        assert server.sql("SELECT count(*) FROM articles WHERE title='recovery committed without acknowledgement'") == '1'
        assert create('recovery fresh request')[0] == 201
        assert server.sql("SELECT count(*) FROM articles WHERE title='recovery committed without acknowledgement'") == '1'
        checks.append('lost COMMIT acknowledgement returns 503 and preserves exactly one committed article without replay')

        for _ in range(3):
            accepted = len(proxy.sessions)
            kill(one=True)
            rebuilt(accepted + 1)
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                assert all(pool.map(lambda _: server.request('GET', '/api/articles?limit=1', token)[0] == 200, range(24)))
        checks.append('repeated backend/socket replacement and concurrent clients preserve response ownership and the pool bound')

        with lock_tags(server), concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(create, 'recovery timed out transaction')
            eventually(lambda: server.sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{server.database}' AND usename='conduit' AND wait_event_type='Lock'") == '1')
            if connection_count > 1:
                started = time.monotonic()
                assert ready() and time.monotonic() - started < 1
                assert not future.done()
                checks.append('a blocked writer leaves another database owner serving fresh reads')
            assert future.result(timeout=11)[0] == 503
        idle()
        assert server.sql("SELECT count(*) FROM articles WHERE title='recovery timed out transaction'") == '0'
        assert create('recovery after statement timeout')[0] == 201
        checks.append('statement deadline rolls back the open transaction, releases its owner and permits new writes')

        if args.restart_cluster:
            data = Path(os.environ['PGDATA']).resolve()
            assert data == (work / 'runtime/postgres-18').resolve() and os.environ['PGPORT'] == '55432'
            accepted = len(proxy.sessions)
            stop = ['pg_ctl', '-D', str(data), '-m', 'fast', '-w', '-t', '30', 'stop']
            start = ['pg_ctl', '-D', str(data), '-l', str(work / 'logs/postgres.log'), '-w', '-t', '30', 'start']
            with (results / 'cluster-restart.log').open('w') as log:
                try:
                    subprocess.run(stop, stdout=log, stderr=log, check=True, timeout=35)
                    for _ in range(3):
                        assert server.request('GET', '/api/tags')[0] == 503
                        time.sleep(0.2)
                finally:
                    status = subprocess.run(['pg_ctl', '-D', str(data), 'status'], stdout=log, stderr=log)
                    if status.returncode != 0:
                        subprocess.run(start, stdout=log, stderr=log, check=True, timeout=35)
            rebuilt(accepted + connection_count)
            assert server.sql("SELECT count(*) FROM articles WHERE title='recovery committed without acknowledgement'") == '1'
            checks.append('the dedicated development cluster restarts while the application stays alive and reconnects')

    with Proxy() as proxy, Server(results, secret, 'recovery', 'contract', submission / 'zig-out/bin/conduit', database_port=proxy.port) as server:
        # One healthy listener does not prove that every reactor's pool recovered.
        count_query = f"SELECT count(*) FROM pg_stat_activity WHERE datname='{server.database}' AND usename='conduit' AND state='idle' AND xact_start IS NULL"
        rebuilt(connection_count)
        accepted = len(proxy.sessions)
        kill()
        rebuilt(accepted + connection_count)
        run, transcript, _, summary = upstream(server, 'after-recovery', work / 'tools/conformance')
        assert run.returncode == 0 and len(transcript) == 197, summary
        checks.append('all 197 unchanged conformance steps pass after backend replacement')
    evidence = {'checks': checks, 'database_connections': connection_count, 'upstream_steps_passed': 197,
                'scope': 'development-seed fault injection; platform recorded by the enclosing run; no capacity claim'}
    (results / 'results.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print(f'PASS: {len(checks)} recovery/concurrency scenarios; {connection_count} owners; 197 upstream steps', flush=True)


if __name__ == '__main__':
    main()

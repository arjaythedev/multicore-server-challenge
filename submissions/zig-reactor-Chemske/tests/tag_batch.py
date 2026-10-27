"""Verify actual shared tag executions, fresh later reads and grouped SQL errors.

Build with -Dtag-batch=true. Only private clones and the local test proxy change.
"""
import concurrent.futures
import json
import os
from pathlib import Path
import threading
import time
from urllib.parse import quote

from support import Server
from recovery import Proxy, eventually, lock_tags

work = Path(os.environ['CHALLENGE_WORK'])
submission = Path(__file__).resolve().parents[1]
results = work / 'results/tag-batch'
results.mkdir(parents=True, exist_ok=True)
with Proxy() as proxy, Server(results, 'tag-batch-only', 'tagbatch', 'focus', submission / 'zig-out/bin/conduit', database_port=proxy.port) as server:
    def executions():
        return sum(session['tags'] for session in proxy.sessions)

    baseline = server.request('GET', '/api/tags')
    count = int(server.sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{server.database}' AND usename='conduit'"))
    barrier = threading.Barrier(65)
    def read(_):
        barrier.wait(timeout=5)
        return server.request('GET', '/api/tags')
    before = executions()
    with concurrent.futures.ThreadPoolExecutor(max_workers=64) as pool:
        with lock_tags(server, mode='ACCESS EXCLUSIVE'):
            futures = [pool.submit(read, i) for i in range(64)]
            barrier.wait(timeout=5)
            eventually(lambda: int(server.sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{server.database}' AND usename='conduit' AND wait_event_type='Lock'")) == count)
            time.sleep(0.2)
        answers = [future.result(timeout=5) for future in futures]
    assert all(answer == baseline for answer in answers)
    shared_executions = executions() - before
    assert 1 <= shared_executions < 32, shared_executions
    server.sql("INSERT INTO tags(name) VALUES ('zz-after-tag-group')")
    before = executions()
    assert 'zz-after-tag-group' in server.request('GET', '/api/tags')[1]['tags']
    assert executions() == before + 1

    # Keep owners occupied while the tag group queues, then reject only its SQL.
    slug = server.sql('SELECT slug FROM articles ORDER BY id DESC LIMIT 1')
    barrier = threading.Barrier(65)
    before = executions()
    with concurrent.futures.ThreadPoolExecutor(max_workers=68) as pool:
        try:
            with lock_tags(server, mode='ACCESS EXCLUSIVE', table='articles'):
                blockers = [pool.submit(server.request, 'GET', '/api/articles/' + quote(slug, safe='') + '/comments') for _ in range(count)]
                eventually(lambda: int(server.sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{server.database}' AND usename='conduit' AND wait_event_type='Lock'")) == count)
                futures = [pool.submit(read, i) for i in range(64)]
                barrier.wait(timeout=5)
                time.sleep(0.2)
                server.sql('REVOKE SELECT ON tags FROM conduit')
            assert all(future.result(timeout=5)[0] == 200 for future in blockers)
            assert all(future.result(timeout=5)[0] == 503 for future in futures)
        finally:
            server.sql('GRANT SELECT ON tags TO conduit')
    failed_executions = executions() - before
    assert 1 <= failed_executions < 32, failed_executions
    assert server.request('GET', '/api/tags')[0] == 200
    (results / 'results.json').write_text(json.dumps({
        'concurrent_requests': 64, 'shared_pg_executions': shared_executions,
        'failed_requests': 64, 'failed_shared_pg_executions': failed_executions,
        'fresh_post_group_query': True, 'sql_error_reuse': True}, indent=2)+'\n')
    print(f'PASS: 64 reads / {shared_executions} PostgreSQL executions; 64 errors / {failed_executions} executions; fresh later reads', flush=True)

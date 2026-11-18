"""Check grouped comment lists, empty/missing articles, viewer isolation and SQL faults."""
import concurrent.futures
import argparse
import json
import os
from pathlib import Path
import threading
import socket
import time
from urllib.parse import quote

from support import Server, mint
from recovery import Proxy, eventually, lock_tags

work = Path(os.environ['CHALLENGE_WORK'])
submission = Path(__file__).resolve().parents[1]
results = work / 'results/comment-batch'
results.mkdir(parents=True, exist_ok=True)
secret = 'comment-batch-test-only'
parser = argparse.ArgumentParser()
parser.add_argument('--compact', action='store_true', help='require actual normalized wire executions')
args = parser.parse_args()
with Proxy() as proxy, Server(results, secret, 'commentbatch', 'focus', submission / 'zig-out/bin/conduit', database_port=proxy.port) as server:
    # Two slugs exercise PostgreSQL array escaping and independent article bodies.
    server.sql("UPDATE articles SET slug='batch,\"quote\\slash',title='batch article one' WHERE id=1")
    server.sql("UPDATE articles SET slug='batch-é-NULL',title='batch article two' WHERE id=2")
    author = int(server.sql('SELECT author_id FROM comments WHERE article_id=1 ORDER BY created_at DESC,id DESC LIMIT 1'))
    server.sql('DELETE FROM comments WHERE article_id=2')
    server.sql(f"INSERT INTO comments(article_id,author_id,body,created_at,updated_at) SELECT 1,{author},'batch comment '||i,'2030-01-01 00:00:00Z'::timestamptz+(i%2)*interval '1 microsecond',now() FROM generate_series(1,105) i")
    server.sql(f'DELETE FROM follows WHERE follower_id IN (1,2) AND followee_id={author}')
    server.sql(f'INSERT INTO follows(follower_id,followee_id) VALUES(1,{author})')
    slugs = ['batch,"quote\\slash', 'batch-é-NULL', 'batch-missing']
    inputs = [(slugs[index % 3], [None, mint(1, secret), mint(2, secret)][(index // 3) % 3]) for index in range(64)]
    expected = [server.request('GET', '/api/articles/' + quote(slug, safe='') + '/comments', token) for slug, token in inputs]
    assert len(expected[0][1]['comments']) == 100
    assert expected[3][1]['comments'][0]['author']['following']
    assert expected[1] == (200, {'comments': []}) and expected[2][0] == 404
    assert not expected[6][1]['comments'][0]['author']['following']
    owners = int(server.sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{server.database}' AND usename='conduit'"))
    current_path = '/api/user'
    current_token = mint(1, secret)
    def counts():
        return tuple(sum(session[key] for session in proxy.sessions) for key in ('comment_groups', 'comment_single'))
    def queued_reads(fault=False):
        barrier = threading.Barrier(65)
        def read(item):
            slug, token = item
            barrier.wait(timeout=10)
            return server.request('GET', '/api/articles/' + quote(slug, safe='') + '/comments', token)
        with concurrent.futures.ThreadPoolExecutor(max_workers=64 + owners) as pool:
            try:
                with lock_tags(server, mode='ACCESS EXCLUSIVE', table='users'):
                    blockers = [pool.submit(server.request, 'GET', current_path, current_token) for _ in range(owners)]
                    eventually(lambda: int(server.sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{server.database}' AND usename='conduit' AND wait_event_type='Lock'")) == owners)
                    futures = [pool.submit(read, item) for item in inputs]
                    barrier.wait(timeout=10)
                    time.sleep(0.2)
                    if fault:
                        server.sql('REVOKE SELECT ON comments FROM conduit')
                assert all(future.result(timeout=10)[0] == 200 for future in blockers)
                return [future.result(timeout=10) for future in futures]
            finally:
                if fault:
                    server.sql('GRANT SELECT ON comments TO conduit')
    before = counts()
    assert queued_reads() == expected
    after = counts()
    group_queries, single_queries = [end - start for start, end in zip(before, after)]
    assert group_queries > 0 and group_queries + single_queries < 16, (group_queries, single_queries)
    compact_groups = sum(session['compact_comment_groups'] for session in proxy.sessions)
    if args.compact: assert compact_groups > 0
    server.sql("UPDATE comments SET body='fresh after group' WHERE id=(SELECT id FROM comments WHERE article_id=1 ORDER BY created_at DESC,id DESC LIMIT 1)")
    before = counts()
    assert server.request('GET', '/api/articles/' + quote(slugs[0], safe='') + '/comments')[1]['comments'][0]['body'] == 'fresh after group'
    after = counts()
    assert sum(after) == sum(before) + 1
    # Retain the primary task's shared metadata until every follower has been
    # serialized, including when the primary socket disappears during SQL.
    current_expected = [server.request('GET', '/api/articles/' + quote(slug, safe='') + '/comments', token) for slug, token in inputs]
    primary = socket.create_connection(('127.0.0.1', server.port), timeout=5)
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=64+owners) as pool:
            with lock_tags(server, mode='ACCESS EXCLUSIVE', table='comments'):
                with lock_tags(server, mode='ACCESS EXCLUSIVE', table='users'):
                    blockers = [pool.submit(server.request, 'GET', current_path, current_token) for _ in range(owners)]
                    eventually(lambda: int(server.sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{server.database}' AND usename='conduit' AND wait_event_type='Lock'")) == owners)
                    primary.sendall(('GET /api/articles/'+quote(slugs[0],safe='')+'/comments HTTP/1.1\r\nHost: test\r\n\r\n').encode())
                    time.sleep(0.05)
                    before_disconnect = counts()[0]
                    followers = [pool.submit(server.request, 'GET', '/api/articles/'+quote(slug,safe='')+'/comments', token) for slug,token in inputs]
                    time.sleep(0.2)
                eventually(lambda: counts()[0] > before_disconnect)
                primary.close()
                time.sleep(0.05)
            assert all(future.result(timeout=10)[0] == 200 for future in blockers)
            assert [future.result(timeout=10) for future in followers] == current_expected
    finally:
        primary.close()
    before = counts()
    assert all(answer[0] == 503 for answer in queued_reads(fault=True))
    after = counts()
    failed_queries = sum(after) - sum(before)
    assert failed_queries < 16, failed_queries
    assert server.request('GET', '/api/articles/' + quote(slugs[0], safe='') + '/comments')[0] == 200
    evidence = {'requests': 64, 'group_queries': group_queries, 'individual_queries': single_queries,
                'compact_groups': compact_groups, 'primary_disconnect_safe': True,
                'viewer_flags_and_missing_rows_match': True, 'fresh_later_query': True,
                'failed_requests': 64, 'failed_queries': failed_queries, 'reusable_after_sql_error': True}
    (results / 'results.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print(f'PASS: 64 mixed comment lists / {group_queries} grouped + {single_queries} individual queries; viewer isolation, 404, freshness and SQL errors', flush=True)

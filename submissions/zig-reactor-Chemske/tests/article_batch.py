"""Check grouped article execution, viewer isolation, missing rows and SQL faults."""
import concurrent.futures
import json
import os
from pathlib import Path
import threading
import time
from urllib.parse import quote

from support import Server, mint
from recovery import Proxy, eventually, lock_tags

work = Path(os.environ['CHALLENGE_WORK'])
submission = Path(__file__).resolve().parents[1]
results = work / 'results/article-batch'
results.mkdir(parents=True, exist_ok=True)
secret = 'article-batch-test-only'
with Proxy() as proxy, Server(results, secret, 'articlebatch', 'focus', submission / 'zig-out/bin/conduit', database_port=proxy.port) as server:
    # Two slugs exercise PostgreSQL array escaping and independent article bodies.
    server.sql("UPDATE articles SET slug='batch,\"quote\\slash',title='batch article one' WHERE id=1")
    server.sql("UPDATE articles SET slug='batch-é-NULL',title='batch article two' WHERE id=2")
    author = int(server.sql('SELECT author_id FROM articles WHERE id=1'))
    server.sql('DELETE FROM favorites WHERE article_id IN (1,2) AND user_id IN (1,2)')
    server.sql('INSERT INTO favorites(user_id,article_id) VALUES(1,1),(2,2)')
    server.sql(f'DELETE FROM follows WHERE follower_id IN (1,2) AND followee_id={author}')
    server.sql(f'INSERT INTO follows(follower_id,followee_id) VALUES(1,{author})')
    slugs = ['batch,"quote\\slash', 'batch-é-NULL', 'batch-missing']
    inputs = [(slugs[index % 3], [None, mint(1, secret), mint(2, secret)][(index // 3) % 3]) for index in range(64)]
    expected = [server.request('GET', '/api/articles/' + quote(slug, safe=''), token) for slug, token in inputs]
    assert expected[3][1]['article']['favorited'] and expected[3][1]['article']['author']['following']
    assert not expected[6][1]['article']['favorited'] and not expected[6][1]['article']['author']['following']
    owners = int(server.sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{server.database}' AND usename='conduit'"))
    comment_path = '/api/articles/' + quote(slugs[0], safe='') + '/comments'
    def counts():
        return tuple(sum(session[key] for session in proxy.sessions) for key in ('article_groups', 'article_single'))
    def queued_reads(fault=False):
        barrier = threading.Barrier(65)
        def read(item):
            slug, token = item
            barrier.wait(timeout=10)
            return server.request('GET', '/api/articles/' + quote(slug, safe=''), token)
        with concurrent.futures.ThreadPoolExecutor(max_workers=64 + owners) as pool:
            try:
                with lock_tags(server, mode='ACCESS EXCLUSIVE', table='articles'):
                    blockers = [pool.submit(server.request, 'GET', comment_path) for _ in range(owners)]
                    eventually(lambda: int(server.sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{server.database}' AND usename='conduit' AND wait_event_type='Lock'")) == owners)
                    futures = [pool.submit(read, item) for item in inputs]
                    barrier.wait(timeout=10)
                    time.sleep(0.2)
                    if fault:
                        server.sql('REVOKE SELECT ON favorites FROM conduit')
                assert all(future.result(timeout=10)[0] == 200 for future in blockers)
                return [future.result(timeout=10) for future in futures]
            finally:
                if fault:
                    server.sql('GRANT SELECT ON favorites TO conduit')
    before = counts()
    assert queued_reads() == expected
    after = counts()
    group_queries, single_queries = [end - start for start, end in zip(before, after)]
    assert group_queries > 0 and group_queries + single_queries < 16, (group_queries, single_queries)
    server.sql("UPDATE articles SET title='fresh after group' WHERE id=1")
    before = counts()
    assert server.request('GET', '/api/articles/' + quote(slugs[0], safe=''))[1]['article']['title'] == 'fresh after group'
    after = counts()
    assert sum(after) == sum(before) + 1
    before = counts()
    assert all(answer[0] == 503 for answer in queued_reads(fault=True))
    after = counts()
    failed_queries = sum(after) - sum(before)
    assert failed_queries < 16, failed_queries
    assert server.request('GET', '/api/articles/' + quote(slugs[0], safe=''))[0] == 200
    evidence = {'requests': 64, 'group_queries': group_queries, 'individual_queries': single_queries,
                'viewer_flags_and_missing_rows_match': True, 'fresh_later_query': True,
                'failed_requests': 64, 'failed_queries': failed_queries, 'reusable_after_sql_error': True}
    (results / 'results.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print(f'PASS: 64 mixed article reads / {group_queries} grouped + {single_queries} individual queries; viewer isolation, 404, freshness and SQL errors', flush=True)

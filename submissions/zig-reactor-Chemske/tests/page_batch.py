"""Compare every batched page family and retain page-before-count snapshots."""
import concurrent.futures
import json
import os
from pathlib import Path
import threading
import time
import socket
from urllib.parse import quote

from support import Server, mint
from recovery import Proxy, eventually, lock_tags

work = Path(os.environ['CHALLENGE_WORK'])
submission = Path(__file__).resolve().parents[1]
results = work / 'results/page-batch'
results.mkdir(parents=True, exist_ok=True)
with Proxy() as proxy, Server(results, 'page-batch-test-only', 'pagebatch', 'focus', submission / 'zig-out/bin/conduit', database_port=proxy.port) as server:
    author = server.fixture('batch_page_author')
    fan = server.fixture('batch_page_fan')
    server.sql(f'UPDATE articles SET author_id={author} WHERE id<=20')
    server.sql(f'INSERT INTO favorites(user_id,article_id) SELECT {fan},id FROM articles WHERE id<=20 ON CONFLICT DO NOTHING')
    server.sql(f'DELETE FROM follows WHERE follower_id IN (1,2) AND followee_id={author}')
    server.sql(f'INSERT INTO follows(follower_id,followee_id) VALUES(1,{author})')
    server.sql('DELETE FROM follows WHERE follower_id=2')
    tag = server.sql('SELECT name FROM tags ORDER BY id LIMIT 1')
    owners = int(server.sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{server.database}' AND usename='conduit'"))
    token = mint(1, server.secret)
    def counts():
        return tuple(sum(s[k] for s in proxy.sessions) for k in ('page_groups', 'count_groups', 'page_queries', 'count_queries'))
    def queued(items, fault=False, after_page=None):
        barrier = threading.Barrier(len(items) + 1)
        def read(item):
            barrier.wait(timeout=10)
            return server.request('GET', item[0], item[1])
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(items)+owners) as pool:
            try:
                with lock_tags(server, mode='ACCESS EXCLUSIVE', table='users'):
                    blockers = [pool.submit(server.request, 'GET', '/api/user', token) for _ in range(owners)]
                    eventually(lambda: int(server.sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{server.database}' AND usename='conduit' AND wait_event_type='Lock'")) == owners)
                    futures = [pool.submit(read, item) for item in items]
                    barrier.wait(timeout=10)
                    time.sleep(0.2)
                    if fault:
                        server.sql('REVOKE SELECT ON favorites FROM conduit')
                if after_page:
                    assert proxy.count_seen.wait(5), 'no batched count reached the proxy'
                    after_page()
                    proxy.release_counts.set()
                assert all(f.result(timeout=10)[0] == 200 for f in blockers)
                return [f.result(timeout=10) for f in futures]
            finally:
                proxy.release_counts.set()
                if fault:
                    server.sql('GRANT SELECT ON favorites TO conduit')
    totals = {}
    for family, endpoint, filters in [
        ('all', '/api/articles', ['', '']),
        ('tag', '/api/articles', ['&tag='+quote(tag,safe=''), '&tag=unknown-page-tag']),
        ('author', '/api/articles', ['&author=batch_page_author', '&author=unknown-page-author']),
        ('favorited', '/api/articles', ['&favorited=batch_page_fan', '&favorited=unknown-page-fan']),
        ('feed', '/api/articles/feed', ['', '']),
    ]:
        items=[]
        for i in range(32):
            limit = [1,2,3,10,100][i%5]
            offset = [0,1,25,1001,100000000,9223372036854775807][(i//5)%6]
            viewer = [0,1,2][(i//2)%3]
            if family == 'feed' and viewer == 0: viewer=1
            path=endpoint+f'?limit={limit}&offset={offset}'+filters[(i//3)%2]
            items.append((path,None if viewer==0 else mint(viewer,server.secret)))
        expected=[server.request('GET',path,auth) for path,auth in items]
        assert all(answer[0] == 200 for answer in expected), [(item[0], answer[0], answer[1]) for item,answer in zip(items,expected) if answer[0]!=200]
        before=counts()
        actual=queued(items)
        assert actual==expected, family
        delta=[b-a for a,b in zip(before,counts())]
        assert delta[0]>0 and delta[1]>0 and sum(delta)<20,(family,delta)
        totals[family]=delta
    items=[('/api/articles?author=batch_page_author&limit=3',token)]*32
    before=[server.request('GET',path,auth) for path,auth in items]
    proxy.hold_counts=True
    proxy.release_counts.clear()
    proxy.count_seen.clear()
    def insert():
        server.sql(f"INSERT INTO articles(author_id,slug,title,description,body) VALUES({author},'page-after-snapshot','page after snapshot','d','b')")
    actual=queued(items,after_page=insert)
    proxy.hold_counts=False
    for old,new in zip(before,actual):
        assert old[1]['articles']==new[1]['articles']
        assert old[1]['articlesCount']+1==new[1]['articlesCount']
    latest=server.request('GET',items[0][0],token)
    assert latest[1]['articles'][0]['slug']=='page-after-snapshot'
    # The primary arena must outlive followers even when its socket disappears
    # between the page result and the separate count statement.
    retained = [(items[0][0], mint(1 + i % 2, server.secret)) for i in range(32)]
    expected_retained = [server.request('GET', path, auth) for path, auth in retained]
    primary = socket.create_connection(('127.0.0.1', server.port), timeout=5)
    proxy.hold_counts = True
    proxy.release_counts.clear()
    proxy.count_seen.clear()
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(retained)+owners) as pool:
            with lock_tags(server, mode='ACCESS EXCLUSIVE', table='users'):
                blockers = [pool.submit(server.request, 'GET', '/api/user', token) for _ in range(owners)]
                eventually(lambda: int(server.sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{server.database}' AND usename='conduit' AND wait_event_type='Lock'")) == owners)
                primary.sendall(('GET '+items[0][0]+' HTTP/1.1\r\nHost: test\r\nAuthorization: Token '+token+'\r\n\r\n').encode())
                time.sleep(.05)
                pending = [pool.submit(server.request, 'GET', path, auth) for path, auth in retained]
                time.sleep(.2)
            assert proxy.count_seen.wait(5), 'no count after the primary page'
            primary.close()
            proxy.release_counts.set()
            assert all(f.result(timeout=10)[0] == 200 for f in blockers)
            assert [f.result(timeout=10) for f in pending] == expected_retained
    finally:
        primary.close()
        proxy.release_counts.set()
        proxy.hold_counts = False
    assert all(answer[0]==503 for answer in queued([('/api/articles?limit=3',token)]*32,fault=True))
    assert server.request('GET','/api/articles?limit=3',token)[0]==200
    (results/'results.json').write_text(json.dumps({'family_query_counts':totals,'page_before_count_snapshot':True,'fresh_later_page':True,'primary_disconnect_before_count':True,'sql_error_reuse':True},indent=2)+'\n')
    print('PASS: all five page families, mixed viewers/windows, separate count snapshot, disconnected primary, fresh reads and SQL faults',flush=True)

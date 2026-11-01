"""Compare grouped feed proofs with the full relation, including fresh counts."""
import concurrent.futures
import json
import os
from pathlib import Path
import threading
import time

from recovery import Proxy, eventually, lock_tags
from support import Server, mint

submission = Path(__file__).resolve().parents[1]
results = Path(os.environ['CHALLENGE_WORK']) / 'results/feed-hubs'
results.mkdir(parents=True, exist_ok=True)
secret = 'feed-hub-test-only'
with Proxy() as proxy, Server(results, secret, 'feedhubs', 'focus', submission / 'zig-out/bin/conduit', database_port=proxy.port) as server:
    viewers = [server.fixture('feed_hub_viewer_' + str(i)) for i in range(4)]
    authors = [server.fixture('feed_hub_author_' + str(i)) for i in range(3)]
    for author, size in zip(authors, (1105, 75, 4)):
        server.sql(f"INSERT INTO articles(author_id,slug,title,description,body) SELECT {author},'hub-{author}-'||i,'hub title','d','body' FROM generate_series(1,{size}) i")
    server.sql(f"INSERT INTO articles(id,author_id,slug,title,description,body) SELECT -i,{authors[2]},'hub-negative-'||i,'negative','d','b' FROM generate_series(1,40) i")
    for viewer, followed in zip(viewers, (authors[:2], [authors[0], authors[2]], authors[1:], [])):
        for author in followed:
            server.sql(f'INSERT INTO follows(follower_id,followee_id) VALUES({viewer},{author})')
    server.sql(f'INSERT INTO favorites(user_id,article_id) SELECT {viewers[0]},id FROM articles WHERE author_id={authors[0]} ORDER BY id DESC LIMIT 3')
    eventually(lambda: sum(s['feed_hub_preparations'] for s in proxy.sessions) > 0)
    owners = int(server.sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{server.database}' AND usename='conduit'"))

    def verify(item, answer, count_override=None):
        viewer, limit, offset = item
        code, body = answer
        assert code == 200, answer
        relation = f'FROM articles a WHERE author_id IN (SELECT followee_id FROM follows WHERE follower_id={viewer})'
        expected = [json.loads(line) for line in server.sql(f"SELECT json_build_object('slug',a.slug,'favorited',EXISTS(SELECT 1 FROM favorites f WHERE f.user_id={viewer} AND f.article_id=a.id)) {relation} ORDER BY a.id DESC LIMIT {limit} OFFSET {offset}").splitlines()]
        assert [dict(slug=row['slug'], favorited=row['favorited']) for row in body['articles']] == expected, item
        count = int(server.sql(f'SELECT count(*) FROM (SELECT 1 {relation} LIMIT 1000) s'))
        assert body['articlesCount'] == (count if count_override is None else count_override)
        assert all(row['author']['following'] for row in body['articles'])

    def queued(items, before_count=None, fault=False):
        barrier = threading.Barrier(len(items) + 1)
        def read(item):
            viewer, limit, offset = item
            barrier.wait(timeout=15)
            return server.request('GET', f'/api/articles/feed?limit={limit}&offset={offset}', mint(viewer, secret))
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(items) + owners) as pool:
            try:
                with lock_tags(server, mode='ACCESS EXCLUSIVE', table='users'):
                    blockers = [pool.submit(server.request, 'GET', '/api/user', mint(1, secret)) for _ in range(owners)]
                    eventually(lambda: int(server.sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{server.database}' AND usename='conduit' AND wait_event_type='Lock'")) == owners)
                    pending = [pool.submit(read, item) for item in items]
                    barrier.wait(timeout=15)
                    time.sleep(0.2)
                    if fault:
                        server.sql('REVOKE SELECT ON follows FROM conduit')
                if before_count:
                    assert proxy.count_seen.wait(5)
                    before_count()
                    proxy.release_counts.set()
                assert all(f.result(timeout=12)[0] == 200 for f in blockers)
                return [f.result(timeout=12) for f in pending]
            finally:
                proxy.release_counts.set()
                if fault:
                    server.sql('GRANT SELECT ON follows TO conduit')

    cases = []
    for offsets in ((0, 1, 10, 99), (0, 1001, 5000, 9223372036854775807)):
        items = [(viewers[i % 4], (1, 10, 100)[(i // 4) % 3], offsets[(i // 12) % 4]) for i in range(128)]
        answers = queued(items)
        for item, answer in zip(items, answers):
            verify(item, answer)
        cases.extend(items)
    # Page and count have separate snapshots: a new follow changes the later
    # count even though the already selected page remains empty.
    items = [(viewers[3], 10, 0)] * 32
    proxy.hold_counts = True
    proxy.count_seen.clear()
    proxy.release_counts.clear()
    answers = queued(items, before_count=lambda: server.sql(f'INSERT INTO follows(follower_id,followee_id) VALUES({viewers[3]},{authors[0]})'))
    proxy.hold_counts = False
    assert all(answer == (200, {'articles': [], 'articlesCount': 1000}) for answer in answers)
    verify(items[0], server.request('GET', '/api/articles/feed?limit=10', mint(viewers[3], secret)))
    assert all(code == 503 for code, _ in queued(items, fault=True))
    assert server.request('GET', '/api/articles/feed', mint(viewers[3], secret))[0] == 200
    evidence = {'compared_feeds': len(cases), 'shared_hub_preparations': sum(s['feed_hub_preparations'] for s in proxy.sessions),
                'deep_and_negative_ids': True, 'fresh_count_after_new_follow': True, 'sql_failure_reusable': True}
    (results / 'results.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print('PASS: 256 feeds match the full relation; shared authors, caps, sparse/empty feeds, deep offsets, negative IDs, viewer flags and fresh count snapshots', flush=True)

"""Exercise actual grouped mutations, atomic rollback and lost implicit commits."""
import concurrent.futures
from collections import Counter
import json
import os
from pathlib import Path
import time
from urllib.parse import quote

from recovery import Proxy, eventually, lock_tags
from support import Server, mint

submission = Path(__file__).resolve().parents[1]
results = Path(os.environ['CHALLENGE_WORK']) / 'results/favorite-batch'
results.mkdir(parents=True, exist_ok=True)
secret = 'favorite-batch-test-only'
with Proxy() as proxy, Server(results, secret, 'favoritebatch', 'focus', submission / 'zig-out/bin/conduit', database_port=proxy.port) as server:
    slug = server.sql('SELECT slug FROM articles WHERE id=1')
    endpoint = '/api/articles/' + quote(slug, safe='') + '/favorite'
    connection_count = int(server.sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{server.database}' AND usename='conduit'"))
    server.sql('DELETE FROM favorites WHERE article_id=1 AND user_id BETWEEN 1 AND 32')

    def total(key):
        return sum(s[key] for s in proxy.sessions)

    def executed_viewers():
        return Counter(viewer for session in proxy.sessions for name, viewers in session['favorite_executions']
                       if name in ('batch_favorite', 'op_favorite') for viewer in viewers)

    def queued(method, identifiers, drop=False):
        # A locked article creation occupies every write owner before the
        # favorite cohort arrives. This also works with an unpartitioned pool.
        owners = int(server.sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{server.database}' AND usename='conduit'"))
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(identifiers) + owners) as pool:
            with lock_tags(server):
                blockers = [pool.submit(server.request, 'POST', '/api/articles', mint(1, secret), {'article': {
                    'title': 'favorite blocker ' + str(time.time_ns()) + str(i), 'description': 'd', 'body': 'b', 'tagList': ['favorite-lock']}}) for i in range(owners)]
                # Dedicated pools have idle read owners; unpartitioned pools
                # have all owners blocked. Wait until the lock count settles.
                eventually(lambda: int(server.sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{server.database}' AND usename='conduit' AND wait_event_type='Lock'")) > 0)
                time.sleep(0.15)
                futures = [pool.submit(server.request, method, endpoint if identifier is not None else '/api/articles/missing-batch-target/favorite', mint(identifier or 1, secret)) for identifier in identifiers]
                time.sleep(0.2)
                if drop:
                    proxy.drop_favorite.set()
            assert all(f.result(timeout=12)[0] == 201 for f in blockers)
            return [f.result(timeout=12) for f in futures]

    before = total('favorite_groups')
    answers = queued('POST', list(range(1, 17)) * 2 + [None] * 4)
    assert total('favorite_groups') > before
    assert all(code == 200 and body['article']['favorited'] for code, body in answers[:32])
    assert all(code == 404 for code, _ in answers[32:])
    assert server.sql('SELECT count(*) FROM favorites WHERE article_id=1 AND user_id BETWEEN 1 AND 16') == '16'
    answers = queued('DELETE', list(range(1, 17)) * 2)
    assert all(code == 200 and not body['article']['favorited'] for code, body in answers)
    assert server.sql('SELECT count(*) FROM favorites WHERE article_id=1 AND user_id BETWEEN 1 AND 16') == '0'

    # A nonexistent viewer fails the whole implicit transaction. A confirmed
    # rollback may be split into individual mutations without losing good work.
    invalid = 999999999
    before = total('favorite_single')
    answers = queued('POST', [1, invalid, 2, 3, 4] * 4)
    assert total('favorite_single') > before
    assert all(code == 200 for (code, _), identifier in zip(answers, [1, invalid, 2, 3, 4] * 4) if identifier != invalid)
    assert all(code >= 400 for (code, _), identifier in zip(answers, [1, invalid, 2, 3, 4] * 4) if identifier == invalid)
    assert server.sql('SELECT count(*) FROM favorites WHERE article_id=1 AND user_id BETWEEN 1 AND 4') == '4'

    server.sql('DELETE FROM favorites WHERE article_id=1 AND user_id BETWEEN 1 AND 16')
    before_executions = executed_viewers()
    singles = total('favorite_single')
    # This distinct first-time operation must be a legitimate singleton. The
    # remaining cohort may also have singleton owners under SO_REUSEPORT.
    assert server.request('POST', endpoint, mint(17, secret))[0] == 200
    assert total('favorite_single') == singles + 1
    answers = queued('POST', list(range(1, 17)), drop=True)
    assert proxy.favorite_dropped.wait(2)
    assert any(code == 503 for code, _ in answers)
    assert server.sql('SELECT count(*) FROM favorites WHERE article_id=1 AND user_id BETWEEN 1 AND 16') == '16'
    eventually(lambda: len(proxy.sessions[-1]['prepared']) == 48)
    eventually(lambda: int(server.sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{server.database}' AND usename='conduit' AND state='idle' AND xact_start IS NULL")) == connection_count)
    executions = executed_viewers() - before_executions
    assert executions == Counter({viewer: 1 for viewer in range(1, 18)}), ('favorite request was omitted or replayed', executions)
    eventually(lambda: server.request('DELETE', endpoint, mint(1, secret))[0] == 200)
    assert server.sql('SELECT count(*) FROM favorites WHERE article_id=1 AND user_id=1') == '0'
    evidence = {'actual_groups': total('favorite_groups'), 'duplicates_and_missing_targets': True,
                'mixed_invalid_viewer_rollback_isolated': True, 'lost_implicit_commit_not_replayed': True,
                'uncertain_cohort_wire_executions': dict(executions), 'legitimate_singleton_verified': True}
    (results / 'results.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print('PASS: grouped favorites/unfavorites, duplicate and missing targets, atomic rollback isolation and no uncertain-commit replay', flush=True)

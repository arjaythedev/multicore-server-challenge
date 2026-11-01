"""Keep fresh reads progressing while every dedicated writer is blocked."""
import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import time

from recovery import eventually, lock_tags
from support import Server, mint

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--writers', type=int, required=True)
args = p.parse_args()
assert 1 <= args.writers <= 32
work = Path(os.environ['CHALLENGE_WORK'])
submission = Path(__file__).resolve().parents[1]
results = work / 'results/write-pool'
results.mkdir(parents=True, exist_ok=True)
with Server(results, 'write-pool-test-only', 'writepool', 'focus', submission / 'zig-out/bin/conduit') as server:
    author = server.fixture('write_pool_author')
    token = mint(author, server.secret)
    def create(index):
        return server.request('POST', '/api/articles', token, {'article': {
            'title': f'pool blocked writer {index}', 'description': 'd', 'body': 'b',
            'tagList': ['write-pool-lock']}})
    # More requests than writers also prove that a queued write cannot block reads.
    count = max(16, args.writers * 8)
    with concurrent.futures.ThreadPoolExecutor(max_workers=count) as pool:
        with lock_tags(server):
            pending = [pool.submit(create, index) for index in range(count)]
            eventually(lambda: int(server.sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{server.database}' AND usename='conduit' AND wait_event_type='Lock'")) == args.writers)
            started = time.monotonic()
            for _ in range(12):
                assert server.request('GET', '/api/tags')[0] == 200
                assert server.request('GET', '/api/articles?limit=3', token)[0] == 200
            read_seconds = time.monotonic() - started
            assert read_seconds < 1.5, read_seconds
            assert not any(item.done() for item in pending)
        assert all(item.result(timeout=10)[0] == 201 for item in pending)
    assert server.sql("SELECT count(*) FROM articles WHERE title LIKE 'pool blocked writer %'") == str(count)
    (results / 'results.json').write_text(json.dumps({'writers': args.writers, 'blocked_and_queued_writes': count,
        'fresh_reads_while_all_writers_blocked': 24, 'read_seconds': read_seconds, 'committed_writes': count}, indent=2) + '\n')
    print(f'PASS: {args.writers} blocked writers, {count} committed writes and 24 fresh reads without write-queue blocking', flush=True)

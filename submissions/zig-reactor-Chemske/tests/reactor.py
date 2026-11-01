"""Check independent reactors, eager partial writes and iterative HTTP pipelining."""
import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import re
import socket
import time

from support import Server, raw_response, mint

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--reactors', type=int, default=2)
args = p.parse_args()
work = Path(os.environ['CHALLENGE_WORK'])
submission = Path(__file__).resolve().parents[1]
results = work / 'results/reactor-v2'
results.mkdir(parents=True, exist_ok=True)
with Server(results, 'reactor-test-only', 'reactortest', 'focus', submission / 'zig-out/bin/conduit') as server:
    token = mint(1, server.secret)
    slug = server.sql('SELECT slug FROM articles WHERE id=1')
    path = '/api/articles/' + slug
    expected = server.request('GET', path, token)
    def read(_):
        for _ in range(8):
            assert server.request('GET', path, token) == expected
    with concurrent.futures.ThreadPoolExecutor(max_workers=48) as pool:
        list(pool.map(read, range(48)))
    # Immediate errors must not recurse one stack frame per pipelined request.
    with socket.create_connection(('127.0.0.1', server.port), timeout=10) as peer:
        peer.sendall(b'GET /missing HTTP/1.1\r\nHost: x\r\n\r\n' * 2048 + b'GET /api/tags HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n')
        with peer.makefile('rb') as reader:
            for _ in range(2048):
                assert raw_response(reader)[0] == 404
            assert raw_response(reader)[0] == 200
            assert reader.read(1) == b''
    # A response larger than a small receiver window exercises partial sends.
    server.sql("UPDATE articles SET body=repeat('payload',50000) WHERE id=1")
    with socket.create_connection(('127.0.0.1', server.port), timeout=20) as peer:
        peer.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        peer.sendall(('GET ' + path + ' HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n').encode())
        time.sleep(0.1)
        with peer.makefile('rb') as reader:
            status, body = raw_response(reader)
            assert status == 200 and body['article']['body'] == 'payload' * 50000
            assert reader.read(1) == b''
    # Every reactor must serve real traffic; a listener existing is insufficient.
    log = results / f'{server.database}.log'
    deadline = time.monotonic() + 15
    while True:
        values = {}
        for line in log.read_text().splitlines():
            if 'reactor_stats ' in line:
                item = {k: int(v) for k, v in re.findall(r'(\w+)=([0-9]+)', line)}
                values[item['id']] = item
        if len(values) == args.reactors and all(v['admitted'] > 0 for v in values.values()):
            break
        assert time.monotonic() < deadline, values
        server.request('GET', '/api/tags')
        time.sleep(0.05)
    assert all(v['capacity_503'] == 0 and v['password_503'] == 0 and v['db_failures'] == 0 for v in values.values()), values
    (results / 'results.json').write_text(json.dumps({'reactors': args.reactors, 'concurrent_article_reads': 384, 'pipelined_immediate_errors': 2048,
                                                    'large_body_bytes': 350000, 'stats': values}, indent=2) + '\n')
    print(f'PASS: {args.reactors} serving reactors, 384 isolated reads, 2048 pipelined errors and partial writes', flush=True)

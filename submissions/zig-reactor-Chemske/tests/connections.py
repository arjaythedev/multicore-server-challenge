"""Native socket scale, slot reuse, retained-input bounds and fixed request deadlines."""
import json
import os
from pathlib import Path
import socket
import subprocess
import time

from support import Server, raw_response

work = Path(os.environ['CHALLENGE_WORK'])
submission = Path(__file__).resolve().parents[1]
results = work / 'results/connections'
results.mkdir(parents=True, exist_ok=True)


def usage(pid):
    value = subprocess.check_output(['ps', '-p', str(pid), '-o', 'time=', '-o', 'rss='], text=True).split()
    minutes, seconds = value[0].split(':')
    return int(minutes) * 60 + float(seconds), int(value[1]) / 1024


with Server(results, 'connections-test-only', 'connections', 'scale', submission / 'zig-out/bin/conduit') as server:
    sockets = []
    try:
        for _ in range(8000):
            sockets.append(socket.create_connection(('127.0.0.1', server.port), timeout=5))
        assert server.request('GET', '/api/tags')[0] == 200
        for index in range(0, len(sockets), 997):
            peer = sockets[index]
            peer.sendall(b'GET /api/tags HTTP/1.1\r\nHost: x\r\n\r\n')
            with peer.makefile('rb') as reader:
                assert raw_response(reader)[0] == 200
        before, _ = usage(server.process.pid)
        time.sleep(2)
        after, rss = usage(server.process.pid)
        for index in range(0, len(sockets), 2):
            sockets[index].close()
        for index in range(0, len(sockets), 2):
            sockets[index] = socket.create_connection(('127.0.0.1', server.port), timeout=5)
        assert server.request('GET', '/api/articles?limit=1')[0] == 200
        print(f'PASS: 8000 native sockets, 4000 replacements; RSS {rss:.1f} MiB; idle CPU {(after-before)/2*100:.2f}% of one core', flush=True)
    finally:
        for peer in sockets:
            peer.close()

    # Aggregate retained input must be bounded even when every request is below
    # its individual header limit. This is deliberately incomplete HTTP input.
    sockets = []
    started = time.monotonic()
    try:
        for _ in range(2400):
            peer = socket.create_connection(('127.0.0.1', server.port), timeout=5)
            sockets.append(peer)
            try:
                peer.sendall(b'GET /api/tags HTTP/1.1\r\nHost: x\r\nX-Padding: ' + b'x' * 15000)
            except (BrokenPipeError, ConnectionResetError):
                pass
        assert time.monotonic() - started < 8, 'input-pressure setup exceeded the request deadline'
        closed = 0
        for peer in sockets:
            peer.setblocking(False)
            try:
                closed += peer.recv(1) == b''
            except (ConnectionResetError, BrokenPipeError):
                closed += 1
            except BlockingIOError:
                pass
        assert closed > 0, 'aggregate input budget did not reject excess buffers'
    finally:
        for peer in sockets:
            peer.close()
    assert server.request('GET', '/api/tags')[0] == 200
    print(f'PASS: aggregate input overload rejected {closed} sockets and recovered', flush=True)

    with socket.create_connection(('127.0.0.1', server.port), timeout=12) as peer:
        started = time.monotonic()
        peer.sendall(b'GET /api/tags HTTP/1.1\r\n')
        time.sleep(5)
        peer.sendall(b'X')
        assert peer.recv(1) == b''
        elapsed = time.monotonic() - started
        assert 8.5 <= elapsed <= 11, elapsed
    assert server.request('GET', '/api/tags')[0] == 200
    evidence = {'native_open_sockets': 8000, 'replaced_sockets': 4000,
                'idle_process_rss_mib': rss, 'idle_cpu_one_core_pct': (after-before)/2*100,
                'input_pressure_rejections': closed, 'partial_request_expiry_seconds': elapsed,
                'scope': 'native Mac socket check; not 100000 live sockets or official capacity'}
    (results / 'results.json').write_text(json.dumps(evidence, indent=2)+'\n')
    print('PASS: partial-request trickles do not extend the fixed deadline', flush=True)

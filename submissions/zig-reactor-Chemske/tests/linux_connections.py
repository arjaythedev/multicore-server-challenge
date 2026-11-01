"""Validate 150,000 live Linux sockets; this is not a workload-capacity score."""
import argparse
import errno
import json
import os
from pathlib import Path
import resource
import selectors
import socket
import sys
import time

from support import Server, raw_response

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--connections', type=int, default=150000)
args = p.parse_args()
assert sys.platform == 'linux', 'run on Linux; do not change the Mac kernel limits'
assert 1000 <= args.connections <= 180000
assert resource.getrlimit(resource.RLIMIT_NOFILE)[0] > args.connections + 128
work = Path(os.environ['CHALLENGE_WORK'])
submission = Path(__file__).resolve().parents[1]
results = work / 'results/linux-connections'
results.mkdir(parents=True, exist_ok=True)


def ticks(pid):
    fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
    return int(fields[11]) + int(fields[12])


with Server(results, 'linux-sockets-test-only', 'linuxsockets', 'scale', submission / 'zig-out/bin/conduit') as server:
    peers = []
    pending = set()
    started = time.monotonic()
    try:
        with selectors.DefaultSelector() as selector:
            created = 0
            while len(peers) < args.connections:
                while created < args.connections and len(pending) < 512:
                    peer = socket.socket()
                    pending.add(peer)
                    peer.setblocking(False)
                    # Separate loopback sources avoid the per-destination port range.
                    # Explicit unique ports avoid quadratic bind(0) searches
                    # as each source address fills its ephemeral range.
                    peer.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    peer.bind((f'127.0.0.{2 + created % 8}', 20000 + created // 8))
                    result = peer.connect_ex(('127.0.0.1', server.port))
                    assert result in (0, errno.EINPROGRESS), result
                    selector.register(peer, selectors.EVENT_WRITE)
                    created += 1
                for key, _ in selector.select(timeout=1):
                    peer = key.fileobj
                    assert peer.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR) == 0
                    selector.unregister(peer)
                    pending.remove(peer)
                    peers.append(peer)
                    if len(peers) % 10000 == 0:
                        print(f'Connected {len(peers)} sockets in {time.monotonic() - started:.2f}s', flush=True)
                assert time.monotonic() - started < 45, 'connection setup exceeded 45 seconds'
        opened_seconds = time.monotonic() - started
        # Validate every retained socket, in bounded windows, with an immediate
        # route. Bursting 100k database queries would test admission instead.
        request = b'GET /missing HTTP/1.1\r\nHost: x\r\n\r\n'
        for begin in range(0, len(peers), 256):
            group = peers[begin:begin + 256]
            for peer in group:
                peer.settimeout(5)
                peer.sendall(request)
            for peer in group:
                with peer.makefile('rb') as reader:
                    assert raw_response(reader)[0] == 404
            assert time.monotonic() - started < 65, 'validation exceeded the idle deadline'
        descriptor_count = len(list(Path(f'/proc/{server.process.pid}/fd').iterdir()))
        assert descriptor_count >= args.connections, descriptor_count
        before = ticks(server.process.pid)
        time.sleep(2)
        idle_cpu = (ticks(server.process.pid) - before) / os.sysconf('SC_CLK_TCK') / 2 * 100
        status = Path(f'/proc/{server.process.pid}/status').read_text().splitlines()
        rss = int(next(line for line in status if line.startswith('VmRSS:')).split()[1]) / 1024
        for index in range(0, len(peers), max(1, len(peers) // 100)):
            peer = peers[index]
            peer.sendall(b'GET /api/tags HTTP/1.1\r\nHost: x\r\n\r\n')
            with peer.makefile('rb') as reader:
                assert raw_response(reader)[0] == 200
        assert server.process.poll() is None
        (results / 'results.json').write_text(json.dumps({'live_sockets': len(peers),
            'http_validated_sockets': len(peers), 'server_descriptors': descriptor_count,
            'open_seconds': opened_seconds, 'rss_mib': rss, 'idle_cpu_pct_one_core': idle_cpu,
            'scope': 'Live socket ownership and reuse only; not a workload capacity result or an official capacity score.'}, indent=2) + '\n')
        print(f'PASS: {len(peers)} live Linux sockets, every socket answered HTTP; RSS {rss:.1f} MiB; idle CPU {idle_cpu:.2f}% of one core', flush=True)
    except BaseException:
        (results / 'failure.json').write_text(json.dumps({'connected': len(peers), 'pending': len(pending),
            'elapsed_seconds': time.monotonic() - started,
            'server_descriptors': len(list(Path(f'/proc/{server.process.pid}/fd').iterdir()))}, indent=2) + '\n')
        raise
    finally:
        for peer in pending | set(peers):
            peer.close()

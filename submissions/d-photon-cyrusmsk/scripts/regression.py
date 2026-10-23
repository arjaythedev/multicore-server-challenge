#!/usr/bin/env python3
"""Raw-socket regression checks for the photon HTTP boundary.

Run against a live server:
    python3 scripts/regression.py http://127.0.0.1:3200
"""
import json
import socket
import sys
import time
import urllib.parse

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:3200"
parsed = urllib.parse.urlparse(BASE)
HOST, PORT = parsed.hostname, parsed.port or 80


def read_response(sock):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            break
        data += chunk
    head, _, body = data.partition(b"\r\n\r\n")
    status = int(head.split(b" ", 2)[1])
    length = None
    for line in head.split(b"\r\n")[1:]:
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":", 1)[1])
    if length is not None:
        while len(body) < length:
            chunk = sock.recv(4096)
            if not chunk:
                break
            body += chunk
    return status, head.decode("latin1"), body


def send_fragmented(payload, chunks):
    s = socket.create_connection((HOST, PORT), timeout=5)
    for part in chunks:
        s.sendall(part)
    status, _, _ = read_response(s)
    s.close()
    return status


def main():
    s = socket.create_connection((HOST, PORT), timeout=5)
    s.sendall(b"GET /api/tags HTTP/1.1\r\nHost: x\r\n\r\n")
    assert read_response(s)[0] == 200
    s.sendall(b"GET /api/tags HTTP/1.1\r\nHost: x\r\n\r\n")
    assert read_response(s)[0] == 200
    s.close()

    # One byte at a time, then a second keep-alive request.
    payload = b"GET /api/tags HTTP/1.1\r\nHost: x\r\n\r\n"
    s = socket.create_connection((HOST, PORT), timeout=5)
    for b in payload:
        s.sendall(bytes([b]))
    assert read_response(s)[0] == 200
    s.sendall(b"GET /api/tags HTTP/1.1\r\nHost: x\r\n\r\n")
    assert read_response(s)[0] == 200
    s.close()

    # Fragmented body on a real POST.
    user = "p3reg%d" % int(time.time())
    body = json.dumps({"user": {"username": user, "email": user + "@example.com", "password": "password123"}}).encode()
    head = ("POST /api/users HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n" % len(body)).encode()
    s = socket.create_connection((HOST, PORT), timeout=5)
    s.sendall(head)
    for i in range(0, len(body), 7):
        s.sendall(body[i:i + 7])
    assert read_response(s)[0] == 201
    s.close()

    neg = b"POST /api/users HTTP/1.1\r\nHost: x\r\nContent-Length: -1\r\n\r\n"
    assert send_fragmented(neg, [neg]) in (400, 413)
    big = b"POST /api/users HTTP/1.1\r\nHost: x\r\nContent-Length: 2000000\r\n\r\n"
    assert send_fragmented(big, [big]) == 413

    # Slow reader: the server must not lose the body under backpressure.
    s = socket.create_connection((HOST, PORT), timeout=5)
    s.sendall(b"GET /api/articles?limit=100 HTTP/1.1\r\nHost: x\r\n\r\n")
    head = b""
    while b"\r\n\r\n" not in head:
        head += s.recv(1)
    assert b" 200 OK" in head.split(b"\r\n")[0]
    length = 0
    for line in head.split(b"\r\n"):
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":", 1)[1])
    got = 0
    while got < length:
        got += len(s.recv(1))
    s.close()
    assert got == length

    # Connection churn should not strand sockets.
    for _ in range(200):
        c = socket.create_connection((HOST, PORT), timeout=5)
        c.sendall(b"GET /api/tags HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        while c.recv(4096):
            pass
        c.close()

    print("regression: PASS")


if __name__ == "__main__":
    main()

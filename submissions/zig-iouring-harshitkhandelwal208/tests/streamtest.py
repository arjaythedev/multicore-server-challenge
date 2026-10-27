#!/usr/bin/env python3
"""Large heap-backed writes, partial sends, pipelining and abandoned slow readers.

Run against an already-running server on a disposable seed database:
  python3 tests/streamtest.py PORT
Requires seeded user 5000. JWT_SECRET defaults to the challenge secret.
"""
import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
import hmac
import http.client
import json
import os
import socket
import sys
import time
import uuid


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def main():
    port = int(sys.argv[1])
    host = "127.0.0.1"
    now = int(time.time())
    b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
    header = b64(b'{"alg":"HS256","typ":"JWT"}')
    claims = b64(json.dumps({"sub": "5000", "iat": now, "exp": now + 3600}).encode())
    signed = header + "." + claims
    token = signed + "." + b64(hmac.new(os.environ.get("JWT_SECRET", "multicore-server-challenge").encode(), signed.encode(), hashlib.sha256).digest())

    def call(method, path, body=None):
        client = http.client.HTTPConnection(host, port, timeout=30)
        try:
            client.request(method, path, json.dumps(body) if body is not None else None,
                           {"Authorization": "Token " + token, "Content-Type": "application/json"})
            response = client.getresponse()
            data = response.read()
            return response.status, json.loads(data) if data else {}
        finally:
            client.close()

    def read_response(stream):
        line = stream.readline(65536)
        require(line.startswith(b"HTTP/1.1 "), "missing response status line")
        status = int(line.split()[1])
        headers = {}
        while True:
            line = stream.readline(65536)
            require(bool(line) and line.endswith(b"\r\n"), "truncated response headers")
            if line == b"\r\n":
                break
            key, value = line.split(b":", 1)
            headers[key.lower()] = value.strip()
        require(b"content-length" in headers and b"transfer-encoding" not in headers, "unexpected framing")
        length = int(headers[b"content-length"])
        require(0 <= length <= 8 * 1024 * 1024, "invalid response size")
        data = stream.read(length)
        require(len(data) == length, "truncated response body")
        return status, json.loads(data)

    title = "stream-test-" + uuid.uuid4().hex
    body = "partial-send-" + "z" * (6 * 1024 * 1024)
    path = None
    try:
        status, created = call("POST", "/api/articles", {"article": {"title": title, "description": "large response", "body": body}})
        require(status == 201, "large create returned %d" % status)
        article = created["article"]
        require(article["title"] == title and article["body"] == body, "large create body differs")
        path = "/api/articles/" + article["slug"]
        print("PASS 6 MiB heap-backed article create and committed response", flush=True)
        for iteration in range(3):
            with socket.socket() as client:
                client.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16384)
                client.settimeout(30)
                client.connect((host, port))
                client.sendall(("GET " + path + " HTTP/1.1\r\nHost: x\r\n\r\nGET /api/tags HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").encode())
                time.sleep(.05)  # a 6 MiB response cannot fit the advertised receive window
                with client.makefile("rb") as stream:
                    status, actual = read_response(stream)
                    require(status == 200 and actual["article"] == article, "large read identity or bytes differ")
                    status, tags = read_response(stream)
                    require(status == 200 and isinstance(tags["tags"], list), "pipelined second response differs")
                    require(stream.read(1) == b"", "Connection: close not honored after large response")
            print("PASS slow-reader partial send and ordered pipeline %d/3" % (iteration + 1), flush=True)

        def reuse_large_response(_):
            client = http.client.HTTPConnection(host, port, timeout=30)
            connection_socket = None
            try:
                for endpoint in (path, "/api/tags", path):
                    client.request("GET", endpoint)
                    if connection_socket is None:
                        connection_socket = client.sock
                    require(connection_socket is not None and client.sock is connection_socket,
                            "concurrent client reconnected instead of retaining its socket")
                    response = client.getresponse()
                    actual = json.loads(response.read())
                    require(not response.will_close and client.sock is connection_socket,
                            "large/small/large sequence did not retain one keep-alive socket")
                    require(response.status == 200, "concurrent keep-alive response returned %d" % response.status)
                    if endpoint == path:
                        require(actual["article"] == article, "concurrent large response bytes differ")
                    else:
                        require(isinstance(actual["tags"], list), "small response after large send differs")
                return True
            finally:
                client.close()

        with ThreadPoolExecutor(max_workers=16) as pool:
            completed = list(pool.map(reuse_large_response, range(16)))
        require(len(completed) == 16 and all(completed), "not every concurrent keep-alive client completed")
        print("PASS 16 concurrent keep-alive clients: large/small/large responses without retries or EOFs", flush=True)
        for _ in range(10):
            client = socket.create_connection((host, port), timeout=5)
            try:
                client.sendall(("GET " + path + " HTTP/1.1\r\nHost: x\r\n\r\n").encode())
                time.sleep(.005)
            finally:
                client.close()
        status, tags = call("GET", "/api/tags")
        require(status == 200 and isinstance(tags["tags"], list), "server failed after abandoned large responses")
        print("PASS server responsive after ten abandoned large responses", flush=True)
    finally:
        if path is not None:
            status, _ = call("DELETE", path)
            require(status == 204, "large fixture cleanup failed with %d" % status)


if __name__ == "__main__":
    try:
        main()
    except (Exception, KeyboardInterrupt) as exc:
        print("FAIL: %s: %s" % (type(exc).__name__, exc), file=sys.stderr)
        sys.exit(1)

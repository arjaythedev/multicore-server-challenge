#!/usr/bin/env python3
"""Exercise the tags milestone on a disposable copy of the development seed."""
import concurrent.futures
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import time

submission = Path(__file__).resolve().parents[1]
database = f"challenge_tags_{os.getpid()}"


def sql(statement, target="postgres"):
    return subprocess.check_output(
        ["psql", "-X", "-v", "ON_ERROR_STOP=1", "-At", "-d", target, "-c", statement],
        text=True,
    ).strip()


def request(path="/api/tags", headers=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        connection.request("GET", path, headers=headers or {})
        response = connection.getresponse()
        return response.status, json.loads(response.read())
    finally:
        connection.close()


def raw_response(reader):
    status = int(reader.readline().split()[1])
    headers = {}
    while True:
        line = reader.readline()
        if line == b"\r\n":
            break
        assert line, "connection ended before response headers"
        key, value = line.decode("ascii").split(":", 1)
        headers[key.lower()] = value.strip()
    body = reader.read(int(headers["content-length"]))
    return status, headers, json.loads(body)


with socket.socket() as probe:
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]

sql(f"CREATE DATABASE {database} TEMPLATE conduit_dev")
process = None
checks = 0
try:
    environment = dict(os.environ, HOST="127.0.0.1", PORT=str(port),
                       JWT_SECRET="milestone-test-only",
                       DATABASE_URL=f"postgres://conduit:conduit@127.0.0.1:{os.environ['PGPORT']}/{database}")
    process = subprocess.Popen([str(submission / "zig-out/bin/conduit")], env=environment,
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    deadline = time.monotonic() + 10
    while True:
        try:
            status, initial = request()
            assert status == 200
            break
        except OSError:
            if process.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError("server did not become healthy")
            time.sleep(0.05)
    assert len(initial["tags"]) == 200
    assert initial["tags"] == sorted(set(initial["tags"]))
    checks += 1

    assert request(headers={"Authorization": ""}) == (200, initial)
    checks += 1
    assert request("/not-implemented")[0] == 404
    checks += 1

    with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
        client.sendall(b"GET /api/ta")
        time.sleep(0.02)
        client.sendall(b"gs HTTP/1.1\r\nHost: x\r\n\r\n"
                       b"GET /api/tags HTTP/1.1\r\nHost: x\r\nConnection: close, keep-alive\r\n\r\n")
        with client.makefile("rb") as reader:
            assert raw_response(reader)[2] == initial
            second = raw_response(reader)
            assert second[2] == initial and second[1]["connection"] == "close"
            assert reader.read(1) == b""
    checks += 1

    malformed = [
        b"Content-Length: 0\r\nContent-Length: 1\r\n",
        b"Transfer-Encoding: chunked\r\nContent-Length: 0\r\n",
    ]
    for extra in malformed:
        with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
            client.sendall(b"GET /api/tags HTTP/1.1\r\nHost: x\r\n" + extra + b"\r\n")
            with client.makefile("rb") as reader:
                assert raw_response(reader)[0] == 400
                assert reader.read(1) == b""
        checks += 1

    with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
        client.sendall(b"GET /api/tags HTTP/1.1\r\nHost: x\r\nX-Large: " + b"a" * 17000)
        with client.makefile("rb") as reader:
            assert raw_response(reader)[0] == 431
    checks += 1

    def repeated(_):
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        try:
            for _ in range(4):
                connection.request("GET", "/api/tags")
                response = connection.getresponse()
                assert response.status == 200 and json.loads(response.read()) == initial
        finally:
            connection.close()
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
        list(pool.map(repeated, range(16)))
    checks += 1

    # Only the disposable database changes; the seed remains untouched.
    sql("INSERT INTO tags(name) VALUES ('zz-milestone-fresh-read')", database)
    status, changed = request()
    assert status == 200 and "zz-milestone-fresh-read" in changed["tags"]
    assert len(changed["tags"]) == 201
    checks += 1

    # An SQL error must be fully drained before the connection is reused.
    sql("ALTER TABLE tags RENAME TO tags_temporarily_unavailable", database)
    assert request()[0] == 503
    sql("ALTER TABLE tags_temporarily_unavailable RENAME TO tags", database)
    assert request() == (200, changed)
    checks += 1

    sql(f"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='{database}' AND usename='conduit'")
    deadline = time.monotonic() + 10
    while True:
        answer = request()
        if answer[0] == 200:
            assert answer == (200, changed)
            break
        assert answer[0] == 503 and time.monotonic() < deadline
        time.sleep(0.03)
    checks += 1
    print(f"PASS: {checks} milestone checks, including 64 concurrent keep-alive requests")
finally:
    if process is not None:
        process.terminate()
        try:
            _, error_log = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            _, error_log = process.communicate()
        if process.returncode not in (-15, 0):
            print(error_log.decode("utf-8", errors="replace"))
    sql(f"DROP DATABASE IF EXISTS {database} WITH (FORCE)")

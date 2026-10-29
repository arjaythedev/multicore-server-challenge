#!/usr/bin/env python3
"""Raw-socket HTTP/1.1 robustness checks against a running server (default 127.0.0.1:3000)."""
import socket, sys, time, json, threading
from concurrent.futures import ThreadPoolExecutor
HOST, PORT = "127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 3000
fails = 0

def conn():
    s = socket.create_connection((HOST, PORT)); s.settimeout(5); return s

def response_head(head):
    lines = head.split(b"\r\n")
    status_line = lines[0].split(b" ", 2)
    if len(status_line) < 2 or status_line[0] not in (b"HTTP/1.0", b"HTTP/1.1") or len(status_line[1]) != 3 or not status_line[1].isdigit():
        raise ValueError("invalid HTTP response status line")
    status = int(status_line[1])
    if not 100 <= status <= 599: raise ValueError("invalid HTTP response status")
    hdrs = {}
    for line in lines[1:]:
        name, sep, value = line.partition(b":")
        if not sep or not name or name.strip() != name: raise ValueError("invalid HTTP response header")
        key = name.decode("ascii").lower()
        if key in ("content-length", "transfer-encoding") and key in hdrs:
            raise ValueError("duplicate HTTP response framing header")
        hdrs[key] = value.decode("latin-1").strip()
    if "transfer-encoding" in hdrs: raise ValueError("expected Content-Length response framing")
    length = hdrs.get("content-length")
    if length is None and status == 204: length = "0"
    if length is None or not length.isascii() or not length.isdecimal():
        raise ValueError("missing or invalid response Content-Length")
    n = int(length)
    if status == 204 and n: raise ValueError("204 response has a nonempty body")
    return status, hdrs, n

def read_resp(s, buf=b""):
    """Read one complete Content-Length response; returns (status, headers, body, rest)."""
    while b"\r\n\r\n" not in buf:
        if len(buf) > 65536: raise ValueError("response headers too large")
        d = s.recv(65536)
        if not d:
            if buf: raise EOFError("truncated HTTP response headers")
            return None, {}, b"", buf
        buf += d
    head, rest = buf.split(b"\r\n\r\n", 1)
    if len(head) > 65536: raise ValueError("response headers too large")
    status, hdrs, n = response_head(head)
    while len(rest) < n:
        d = s.recv(65536)
        if not d: raise EOFError("truncated HTTP response body")
        rest += d
    return status, hdrs, rest[:n], rest[n:]

def discard_resp(stream):
    """Parse one framed response, discarding its body with bounded memory."""
    lines = []; size = 0
    while True:
        line = stream.readline(65537)
        if not line: raise EOFError("connection closed before a complete response")
        size += len(line)
        if size > 65536 or not line.endswith(b"\r\n"):
            raise ValueError("invalid or oversized response headers")
        if line == b"\r\n": break
        lines.append(line[:-2])
    status, hdrs, remaining = response_head(b"\r\n".join(lines))
    while remaining:
        data = stream.read(min(remaining, 65536))
        if not data: raise EOFError("truncated HTTP response body")
        remaining -= len(data)
    return status, hdrs

def check(name, cond, extra: object = ""):
    global fails
    print(("PASS " if cond else "FAIL ") + name + (" " + str(extra) if not cond else ""))
    if not cond: fails += 1

GET = b"GET /api/tags HTTP/1.1\r\nHost: x\r\n\r\n"

# 1. basic
s = conn(); s.sendall(GET); st, h, b, rest = read_resp(s)
check("basic GET", st == 200 and h["content-type"] == "application/json" and json.loads(b)["tags"])

# 2. pipelining: three requests in one write, responses in order
s = conn(); s.sendall(GET * 3)
ok = True; rest = b""
for _ in range(3):
    st, h, b, rest = read_resp(s, rest); ok &= st == 200
check("pipelined x3", ok)

# 3. request split byte-by-byte
s = conn()
for i in range(len(GET)):
    s.sendall(GET[i:i+1]); time.sleep(0.001)
st, h, b, rest = read_resp(s)
check("byte-at-a-time request", st == 200)

# 4. POST with body split across packets
body = json.dumps({"user": {"email": "nobody@example.com", "password": "x"}}).encode()
req = b"POST /api/users/login HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n" % len(body)
s = conn(); s.sendall(req); time.sleep(0.05); s.sendall(body[:10]); time.sleep(0.05); s.sendall(body[10:])
st, h, b, rest = read_resp(s)
check("POST body split across packets (login unknown email -> 401)", st == 401, st)

# 5. chunked request body
chunks = b"%x\r\n%s\r\n%x\r\n%s\r\n0\r\n\r\n" % (10, body[:10], len(body) - 10, body[10:])
req = b"POST /api/users/login HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
s = conn(); s.sendall(req + chunks)
st, h, b, rest = read_resp(s)
check("chunked POST", st == 401, st)

# 6. Connection: close
s = conn(); s.sendall(b"GET /api/tags HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
st, h, b, rest = read_resp(s)
closed = False
try: closed = s.recv(10) == b""
except Exception: pass
check("Connection: close honoured", st == 200 and h.get("connection") == "close" and closed)

# 7. HTTP/1.0 closes by default
s = conn(); s.sendall(b"GET /api/tags HTTP/1.0\r\n\r\n")
st, h, b, rest = read_resp(s)
check("HTTP/1.0 closes", st == 200 and s.recv(10) == b"")

# 8. garbage request line
s = conn(); s.sendall(b"BLAH\r\n\r\n")
st, h, b, rest = read_resp(s)
check("garbage request -> 400", st == 400, st)

# 9. unsupported version
s = conn(); s.sendall(b"GET / HTTP/2.0\r\n\r\n")
st, h, b, rest = read_resp(s)
check("HTTP/2.0 -> 505", st == 505, st)

# 10. oversized header
s = conn(); s.sendall(b"GET /api/tags HTTP/1.1\r\nX: " + b"a" * 40000 + b"\r\n\r\n")
st, h, b, rest = read_resp(s)
check("oversized header -> 431", st == 431, st)

# 11. body larger than the cap
s = conn(); s.sendall(b"POST /api/users HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n")
st, h, b, rest = read_resp(s)
check("huge Content-Length -> 413", st == 413, st)

# 12. unknown route / method
s = conn(); s.sendall(b"GET /nope HTTP/1.1\r\n\r\n"); st, *_ = read_resp(s); check("unknown route 404", st == 404, st)
s = conn(); s.sendall(b"DELETE /api/tags HTTP/1.1\r\n\r\n"); st, *_ = read_resp(s); check("wrong method 405", st == 405, st)

# 13. several keep-alive requests on one connection, varied
s = conn(); rest = b""; ok = True
for path, expected in [("/api/tags", 200), ("/api/articles?limit=2", 200), ("/api/articles/nope-1", 404), ("/api/profiles/nobody", 404)]:
    s.sendall(("GET %s HTTP/1.1\r\nHost: x\r\n\r\n" % path).encode()); st, h, b, rest = read_resp(s, rest)
    check("keep-alive %s -> %d" % (path, expected), st == expected, st)
    ok &= st == expected
check("keep-alive mix", ok)

# 14. percent-encoded path segment & query
s = conn(); s.sendall(b"GET /api/profiles/no%20such%20user HTTP/1.1\r\n\r\n"); st, *_ = read_resp(s); check("encoded username -> 404", st == 404, st)
s = conn(); s.sendall(b"GET /api/articles?tag=%zz HTTP/1.1\r\n\r\n"); st, *_ = read_resp(s); check("bad % in query is not a crash", st in (200, 422), st)

# 15. client sends request then closes immediately
for _ in range(50):
    s = conn(); s.sendall(GET); s.close()
s = conn(); s.sendall(GET); st, *_ = read_resp(s); check("server alive after abrupt closes", st == 200)

# 16. many half-sent requests then drop
socks = []
for _ in range(500):
    s = conn(); s.sendall(b"GET /api/tags HTTP/1.1\r\nHost: x\r\nX-Partial: "); socks.append(s)
for s in socks: s.close()
s = conn(); s.sendall(GET); st, *_ = read_resp(s); check("server alive after 500 half-sent requests dropped", st == 200)

# 17. duplicate / conflicting Content-Length
s = conn(); s.sendall(b"POST /api/users HTTP/1.1\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\nabcd"); st, *_ = read_resp(s); check("conflicting Content-Length -> 400", st == 400, st)

# 18. both TE and CL -> 400 (request smuggling guard)
s = conn(); s.sendall(b"POST /api/users HTTP/1.1\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"); st, *_ = read_resp(s); check("CL+TE -> 400", st == 400, st)

# 19. half-close: client sends a request and shuts down its write side; the response must still arrive
s = conn(); s.sendall(GET); s.shutdown(socket.SHUT_WR)
st, h, b, rest = read_resp(s)
check("half-close still gets its response", st == 200 and b and json.loads(b)["tags"])

# 20. pipelined request followed by FIN
s = conn(); s.sendall(GET * 2); s.shutdown(socket.SHUT_WR)
st1, h, b, rest = read_resp(s); st2, h, b, rest = read_resp(s, rest)
check("two pipelined requests + FIN both answered", st1 == 200 and st2 == 200, (st1, st2))

# chunked framing that would make the parser rescan a lot is refused, and the server stays responsive
t0 = time.time()
s = conn(); s.sendall(b"POST /api/users HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nx\r\n0\r\n")
try:
    for _ in range(3000): s.sendall(b"a:b\r\n" * 40)
except OSError:
    pass
st, *_ = read_resp(s); check("endless trailer lines are refused", st == 400, st); s.close()
s = conn(); s.sendall(b"POST /api/users HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5;" + b"e=" * 200 + b"\r\nhello\r\n0\r\n\r\n")
st, *_ = read_resp(s); check("a size line with a huge extension is refused", st == 400, st); s.close()
s = conn(); s.sendall(b"POST /api/users HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" + b"1\r\nx\r\n" * 1100)
st, *_ = read_resp(s); check("more than 1024 chunks is refused", st in (400, 413), st); s.close()
s = conn(); s.sendall(GET); st, *_ = read_resp(s); check("server responsive after chunk abuse (%.1fs)" % (time.time() - t0), st == 200 and time.time() - t0 < 10, st); s.close()

# Reuse server-side fd slots while asynchronous shutdowns and new accepts overlap.
def close_churn_client(_):
    for iteration in range(32):
        payload, expected = ((b"BLAH\r\n\r\n", 400) if iteration % 2 else
                             (b"GET /api/tags HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", 200))
        with conn() as client:
            client.sendall(payload)
            status, *_ = read_resp(client)
            if status != expected:
                raise RuntimeError("close-response status %s, expected %d" % (status, expected))
        with conn() as client:
            client.sendall(GET)
            status, _, body, _ = read_resp(client)
            if status != 200 or not isinstance(json.loads(body)["tags"], list):
                raise RuntimeError("fresh connection after close returned %s" % status)
    return 32

completed = 0; churn_error = None
try:
    with ThreadPoolExecutor(max_workers=32) as pool:
        completed = sum(pool.map(close_churn_client, range(32)))
except (OSError, EOFError, ValueError, RuntimeError) as exc:
    churn_error = "%s: %s" % (type(exc).__name__, exc)
check("32 concurrent close/reopen clients: 2048 responses without retries or EOFs",
      completed == 1024 and churn_error is None, (completed, churn_error))

# a large pipelined burst on one connection (consuming each request used to move the whole remaining buffer)
N = 60000
burst = GET * N
t0 = time.monotonic()
s = conn(); s.settimeout(30)
sender_errors = []
def send_burst():
    try:
        s.sendall(burst)
    except Exception as exc:
        sender_errors.append("%s: %s" % (type(exc).__name__, exc))
sender = threading.Thread(target=send_burst, daemon=True); sender.start()
got = 0; pipeline_error = None
try:
    with s.makefile("rb", buffering=65536) as stream:
        while got < N:
            remaining = 30 - (time.monotonic() - t0)
            if remaining <= 0: raise TimeoutError("pipeline exceeded 30 seconds")
            s.settimeout(remaining)
            st, h = discard_resp(stream)
            if st != 200 or h.get("content-type") != "application/json":
                raise ValueError("pipeline response %d has status %d or invalid content type" % (got + 1, st))
            got += 1
except (OSError, ValueError, EOFError) as exc:
    pipeline_error = "%s: %s" % (type(exc).__name__, exc)
finally:
    try: s.shutdown(socket.SHUT_RDWR)
    except OSError: pass
    s.close()
    sender.join(timeout=5)
el = time.monotonic() - t0
check("%d pipelined requests on one connection all answered in %.1fs" % (N, el),
      got == N and pipeline_error is None and not sender_errors and not sender.is_alive() and el < 30,
      (got, el, pipeline_error, sender_errors, "sender alive: %s" % sender.is_alive()))

print("\n%d failures" % fails)
sys.exit(1 if fails else 0)

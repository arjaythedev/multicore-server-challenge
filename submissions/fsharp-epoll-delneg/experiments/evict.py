#!/usr/bin/env python3
# Eviction stress: many keep-alive clients over the app's fd budget, a slice active each tick. Counts what a real
# client would call an error: a fresh connection closed before its reply, a wrong reply.
import socket, sys, time, random, selectors
port=int(sys.argv[1]); n=int(sys.argv[2]); secs=int(sys.argv[3]); rate=int(sys.argv[4])
req=b"GET /api/tags HTTP/1.1\r\nHost: x\r\n\r\n"
sel=selectors.DefaultSelector()
class C: __slots__=("s","fresh","wait","buf")
cs=[C() for _ in range(n)]
for c in cs: c.s=None;c.fresh=True;c.wait=False;c.buf=b""
stats=dict(ok=0,reused_gone=0,fresh_gone=0,bad=0,dial=0,conn_err=0)
def drop(c):
    try: sel.unregister(c.s)
    except Exception: pass
    c.s.close(); c.s=None; c.wait=False; c.buf=b""
def send(c):
    if c.s is None:
        s=socket.socket(); s.setsockopt(socket.IPPROTO_TCP,socket.TCP_NODELAY,1)
        try: s.connect(("127.0.0.1",port))
        except OSError: stats["conn_err"]+=1; s.close(); return
        s.setblocking(False); c.s=s; c.fresh=True; stats["dial"]+=1
        sel.register(s,selectors.EVENT_READ,c)
    try: c.s.send(req); c.wait=True
    except OSError:
        if c.fresh: stats["fresh_gone"]+=1
        else: stats["reused_gone"]+=1
        drop(c)
t0=time.time(); last=t0; nextp=t0
while time.time()-t0<secs:
    for _ in range(rate//100):
        c=random.choice(cs)
        if not c.wait: send(c)
    for k,_ in sel.select(0.01):
        c=k.data
        try: d=c.s.recv(65536)
        except BlockingIOError: continue
        except OSError: d=b""
        if not d:
            if c.wait:
                if c.fresh: stats["fresh_gone"]+=1
                else: stats["reused_gone"]+=1
            drop(c); continue
        if not c.wait: stats["bad"]+=1; continue
        c.buf+=d
        i=c.buf.find(b"\r\n\r\n")
        if i>=0:
            hdr=c.buf[:i].lower(); j=hdr.find(b"content-length:")
            l=int(hdr[j+15:].split(b"\r\n")[0]) if j>=0 else 0
            if len(c.buf)>=i+4+l:
                if not c.buf.startswith(b"HTTP/1.1 200"): stats["bad"]+=1
                else: stats["ok"]+=1
                c.wait=False; c.fresh=False; c.buf=b""
    if time.time()>nextp:
        nextp+=5; print(f"t={time.time()-t0:.0f} {stats}",flush=True)
print("final",stats)

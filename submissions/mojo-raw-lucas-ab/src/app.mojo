# The event loop. A request runs as a short chain of steps on its connection (api.mojo): Postgres batches,
# completed when their ReadyForQuery arrives, and bcrypt jobs, completed by a bcrypt worker's reply. Strings a
# later step needs are copied into Conn.ctx, because the request bytes don't survive past the first step.
#
# A client connection has at most one request in flight. Requests pipelined behind it stay in the connection's
# input buffer until the response is written, so responses go out in request order.

from std.memory.alloc import unsafe_alloc
from std.os import getenv
from linux import *
from buf import BytePtr, ByteBuf
from http import (
    Request,
    parse_request,
    error_response,
    PARSE_INCOMPLETE,
    PARSE_BAD,
    PARSE_TOO_LARGE,
    MAX_HEADER_BYTES,
    MAX_BODY_BYTES,
)
from server import Worker, make_listener, MAX_EVENTS, SCRATCH_BYTES, PG_TAG, BC_TAG, FD_BITS
from pg import (
    PgConn,
    PgConfig,
    Pending,
    Results,
    pg_connect,
    be32,
    MSG_READY,
    MSG_ERROR,
    MSG_COMMAND_COMPLETE,
    MSG_EMPTY_QUERY,
    K_GROUP,
)
from bcrypt_worker import get_u64, REPLY_BYTES
from api import route, on_result, on_bcrypt, S_NONE
import sql

comptime PG_CONNECT_ATTEMPTS = 120
comptime PG_RETRY_MS = 250


def sleep_ms(ms: Int):
    var ts = unsafe_alloc[Int64](2)
    ts[unsafe_offset=0] = Int64(ms // 1000)
    ts[unsafe_offset=1] = Int64((ms % 1000) * 1_000_000)
    _ = syscall3(SYS_NANOSLEEP, Int(ts), 0, 0)
    ts.unsafe_free()


def run_worker(id: Int, addr: UInt32, port: Int, cfg: PgConfig, read_conns: Int, write_conns: Int,
               bcrypt_fds: List[Int]) -> Int:
    var lfd = make_listener(addr, port)
    if lfd < 0:
        log("worker " + String(id) + ": cannot listen on port " + String(port) + ": errno " + String(-lfd))
        return 1
    var epfd = sys_epoll_create1(EPOLL_CLOEXEC)
    if epfd < 0:
        log("worker " + String(id) + ": epoll_create1 failed: " + String(epfd))
        return 1
    var w = Worker(id, lfd, epfd, getenv("JWT_SECRET", ""))
    try:
        w.log_groups_every = Int(getenv("PG_GROUP_STATS", "0"))
    except:
        w.log_groups_every = 0

    var stmts = sql.statements()
    w.n_read = read_conns
    for i in range(read_conns + write_conns):
        var conn = PgConn()
        var err = String("")
        for attempt in range(PG_CONNECT_ATTEMPTS):
            err = pg_connect(cfg, stmts, conn)
            if err == "":
                break
            # Only an unreachable or still-starting server is worth waiting for; a rejected login or a bad
            # statement won't fix itself.
            if not (err.startswith("connect to") or err.startswith("connection closed")):
                break
            if attempt == 0:
                log("worker " + String(id) + ": postgres not ready (" + err + "), retrying")
            sleep_ms(PG_RETRY_MS)
        if err != "":
            log("worker " + String(id) + ": postgres connection " + String(i) + " failed: " + err)
            return 1
        w.pgs.append(conn^)
        if w.epoll_set(EPOLL_CTL_ADD, w.pgs[i].fd, EPOLLIN, PG_TAG | i) < 0:
            log("worker " + String(id) + ": epoll_ctl on a postgres socket failed")
            return 1
    for fd in bcrypt_fds:
        if not w.bc_add(fd):
            log("worker " + String(id) + ": epoll_ctl on a bcrypt socket failed")
            return 1

    if w.epoll_set(EPOLL_CTL_ADD, lfd, EPOLLIN, lfd) < 0:
        log("worker " + String(id) + ": epoll_ctl on the listener failed")
        return 1
    return event_loop(w)


def event_loop(mut w: Worker) -> Int:
    while True:
        var n = sys_epoll_wait(w.epfd, Int(w.events), MAX_EVENTS, -1)
        if n == -EINTR:
            continue
        if n < 0:
            log("worker " + String(w.id) + ": epoll_wait failed: " + String(n))
            return 1
        for i in range(n):
            var ev = w.events.unsafe_offset(i * EPOLL_EVENT_SIZE)
            var flags = ev.unsafe_bitcast[UInt32]().unsafe_load[alignment=1]()
            var data = Int(ev.unsafe_offset(EPOLL_DATA_OFFSET).unsafe_bitcast[UInt64]().unsafe_load[alignment=1]())
            if data & PG_TAG:
                var pi = data & 0xFFFF
                if flags & EPOLLOUT and not w.pg_flush(pi):
                    return lost(w, "postgres connection " + String(pi))
                if flags & (EPOLLIN | EPOLLERR | EPOLLHUP) and not pg_on_readable(w, pi):
                    return lost(w, "postgres connection " + String(pi))
                continue
            if data & BC_TAG:
                if not bc_on_readable(w, data & 0xFFFF):
                    return lost(w, "bcrypt worker " + String(data & 0xFFFF))
                continue
            var fd = data
            if fd == w.lfd:
                w.accept_all()
                continue
            if not w.conn(fd).open:
                continue
            if flags & EPOLLOUT:
                w.flush_pending(fd)
            if flags & EPOLLIN:
                on_readable(w, fd)
            elif flags & (EPOLLERR | EPOLLHUP):
                w.close_conn(fd)
        # Everything the handlers queued for Postgres in this round goes out now, one send per connection.
        if not w.pg_flush_all():
            return lost(w, "a postgres connection")


def lost(mut w: Worker, what: String) -> Int:
    # In-flight results can't be replayed safely, so a lost backend ends the server (the box doesn't restart it
    # either way).
    log("worker " + String(w.id) + ": lost " + what)
    return 1


# --- client side -------------------------------------------------------------------------------------------


def on_readable(mut w: Worker, fd: Int):
    ref c = w.conn(fd)
    if c.busy or c.inb.len > 0:
        c.inb.reserve(16 * 1024)
        var r = sys_recv(fd, Int(c.inb.tail()), c.inb.cap - c.inb.len)
        if r == -EAGAIN or r == -EINTR:
            return
        if r <= 0:
            w.close_conn(fd)
            return
        c.inb.len += r
        if c.inb.len > MAX_HEADER_BYTES + MAX_BODY_BYTES + SCRATCH_BYTES:
            w.close_conn(fd)  # flooding us while a request is in flight
            return
        if c.busy:
            return
        process(w, fd, c.inb.ptr, c.inb.len, True)
    else:
        var r = sys_recv(fd, Int(w.scratch), SCRATCH_BYTES)
        if r == -EAGAIN or r == -EINTR:
            return
        if r <= 0:
            w.close_conn(fd)
            return
        process(w, fd, w.scratch, r, False)


def process(mut w: Worker, fd: Int, data: BytePtr, total: Int, from_inb: Bool):
    """Handles the complete requests in `data` and keeps the rest in the connection's input buffer."""
    w.out.len = 0
    var used = handle_requests(w, fd, data, total)
    ref c = w.conn(fd)
    var left = total - used
    if c.close_after_write:
        left = 0
    if left == 0:
        c.inb.free()
    elif not from_inb:
        c.inb.len = 0
        c.inb.put_bytes(data.unsafe_offset(used), left)
    else:
        c.inb.consume(used)
    if w.out.len > 0:
        w.send_out(fd)


def handle_requests(mut w: Worker, fd: Int, data: BytePtr, total: Int) -> Int:
    """Answers complete requests until one has to wait for Postgres or bcrypt. Returns the bytes consumed."""
    var used = 0
    var req = Request()
    while used < total:
        var n = parse_request(data.unsafe_offset(used), total - used, req)
        if n == PARSE_INCOMPLETE:
            break
        if n < 0:
            var status = 431 if n == PARSE_TOO_LARGE else (400 if n == PARSE_BAD else 501)
            error_response(w.out, status, False, "bad request")
            w.conn(fd).close_after_write = True
            return total
        w.conn(fd).keep_alive = req.keep_alive
        var waiting = route(w, fd, data.unsafe_offset(used), req)
        used += n
        if waiting:
            w.conn(fd).busy = True
            return used
        if not req.keep_alive:
            w.conn(fd).close_after_write = True
            return total
    return used


def finish(mut w: Worker, fd: Int):
    """The in-flight request's response is in w.out: send it and pick up any pipelined requests."""
    ref c = w.conn(fd)
    c.busy = False
    c.stage = S_NONE
    c.ctx.free()
    if not c.keep_alive:
        c.close_after_write = True
        c.inb.free()
    var gen = c.gen
    w.send_out(fd)
    ref c2 = w.conn(fd)
    if c2.open and c2.gen == gen and not c2.busy and c2.inb.len > 0:
        process(w, fd, c2.inb.ptr, c2.inb.len, True)


# --- Postgres side -----------------------------------------------------------------------------------------


def pg_on_readable(mut w: Worker, i: Int) -> Bool:
    """Reads from Postgres and completes every request whose ReadyForQuery has arrived."""
    w.pgs[i].inb.reserve(64 * 1024)
    var r = sys_recv(w.pgs[i].fd, Int(w.pgs[i].inb.tail()), w.pgs[i].inb.cap - w.pgs[i].inb.len)
    if r == -EAGAIN or r == -EINTR:
        return True
    if r <= 0:
        return False
    w.pgs[i].inb.len += r
    var base = w.pgs[i].inb.ptr
    var avail = w.pgs[i].inb.len
    var pos = 0
    var start = 0
    while pos + 5 <= avail:
        var end = pos + 1 + be32(base.unsafe_offset(pos + 1))
        if end > avail:
            break
        var kind = base[unsafe_offset=pos]
        pos = end
        if kind == MSG_READY:
            if w.pgs[i].in_flight() == 0:
                log("worker " + String(w.id) + ": ReadyForQuery with nothing in flight")
                return False
            var pending = w.pgs[i].pop()
            if pending.kind == K_GROUP:
                on_group(w, i, base.unsafe_offset(start), pos - start)
            else:
                complete(w, pending, Results(base.unsafe_offset(start), pos - start))
            start = pos
    w.pgs[i].inb.consume(start)
    return True


def on_group(mut w: Worker, i: Int, p: BytePtr, n: Int):
    """A commit group's batch is done. If any statement failed, the whole implicit transaction rolled back: its
    members are resent one by one. Otherwise each member gets its own slice of the replies (its statements' results,
    up to its last CommandComplete) as if it had been its own batch."""
    var failed = False
    var pos = 0
    while pos + 5 <= n:
        if p[unsafe_offset=pos] == MSG_ERROR:
            failed = True
            w.group_retries += len(w.pgs[i].sent_members)
            break
        pos += 1 + be32(p.unsafe_offset(pos + 1))
    if w.log_groups_every > 0 and w.groups % w.log_groups_every == 0:
        log("worker " + String(w.id) + ": " + String(w.groups) + " commit groups, " + String(w.group_members)
            + " writes, " + String(w.group_retries) + " retried alone")
    if failed:
        w.pgs[i].retry_sent()
        return
    pos = 0
    var start = 0
    for k in range(len(w.pgs[i].sent_members)):
        var m = w.pgs[i].sent_members[k]
        var done = 0
        while pos + 5 <= n and done < m.stmts:
            var kind = p[unsafe_offset=pos]
            pos += 1 + be32(p.unsafe_offset(pos + 1))
            if kind == MSG_COMMAND_COMPLETE or kind == MSG_EMPTY_QUERY:
                done += 1
        complete(w, m.p, Results(p.unsafe_offset(start), pos - start))
        start = pos


def complete(mut w: Worker, p: Pending, res: Results):
    ref c = w.conn(p.fd)
    if not c.open or c.gen != p.gen or not c.busy:
        return  # the client went away meanwhile
    w.out.len = 0
    var r = res
    if on_result(w, p.fd, p.kind, r):
        finish(w, p.fd)


# --- bcrypt side -------------------------------------------------------------------------------------------


def bc_on_readable(mut w: Worker, b: Int) -> Bool:
    var buf = w.jobbuf
    while True:
        var r = sys_recv(w.bcs[b], Int(buf), REPLY_BYTES)
        if r == -EAGAIN or r == -EINTR:
            return True
        if r <= 0:
            return False
        w.bc_load[b] -= 1
        if r < 9:
            continue
        var id = get_u64(buf)
        var fd = id & ((1 << FD_BITS) - 1)
        var gen = id >> FD_BITS
        ref c = w.conn(fd)
        if not c.open or c.gen != gen or not c.busy:
            continue  # the client went away meanwhile
        var ok = buf[unsafe_offset=8] == 1
        w.out.len = 0
        if on_bcrypt(w, fd, ok, buf.unsafe_offset(9), r - 9):
            finish(w, fd)



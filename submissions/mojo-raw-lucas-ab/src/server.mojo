# One worker's transport: its own SO_REUSEPORT listener, its own epoll instance and its own Postgres connections,
# nothing shared with the other workers. The event loop and the request handlers are in app.mojo.
#
# Level-triggered epoll. Client reads land in one scratch buffer per worker, so an idle keep-alive connection owns
# no buffer at all, only its slot in the connection table.

from std.memory.alloc import unsafe_alloc
from std.sys import size_of
from linux import *
from buf import BytePtr, ByteBuf, copy_bytes
from pg import PgConn, set_nonblocking
from bcrypt_worker import OP_HASH, OP_VERIFY, put_u64, JOB_MAX_BYTES
from bcrypt import MAX_PASSWORD_BYTES
from jwt import Jwt

comptime MAX_EVENTS = 512
comptime SCRATCH_BYTES = 64 * 1024
comptime LISTEN_BACKLOG = 65535
# epoll data for a Postgres socket is PG_TAG | index, for a bcrypt worker's socket BC_TAG | index; for a client
# it is the fd.
comptime PG_TAG = 1 << 40
comptime BC_TAG = 1 << 41
# A bcrypt job's id is (connection generation << FD_BITS) | fd: the reply finds its connection without a table.
comptime FD_BITS = 20


struct Conn(ImplicitlyCopyable):
    var inb: ByteBuf  # bytes received but not yet handled; empty (no allocation) most of the time
    var outb: ByteBuf  # response bytes the socket didn't take yet
    var gen: Int  # changes on every accept, so a late Postgres result can't reach a reused fd
    var open: Bool
    var busy: Bool  # a request is waiting on Postgres; later pipelined requests wait in inb
    var close_after_write: Bool
    var want_out: Bool  # EPOLLOUT is registered
    # State of the request in flight (there is at most one per connection):
    var stage: Int  # what it waits for next (app.mojo's S_* values)
    var keep_alive: Bool
    var uid: Int  # the authenticated user, or 0
    var aux: Int  # an id a later step needs (article, comment) or a flag (follow vs unfollow)
    var ctx: ByteBuf  # strings it needs later: the presented token, request fields, a pre-rendered user...

    def __init__(out self):
        self.inb = ByteBuf()
        self.outb = ByteBuf()
        self.stage = 0
        self.keep_alive = True
        self.uid = 0
        self.aux = 0
        self.ctx = ByteBuf()
        self.gen = 0
        self.open = False
        self.busy = False
        self.close_after_write = False
        self.want_out = False


struct ConnTable:
    """Connections indexed by fd. Grows by doubling; entries are plain data, so growing is a memcpy."""

    var ptr: Pointer[Conn, MutUntrackedOrigin]
    var cap: Int

    def __init__(out self):
        self.cap = 1024
        self.ptr = unsafe_alloc[Conn](self.cap)
        for i in range(self.cap):
            self.ptr.unsafe_offset(i).unsafe_write(Conn())

    def ensure(mut self, fd: Int):
        if fd < self.cap:
            return
        var cap = self.cap
        while cap <= fd:
            cap *= 2
        var p = unsafe_alloc[Conn](cap)
        copy_bytes(p.unsafe_bitcast[UInt8](), self.ptr.unsafe_bitcast[UInt8](), self.cap * size_of[Conn]())
        for i in range(self.cap, cap):
            p.unsafe_offset(i).unsafe_write(Conn())
        self.ptr.unsafe_free()
        self.ptr = p
        self.cap = cap


struct Worker:
    var id: Int
    var epfd: Int
    var lfd: Int
    var events: BytePtr
    var scratch: BytePtr
    # Heap memory for structs passed to syscalls by address. Never use a stack Array for that: Mojo ends a value's
    # lifetime at its last use, and an address turned into an Int isn't a use, so the slot can be reused before
    # the kernel reads it.
    var sysbuf: BytePtr
    var out: ByteBuf  # the response(s) being written, sent with one send
    var conns: ConnTable
    var pgs: List[PgConn]
    var n_read: Int  # pgs[:n_read] are for reads, the rest for writes (see pg_read)
    var groups: Int  # commit groups sent, their members, and members retried alone after a failed group
    var group_members: Int
    var group_retries: Int
    var log_groups_every: Int  # PG_GROUP_STATS=N: log the counters every N groups (0: never)
    var next_gen: Int
    var rr: Int  # round-robin start for picking a Postgres connection
    var bcs: List[Int]  # sockets to the bcrypt workers
    var bc_load: List[Int]  # jobs in flight on each
    var jobbuf: BytePtr
    var jwt: Jwt
    var tmp: ByteBuf  # scratch for decoded request fields and path segments
    var qbuf: ByteBuf  # decoded query-string values
    var arr: ByteBuf  # scratch for unescaping Postgres array elements

    def __init__(out self, id: Int, lfd: Int, epfd: Int, jwt_secret: String):
        self.id = id
        self.lfd = lfd
        self.epfd = epfd
        self.events = unsafe_alloc[UInt8](MAX_EVENTS * EPOLL_EVENT_SIZE)
        self.scratch = unsafe_alloc[UInt8](SCRATCH_BYTES)
        self.sysbuf = unsafe_alloc[UInt8](64)
        self.sysbuf.unsafe_offset(32).unsafe_bitcast[Int32]().unsafe_store(Int32(1))  # the int `1` for setsockopt
        self.out = ByteBuf(64 * 1024)
        self.conns = ConnTable()
        self.pgs = List[PgConn]()
        self.n_read = 0
        self.groups = 0
        self.group_members = 0
        self.group_retries = 0
        self.log_groups_every = 0
        self.next_gen = 1
        self.rr = 0
        self.bcs = List[Int]()
        self.bc_load = List[Int]()
        self.jobbuf = unsafe_alloc[UInt8](JOB_MAX_BYTES)
        self.jwt = Jwt(jwt_secret)
        self.tmp = ByteBuf(1024)
        self.qbuf = ByteBuf(256)
        self.arr = ByteBuf(256)

    @inline(.always)
    def conn(self, fd: Int) -> ref[MutUntrackedOrigin] Conn:
        return self.conns.ptr[unsafe_offset=fd]

    def epoll_set(self, op: Int, fd: Int, events: UInt32, data: Int) -> Int:
        var p = self.sysbuf
        p.unsafe_bitcast[UInt32]().unsafe_store[alignment=1](events)
        p.unsafe_offset(EPOLL_DATA_OFFSET).unsafe_bitcast[UInt64]().unsafe_store[alignment=1](UInt64(data))
        return sys_epoll_ctl(self.epfd, op, fd, Int(p))

    def accept_all(mut self):
        var one = Int(self.sysbuf.unsafe_offset(32))
        while True:
            var fd = sys_accept4(self.lfd, SOCK_NONBLOCK | SOCK_CLOEXEC)
            if fd < 0:
                # EAGAIN: no more pending. EMFILE/ENFILE: leave them in the backlog until fds free up.
                return
            _ = sys_setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, one, 4)
            self.conns.ensure(fd)
            var c = Conn()
            c.open = True
            c.gen = self.next_gen
            self.next_gen += 1
            self.conn(fd) = c
            if self.epoll_set(EPOLL_CTL_ADD, fd, EPOLLIN | EPOLLRDHUP, fd) < 0:
                self.close_conn(fd)

    def close_conn(mut self, fd: Int):
        ref c = self.conn(fd)
        if not c.open:
            return
        c.inb.free()
        c.outb.free()
        c.ctx.free()
        c.open = False
        c.busy = False
        c.want_out = False
        c.close_after_write = False
        _ = sys_close(fd)  # closing also removes it from the epoll set

    def send_out(mut self, fd: Int):
        """Sends self.out to the client, queueing what the socket doesn't take."""
        ref c = self.conn(fd)
        if c.outb.len > 0:
            # Earlier output is still queued: keep the order.
            c.outb.put_bytes(self.out.ptr, self.out.len)
            return
        var sent = 0
        while sent < self.out.len:
            var r = sys_send(fd, Int(self.out.ptr.unsafe_offset(sent)), self.out.len - sent)
            if r == -EINTR:
                continue
            if r == -EAGAIN:
                break
            if r < 0:
                self.close_conn(fd)
                return
            sent += r
        if sent < self.out.len:
            c.outb.put_bytes(self.out.ptr.unsafe_offset(sent), self.out.len - sent)
            if not c.want_out:
                c.want_out = True
                _ = self.epoll_set(EPOLL_CTL_MOD, fd, EPOLLIN | EPOLLOUT | EPOLLRDHUP, fd)
            return
        if c.close_after_write:
            self.close_conn(fd)

    def flush_pending(mut self, fd: Int):
        ref c = self.conn(fd)
        var sent = 0
        while sent < c.outb.len:
            var r = sys_send(fd, Int(c.outb.ptr.unsafe_offset(sent)), c.outb.len - sent)
            if r == -EINTR:
                continue
            if r == -EAGAIN:
                break
            if r < 0:
                self.close_conn(fd)
                return
            sent += r
        c.outb.consume(sent)
        if c.outb.len > 0:
            return
        c.outb.free()
        if c.close_after_write:
            self.close_conn(fd)
            return
        c.want_out = False
        _ = self.epoll_set(EPOLL_CTL_MOD, fd, EPOLLIN | EPOLLRDHUP, fd)

    # --- bcrypt workers ---

    def bc_add(mut self, fd: Int) -> Bool:
        _ = set_nonblocking(fd)
        var i = len(self.bcs)
        self.bcs.append(fd)
        self.bc_load.append(0)
        return self.epoll_set(EPOLL_CTL_ADD, fd, EPOLLIN, BC_TAG | i) >= 0

    def bc_submit(mut self, fd: Int, op: UInt8, cost: Int, password: BytePtr, password_len: Int, hash: BytePtr,
                  hash_len: Int) -> Bool:
        """Sends a bcrypt job for client `fd` to the least-loaded bcrypt worker. bcrypt only ever reads the first
        72 password bytes, so longer passwords are cut there (same result, bounded message)."""
        var best = 0
        for i in range(1, len(self.bcs)):
            if self.bc_load[i] < self.bc_load[best]:
                best = i
        var n = min(password_len, MAX_PASSWORD_BYTES)
        var j = self.jobbuf
        put_u64(j, (self.conn(fd).gen << FD_BITS) | fd)
        j[unsafe_offset=8] = op
        j[unsafe_offset=9] = UInt8(cost)
        j[unsafe_offset=10] = UInt8(n & 0xFF)
        j[unsafe_offset=11] = UInt8(n >> 8)
        copy_bytes(j.unsafe_offset(12), password, n)
        copy_bytes(j.unsafe_offset(12 + n), hash, hash_len)
        var len = 12 + n + hash_len
        var r = sys_send(self.bcs[best], Int(j), len)
        if r != len:
            return False  # the socket buffer holds hundreds of jobs; full means the bcrypt workers are stuck
        self.bc_load[best] += 1
        return True

    # --- Postgres connections ---

    # Reads and writes use separate connections (pgs[:n_read] and pgs[n_read:]). A batch on a connection waits for
    # every batch pipelined before it, so a commit that stalls (a slow WAL flush, a lock) would otherwise hold up
    # every read queued behind it on its connection.

    def pg_read(mut self) -> Int:
        """A connection for a batch that only reads."""
        return self.pg_pick(0, self.n_read)

    def pg_write(mut self) -> Int:
        """A connection for a request that writes (INSERT, UPDATE or DELETE). Its statements join the connection's
        next commit group (PgConn.begin_member); send_batch ends the member."""
        var i = self.pg_pick(self.n_read, len(self.pgs))
        self.pgs[i].begin_member()
        return i

    def pg_pick(mut self, lo: Int, hi: Int) -> Int:
        """The connection in pgs[lo:hi] with the least work queued, rotating among ties."""
        var n = hi - lo
        var best = lo + self.rr % n
        var best_load = self.pgs[best].load()
        for k in range(1, n):
            var i = lo + (self.rr + k) % n
            var load = self.pgs[i].load()
            if load < best_load:
                best = i
                best_load = load
        self.rr += 1
        return best

    def pg_flush(mut self, i: Int) -> Bool:
        """Sends queued frontend messages. False if the connection failed."""
        if self.pgs[i].out.len == 0:
            return True
        var sent = 0
        var total = self.pgs[i].out.len
        var fd = self.pgs[i].fd
        var p = self.pgs[i].out.ptr
        while sent < total:
            var r = sys_send(fd, Int(p.unsafe_offset(sent)), total - sent)
            if r == -EINTR:
                continue
            if r == -EAGAIN:
                break
            if r < 0:
                return False
            sent += r
        self.pgs[i].out.consume(sent)
        var want = self.pgs[i].out.len > 0
        if want != self.pgs[i].want_out:
            self.pgs[i].want_out = want
            var ev = EPOLLIN | EPOLLOUT if want else EPOLLIN
            _ = self.epoll_set(EPOLL_CTL_MOD, fd, ev, PG_TAG | i)
        return True

    def pg_flush_all(mut self) -> Bool:
        for i in range(len(self.pgs)):
            if self.pgs[i].group_ready():  # write connections: the requests that waited become one commit
                self.pgs[i].close_group()
                self.groups += 1
                self.group_members += len(self.pgs[i].sent_members)
            if not self.pgs[i].want_out and not self.pg_flush(i):
                return False
        return True


def make_listener(addr: UInt32, port: Int) -> Int:
    """A non-blocking IPv4 listening socket with SO_REUSEPORT, so each worker can bind its own."""
    var fd = sys_socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0)
    if fd < 0:
        return fd
    var buf = unsafe_alloc[UInt8](32)  # heap, not a stack Array: see Worker.sysbuf
    var one = buf.unsafe_offset(16)
    one.unsafe_bitcast[Int32]().unsafe_store(Int32(1))
    _ = sys_setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, Int(one), 4)
    _ = sys_setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, Int(one), 4)
    # struct sockaddr_in: family (host order), port (network order), address (network order), 8 bytes of zero
    var sa = buf
    for i in range(16):
        sa[unsafe_offset=i] = 0
    sa[unsafe_offset=0] = UInt8(AF_INET)
    sa[unsafe_offset=2] = UInt8((port >> 8) & 0xFF)
    sa[unsafe_offset=3] = UInt8(port & 0xFF)
    sa[unsafe_offset=4] = UInt8((addr >> 24) & 0xFF)
    sa[unsafe_offset=5] = UInt8((addr >> 16) & 0xFF)
    sa[unsafe_offset=6] = UInt8((addr >> 8) & 0xFF)
    sa[unsafe_offset=7] = UInt8(addr & 0xFF)
    var r = sys_bind(fd, Int(sa), 16)
    buf.unsafe_free()
    if r < 0:
        _ = sys_close(fd)
        return r
    r = sys_listen(fd, LISTEN_BACKLOG)
    if r < 0:
        _ = sys_close(fd)
        return r
    return fd

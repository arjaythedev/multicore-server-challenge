# bcrypt worker processes. Each HTTP worker has one SOCK_SEQPACKET socketpair to each bcrypt worker; a job is one
# message, its reply is one message. A ~60 ms hash never runs on an event loop.
#
#   job:   u64 id | u8 op | u8 cost | u16 password length | password | (verify) 60-byte hash
#   reply: u64 id | u8 ok | (hash) 60-byte hash

from std.memory.alloc import unsafe_alloc
from linux import *
from buf import BytePtr, ByteBuf
from bcrypt import Blowfish, bcrypt_hash, bcrypt_verify, HASH_LEN, MAX_PASSWORD_BYTES

comptime OP_HASH: UInt8 = 1
comptime OP_VERIFY: UInt8 = 2
comptime JOB_MAX_BYTES = 8 + 4 + MAX_PASSWORD_BYTES + HASH_LEN + 64
comptime REPLY_BYTES = 8 + 1 + HASH_LEN
comptime BCRYPT_COST = 10
comptime SOCK_SEQPACKET = 5


@inline(.always)
def put_u64(p: BytePtr, v: Int):
    p.unsafe_bitcast[UInt64]().unsafe_store[alignment=1](UInt64(v))


@inline(.always)
def get_u64(p: BytePtr) -> Int:
    return Int(p.unsafe_bitcast[UInt64]().unsafe_load[alignment=1]())


def run_bcrypt_worker(id: Int, fds: List[Int]) -> Int:
    var epfd = sys_epoll_create1(EPOLL_CLOEXEC)
    var ev = unsafe_alloc[UInt8](16 * (len(fds) + 1))
    for i in range(len(fds)):
        ev.unsafe_bitcast[UInt32]().unsafe_store[alignment=1](EPOLLIN)
        ev.unsafe_offset(EPOLL_DATA_OFFSET).unsafe_bitcast[UInt64]().unsafe_store[alignment=1](UInt64(i))
        if sys_epoll_ctl(epfd, EPOLL_CTL_ADD, fds[i], Int(ev)) < 0:
            log("bcrypt worker " + String(id) + ": epoll_ctl failed")
            return 1
    var job = unsafe_alloc[UInt8](JOB_MAX_BYTES)
    var reply = unsafe_alloc[UInt8](REPLY_BYTES)
    var salt = unsafe_alloc[UInt8](16)
    var hash = ByteBuf(64)
    var bf = Blowfish()
    var open = len(fds)
    while open > 0:
        var n = sys_epoll_wait(epfd, Int(ev), len(fds), -1)
        if n == -EINTR:
            continue
        if n < 0:
            return 1
        for e in range(n):
            var i = Int(ev.unsafe_offset(e * EPOLL_EVENT_SIZE + EPOLL_DATA_OFFSET).unsafe_bitcast[UInt64]()
                .unsafe_load[alignment=1]())
            var fd = fds[i]
            var r = sys_recv(fd, Int(job), JOB_MAX_BYTES)
            if r == -EAGAIN or r == -EINTR:
                continue
            if r <= 0:
                # That HTTP worker is gone; stop listening to it.
                _ = sys_epoll_ctl(epfd, EPOLL_CTL_DEL, fd, 0)
                open -= 1
                continue
            if r < 12:
                continue
            var op = job[unsafe_offset=8]
            var cost = Int(job[unsafe_offset=9])
            var pw_len = Int(job[unsafe_offset=10]) | (Int(job[unsafe_offset=11]) << 8)
            var pw = job.unsafe_offset(12)
            put_u64(reply, get_u64(job))
            reply[unsafe_offset=8] = 0
            var reply_len = 9
            if 12 + pw_len > r:
                pass  # malformed: reply "not ok"
            elif op == OP_HASH:
                var got = 0
                while got < 16:
                    var g = sys_getrandom(Int(salt.unsafe_offset(got)), 16 - got)
                    if g <= 0:
                        break
                    got += g
                if got == 16:
                    hash.len = 0
                    bcrypt_hash(bf, pw, pw_len, salt, cost, hash)
                    for k in range(HASH_LEN):
                        reply[unsafe_offset=9 + k] = hash.ptr[unsafe_offset=k]
                    reply[unsafe_offset=8] = 1
                    reply_len = REPLY_BYTES
            elif op == OP_VERIFY and r >= 12 + pw_len + HASH_LEN:
                if bcrypt_verify(bf, pw, pw_len, job.unsafe_offset(12 + pw_len), HASH_LEN):
                    reply[unsafe_offset=8] = 1
            # A blocking send of a 69-byte message; the HTTP worker always drains its sockets.
            _ = sys_send(fd, Int(reply), reply_len)
    return 0

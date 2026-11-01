# Conduit server, all Mojo. The main process forks WORKERS event-loop processes (raw clone, no libc) and supervises
# them: if any worker dies, the rest are killed and the server exits, since the box never restarts it (rule 9).

from std.memory.alloc import unsafe_alloc
from std.os import getenv
from linux import *
from app import run_worker
from pg import parse_database_url
from bcrypt_worker import run_bcrypt_worker, SOCK_SEQPACKET


def parse_ipv4(s: String) -> Int:
    """Dotted quad to a host-order address, or -1."""
    if s == "localhost":
        return 0x7F000001
    var parts = s.split(".")
    if len(parts) != 4:
        return -1
    var addr = 0
    for i in range(4):
        var octet: Int
        try:
            octet = Int(parts[i])
        except:
            return -1
        if octet < 0 or octet > 255:
            return -1
        addr = (addr << 8) | octet
    return addr


def env_int(name: String, default: Int) -> Int:
    var v = getenv(name, "")
    if v == "":
        return default
    try:
        return Int(v)
    except:
        return default


def main():
    var host = getenv("HOST", "127.0.0.1")
    var port = env_int("PORT", 3000)
    var workers = env_int("WORKERS", 2)
    # Postgres connections per worker, for reads and for writes; keep workers * (both) <= 95 (SPEC.md)
    var read_conns = max(1, env_int("PG_READ_CONNS", 6))
    var write_conns = max(1, env_int("PG_WRITE_CONNS", 2))
    var cfg = parse_database_url(getenv("DATABASE_URL", "postgres://conduit:conduit@127.0.0.1:5432/conduit"))
    cfg.generic_plans = env_int("PG_GENERIC_PLANS", 1) != 0
    var addr = parse_ipv4(host)
    if addr < 0:
        log("HOST must be an IPv4 address, got " + host)
        _ = sys_exit_group(2)
    if workers < 1:
        workers = 1
    # 4: ~80 hashes/s at ~50 ms each, so the ~28 logins/s of 100k users keep them under half busy (2 would run at
    # 70-80%, where login latency climbs steeply). Idle ones cost nothing.
    var bcrypt_workers = max(1, env_int("BCRYPT_WORKERS", 4))

    # One SOCK_SEQPACKET socketpair per (HTTP worker, bcrypt worker): pair_fds[2 * (h * B + b)] is the HTTP
    # worker's end, the next one the bcrypt worker's.
    var pair_fds = List[Int]()
    var two = unsafe_alloc[Int32](2)
    for _ in range(workers * bcrypt_workers):
        var r = sys_socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, Int(two))
        if r < 0:
            log("socketpair failed: errno " + String(-r))
            _ = sys_exit_group(1)
        pair_fds.append(Int(two[unsafe_offset=0]))
        pair_fds.append(Int(two[unsafe_offset=1]))
    two.unsafe_free()

    var pids = List[Int]()
    for id in range(workers + bcrypt_workers):
        var pid = sys_fork()
        if pid == 0:
            # Die with the supervisor, whatever kills it.
            _ = sys_prctl(PR_SET_PDEATHSIG, SIGKILL)
            # Keep only this process's ends, so a peer that dies shows up as EOF.
            var mine = List[Int]()
            for h in range(workers):
                for b in range(bcrypt_workers):
                    var k = 2 * (h * bcrypt_workers + b)
                    if id < workers and h == id:
                        mine.append(pair_fds[k])
                        _ = sys_close(pair_fds[k + 1])
                    elif id >= workers and b == id - workers:
                        mine.append(pair_fds[k + 1])
                        _ = sys_close(pair_fds[k])
                    else:
                        _ = sys_close(pair_fds[k])
                        _ = sys_close(pair_fds[k + 1])
            if id < workers:
                _ = sys_exit_group(run_worker(id, UInt32(addr), port, cfg, read_conns, write_conns, mine))
            _ = sys_exit_group(run_bcrypt_worker(id - workers, mine))
        if pid < 0:
            log("fork failed: errno " + String(-pid))
            for p in pids:
                _ = sys_kill(p, SIGKILL)
            _ = sys_exit_group(1)
        pids.append(pid)
    for fd in pair_fds:
        _ = sys_close(fd)
    log("conduit (mojo): " + String(workers) + " HTTP workers on " + host + ":" + String(port) + ", "
        + String(bcrypt_workers) + " bcrypt workers")

    var status = unsafe_alloc[Int32](1)
    while True:
        var pid = sys_wait4(-1, Int(status), 0)
        if pid == -EINTR:
            continue
        if pid < 0:
            break
        log("worker pid " + String(pid) + " exited (status " + String(Int(status[])) + "), stopping")
        break
    for p in pids:
        _ = sys_kill(p, SIGKILL)
    _ = sys_exit_group(1)

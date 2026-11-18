# Checks that a raw clone(SIGCHLD) fork is safe with the Mojo runtime: children allocate, build Strings and
# Lists, read the environment, and exit with a known code that the parent collects with wait4.
#
#   mojo build -I src tests/test_fork.mojo -o /tmp/test_fork && /tmp/test_fork

from std.memory.alloc import unsafe_alloc
from std.os import getenv
from linux import sys_fork, sys_wait4, sys_exit_group, sys_getpid, log

comptime CHILDREN = 8
comptime ROUNDS = 3


def child_work(id: Int) -> Int:
    var words = List[String]()
    var total = 0
    for i in range(20_000):
        var s = String("child-") + String(id) + "-" + String(i)
        total += s.byte_length()
        if i % 1000 == 0:
            words.append(s^)
    var home = getenv("HOME", "?")
    log("child " + String(id) + " pid " + String(sys_getpid()) + " bytes " + String(total) + " kept "
        + String(len(words)) + " HOME " + home)
    return 40 + id


def main():
    # Use the allocator and Strings before forking, so any runtime state they create exists at fork time.
    var warm = List[String]()
    for i in range(1000):
        warm.append(String("warm-") + String(i))
    var status = unsafe_alloc[Int32](1)
    var failures = 0
    for round in range(ROUNDS):
        var pids = List[Int]()
        for id in range(CHILDREN):
            var pid = sys_fork()
            if pid == 0:
                _ = sys_exit_group(child_work(id))
            if pid < 0:
                log("fork failed: " + String(pid))
                failures += 1
            pids.append(pid)
        for id in range(CHILDREN):
            status[] = 0
            var r = sys_wait4(pids[id], Int(status), 0)
            var raw = Int(status[])
            var exited = (raw & 0x7F) == 0
            var code = (raw >> 8) & 0xFF
            if r != pids[id] or not exited or code != 40 + id:
                log("child " + String(id) + " bad: wait4=" + String(r) + " status=" + String(raw))
                failures += 1
        log("round " + String(round) + " done")
    status.unsafe_free()
    if failures == 0:
        log("FORK TEST PASS: " + String(ROUNDS * CHILDREN) + " children, parent still has " + String(len(warm))
            + " strings")
    else:
        log("FORK TEST FAIL: " + String(failures) + " failures")
        _ = sys_exit_group(1)

// What Swift's Glibc module leaves out and the event loops (Loop.swift, Sockets.swift) need: epoll, eventfd, and two
// GNU extensions, wrapped in C because they are only declared under _GNU_SOURCE. Empty on macOS, where the loops use
// kqueue from Darwin.
#ifndef CEVENTLOOP_H
#define CEVENTLOOP_H
#ifdef __linux__
#include <sys/epoll.h>
#include <sys/eventfd.h>

/// accept4(2) without the peer's address: the new connection's descriptor, or -1 with errno set.
int CEventLoop_accept(int listener, int flags);
/// pthread_setname_np(3) for the calling thread (at most 15 bytes are kept).
int CEventLoop_nameThread(const char *name);
/// How many CPUs this process may run on (sched_getaffinity), or -1.
int CEventLoop_cpusAllowed(void);
#endif
#endif

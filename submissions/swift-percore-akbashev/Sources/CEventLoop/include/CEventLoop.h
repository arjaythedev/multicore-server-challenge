// What Swift's Glibc module leaves out and the event loops (Loop.swift, Sockets.swift) need: epoll, eventfd, and two
// GNU extensions, wrapped in C because they are only declared under _GNU_SOURCE (none of them on macOS, where the
// loops use kqueue from Darwin); and the descriptor limit, on both.
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

/// How many descriptors this process may have open (RLIMIT_NOFILE), its soft limit raised to the hard one first (on
/// macOS to at most OPEN_MAX), as Go's runtime does at startup; -1 if it can't be read.
long CEventLoop_descriptorLimit(void);
#endif

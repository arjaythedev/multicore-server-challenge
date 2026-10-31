/// Bridges libpq's raw socket I/O with photon's readiness cache.
///
/// dpq2's async connection reads and writes the socket itself, bypassing
/// photon's read/write hooks. Photon therefore cannot clear the "ready" bit it
/// cached for the descriptor after the data has been consumed. Before every
/// wait this module drops that cached bit and re-arms the edge-triggered
/// notification, so a descriptor that is already readable is reported again.
module photon.conduit_shim;

import photon.reactor : descriptors, ReaderState, WriterState, scheds, currentFiber;

version (linux)
{
    import core.sys.linux.epoll;
}
else version (Darwin)
{
    import core.sys.darwin.sys.event;
    import photon.macos.core : KEvent;
}

/// Forgets a cached readable event and re-arms the descriptor.
void resetRead(int fd) nothrow
{
    if (fd < 0 || fd >= descriptors.length)
        return;
    auto readers = &descriptors[fd].readers;
    readers.lock();
    readers.state = ReaderState.EMPTY;
    readers.unlock();
    rearm(fd);
}

/// Forgets a cached writable event and re-arms the descriptor.
void resetWrite(int fd) nothrow
{
    if (fd < 0 || fd >= descriptors.length)
        return;
    auto writers = &descriptors[fd].writers;
    writers.lock();
    writers.state = WriterState.FULL;
    writers.unlock();
    rearm(fd);
}

private void rearm(int fd) nothrow
{
    version (linux)
    {
        epoll_event event;
        event.events = EPOLLIN | EPOLLOUT | EPOLLET;
        event.data.fd = fd;
        const scheduler = currentFiber !is null ? currentFiber.numScheduler : 0;
        epoll_ctl(scheds[scheduler].event_loop, EPOLL_CTL_MOD, fd, &event);
    }
    else version (Darwin)
    {
        KEvent[2] events;
        events[0].ident = fd;
        events[0].filter = EVFILT_READ;
        events[1].ident = fd;
        events[1].filter = EVFILT_WRITE;
        events[0].flags = events[1].flags = EV_ADD | EV_ENABLE | EV_CLEAR;
        const scheduler = currentFiber !is null ? currentFiber.numScheduler : 0;
        kevent(scheds[scheduler].event_loop, events.ptr, 2, null, 0, null);
    }
}

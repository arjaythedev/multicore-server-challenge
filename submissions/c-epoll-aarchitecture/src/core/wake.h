#ifndef CORE_WAKE_H
#define CORE_WAKE_H

/* eventfd wakes for cross-thread resume queues; crypto/ and pg/ just ask */

int  wake_new(void);            // nonblocking, cloexec; -1 on error
void wake_fire(int fd);         // counter +1; FATAL if invariant breaks
void wake_drain(int fd);        // consume all pending counts

#endif

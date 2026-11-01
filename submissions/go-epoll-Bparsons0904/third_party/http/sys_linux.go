package http

import (
	"unsafe"

	"golang.org/x/sys/unix"
)

// Raw system calls for the hot path. Every socket is non-blocking, so these
// never block and can skip the scheduler bookkeeping of unix.Read/Write
// (entersyscall/exitsyscall). Sends use MSG_NOSIGNAL so a closed peer gives
// EPIPE instead of SIGPIPE, and MSG_DONTWAIT, so they never block even if a
// descriptor were blocking. A zero Errno means success.

const sendFlags = unix.MSG_NOSIGNAL | unix.MSG_DONTWAIT

func sysRead(fd int32, b []byte) (int, unix.Errno) {
	n, _, e := unix.RawSyscall(unix.SYS_READ, uintptr(fd), uintptr(unsafe.Pointer(unsafe.SliceData(b))), uintptr(len(b)))
	return int(n), e
}

func sysSend(fd int32, b []byte) (int, unix.Errno) {
	n, _, e := unix.RawSyscall6(unix.SYS_SENDTO, uintptr(fd), uintptr(unsafe.Pointer(unsafe.SliceData(b))), uintptr(len(b)),
		sendFlags, 0, 0)
	return int(n), e
}

// sysSendmsg sends iov through msg, which must not live on the stack.
func sysSendmsg(fd int32, msg *unix.Msghdr, iov []unix.Iovec) (int, unix.Errno) {
	msg.Iov = &iov[0]
	msg.SetIovlen(len(iov))
	n, _, e := unix.RawSyscall(unix.SYS_SENDMSG, uintptr(fd), uintptr(unsafe.Pointer(msg)), sendFlags)
	return int(n), e
}

func sysAccept(fd int) (int, unix.Errno) {
	n, _, e := unix.RawSyscall6(unix.SYS_ACCEPT4, uintptr(fd), 0, 0, unix.SOCK_NONBLOCK|unix.SOCK_CLOEXEC, 0, 0)
	return int(n), e
}

var eventfdOne = [8]byte{1}

// sysWake adds one to an eventfd counter.
func sysWake(efd int) {
	unix.RawSyscall(unix.SYS_WRITE, uintptr(efd), uintptr(unsafe.Pointer(&eventfdOne[0])), 8)
}

// sendAll sends segs with one send or sendmsg, retrying EINTR. It returns the
// bytes sent, which may be fewer than the total, and false on a socket error
// other than EAGAIN.
func sendAll(fd int32, segs [][]byte, iov []unix.Iovec, msg *unix.Msghdr) (int, bool) {
	for {
		var n int
		var e unix.Errno
		if len(segs) == 1 {
			n, e = sysSend(fd, segs[0])
		} else {
			for i, b := range segs {
				iov[i].Base = &b[0]
				iov[i].SetLen(len(b))
			}
			n, e = sysSendmsg(fd, msg, iov[:len(segs)])
		}
		switch e {
		case 0:
			return n, true
		case unix.EINTR:
			continue
		case unix.EAGAIN:
			return 0, true
		}
		return 0, false
	}
}

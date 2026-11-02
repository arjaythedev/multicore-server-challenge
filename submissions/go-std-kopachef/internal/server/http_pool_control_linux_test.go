//go:build linux

package server

import (
	"net"
	"syscall"
	"testing"
)

// Experimental owned callback state: Control invokes this synchronously while
// the reactor owns the connection. The method value is allocated once.
type storedPollControl struct {
	raw      syscall.RawConn
	epoll    int
	event    syscall.EpollEvent
	result   error
	callback func(uintptr)
}

func (s *storedPollControl) control(fd uintptr) {
	s.result = syscall.EpollCtl(s.epoll, syscall.EPOLL_CTL_MOD, int(fd), &s.event)
}

func BenchmarkPooledPollControl(b *testing.B) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		b.Fatal(err)
	}
	defer listener.Close()
	accepted := make(chan net.Conn, 1)
	go func() { c, _ := listener.Accept(); accepted <- c }()
	client, err := net.Dial("tcp", listener.Addr().String())
	if err != nil {
		b.Fatal(err)
	}
	defer client.Close()
	server := <-accepted
	if server == nil {
		b.Fatal("accept failed")
	}
	defer server.Close()
	raw, err := server.(syscall.Conn).SyscallConn()
	if err != nil {
		b.Fatal(err)
	}
	epoll, err := syscall.EpollCreate1(syscall.EPOLL_CLOEXEC)
	if err != nil {
		b.Fatal(err)
	}
	defer syscall.Close(epoll)
	p := &pooledConnection{raw: raw, id: 1}
	if err := pooledPollControl(epoll, syscall.EPOLL_CTL_ADD, p); err != nil {
		b.Fatal(err)
	}
	state := &storedPollControl{raw: raw, epoll: epoll, event: syscall.EpollEvent{Fd: 1, Events: syscall.EPOLLIN | syscall.EPOLLRDHUP | syscall.EPOLLONESHOT}}
	state.callback = state.control
	b.Run("fresh", func(b *testing.B) {
		b.ReportAllocs()
		for b.Loop() {
			if err := pooledPollControl(epoll, syscall.EPOLL_CTL_MOD, p); err != nil {
				b.Fatal(err)
			}
		}
	})
	b.Run("owned", func(b *testing.B) {
		b.ReportAllocs()
		for b.Loop() {
			if err := state.raw.Control(state.callback); err != nil {
				b.Fatal(err)
			}
			if state.result != nil {
				b.Fatal(state.result)
			}
		}
	})
}

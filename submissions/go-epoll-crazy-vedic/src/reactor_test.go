package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func TestTimerWheelRescheduleAndWrap(t *testing.T) {
	pair, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer unix.Close(pair[1])
	fd := pair[0]
	r := &eventLoop{conns: make([]reactorConn, fd+1), tick: time.Millisecond * 10, ep: -1, server: &reactorServer{}}
	for i := range r.timers {
		r.timers[i] = -1
	}
	r.conns[fd] = reactorConn{open: true, timerSlot: -1, timerNext: -1, timerPrev: -1, inputID: -1, largeID: -1}
	r.server.sockets.Store(1)
	r.setDeadline(fd, 30)
	r.setDeadline(fd, 3000) // beyond one complete wheel rotation
	r.now = 2560
	r.expire()
	if !r.conns[fd].open {
		t.Fatal("expired a rescheduled connection")
	}
	r.now = 2999
	r.expire()
	if !r.conns[fd].open {
		t.Fatal("deadline rounded down")
	}
	r.now = 3000
	r.expire()
	if r.conns[fd].open || r.server.sockets.Load() != 0 {
		t.Fatal("wrapped deadline did not expire")
	}
}

func TestReactorFragmentationChunkingAndPipelining(t *testing.T) {
	cfg := reactorConfig{host: "127.0.0.1", port: 0, loops: 1, workers: 4, active: 8, queued: 8, sockets: 1024, fdSlots: 8192,
		readTimeout: time.Second, writeTimeout: time.Second, idleTimeout: time.Second, shutdownTimeout: time.Second}
	srv, err := newReactorServer(func(out *response, req *request) { out.status = 200; out.body = append([]byte(nil), req.body...) }, cfg)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- srv.Serve(ctx) }()
	t.Cleanup(func() {
		cancel()
		select {
		case err := <-done:
			if err != nil {
				t.Error(err)
			}
		case <-time.After(5 * time.Second):
			t.Error("reactor failed to stop")
		}
	})
	c, err := net.Dial("tcp", srv.Addr())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(5 * time.Second))
	parts := []string{"POST /echo HTTP/1.1\r\nHost: local\r\nTransfer-Encoding: chunked\r\n\r\n", "3\r\na", "bc\r\n0\r\n\r\nGET /echo HTTP/1.1\r\nHost: local\r\nConnection: close\r\n\r\n"}
	for _, part := range parts {
		if _, err := io.WriteString(c, part); err != nil {
			t.Fatal(err)
		}
	}
	reader := bufio.NewReader(c)
	for i, want := range []string{"abc", ""} {
		response, err := http.ReadResponse(reader, nil)
		if err != nil {
			t.Fatal(err)
		}
		body, err := io.ReadAll(response.Body)
		response.Body.Close()
		if err != nil {
			t.Fatal(err)
		}
		if response.StatusCode != 200 || string(body) != want {
			t.Fatalf("response %d: %s", i, body)
		}
	}
}

func FuzzWireFraming(f *testing.F) {
	f.Add([]byte("GET /api/tags HTTP/1.1\r\nHost: local\r\n\r\n"))
	f.Add([]byte("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nx\r\n0\r\n\r\n"))
	f.Add([]byte("POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nx"))
	f.Fuzz(func(t *testing.T, b []byte) {
		var wire wireRequest
		n := parseWire(b, &wire)
		if n > len(b) {
			t.Fatal("framer consumed beyond input")
		}
		if n > 0 && (!strings.HasPrefix(string(b), string(wire.method)) || len(wire.target) == 0) {
			t.Fatal(fmt.Sprint("invalid complete frame: ", n))
		}
	})
}

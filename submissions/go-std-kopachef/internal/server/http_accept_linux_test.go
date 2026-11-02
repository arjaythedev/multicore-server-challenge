//go:build linux

package server

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"syscall"
	"testing"
	"time"
)

type intermittentListener struct {
	net.Listener
	errors   []error
	repeated error
	observed chan error
}

func (l *intermittentListener) Accept() (net.Conn, error) {
	err := l.repeated
	if len(l.errors) != 0 {
		err, l.errors = l.errors[0], l.errors[1:]
	}
	if err != nil {
		select {
		case l.observed <- err:
		default:
		}
		return nil, err
	}
	return l.Listener.Accept()
}

func TestCompactAcceptRetry(t *testing.T) {
	old := compactHTTPWorkers
	t.Cleanup(func() { compactHTTPWorkers = old })
	for _, workers := range []int{0, 2} {
		t.Run(fmt.Sprintf("workers%d", workers), func(t *testing.T) {
			compactHTTPWorkers = workers
			base, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			listener := &intermittentListener{Listener: base, errors: []error{
				nil, &net.OpError{Op: "accept", Net: "tcp", Err: syscall.EMFILE},
				fmt.Errorf("wrapped: %w", &net.OpError{Op: "accept", Net: "tcp", Err: syscall.ENFILE}),
				&net.OpError{Op: "accept", Net: "tcp", Err: syscall.ECONNABORTED}, nil,
			}, observed: make(chan error, 4)}
			ctx, cancel := context.WithCancel(context.Background())
			done := make(chan error, 1)
			go func() {
				done <- serveCompactListener(ctx, listener, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
			}()
			t.Cleanup(func() {
				cancel()
				select {
				case err := <-done:
					if !errors.Is(err, http.ErrServerClosed) {
						t.Error(err)
					}
				case <-time.After(time.Second):
					t.Error("accept retry prevented shutdown")
				}
			})
			// The first connection remains usable while the accept loop meets
			// descriptor exhaustion. A later connection succeeds after retries.
			var connections []net.Conn
			for range 2 {
				c, err := net.DialTimeout("tcp", base.Addr().String(), time.Second)
				if err != nil {
					t.Fatal(err)
				}
				connections = append(connections, c)
				defer c.Close()
			}
			for _, c := range connections {
				c.SetDeadline(time.Now().Add(time.Second))
				io.WriteString(c, "GET / HTTP/1.1\r\nHost: test\r\n\r\n")
				response, err := http.ReadResponse(bufio.NewReader(c), nil)
				if err != nil {
					t.Fatal(err)
				}
				response.Body.Close()
				if response.StatusCode != 204 {
					t.Fatal("unexpected status")
				}
			}
			if len(listener.observed) != 3 {
				t.Fatal("accept errors were not retried", len(listener.observed))
			}
		})
	}
}

func TestCompactAcceptRetryCancellation(t *testing.T) {
	old := compactHTTPWorkers
	t.Cleanup(func() { compactHTTPWorkers = old })
	for _, workers := range []int{0, 2} {
		t.Run(fmt.Sprintf("workers%d", workers), func(t *testing.T) {
			compactHTTPWorkers = workers
			base, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			listener := &intermittentListener{Listener: base, repeated: &net.OpError{Op: "accept", Net: "tcp", Err: syscall.EMFILE}, observed: make(chan error, 1)}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			done := make(chan error, 1)
			go func() {
				done <- serveCompactListener(ctx, listener, http.HandlerFunc(func(http.ResponseWriter, *http.Request) { t.Error("unexpected request") }))
			}()
			select {
			case <-listener.observed:
			case <-time.After(time.Second):
				t.Fatal("accept loop did not start")
			}
			cancel()
			select {
			case err := <-done:
				if !errors.Is(err, http.ErrServerClosed) {
					t.Error(err)
				}
			case <-time.After(time.Second):
				t.Fatal("retry delay did not cancel")
			}
		})
	}
}

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
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestPooledCompactProtocol(t *testing.T) {
	oldWorkers, oldHot, oldParent := compactHTTPWorkers, compactHTTPHotPath, compactContextParent
	compactHTTPWorkers = 4
	t.Cleanup(func() { compactHTTPWorkers, compactHTTPHotPath, compactContextParent = oldWorkers, oldHot, oldParent })
	for _, parent := range []string{"server", "connection", "sharded"} {
		for _, hot := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/hot=%t", parent, hot), func(t *testing.T) {
				compactHTTPHotPath, compactContextParent = hot, parent
				TestCompactHTTP(t)
				TestCompactHTTPLargeRequests(t)
			})
		}
	}
}

func TestPooledIdleWheel(t *testing.T) {
	now := time.Unix(1000, 500000000)
	w := pooledIdleWheel{origin: now.Add(-3 * time.Second)}
	var a, b, c pooledConnection
	w.add(&a, now.Add(-2*time.Second))
	w.add(&b, now.Add(75*time.Second)) // Wraps into the bucket being visited now.
	w.add(&c, now.Add(2*time.Second))
	w.remove(&c)
	closed := make(map[*pooledConnection]int)
	closeConnection := func(p *pooledConnection) { closed[p]++ }
	w.expire(now, closeConnection)
	if closed[&a] != 1 || closed[&b] != 0 || closed[&c] != 0 {
		t.Fatal("early expiry or removed connection expired", closed)
	}
	w.add(&b, now.Add(74*time.Second)) // Refresh does not retain the old link.
	w.expire(now.Add(76*time.Second), closeConnection)
	if closed[&b] != 1 || closed[&a] != 1 || closed[&c] != 0 || b.idlePrev != nil {
		t.Fatal("expiry/refresh did not unlink exactly once", closed)
	}
}

func TestPooledConnectionHandoffs(t *testing.T) {
	oldWorkers, oldHot := compactHTTPWorkers, compactHTTPHotPath
	compactHTTPWorkers, compactHTTPHotPath = 2, true
	t.Cleanup(func() { compactHTTPWorkers, compactHTTPHotPath = oldWorkers, oldHot })
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	finished := make(chan error, 1)
	var calls, active, maxActive atomic.Int64
	gate := make(chan struct{})
	panicContext := make(chan context.Context, 1)
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := active.Add(1)
		defer active.Add(-1)
		for previous := maxActive.Load(); n > previous && !maxActive.CompareAndSwap(previous, n); previous = maxActive.Load() {
		}
		calls.Add(1)
		if r.URL.Path == "/wait" {
			select {
			case <-gate:
			case <-r.Context().Done():
			}
		}
		if r.URL.Path == "/panic" {
			panicContext <- r.Context()
			panic("test worker survival")
		}
		_, _ = io.WriteString(w, r.URL.Path)
	})
	go func() { finished <- serveCompactListener(ctx, listener, handler) }()
	var sockets []net.Conn
	defer func() {
		cancel()
		for _, c := range sockets {
			c.Close()
		}
		select {
		case err := <-finished:
			if !errors.Is(err, http.ErrServerClosed) {
				t.Error(err)
			}
		case <-time.After(5 * time.Second):
			t.Error("pool shutdown blocked")
		}
	}()
	dial := func() net.Conn {
		c, err := net.DialTimeout("tcp", listener.Addr().String(), time.Second)
		if err != nil {
			t.Fatal(err)
		}
		c.SetDeadline(time.Now().Add(5 * time.Second))
		sockets = append(sockets, c)
		return c
	}
	read := func(reader *bufio.Reader, want string) {
		r, err := http.ReadResponse(reader, nil)
		if err != nil {
			t.Fatal(err)
		}
		body, err := io.ReadAll(r.Body)
		r.Body.Close()
		if err != nil || string(body) != want {
			t.Fatalf("body=%q want=%q err=%v", body, want, err)
		}
	}
	// More idle sockets than workers leave workers available for useful requests.
	before := runtime.NumGoroutine()
	for range 64 {
		dial()
	}
	for range 100 {
		if runtime.NumGoroutine() > before+20 {
			t.Fatal("idle sockets created per-connection goroutines")
		}
		time.Sleep(time.Millisecond)
	}
	c := dial()
	reader := bufio.NewReader(c)
	// Pipelined input exceeds the reader buffer and must survive worker handoff.
	var pipelined strings.Builder
	for range 80 {
		pipelined.WriteString("GET /pipeline HTTP/1.1\r\nHost: test\r\n\r\n")
	}
	io.WriteString(c, pipelined.String())
	for range 80 {
		read(reader, "/pipeline")
	}
	for range 16 {
		io.WriteString(c, "GET /again HTTP/1.1\r\nHost: test\r\n\r\n")
		read(reader, "/again")
	}
	// FIN after a complete request still permits the response to be written.
	half := dial().(*net.TCPConn)
	io.WriteString(half, "GET /half HTTP/1.1\r\nHost: test\r\n\r\n")
	half.CloseWrite()
	read(bufio.NewReader(half), "/half")
	// A recovered panic closes only that connection and cancels its request.
	broken := dial()
	io.WriteString(broken, "GET /panic HTTP/1.1\r\nHost: test\r\n\r\n")
	if _, err := bufio.NewReader(broken).ReadByte(); err == nil {
		t.Fatal("panic connection remained open")
	}
	select {
	case <-((<-panicContext).Done()):
	default:
		t.Fatal("panic leaked its request context")
	}
	io.WriteString(c, "GET /survived HTTP/1.1\r\nHost: test\r\n\r\n")
	read(reader, "/survived")
	for range 64 {
		churn := dial()
		io.WriteString(churn, "GET /churn HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n")
		read(bufio.NewReader(churn), "/churn")
		churn.Close()
	}
	// Fill both workers, then exceed the admission channel's capacity. The
	// reactor must retain one job per connection without dropping or duplicating.
	var pending []net.Conn
	for range 20 {
		p := dial()
		pending = append(pending, p)
		io.WriteString(p, "GET /wait HTTP/1.1\r\nHost: test\r\n\r\n")
	}
	deadline := time.Now().Add(time.Second)
	for active.Load() != 2 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if active.Load() != 2 {
		t.Fatal("workers did not receive requests")
	}
	close(gate)
	var wg sync.WaitGroup
	for _, p := range pending {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r, err := http.ReadResponse(bufio.NewReader(p), nil)
			if err != nil {
				t.Error(err)
				return
			}
			io.Copy(io.Discard, r.Body)
			r.Body.Close()
		}()
	}
	wg.Wait()
	if maxActive.Load() != 2 || calls.Load() != 183 {
		t.Fatalf("max active=%d calls=%d", maxActive.Load(), calls.Load())
	}
}

func TestPooledShutdownBusy(t *testing.T) {
	old := compactHTTPWorkers
	compactHTTPWorkers = 2
	t.Cleanup(func() { compactHTTPWorkers = old })
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	entered := make(chan context.Context, 1)
	finished := make(chan error, 1)
	go func() {
		finished <- serveCompactListener(ctx, listener, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			select {
			case entered <- r.Context():
			default:
			}
			<-r.Context().Done()
		}))
	}()
	var connections []net.Conn
	for i := range 12 {
		c, err := net.DialTimeout("tcp", listener.Addr().String(), time.Second)
		if err != nil {
			t.Fatal(err)
		}
		connections = append(connections, c)
		defer c.Close()
		if i == 0 {
			io.WriteString(c, "GET /partial HTTP/1.1\r\nHost:")
		} else {
			io.WriteString(c, "GET /wait HTTP/1.1\r\nHost: test\r\n\r\n")
		}
	}
	select {
	case request := <-entered:
		cancel()
		select {
		case <-request.Done():
		case <-time.After(time.Second):
			t.Fatal("request did not cancel")
		}
	case <-time.After(time.Second):
		t.Fatal("handler did not start")
	}
	select {
	case err := <-finished:
		if !errors.Is(err, http.ErrServerClosed) {
			t.Error(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("shutdown blocked on headers, active handlers or queued jobs")
	}
}

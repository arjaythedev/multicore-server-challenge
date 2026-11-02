package server

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptrace"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestCompactConnectionContextParent(t *testing.T) {
	old := compactContextParent
	compactContextParent = "connection"
	t.Cleanup(func() { compactContextParent = old })
	// Reuse the protocol suite, including parent values, cancellation after
	// every response, keep-alive, trailers, pipelining and parent shutdown.
	TestCompactHTTP(t)
	TestCompactHTTPLargeRequests(t)
}

func TestCompactShardedContextParent(t *testing.T) {
	old := compactContextParent
	compactContextParent = "sharded"
	t.Cleanup(func() { compactContextParent = old })
	TestCompactHTTP(t)
	TestCompactHTTPLargeRequests(t)
}

func TestCompactHTTP(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	type contextKey struct{}
	ctx, cancel := context.WithCancel(context.WithValue(context.Background(), contextKey{}, "parent"))
	finished := make(chan error, 1)
	contexts := make(chan context.Context, 64)
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Context().Value(contextKey{}) != "parent" || r.Context().Err() != nil {
			t.Error("request context lost the parent or was canceled before handling")
		}
		contexts <- r.Context()
		body, err := io.ReadAll(r.Body)
		if err != nil || (r.Method == http.MethodPost && string(body) != "payload") {
			t.Errorf("request body=%q error=%v", body, err)
		}
		if r.Trailer != nil && r.Trailer.Get("X-Test") != "preserved" {
			t.Error("chunked body lost its declared trailer")
		}
		size, _ := strconv.Atoi(r.URL.Query().Get("size"))
		if size == 0 {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(strings.Repeat("x", size)))
	})
	go func() { finished <- serveCompactListener(ctx, listener, handler) }()
	var once sync.Once
	stop := func() {
		once.Do(func() {
			cancel()
			select {
			case err := <-finished:
				if !errors.Is(err, http.ErrServerClosed) {
					t.Error(err)
				}
			case <-time.After(5 * time.Second):
				t.Error("compact server did not stop")
			}
		})
	}
	t.Cleanup(stop)
	client := &http.Client{Transport: &http.Transport{}, Timeout: 5 * time.Second}
	defer client.CloseIdleConnections()
	local := ""
	for _, size := range []int{1, 2048, 4096, 131072, 0, 128} {
		for _, method := range []string{http.MethodGet, http.MethodHead, http.MethodPost} {
			var body io.Reader
			if method == http.MethodPost {
				body = strings.NewReader("payload")
			}
			r, _ := http.NewRequest(method, fmt.Sprintf("http://%s?size=%d", listener.Addr(), size), body)
			if method == http.MethodPost {
				r.Header.Set("Expect", "100-continue")
			}
			r = r.WithContext(httptrace.WithClientTrace(r.Context(), &httptrace.ClientTrace{GotConn: func(info httptrace.GotConnInfo) {
				address := info.Conn.LocalAddr().String()
				if local != "" && local != address {
					t.Error("keep-alive connection changed")
				}
				local = address
			}}))
			response, err := client.Do(r)
			if err != nil {
				t.Fatal(err)
			}
			got, err := io.ReadAll(response.Body)
			response.Body.Close()
			requestContext := <-contexts
			select {
			case <-requestContext.Done():
			case <-time.After(time.Second):
				t.Fatal("completed handler left its request context live")
			}
			want := strings.Repeat("x", size)
			if method == http.MethodHead {
				want = ""
			}
			status := http.StatusCreated
			if size == 0 {
				status = http.StatusNoContent
			}
			if err != nil || string(got) != want || response.StatusCode != status || response.Header.Get("Date") == "" {
				t.Fatalf("%s size=%d status=%d bytes=%d error=%v", method, size, response.StatusCode, len(got), err)
			}
		}
	}
	connection, err := net.DialTimeout("tcp", listener.Addr().String(), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	connection.SetDeadline(time.Now().Add(5 * time.Second))
	_, err = io.WriteString(connection, "POST /?size=5 HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\nTrailer: X-Test\r\n\r\n7\r\npayload\r\n0\r\nX-Test: preserved\r\n\r\nGET /?size=0 HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n")
	if err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(connection)
	first, err := http.ReadResponse(reader, &http.Request{Method: http.MethodPost})
	if err != nil {
		t.Fatal(err)
	}
	body, err := io.ReadAll(first.Body)
	first.Body.Close()
	if err != nil || string(body) != "xxxxx" {
		t.Fatalf("chunked request response=%q, error=%v", body, err)
	}
	second, err := http.ReadResponse(reader, &http.Request{Method: http.MethodGet})
	if err != nil {
		t.Fatal(err)
	}
	second.Body.Close()
	if second.StatusCode != http.StatusNoContent || !second.Close {
		t.Fatal("pipelined closing response was not preserved")
	}
	if _, err := reader.ReadByte(); err != io.EOF {
		t.Fatalf("connection did not close cleanly: %v", err)
	}
	// Stop while a valid keep-alive socket is still held by the client.
	response, err := client.Get("http://" + listener.Addr().String() + "?size=128")
	if err != nil {
		t.Fatal(err)
	}
	_, err = io.Copy(io.Discard, response.Body)
	response.Body.Close()
	if err != nil {
		t.Fatal(err)
	}
	stop()
}

func TestCompactHTTPLargeRequests(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	finished := make(chan error, 1)
	header, payload, trailer := strings.Repeat("h", 8193), strings.Repeat("p", 32769), strings.Repeat("t", 3000)
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Errorf("read chunked body: %v", err)
		}
		if r.URL.Path == "/large" {
			if r.Header.Get("X-Fill") != header || string(body) != payload || (len(r.TransferEncoding) != 0 && r.Trailer.Get("X-Check") != trailer) {
				t.Error("large request lost header, body or trailer data")
			}
		} else if r.URL.Path != "/next" || len(body) != 0 {
			t.Error("pipelined request after reader growth was corrupted")
		}
		_, _ = io.WriteString(w, r.URL.Path)
	})
	go func() { finished <- serveCompactListener(ctx, listener, handler) }()
	t.Cleanup(func() {
		cancel()
		select {
		case err := <-finished:
			if !errors.Is(err, http.ErrServerClosed) {
				t.Error(err)
			}
		case <-time.After(5 * time.Second):
			t.Error("compact server did not stop")
		}
	})
	connection, err := net.DialTimeout("tcp", listener.Addr().String(), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	connection.SetDeadline(time.Now().Add(5 * time.Second))
	wire := fmt.Sprintf("POST /large HTTP/1.1\r\nHost: test\r\nX-Fill: %s\r\nContent-Length: %d\r\n\r\n%s", header, len(payload), payload)
	wire += fmt.Sprintf("POST /large HTTP/1.1\r\nHost: test\r\nX-Fill: %s\r\nTransfer-Encoding: chunked\r\nTrailer: X-Check\r\n\r\n%x\r\n%s\r\n0\r\nX-Check: %s\r\n\r\nGET /next HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n", header, len(payload), payload, trailer)
	if _, err := io.WriteString(connection, wire); err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(connection)
	for _, want := range []string{"/large", "/large", "/next"} {
		response, err := http.ReadResponse(reader, nil)
		if err != nil {
			t.Fatal(err)
		}
		body, err := io.ReadAll(response.Body)
		response.Body.Close()
		if err != nil || response.StatusCode != http.StatusOK || string(body) != want {
			t.Fatalf("response = %q, status %d, error %v", body, response.StatusCode, err)
		}
	}
	if _, err := reader.ReadByte(); err != io.EOF {
		t.Fatalf("closing request left bytes after reader growth: %v", err)
	}
}

var contextRequestSink *http.Request

func BenchmarkRequestContextOwnership(b *testing.B) {
	for _, inPlace := range []bool{false, true} {
		b.Run(fmt.Sprintf("in-place=%v", inPlace), func(b *testing.B) {
			original := &http.Request{Header: make(http.Header)}
			ctx := context.Background()
			b.ReportAllocs()
			for b.Loop() {
				request := original
				if inPlace {
					*request = *request.WithContext(ctx)
				} else {
					request = request.WithContext(ctx)
				}
				contextRequestSink = request
			}
		})
	}
}

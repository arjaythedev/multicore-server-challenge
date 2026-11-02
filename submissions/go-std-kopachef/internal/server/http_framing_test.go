package server

import (
	"bytes"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httptrace"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type countingListener struct {
	net.Listener
	writes atomic.Int64
	bytes  atomic.Int64
}

func TestResponseConnectionHTTP(t *testing.T) {
	// Reuse one TCP connection across large/small bodies, HEAD and empty
	// responses. This catches a staged prefix leaking into the next response.
	s := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n, err := strconv.Atoi(r.URL.Query().Get("size"))
		if err != nil {
			t.Error(err)
			return
		}
		if n == 0 {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		writeFramedJSON(w, http.StatusCreated, []byte(strings.Repeat("z", n)))
	}))
	configureResponseWrites(s.Config)
	s.Listener = responseListener{s.Listener}
	s.Start()
	defer s.Close()
	client := s.Client()
	client.Timeout = 5 * time.Second
	defer client.CloseIdleConnections()
	var remote string
	for range 3 {
		for _, size := range []int{131072, 128, 0, 2050, 4096, 2048, 16384} {
			for _, method := range []string{http.MethodGet, http.MethodHead} {
				request, err := http.NewRequest(method, fmt.Sprintf("%s?size=%d", s.URL, size), nil)
				if err != nil {
					t.Fatal(err)
				}
				request = request.WithContext(httptrace.WithClientTrace(request.Context(), &httptrace.ClientTrace{
					GotConn: func(info httptrace.GotConnInfo) {
						local := info.Conn.LocalAddr().String()
						if remote != "" && local != remote {
							t.Errorf("connection changed: %s -> %s", remote, local)
						}
						remote = local
					},
				}))
				response, err := client.Do(request)
				if err != nil {
					t.Fatal(err)
				}
				got, err := io.ReadAll(response.Body)
				response.Body.Close()
				want := strings.Repeat("z", size)
				if method == http.MethodHead {
					want = ""
				}
				if err != nil || string(got) != want || len(response.TransferEncoding) != 0 {
					t.Fatalf("%s size=%d: bytes=%d, encoding=%v, error=%v", method, size, len(got), response.TransferEncoding, err)
				}
				status := http.StatusCreated
				if size == 0 {
					status = http.StatusNoContent
				}
				if response.StatusCode != status || (size > 2048 && response.ContentLength != int64(size)) {
					t.Fatalf("%s size=%d: status=%d, length=%d", method, size, response.StatusCode, response.ContentLength)
				}
			}
		}
	}
}

func (l *countingListener) Accept() (net.Conn, error) {
	c, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	return &countingConnection{Conn: c, listener: l}, nil
}

type countingConnection struct {
	net.Conn
	listener *countingListener
}

func (c *countingConnection) Write(p []byte) (int, error) {
	c.listener.writes.Add(1)
	n, err := c.Conn.Write(p)
	c.listener.bytes.Add(int64(n))
	return n, err
}

// Measure actual HTTP/1.1 traffic on a persistent TCP connection. Conn.Write
// counts describe framing overhead; end-to-end time also includes the client.
func BenchmarkHTTPFraming(b *testing.B) {
	for _, size := range []int{128, 2048, 4096, 16384, 131072} {
		for _, framing := range []string{"implicit", "length", "coalesce"} {
			b.Run(fmt.Sprintf("bytes%d/%s", size, framing), func(b *testing.B) {
				body := bytes.Repeat([]byte{'x'}, size)
				length := strconv.Itoa(len(body))
				s := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					if framing == "coalesce" {
						writeFramedJSON(w, http.StatusOK, body)
						return
					}
					w.Header().Set("Content-Type", "application/json")
					if framing == "length" {
						w.Header().Set("Content-Length", length)
					}
					w.WriteHeader(http.StatusOK)
					_, _ = w.Write(body)
				}))
				listener := &countingListener{Listener: s.Listener}
				if framing == "coalesce" {
					// Keep the underlying *net.TCPConn visible to net.Buffers so
					// its writev fast path is exercised. A counting Conn would
					// hide that interface and force separate writes.
					configureResponseWrites(s.Config)
					s.Listener = responseListener{s.Listener}
				} else {
					s.Listener = listener
				}
				s.Start()
				defer s.Close()
				client := s.Client()
				defer client.CloseIdleConnections()
				request, err := http.NewRequest(http.MethodGet, s.URL, nil)
				if err != nil {
					b.Fatal(err)
				}
				for b.Loop() {
					response, err := client.Do(request)
					if err != nil {
						b.Fatal(err)
					}
					n, err := io.Copy(io.Discard, response.Body)
					response.Body.Close()
					if err != nil || n != int64(size) || response.StatusCode != http.StatusOK {
						b.Fatalf("invalid response: bytes=%d, status=%d, error=%v", n, response.StatusCode, err)
					}
				}
				if framing != "coalesce" {
					b.ReportMetric(float64(listener.writes.Load())/float64(b.N), "writes/response")
					b.ReportMetric(float64(listener.bytes.Load())/float64(b.N), "wire-B/response")
				}
			})
		}
	}
}

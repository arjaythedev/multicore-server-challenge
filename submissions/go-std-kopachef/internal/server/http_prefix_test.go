package server

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

type prefixTestConn struct {
	bufferedTestConn
	observe func([]byte)
	writes  int
	limit   int
	failure error
}

func (c *prefixTestConn) Write(p []byte) (int, error) {
	c.writes++
	if c.observe != nil {
		c.observe(p)
	}
	if c.limit > 0 && len(p) > c.limit {
		p = p[:c.limit]
	}
	n, _ := c.output.Write(p)
	return n, c.failure
}

func TestPrefixedResponse(t *testing.T) {
	for _, method := range []string{http.MethodGet, http.MethodHead} {
		for _, status := range []int{200, 201, 204, 304, 401, 500} {
			for _, offset := range []int{0, 1, responseHeadReserve, 1024} {
				for _, extra := range []string{"", strings.Repeat("h", 600), "a\r\nX-Injected: b"} {
					name := fmt.Sprintf("%s/%d/reserve%d/extra%d", method, status, offset, len(extra))
					t.Run(name, func(t *testing.T) {
						body := []byte(`{"ok":true}`)
						headers := http.Header{"Content-Type": {"application/json"}}
						if extra != "" {
							headers.Set("X-Extra", extra)
						}
						var want http.Header
						for _, prefixed := range []bool{false, true} {
							c := &prefixTestConn{}
							w := compactResponse{connection: c, header: headers.Clone(), wire: make([]byte, 0, 512)}
							w.reset(&http.Request{Method: method, Close: true})
							w.header = headers.Clone()
							w.WriteHeader(status)
							buffer := append(bytes.Repeat([]byte{'#'}, offset), body...)
							if prefixed && offset >= 1024 && method == http.MethodGet && status != 204 && status != 304 {
								c.observe = func(p []byte) {
									start := bytes.Index(p, []byte("\r\n\r\n")) + 4
									if start < 4 || len(p)-start != len(body) || &p[start] != &buffer[offset] {
										t.Fatal("body moved instead of using its owned prefix")
									}
								}
							}
							var n int
							var err error
							if prefixed {
								n, err = w.writePrefixed(buffer, offset)
							} else {
								n, err = w.Write(body)
							}
							wantCount := len(body)
							if method != http.MethodHead && (status == 204 || status == 304) {
								wantCount = 0
							}
							if err != nil || n != wantCount {
								t.Fatalf("n=%d want=%d err=%v", n, wantCount, err)
							}
							if prefixed && offset >= 1024 && c.writes != 1 {
								t.Fatal("prefixed write split into multiple calls")
							}
							reader := bufio.NewReader(bytes.NewReader(c.output.Bytes()))
							response, err := http.ReadResponse(reader, &http.Request{Method: method})
							if err != nil {
								t.Fatal(err)
							}
							got, err := io.ReadAll(response.Body)
							response.Body.Close()
							wantBody := body
							if method == http.MethodHead || status == 204 || status == 304 {
								wantBody = nil
							}
							if err != nil || !bytes.Equal(got, wantBody) || response.StatusCode != status || !response.Close {
								t.Fatalf("invalid response: %#v body=%q error=%v", response, got, err)
							}
							if _, err := http.ParseTime(response.Header.Get("Date")); err != nil {
								t.Fatal(err)
							}
							response.Header.Del("Date")
							if !prefixed {
								want = response.Header
							} else if !reflect.DeepEqual(want, response.Header) {
								t.Fatal("header semantics changed")
							}
							if left, _ := io.ReadAll(reader); len(left) != 0 {
								t.Fatal("unexpected bytes after response")
							}
							if prefixed {
								before := c.output.Len()
								if _, err := w.writePrefixed(buffer, offset); !errors.Is(err, http.ErrContentLength) || c.output.Len() != before {
									t.Fatal("second response was not rejected")
								}
							}
						}
					})
				}
			}
		}
	}
}

func TestPrefixedWriteErrors(t *testing.T) {
	for _, failure := range []error{nil, io.ErrClosedPipe} {
		c := &prefixTestConn{limit: 3, failure: failure}
		w := compactResponse{connection: c, header: make(http.Header)}
		buffer := append(make([]byte, responseHeadReserve), []byte("body")...)
		n, err := w.writePrefixed(buffer, responseHeadReserve)
		want := failure
		if want == nil {
			want = io.ErrShortWrite
		}
		if n != 0 || !errors.Is(err, want) || !errors.Is(w.err, want) {
			t.Fatal("short/error write did not propagate", n, err)
		}
	}
	for _, offset := range []int{-1, 10} {
		c := &prefixTestConn{}
		w := compactResponse{connection: c, header: make(http.Header)}
		if _, err := w.writePrefixed(nil, offset); err == nil || c.writes != 0 {
			t.Fatal("invalid offset reached connection")
		}
	}
}

func TestPrefixedJSONHTTP(t *testing.T) {
	oldPrefix, oldEncoding, oldWorkers := compactPrefixResponses, responseEncoding, compactHTTPWorkers
	compactPrefixResponses = true
	t.Cleanup(func() {
		compactPrefixResponses, responseEncoding, compactHTTPWorkers = oldPrefix, oldEncoding, oldWorkers
	})
	for _, workers := range []int{0, 4} {
		for _, encoding := range []string{"direct", "standard"} {
			t.Run(fmt.Sprintf("workers%d/%s", workers, encoding), func(t *testing.T) {
				compactHTTPWorkers, responseEncoding = workers, encoding
				listener, err := net.Listen("tcp", "127.0.0.1:0")
				if err != nil {
					t.Fatal(err)
				}
				ctx, cancel := context.WithCancel(context.Background())
				done := make(chan error, 1)
				values := []any{}
				for _, length := range []int{40000, 2, 400000, 0, 3} {
					values = append(values, struct {
						Profile profileJSON `json:"profile"`
					}{profileJSON{Username: strings.Repeat("λ\"", length)}})
				}
				values = append(values, map[string]any{"generic": "fallback"}, nil, failingJSON{})
				go func() {
					done <- serveCompactListener(ctx, listener, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
						i, _ := strconv.Atoi(r.URL.Query().Get("i"))
						if i == 1 {
							w.Header().Set("X-Long", strings.Repeat("x", 1024))
						}
						writeJSON(w, 201, values[i])
					}))
				}()
				t.Cleanup(func() {
					cancel()
					select {
					case err := <-done:
						if !errors.Is(err, http.ErrServerClosed) {
							t.Error(err)
						}
					case <-time.After(5 * time.Second):
						t.Error("prefix server shutdown blocked")
					}
				})
				client := &http.Client{Transport: &http.Transport{}, Timeout: 5 * time.Second}
				defer client.CloseIdleConnections()
				for range 2 {
					for i, value := range values {
						r, err := client.Get(fmt.Sprintf("http://%s/?i=%d", listener.Addr(), i))
						if err != nil {
							t.Fatal(err)
						}
						body, err := io.ReadAll(r.Body)
						r.Body.Close()
						if err != nil {
							t.Fatal(err)
						}
						if _, failed := value.(failingJSON); failed {
							if r.StatusCode != 500 || string(body) != `{"errors":{"body":["internal error"]}}` {
								t.Fatal("encoding failure changed")
							}
						} else {
							if r.StatusCode != 201 {
								t.Fatal("status changed")
							}
							compareAPIJSON(t, body, value)
						}
					}
				}
			})
		}
	}
}

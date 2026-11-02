package server

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"
)

func compareBufferedGET(t *testing.T, input []byte) bool {
	t.Helper()
	got, consumed := bufferedGET(input)
	if got == nil {
		if consumed != 0 {
			t.Fatal("rejected input was consumed")
		}
		return false
	}
	reader := bufio.NewReader(bytes.NewReader(input))
	want, err := http.ReadRequest(reader)
	if err != nil {
		t.Fatalf("fast parser accepted input rejected by ReadRequest: %q: %v", input, err)
	}
	defer want.Body.Close()
	if got.Method != want.Method || got.Proto != want.Proto || got.ProtoMajor != want.ProtoMajor || got.ProtoMinor != want.ProtoMinor ||
		got.RequestURI != want.RequestURI || got.Host != want.Host || got.Close != want.Close || got.ContentLength != want.ContentLength ||
		!reflect.DeepEqual(got.URL, want.URL) || !reflect.DeepEqual(got.Header, want.Header) ||
		!reflect.DeepEqual(got.TransferEncoding, want.TransferEncoding) || !reflect.DeepEqual(got.Trailer, want.Trailer) {
		t.Fatalf("request mismatch for %q:\ngot  %#v URL=%#v headers=%#v\nwant %#v URL=%#v headers=%#v", input, got, got.URL, got.Header, want, want.URL, want.Header)
	}
	if got.Body != http.NoBody || want.Body != http.NoBody {
		t.Fatal("accepted a request with a body")
	}
	remaining, err := io.ReadAll(reader)
	if err != nil || !bytes.Equal(remaining, input[consumed:]) {
		t.Fatal("parser consumed pipelined data")
	}
	return true
}

func TestBufferedGET(t *testing.T) {
	for _, uri := range []string{"/", "/api/articles", "/api/articles?", "/api/articles??", "/api/articles?limit=20&offset=0&tag=go", "/api/articles/a-title-1/comments", "/api/profiles/a_user", "/a/../b//"} {
		for _, extra := range []string{"", "Authorization: Bearer token\r\nUser-Agent: client\r\nAccept: application/json\r\nAccept-Encoding: gzip\r\n", "connection: CLOSE\r\n", "Connection: keep-alive\r\n", "aUtHoRiZaTiOn:\tBearer token \t\r\n"} {
			input := []byte("GET " + uri + " HTTP/1.1\r\nHost: localhost:3180\r\n" + extra + "\r\nGET /next HTTP/1.1\r\nHost: test\r\n\r\n")
			if !compareBufferedGET(t, input) {
				t.Fatalf("ordinary GET rejected: %q", input)
			}
			request, _ := bufferedGET(input)
			before := request.URL.String() + request.Host + request.Header.Get("Authorization")
			for i := range input {
				input[i] = '!'
			}
			if got := request.URL.String() + request.Host + request.Header.Get("Authorization"); got != before {
				t.Fatal("request borrowed reader storage")
			}
		}
	}
	for _, input := range []string{
		"GET / HTTP/1.1\r\nHost: test\r\n", "POST / HTTP/1.1\r\nHost: test\r\n\r\n", "HEAD / HTTP/1.1\r\nHost: test\r\n\r\n",
		"GET / HTTP/1.0\r\nHost: test\r\n\r\n", "GET /%61 HTTP/1.1\r\nHost: test\r\n\r\n", "GET /λ HTTP/1.1\r\nHost: test\r\n\r\n",
		"GET / HTTP/1.1\r\nHost: test\r\nContent-Length: 0\r\n\r\n", "GET / HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\n\r\n",
		"GET / HTTP/1.1\r\nHost: test\r\nHost: second\r\n\r\n", "GET / HTTP/1.1\r\nHost: test\r\nX-Extra: value\r\n\r\n",
		"GET / HTTP/1.1\r\nHost: test\r\nConnection: upgrade\r\n\r\n", "GET / HTTP/1.1\r\nHost: test\r\nAuthorization: a\r\n b\r\n\r\n",
		"GET /[ HTTP/1.1\r\nHost: test\r\n\r\n", "GET / HTTP/1.1\r\n\r\n",
		"GET / HTTP/1.1\r\nHoſt: test\r\n\r\n",
	} {
		if request, n := bufferedGET([]byte(input)); request != nil || n != 0 {
			t.Fatalf("general input did not select fallback: %q", input)
		}
	}
}

func FuzzBufferedGETFields(f *testing.F) {
	for _, uri := range []string{"api/articles?tag=go", "api/articles?", "api/profiles/a_user", "a/../b", "[", "?x=1?", "%61", "λ"} {
		f.Add(uri, "Bearer token", "test", "keep-alive")
	}
	f.Fuzz(func(t *testing.T, uri, auth, host, connection string) {
		input := "GET /" + uri + " HTTP/1.1\r\nHost: " + host + "\r\nAuthorization: " + auth + "\r\nConnection: " + connection + "\r\n\r\n"
		compareBufferedGET(t, []byte(input))
	})
}

func FuzzBufferedGET(f *testing.F) {
	for _, uri := range []string{"/", "/api/articles?limit=20", "/api/articles??", "/api/articles/%61", "/λ", "/a/../b"} {
		f.Add("GET " + uri + " HTTP/1.1\r\nHost: test\r\nAuthorization: Bearer token\r\n\r\n")
	}
	f.Fuzz(func(t *testing.T, input string) { compareBufferedGET(t, []byte(input)) })
}

func TestCompactHTTPHotPath(t *testing.T) {
	old := compactHTTPHotPath
	compactHTTPHotPath = true
	t.Cleanup(func() { compactHTTPHotPath = old })
	TestCompactHTTP(t)
	TestCompactHTTPLargeRequests(t)
}

type bufferedTestConn struct {
	input     *bytes.Reader
	output    bytes.Buffer
	deadlines []time.Time
	fragment  int
}

func (c *bufferedTestConn) Read(p []byte) (int, error) {
	if c.fragment > 0 && len(p) > c.fragment {
		p = p[:c.fragment]
	}
	return c.input.Read(p)
}
func (c *bufferedTestConn) Write(p []byte) (int, error) { return c.output.Write(p) }
func (*bufferedTestConn) Close() error                  { return nil }
func (*bufferedTestConn) LocalAddr() net.Addr           { return &net.TCPAddr{} }
func (*bufferedTestConn) RemoteAddr() net.Addr          { return &net.TCPAddr{} }
func (*bufferedTestConn) SetDeadline(time.Time) error   { return nil }
func (c *bufferedTestConn) SetReadDeadline(t time.Time) error {
	c.deadlines = append(c.deadlines, t)
	return nil
}
func (*bufferedTestConn) SetWriteDeadline(time.Time) error { return nil }

func TestBufferedGETDeadlines(t *testing.T) {
	old := compactHTTPHotPath
	compactHTTPHotPath = true
	t.Cleanup(func() { compactHTTPHotPath = old })
	for _, fragment := range []int{0, 1} {
		conn := &bufferedTestConn{input: bytes.NewReader([]byte("GET / HTTP/1.1\r\nHost: test\r\n\r\nGET / HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n")), fragment: fragment}
		count := 0
		serveCompactConnection(context.Background(), conn, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { count++; w.WriteHeader(http.StatusNoContent) }))
		if count != 2 {
			t.Fatalf("fragment=%d handlers=%d", fragment, count)
		}
		want := 2
		if fragment != 0 {
			want = 6
		}
		if len(conn.deadlines) != want {
			t.Fatalf("fragment=%d deadline updates=%d want %d", fragment, len(conn.deadlines), want)
		}
		if fragment == 0 {
			for _, d := range conn.deadlines {
				if d.IsZero() || time.Until(d) < 70*time.Second {
					t.Fatal("complete GET lost its idle deadline")
				}
			}
		}
	}
}

func TestBufferedHeaderFallback(t *testing.T) {
	old := compactHTTPHotPath
	t.Cleanup(func() { compactHTTPHotPath = old })
	for _, headers := range []http.Header{
		{"Content-Type": {"application/json"}},
		{"Content-Type": {"application/json"}, "X-Trace": {"first", "second"}},
		{"Content-Type": {"application/json\r\nX-Sneak: yes"}},
		{"Content-Type": {"application/json", "text/plain"}},
		{"Bad Name": {"ignored"}}, {},
	} {
		var wantHeader http.Header
		for _, hot := range []bool{false, true} {
			compactHTTPHotPath = hot
			conn := &bufferedTestConn{}
			w := compactResponse{connection: conn, header: headers.Clone(), wire: make([]byte, 0, 512)}
			if _, err := w.Write([]byte(`{"ok":true}`)); err != nil {
				t.Fatal(err)
			}
			r, err := http.ReadResponse(bufio.NewReader(bytes.NewReader(conn.output.Bytes())), &http.Request{Method: http.MethodGet})
			if err != nil {
				t.Fatal(err)
			}
			body, err := io.ReadAll(r.Body)
			r.Body.Close()
			if err != nil || string(body) != `{"ok":true}` {
				t.Fatal("response body changed")
			}
			r.Header.Del("Date")
			if !hot {
				wantHeader = r.Header
			} else if !reflect.DeepEqual(wantHeader, r.Header) {
				t.Fatalf("headers differ: got %#v want %#v", r.Header, wantHeader)
			}
		}
	}
}

func BenchmarkBufferedGET(b *testing.B) {
	input := []byte("GET /api/articles?limit=20&offset=0 HTTP/1.1\r\nHost: localhost:3180\r\nAuthorization: Bearer " + strings.Repeat("a", 180) + "\r\nUser-Agent: challenge\r\nAccept: application/json\r\nAccept-Encoding: gzip\r\n\r\n")
	for _, mode := range []string{"standard", "buffered"} {
		b.Run(mode, func(b *testing.B) {
			reader := bufio.NewReaderSize(bytes.NewReader(nil), 1024)
			var source bytes.Reader
			b.ReportAllocs()
			for b.Loop() {
				source.Reset(input)
				reader.Reset(&source)
				if _, err := reader.Peek(len(input)); err != nil {
					b.Fatal(err)
				}
				var r *http.Request
				if mode == "standard" {
					var err error
					r, err = http.ReadRequest(reader)
					if err != nil {
						b.Fatal(err)
					}
				} else {
					data, _ := reader.Peek(reader.Buffered())
					r, _ = bufferedGET(data)
				}
				if r == nil || r.Header.Get("Authorization") == "" {
					b.Fatal("invalid benchmark request")
				}
			}
		})
	}
}

type oldHeaderBytes []byte

func (b *oldHeaderBytes) Write(p []byte) (int, error) { *b = append(*b, p...); return len(p), nil }

func BenchmarkHeaderStrings(b *testing.B) {
	for _, mode := range []string{"writer", "string_writer"} {
		b.Run(mode, func(b *testing.B) {
			header := http.Header{"Content-Type": []string{"application/json"}}
			before := make(oldHeaderBytes, 0, 512)
			after := make(compactHeaderBytes, 0, 512)
			b.ReportAllocs()
			for b.Loop() {
				if mode == "writer" {
					before = before[:0]
					if err := header.Write(&before); err != nil {
						b.Fatal(err)
					}
				} else {
					after = after[:0]
					if err := header.Write(&after); err != nil {
						b.Fatal(err)
					}
				}
			}
			if fmt.Sprint(string(before), string(after)) == "" {
				b.Fatal("no headers")
			}
		})
	}
}

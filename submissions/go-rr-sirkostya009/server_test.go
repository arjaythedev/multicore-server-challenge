package main

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

var testAddr = func() string {
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		panic(err)
	}
	addr := l.Addr().String()
	_ = l.Close()
	h := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/echo":
			b, err := io.ReadAll(r.Body)
			if err != nil {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			_, _ = w.Write(b)
		case "/skip":
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte("skipped"))
		case "/big":
			n, _ := strconv.Atoi(r.URL.RawQuery)
			_, _ = w.Write(bytes.Repeat([]byte{'x'}, n))
		case "/empty":
			w.WriteHeader(http.StatusNoContent)
		case "/head":
			b, _ := io.ReadAll(r.Body)
			time.Sleep(time.Millisecond)
			_, _ = fmt.Fprintf(w, "%s?%s %s %s", r.URL.Path, r.URL.RawQuery, r.Header.Get("Authorization"), b)
		}
	})
	go func() { panic(serve(netip.MustParseAddrPort(addr), 2, h)) }()
	for range 100 {
		if c, err := net.Dial("tcp4", addr); err == nil {
			_ = c.Close()
			return addr
		}
		time.Sleep(10 * time.Millisecond)
	}
	panic("server did not start")
}()

func dial(t *testing.T) (net.Conn, *bufio.Reader) {
	t.Helper()
	c, err := net.Dial("tcp4", testAddr)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	_ = c.SetDeadline(time.Now().Add(10 * time.Second))
	return c, bufio.NewReader(c)
}

func post(path, body string) string {
	return fmt.Sprintf("POST %s HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n%s", path, len(body), body)
}

func expect(t *testing.T, br *bufio.Reader, status int, body string) {
	t.Helper()
	res, err := http.ReadResponse(br, nil)
	if err != nil {
		t.Fatal(err)
	}
	b, err := io.ReadAll(res.Body)
	if err != nil {
		t.Fatal(err)
	}
	if res.StatusCode != status || string(b) != body {
		t.Fatalf("got %d %.40q (%d bytes), want %d %.40q (%d bytes)", res.StatusCode, b, len(b), status, body, len(body))
	}
}

func write(t *testing.T, c net.Conn, parts ...string) {
	t.Helper()
	for i, p := range parts {
		if i > 0 {
			time.Sleep(20 * time.Millisecond)
		}
		if _, err := io.WriteString(c, p); err != nil {
			t.Fatal(err)
		}
	}
}

func TestBodyInOneRead(t *testing.T) {
	c, br := dial(t)
	for range 3 {
		write(t, c, post("/echo", `{"a":1}`))
		expect(t, br, 200, `{"a":1}`)
	}
}

func TestBodyInPieces(t *testing.T) {
	c, br := dial(t)
	req := post("/echo", "hello, world")
	write(t, c, req[:len(req)-10], req[len(req)-10:len(req)-4], req[len(req)-4:])
	expect(t, br, 200, "hello, world")
	write(t, c, post("/echo", "again"))
	expect(t, br, 200, "again")
}

func TestHeadInPieces(t *testing.T) {
	c, br := dial(t)
	req := post("/echo", "body")
	write(t, c, req[:10], req[10:30], req[30:])
	expect(t, br, 200, "body")
}

func TestBodyBiggerThanBuffer(t *testing.T) {
	c, br := dial(t)
	body := strings.Repeat("0123456789", 50_000)
	write(t, c, post("/echo", body))
	expect(t, br, 200, body)
	write(t, c, post("/echo", "after"))
	expect(t, br, 200, "after")
}

func TestPipelined(t *testing.T) {
	c, br := dial(t)
	big := strings.Repeat("y", 3*bufSize)
	write(t, c, post("/echo", "one")+post("/echo", big)+"GET /empty HTTP/1.1\r\nHost: x\r\n\r\n"+post("/echo", "four"))
	expect(t, br, 200, "one")
	expect(t, br, 200, big)
	expect(t, br, 204, "")
	expect(t, br, 200, "four")
}

func TestPipelinedInPieces(t *testing.T) {
	c, br := dial(t)
	all := post("/echo", "first") + post("/echo", "second body") + post("/echo", "third")
	cut := strings.Index(all, "second body") + 3
	write(t, c, all[:cut], all[cut:])
	expect(t, br, 200, "first")
	expect(t, br, 200, "second body")
	expect(t, br, 200, "third")
}

func TestUnreadBody(t *testing.T) {
	c, br := dial(t)
	req := post("/skip", strings.Repeat("z", 20_000))
	write(t, c, req[:200], req[200:])
	expect(t, br, 401, "skipped")
	write(t, c, post("/echo", "next"))
	expect(t, br, 200, "next")
}

func TestBigResponse(t *testing.T) {
	c, br := dial(t)
	write(t, c, "GET /big?8000000 HTTP/1.1\r\nHost: x\r\n\r\n")
	time.Sleep(100 * time.Millisecond)
	expect(t, br, 200, strings.Repeat("x", 8_000_000))
	write(t, c, post("/echo", "still here"))
	expect(t, br, 200, "still here")
}

func TestClientGoneMidBody(t *testing.T) {
	for range 20 {
		c, _ := dial(t)
		req := post("/echo", strings.Repeat("q", 1000))
		write(t, c, req[:len(req)-500])
		_ = c.Close()
	}
	c, br := dial(t)
	write(t, c, post("/echo", "alive"))
	expect(t, br, 200, "alive")
}

func TestConnectionClose(t *testing.T) {
	c, br := dial(t)
	write(t, c, "GET /empty HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
	expect(t, br, 204, "")
	if _, err := br.ReadByte(); err != io.EOF {
		t.Fatalf("got %v, want EOF", err)
	}
}

func TestBadRequestDoesNotLeakClose(t *testing.T) {
	for range 50 {
		c, br := dial(t)
		write(t, c, "GET / HTTP/1.1\r\nConnection: close\r\nbroken\r\n\r\n")
		expect(t, br, 400, "")
	}
	c, br := dial(t)
	for range 50 {
		write(t, c, "GET /empty HTTP/1.1\r\nHost: x\r\n\r\n")
		expect(t, br, 204, "")
	}
}

func TestChunkedLengthRequired(t *testing.T) {
	c, br := dial(t)
	write(t, c, "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n")
	expect(t, br, 411, "")
	if _, err := br.ReadByte(); err != io.EOF {
		t.Fatalf("got %v, want EOF", err)
	}
}

func TestHeadOutlivesReadBuffer(t *testing.T) {
	var wg sync.WaitGroup
	for g := range 64 {
		wg.Go(func() {
			c, br := dial(t)
			for i := range 20 {
				body := strings.Repeat(strconv.Itoa(g), 100+i)
				auth := fmt.Sprintf("Token %d-%d", g, i)
				if _, err := fmt.Fprintf(c, "POST /head?g=%d&i=%d HTTP/1.1\r\nAuthorization: %s\r\nContent-Length: %d\r\n\r\n%s", g, i, auth, len(body), body); err != nil {
					t.Error(err)
					return
				}
				res, err := http.ReadResponse(br, nil)
				if err != nil {
					t.Error(err)
					return
				}
				b, _ := io.ReadAll(res.Body)
				if want := fmt.Sprintf("/head?g=%d&i=%d %s %s", g, i, auth, body); string(b) != want {
					t.Errorf("got %.80q, want %.80q", b, want)
					return
				}
			}
		})
	}
	wg.Wait()
}

func TestEmptyAuthorization(t *testing.T) {
	c, br := dial(t)
	write(t, c, "POST /head?q HTTP/1.1\r\nAuthorization:\r\nContent-Length: 2\r\n\r\nhi")
	expect(t, br, 200, "/head?q  hi")
}

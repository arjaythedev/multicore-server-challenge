package server

import (
	"bufio"
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"io"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"

	"conduit/internal/auth"
)

const dispatchTestSecret = "dispatch-test-secret"

func fakeDispatchApp(t *testing.T) (*app, <-chan *queuedRead) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	q := &readQueue{ctx: ctx, pending: make(chan *queuedRead, 32)}
	a := &app{tokens: auth.NewSigner([]byte(dispatchTestSecret)), reads: q}
	calls := make(chan *queuedRead, 32)
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			select {
			case c := <-q.pending:
				c.status, c.value = http.StatusOK, struct {
					Tags []string `json:"tags"`
				}{[]string{"reply"}}
				calls <- c
				close(c.done)
			case <-ctx.Done():
				return
			}
		}
	}()
	t.Cleanup(func() { cancel(); <-done })
	return a, calls
}

type dispatchResult struct {
	status                int
	header                http.Header
	body                  string
	kind                  readKind
	viewer, limit, offset int64
	slug, filter          string
	queued                bool
}

func runDispatch(t *testing.T, a *app, calls <-chan *queuedRead, wire string, direct bool, fragment int) dispatchResult {
	t.Helper()
	compactAPIReads = direct
	c := &bufferedTestConn{input: bytes.NewReader([]byte(wire)), fragment: fragment}
	serveCompactConnection(context.Background(), c, a.routes())
	method, _, _ := strings.Cut(wire, " ")
	response, err := http.ReadResponse(bufio.NewReader(bytes.NewReader(c.output.Bytes())), &http.Request{Method: method})
	if err != nil {
		t.Fatal(err, c.output.String())
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	response.Header.Del("Date")
	x := dispatchResult{status: response.StatusCode, header: response.Header, body: string(body)}
	select {
	case c := <-calls:
		<-c.done
		x.queued, x.kind, x.viewer, x.limit, x.offset, x.slug, x.filter = true, c.kind, c.viewer, c.limit, c.offset, c.slug, c.filter
		select {
		case <-c.ctx.Done():
		default:
			t.Fatal("request context survived the response")
		}
	default:
	}
	return x
}

func TestCompactAPIDispatchDifferential(t *testing.T) {
	oldUser := userReadBatching
	userReadBatching = true
	t.Cleanup(func() { userReadBatching = oldUser })
	oldHot, oldDirect, oldPrefix := compactHTTPHotPath, compactAPIReads, compactPrefixResponses
	compactHTTPHotPath = true
	t.Cleanup(func() { compactHTTPHotPath, compactAPIReads, compactPrefixResponses = oldHot, oldDirect, oldPrefix })
	a, calls := fakeDispatchApp(t)
	token := a.issueToken(7)
	paths := []string{"/api/user", "/api/user?limit=0", "/api/user?ignored=%ZZ", "/api/user/", "/api/tags", "/api/articles", "/api/articles?", "/api/articles/feed", "/api/articles/a-title-1", "/api/articles/a-title-1/comments", "/api/articles/feed/comments", "/api/profiles/a_user",
		"/api/articles?limit=100&offset=1001", "/api/articles?limit=0", "/api/articles?limit=", "/api/articles?limit=-1", "/api/articles?offset=9223372036854775808",
		"/api/articles?tag=go&author=someone&favorited=reader", "/api/articles?tag=&tag=go&author=someone", "/api/articles?favorited=reader", "/api/articles?limit=20&limit=0", "/api/articles?tag=a+b", "/api/articles?limit=%ZZ&offset=2", "/api/articles?tag=a;b&limit=10",
		"/api/articles/feed?limit=0", "/api/articles/feed?offset=3&tag=ignored", "/api/tags?limit=0", "/api/profiles/a_user?ignored=x",
		"/api/articles/", "/api/articles/a/comments/", "/api/articles/a/other", "/api/articles/../tags", "/api//tags", "/api/articles/%61", "/api/profiles/%CE%BB", "/unknown"}
	for _, prefix := range []bool{false, true} {
		compactPrefixResponses = prefix
		for _, uri := range paths {
			for _, auth := range []string{"", "Authorization:\r\n", "Authorization: Token invalid\r\n", "Authorization: Token " + token + "\r\n"} {
				wire := "GET " + uri + " HTTP/1.1\r\nHost: test\r\n" + auth + "Connection: close\r\n\r\n"
				want := runDispatch(t, a, calls, wire, false, 0)
				got := runDispatch(t, a, calls, wire, true, 0)
				if !reflect.DeepEqual(got, want) {
					t.Fatalf("uri=%s auth=%q prefix=%v\ngot %+v\nwant %+v", uri, auth, prefix, got, want)
				}
			}
		}
	}
	for _, wire := range []string{
		"HEAD /api/tags HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n",
		"POST /api/users HTTP/1.1\r\nHost: test\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
		"GET /api/tags HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n1\r\nx\r\n0\r\n\r\n",
		"GET /api/tags HTTP/1.1\r\nHost: test\r\nX-Other: value\r\nConnection: close\r\n\r\n",
	} {
		for _, fragment := range []int{0, 1} {
			want := runDispatch(t, a, calls, wire, false, fragment)
			got := runDispatch(t, a, calls, wire, true, fragment)
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("general fallback changed for %q", wire)
			}
		}
	}
}

func TestCompactAPIReadOwnership(t *testing.T) {
	for _, pooled := range []bool{false, true} {
		t.Run(fmt.Sprintf("pooled=%v", pooled), func(t *testing.T) { testCompactAPIReadOwnership(t, pooled) })
	}
}

func TestCompactCurrentUserOwnershipAndAuth(t *testing.T) {
	oldHot, oldDirect, oldUser := compactHTTPHotPath, compactAPIReads, userReadBatching
	compactHTTPHotPath, compactAPIReads, userReadBatching = true, true, true
	t.Cleanup(func() { compactHTTPHotPath, compactAPIReads, userReadBatching = oldHot, oldDirect, oldUser })
	for _, pooled := range []bool{false, true} {
		t.Run(fmt.Sprint(pooled), func(t *testing.T) {
			a, calls := fakeDispatchApp(t)
			sign := func(expires int64, nonce string) string {
				payload := fmt.Sprintf(`{"sub":"7","exp":%d,"nonce":%q}`, expires, nonce)
				message := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`)) + "." + base64.RawURLEncoding.EncodeToString([]byte(payload))
				mac := hmac.New(sha256.New, []byte(dispatchTestSecret))
				_, _ = mac.Write([]byte(message))
				return message + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
			}
			first, second := sign(time.Now().Unix()+60, "first"), sign(time.Now().Unix()+60, "second")
			parts := strings.Split(first, ".")
			parts[1] = base64.RawURLEncoding.EncodeToString([]byte(`{"sub":"8","exp":9999999999}`))
			tampered := strings.Join(parts, ".")
			headers := []string{"Token " + first, "Token " + second, "Token " + tampered, "Token " + sign(time.Now().Unix()-60, "expired"), ""}
			var wire strings.Builder
			for i, header := range headers {
				wire.WriteString("GET /api/user HTTP/1.1\r\nHost: test\r\nAuthorization: " + header + "\r\n")
				if i == len(headers)-1 {
					wire.WriteString("Connection: close\r\n")
				}
				wire.WriteString("\r\n")
			}
			c := &bufferedTestConn{input: bytes.NewReader([]byte(wire.String()))}
			s := newCompactSession(c)
			s.pooled = pooled
			handler := &apiRoutes{app: a} // Any general-handler fallback fails.
			for i := range headers {
				if keep := s.serveOne(context.Background(), handler); keep != (i < len(headers)-1) {
					t.Fatalf("request %d keep-alive=%v", i, keep)
				}
			}
			reader := bufio.NewReader(bytes.NewReader(c.output.Bytes()))
			for i := range headers {
				response, err := http.ReadResponse(reader, &http.Request{Method: "GET"})
				if err != nil {
					t.Fatal(err)
				}
				_, err = io.Copy(io.Discard, response.Body)
				response.Body.Close()
				want := 401
				if i < 2 {
					want = 200
				}
				if err != nil || response.StatusCode != want {
					t.Fatalf("request %d status=%d err=%v", i, response.StatusCode, err)
				}
			}
			left, right := <-calls, <-calls
			<-left.done
			<-right.done
			if left.viewer != 7 || right.viewer != 7 || left.kind != readUser || right.kind != readUser || left.filter != first || right.filter != second {
				t.Fatal("current-user requests lost their independent tokens")
			}
			select {
			case <-calls:
				t.Fatal("invalid authentication reached the read queue")
			default:
			}
			// Overwrite connection-reader storage after both callers canceled.
			c.input = bytes.NewReader([]byte("GET /api/articles/" + strings.Repeat("x", 600) + " HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n"))
			s.serveOne(context.Background(), handler)
			last := <-calls
			<-last.done
			if left.filter != first || right.filter != second {
				t.Fatal("tokens borrowed reader storage")
			}
		})
	}
}

func testCompactAPIReadOwnership(t *testing.T, pooled bool) {
	oldHot, oldDirect := compactHTTPHotPath, compactAPIReads
	compactHTTPHotPath, compactAPIReads = true, true
	t.Cleanup(func() { compactHTTPHotPath, compactAPIReads = oldHot, oldDirect })
	a, calls := fakeDispatchApp(t)
	wire := "GET /api/articles/first HTTP/1.1\r\nHost: test\r\n\r\nGET /api/articles?tag=second HTTP/1.1\r\nHost: test\r\n\r\n"
	c := &bufferedTestConn{input: bytes.NewReader([]byte(wire))}
	s := newCompactSession(c)
	s.pooled = pooled
	// A nil fallback mux makes accidental use of the generic handler fail.
	handler := &apiRoutes{app: a}
	for range 2 {
		if !s.serveOne(context.Background(), handler) {
			t.Fatal("keep-alive request stopped")
		}
	}
	first, second := <-calls, <-calls
	<-first.done
	<-second.done
	for _, c := range []*queuedRead{first, second} {
		select {
		case <-c.ctx.Done():
		default:
			t.Fatal("context not canceled")
		}
	}
	// Refill and overwrite the same connection-reader storage.
	c.input = bytes.NewReader([]byte("GET /api/articles/" + strings.Repeat("x", 600) + " HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n"))
	s.serveOne(context.Background(), handler)
	last := <-calls
	<-last.done
	if first.slug != "first" || second.filter != "second" || len(last.slug) != 600 {
		t.Fatal("queued request borrowed reader storage")
	}
}

func TestCompactAPIReadCancellation(t *testing.T) {
	a := &app{reads: &readQueue{ctx: context.Background(), pending: make(chan *queuedRead)}}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		a.serveCompactRead(ctx, &compactResponse{connection: &bufferedTestConn{}, header: make(http.Header)}, compactReadPlan{kind: readTags}, "")
	}()
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("read admission did not cancel")
	}
}

func FuzzCompactAPIRead(f *testing.F) {
	for _, uri := range []string{"/api/tags", "/api/articles?limit=20&tag=go", "/api/articles/feed?limit=0", "/api/articles/a/comments", "/api/profiles/a", "/api/articles/../tags", "/api/articles?tag=&tag=x&author=y", "/api/articles?limit=%ZZ&offset=2"} {
		f.Add(uri, "")
		f.Add(uri, "Token invalid")
	}
	f.Fuzz(func(t *testing.T, uri, auth string) {
		if len(uri)+len(auth) > 512 || strings.ContainsAny(uri+auth, "\r\n") {
			t.Skip()
		}
		oldHot, oldDirect := compactHTTPHotPath, compactAPIReads
		compactHTTPHotPath = true
		t.Cleanup(func() { compactHTTPHotPath, compactAPIReads = oldHot, oldDirect })
		a, calls := fakeDispatchApp(t)
		wire := "GET " + uri + " HTTP/1.1\r\nHost: test\r\nAuthorization: " + auth + "\r\nConnection: close\r\n\r\n"
		want := runDispatch(t, a, calls, wire, false, 0)
		got := runDispatch(t, a, calls, wire, true, 0)
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("differential failure uri=%q auth=%q\ngot %+v\nwant %+v", uri, auth, got, want)
		}
	})
}

func BenchmarkCompactAPIDispatch(b *testing.B) {
	a := &app{reads: &readQueue{}}
	data := []byte("GET /api/articles/a-title-1/comments HTTP/1.1\r\nHost: test\r\nAuthorization: Token token\r\nUser-Agent: loadgen\r\n\r\n")
	for _, direct := range []bool{false, true} {
		b.Run(fmt.Sprint(direct), func(b *testing.B) {
			b.ReportAllocs()
			for b.Loop() {
				if direct {
					spec, ok := parseBufferedGET(data)
					if !ok {
						b.Fatal("parse")
					}
					owned := string(data[:spec.end+4])
					p, ok := a.planCompactRead(owned[4:spec.uriEnd])
					if !ok {
						b.Fatal("route")
					}
					dispatchBenchmarkString = p.arg
				} else {
					r, _ := bufferedGET(data)
					dispatchBenchmarkRequest = r
				}
			}
		})
	}
}

var dispatchBenchmarkString string
var dispatchBenchmarkRequest *http.Request

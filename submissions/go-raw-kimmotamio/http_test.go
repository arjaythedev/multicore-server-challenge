package main

import "testing"

func TestParseRequestEdgeCases(t *testing.T) {
	var r request
	// No headers at all must not panic.
	n, ok, err := parseRequest([]byte("GET /api/tags HTTP/1.1\r\n\r\n"), &r)
	if err != nil || !ok || n != 26 || r.method != "GET" || r.path != "/api/tags" {
		t.Fatalf("no headers: n=%d ok=%v err=%v %+v", n, ok, err, r)
	}
	// Leading empty lines are skipped and counted as consumed.
	n, ok, err = parseRequest([]byte("\r\nGET /x HTTP/1.1\r\nHost: a\r\n\r\n"), &r)
	if err != nil || !ok || n != 30 || r.path != "/x" {
		t.Fatalf("leading CRLF: n=%d ok=%v err=%v %+v", n, ok, err, r)
	}
	// An empty Authorization header is present (invalid), not absent.
	_, ok, _ = parseRequest([]byte("GET /x HTTP/1.1\r\nAuthorization: \r\n\r\n"), &r)
	if !ok || r.auth == nil || len(r.auth) != 0 {
		t.Fatalf("empty auth: ok=%v auth=%q", ok, r.auth)
	}
	// Body framing with pipelined requests.
	b := []byte("POST /x HTTP/1.1\r\nContent-Length: 2\r\n\r\nhiGET /y HTTP/1.1\r\n\r\n")
	n, ok, err = parseRequest(b, &r)
	if err != nil || !ok || string(r.body) != "hi" {
		t.Fatalf("body: n=%d ok=%v err=%v body=%q", n, ok, err, r.body)
	}
	if _, ok, _ = parseRequest(b[n:], &r); !ok || r.path != "/y" {
		t.Fatalf("pipelined second request: ok=%v %+v", ok, r)
	}
}

func TestParseUint(t *testing.T) {
	for _, s := range []string{"9223372036854775807", "0", "42"} {
		if _, ok := parseUint(s); !ok {
			t.Errorf("%s should parse", s)
		}
	}
	for _, s := range []string{"9223372036854775808", "9999999999999999999", "", "-1", "1x", "12345678901234567890"} {
		if _, ok := parseUint(s); ok {
			t.Errorf("%s should be rejected", s)
		}
	}
}

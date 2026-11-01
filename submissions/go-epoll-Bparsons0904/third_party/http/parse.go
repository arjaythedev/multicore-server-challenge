package http

import "bytes"

const (
	// MaxHeaderBytes bounds the request line and headers (431 beyond).
	MaxHeaderBytes = 64 << 10
	// MaxBodyBytes bounds the request body (413 beyond).
	MaxBodyBytes = 1 << 20
)

var crlf2 = []byte("\r\n\r\n")

// parseRequest parses the request at the start of b into r without copying:
// r's slices point into b. It reads only the method, target, Host,
// Authorization, Content-Length, Connection and Expect, and rejects
// Transfer-Encoding. Like net/http it rejects (400) a method or header name
// that is not a token, control characters in the target or a header value
// (other than tab), and an HTTP/1.1 request without exactly one Host.
//
// It returns the request's length in bytes. When b holds only part of the
// request it returns 0 and need, the request's full length once its headers
// are in (0 before). A non-zero status means the request is rejected with it.
//
// from is how far an earlier call already searched b for the end of the
// headers: a slow sender costs one pass over its bytes, not one per read.
func parseRequest(b []byte, r *Request, from int) (n, need, status int) {
	r.expect = false
	from = max(from-3, 0)
	end := bytes.Index(b[from:], crlf2)
	if end >= 0 {
		end += from
	}
	if end < 0 {
		if len(b) >= MaxHeaderBytes {
			return 0, 0, 431
		}
		return 0, 0, 0
	}
	if end+4 > MaxHeaderBytes {
		return 0, 0, 431
	}
	head := b[:end+2] // every line, the last one included, ends with \r\n

	eol := bytes.IndexByte(head, '\n')
	if eol < 1 || head[eol-1] != '\r' {
		return 0, 0, 400
	}
	line := head[:eol-1]
	sp := bytes.IndexByte(line, ' ')
	if sp <= 0 {
		return 0, 0, 400
	}
	r.Method = line[:sp:sp]
	if !isToken(r.Method) {
		return 0, 0, 400
	}
	line = line[sp+1:]
	sp = bytes.IndexByte(line, ' ')
	if sp <= 0 || line[0] != '/' {
		return 0, 0, 400
	}
	target, proto := line[:sp:sp], line[sp+1:]
	if hasCTL(target) {
		return 0, 0, 400
	}
	if len(proto) != 8 || string(proto[:7]) != "HTTP/1." {
		return 0, 0, 400
	}
	switch proto[7] {
	case '1':
		r.http10 = false
	case '0':
		r.http10 = true
	default:
		return 0, 0, 400
	}
	r.Path, r.Query = target, nil
	if q := bytes.IndexByte(target, '?'); q >= 0 {
		r.Path, r.Query = target[:q:q], target[q+1:]
	}
	r.head = string(r.Method) == "HEAD"
	r.Auth, r.Body = nil, nil

	length, hosts := -1, 0
	closing, keepAlive := false, false
	for pos := eol + 1; pos < len(head); {
		e := pos + bytes.IndexByte(head[pos:], '\n')
		if e == pos || head[e-1] != '\r' {
			return 0, 0, 400
		}
		h := head[pos : e-1]
		pos = e + 1
		colon := bytes.IndexByte(h, ':')
		// No whitespace around the name: that also rejects obsolete line folding.
		if colon <= 0 || !isToken(h[:colon]) {
			return 0, 0, 400
		}
		name, value := h[:colon], trimSpace(h[colon+1:])
		if hasCTL(value) {
			return 0, 0, 400
		}
		switch len(name) {
		case 4:
			if equalFold(name, "host") {
				hosts++
			}
		case 6:
			if equalFold(name, "expect") {
				r.expect = equalFold(value, "100-continue")
			}
		case 10:
			if equalFold(name, "connection") {
				c, k := connectionTokens(value)
				closing, keepAlive = closing || c, keepAlive || k
			}
		case 13:
			if r.Auth == nil && equalFold(name, "authorization") {
				r.Auth = value[:len(value):len(value)]
			}
		case 14:
			if equalFold(name, "content-length") {
				l, st := parseLength(value)
				if st != 0 {
					return 0, 0, st
				}
				if length >= 0 && l != length {
					return 0, 0, 400
				}
				length = l
			}
		case 17:
			if equalFold(name, "transfer-encoding") {
				return 0, 0, 411
			}
		}
	}
	if hosts > 1 || hosts == 0 && !r.http10 {
		return 0, 0, 400
	}
	r.keepAlive = !closing && (!r.http10 || keepAlive)

	start := end + 4
	total := start + max(length, 0)
	if len(b) < total {
		return 0, total, 0
	}
	if total > start {
		r.Body = b[start:total:total]
	}
	return total, 0, 0
}

func parseLength(v []byte) (int, int) {
	if len(v) == 0 {
		return 0, 400
	}
	n := 0
	for _, c := range v {
		if c < '0' || c > '9' {
			return 0, 400
		}
		n = n*10 + int(c-'0')
		if n > MaxBodyBytes {
			return 0, 413
		}
	}
	return n, 0
}

// connectionTokens reports whether a Connection header value lists close and keep-alive.
func connectionTokens(v []byte) (closing, keepAlive bool) {
	for len(v) > 0 {
		tok := v
		if i := bytes.IndexByte(v, ','); i >= 0 {
			tok, v = v[:i], v[i+1:]
		} else {
			v = nil
		}
		tok = trimSpace(tok)
		closing = closing || equalFold(tok, "close")
		keepAlive = keepAlive || equalFold(tok, "keep-alive")
	}
	return closing, keepAlive
}

// equalFold compares b with lower, which must be lower case, ignoring ASCII case.
func equalFold(b []byte, lower string) bool {
	if len(b) != len(lower) {
		return false
	}
	for i := 0; i < len(b); i++ {
		c := b[i]
		if 'A' <= c && c <= 'Z' {
			c += 'a' - 'A'
		}
		if c != lower[i] {
			return false
		}
	}
	return true
}

// isSpace is optional whitespace, trimmed from header values. A CR is not: a
// value ending in one is rejected, as net/http does.
func isSpace(c byte) bool { return c == ' ' || c == '\t' }

func trimSpace(b []byte) []byte {
	for len(b) > 0 && isSpace(b[0]) {
		b = b[1:]
	}
	for len(b) > 0 && isSpace(b[len(b)-1]) {
		b = b[:len(b)-1]
	}
	return b
}

// tokenChars marks the bytes of an HTTP token (RFC 9110): method and header
// names.
var tokenChars = func() (t [256]bool) {
	for c := '0'; c <= '9'; c++ {
		t[c] = true
	}
	for c := 'a'; c <= 'z'; c++ {
		t[c], t[c-'a'+'A'] = true, true
	}
	for _, c := range "!#$%&'*+-.^_`|~" {
		t[c] = true
	}
	return t
}()

func isToken(b []byte) bool {
	for _, c := range b {
		if !tokenChars[c] {
			return false
		}
	}
	return len(b) > 0
}

// hasCTL reports whether b has a control character other than tab: a byte
// below 0x20, or 0x7f. Eight bytes at a time.
func hasCTL(b []byte) bool {
	const lsb, msb = 0x0101010101010101, 0x8080808080808080
	i := 0
	for ; i+8 <= len(b); i += 8 {
		x := uint64(b[i]) | uint64(b[i+1])<<8 | uint64(b[i+2])<<16 | uint64(b[i+3])<<24 |
			uint64(b[i+4])<<32 | uint64(b[i+5])<<40 | uint64(b[i+6])<<48 | uint64(b[i+7])<<56
		low := (x - lsb*0x20) &^ x // high bit set: byte < 0x20
		t := x ^ lsb*'\t'
		tab := (t - lsb) &^ t // high bit set: byte == '\t'
		d := x ^ lsb*0x7f
		del := (d - lsb) &^ d // high bit set: byte == 0x7f
		if (low&^tab|del)&msb != 0 {
			// The borrow trick can flag a byte above a true match; check exactly.
			if ctlIn(b[i : i+8]) {
				return true
			}
		}
	}
	return ctlIn(b[i:])
}

func ctlIn(b []byte) bool {
	for _, c := range b {
		if c < 0x20 && c != '\t' || c == 0x7f {
			return true
		}
	}
	return false
}

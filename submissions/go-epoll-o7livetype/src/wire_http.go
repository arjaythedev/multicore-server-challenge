package main

// wire_http.go parses and writes HTTP/1.1 on raw bytes for the event loops.
// parseWire finds one complete request at the start of a buffer (request line,
// headers, Content-Length or chunked body) without copying; it rejects anything
// ambiguous (duplicate lengths, both length and chunked, bad characters). It
// returns the request's length, 0 if more bytes are needed, or minus the status
// to answer (400, 413, 417). appendResponseHeader writes a response header.

import (
	"bytes"
	"net/http"
	"strconv"
	"time"
)

const (
	maxHeaderBytes = 16 << 10
	maxBodyBytes   = 1 << 20
	// Independently bound chunk extensions, trailers and pipelined lookahead.
	maxWireBytes    = maxHeaderBytes + maxBodyBytes + (64 << 10)
	smallInputBytes = 16 << 10
)

type wireRequest struct {
	method, target, auth, body                        []byte
	authCount                                         int
	close, head, http10, expect, chunked, headerReady bool
}

func asciiEqual(a []byte, b string) bool {
	if len(a) != len(b) {
		return false
	}
	for i, c := range a {
		if c >= 'A' && c <= 'Z' {
			c += 32
		}
		d := b[i]
		if d >= 'A' && d <= 'Z' {
			d += 32
		}
		if c != d {
			return false
		}
	}
	return true
}
func headerToken(b []byte, t string) bool {
	for {
		part, rest, ok := bytes.Cut(b, []byte(","))
		if asciiEqual(bytes.Trim(part, " \t"), t) {
			return true
		}
		if !ok {
			return false
		}
		b = rest
	}
}
func tokenByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || bytes.IndexByte([]byte("!#$%&'*+-.^_`|~"), c) >= 0
}
func hexByte(c byte) int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'f':
		return int(c-'a') + 10
	case c >= 'A' && c <= 'F':
		return int(c-'A') + 10
	}
	return -1
}

// Positive: complete frame bytes; zero: incomplete; negative: HTTP error status.
// Parsing never modifies input. Chunk decoding only happens after job ownership.
func parseWire(b []byte, r *wireRequest) int {
	*r = wireRequest{}
	end := bytes.Index(b, []byte("\r\n\r\n"))
	if end < 0 {
		if len(b) >= maxHeaderBytes {
			return -400
		}
		return 0
	}
	headerEnd := end + 4
	if headerEnd > maxHeaderBytes {
		return -400
	}
	nl := bytes.Index(b[:headerEnd], []byte("\r\n"))
	if nl < 0 {
		return -400
	}
	line := b[:nl]
	i := bytes.IndexByte(line, ' ')
	if i <= 0 {
		return -400
	}
	r.method = line[:i]
	for _, c := range r.method {
		if !tokenByte(c) {
			return -400
		}
	}
	line = line[i+1:]
	i = bytes.IndexByte(line, ' ')
	if i <= 0 {
		return -400
	}
	r.target = line[:i]
	if r.target[0] != '/' {
		return -400
	}
	for i := 0; i < len(r.target); i++ {
		c := r.target[i]
		if c <= 32 || c == 127 || c == '#' {
			return -400
		}
		if c == '%' {
			if i+2 >= len(r.target) || hexByte(r.target[i+1]) < 0 || hexByte(r.target[i+2]) < 0 {
				return -400
			}
			i += 2
		}
	}
	switch string(line[i+1:]) {
	case "HTTP/1.0":
		r.http10 = true
		r.close = true
	case "HTTP/1.1":
	default:
		return -400
	}
	r.head = string(r.method) == "HEAD"
	length, cl, te, host := 0, false, false, 0
	closing := false
	for pos := nl + 2; pos < end; {
		n := bytes.Index(b[pos:headerEnd], []byte("\r\n"))
		if n < 0 {
			return -400
		}
		h := b[pos : pos+n]
		pos += n + 2
		k := bytes.IndexByte(h, ':')
		if k <= 0 {
			return -400
		}
		name := h[:k]
		for _, c := range name {
			if !tokenByte(c) {
				return -400
			}
		}
		value := bytes.Trim(h[k+1:], " \t")
		for _, c := range value {
			if c < 32 && c != '\t' || c == 127 {
				return -400
			}
		}
		switch {
		case asciiEqual(name, "host"):
			host++
			if host > 1 || len(value) == 0 {
				return -400
			}
		case asciiEqual(name, "content-length"):
			if cl || len(value) == 0 {
				return -400
			}
			cl = true
			for _, c := range value {
				if c < '0' || c > '9' {
					return -400
				}
				if length > maxBodyBytes/10 {
					return -413
				}
				length = length*10 + int(c-'0')
				if length > maxBodyBytes {
					return -413
				}
			}
		case asciiEqual(name, "transfer-encoding"):
			if te || !asciiEqual(value, "chunked") {
				return -400
			}
			te = true
			r.chunked = true
		case asciiEqual(name, "authorization"):
			r.authCount++
			r.auth = value
		case asciiEqual(name, "connection"):
			if headerToken(value, "close") {
				closing = true
				r.close = true
			} else if !closing && headerToken(value, "keep-alive") {
				r.close = false
			}
		case asciiEqual(name, "expect"):
			if !asciiEqual(value, "100-continue") {
				return -417
			}
			r.expect = true
		}
	}
	if !r.http10 && host != 1 || cl && te {
		return -400
	}
	r.headerReady = true
	if te {
		n := scanChunks(b, headerEnd)
		if n > 0 {
			r.body = b[headerEnd:n]
		}
		return n
	}
	if len(b) < headerEnd+length {
		return 0
	}
	r.body = b[headerEnd : headerEnd+length]
	return headerEnd + length
}
func scanChunks(b []byte, pos int) int {
	total := 0
	for {
		if pos > len(b) {
			return 0
		}
		i := bytes.Index(b[pos:], []byte("\r\n"))
		if i < 0 {
			if len(b)-pos > 1024 {
				return -400
			}
			return 0
		}
		line := b[pos : pos+i]
		if len(line) > 1024 {
			return -400
		}
		if ext := bytes.IndexByte(line, ';'); ext >= 0 {
			for _, c := range line[ext+1:] {
				if c < 32 && c != '\t' || c == 127 {
					return -400
				}
			}
			line = line[:ext]
		}
		if len(line) == 0 || len(line) > 8 {
			return -400
		}
		n := 0
		for _, c := range line {
			v := hexByte(c)
			if v < 0 {
				return -400
			}
			n = n*16 + v
			if n > maxBodyBytes {
				return -413
			}
		}
		pos += i + 2
		if n == 0 {
			trailerStart := pos
			for {
				i = bytes.Index(b[pos:], []byte("\r\n"))
				if i < 0 {
					if len(b)-trailerStart > maxHeaderBytes {
						return -400
					}
					return 0
				}
				if pos-trailerStart+i > maxHeaderBytes {
					return -400
				}
				if i == 0 {
					return pos + 2
				}
				h := b[pos : pos+i]
				k := bytes.IndexByte(h, ':')
				if k < 1 {
					return -400
				}
				for _, c := range h[:k] {
					if !tokenByte(c) {
						return -400
					}
				}
				for _, c := range h[k+1:] {
					if c < 32 && c != '\t' || c == 127 {
						return -400
					}
				}
				name := h[:k]
				if asciiEqual(name, "content-length") || asciiEqual(name, "transfer-encoding") || asciiEqual(name, "authorization") || asciiEqual(name, "host") {
					return -400
				}
				pos += i + 2
			}
		}
		total += n
		if total > maxBodyBytes {
			return -413
		}
		if pos+n+2 > len(b) {
			return 0
		}
		if b[pos+n] != '\r' || b[pos+n+1] != '\n' {
			return -400
		}
		pos += n + 2
	}
}
func decodeChunks(b []byte) []byte {
	pos, out := 0, 0
	for {
		i := bytes.Index(b[pos:], []byte("\r\n"))
		line := b[pos : pos+i]
		if ext := bytes.IndexByte(line, ';'); ext >= 0 {
			line = line[:ext]
		}
		n := 0
		for _, c := range line {
			n = n*16 + hexByte(c)
		}
		if n == 0 {
			return b[:out]
		}
		pos += i + 2
		copy(b[out:], b[pos:pos+n])
		out += n
		pos += n + 2
	}
}
func appendResponseHeader(b []byte, w *response, close, http10 bool) []byte {
	if w.status == 0 {
		w.status = 200
	}
	status := http.StatusText(w.status)
	if status == "" {
		w.status = 500
		status = "Internal Server Error"
	}
	if w.status == 204 || w.status == 304 {
		w.body = nil
	}
	if http10 {
		b = append(b, "HTTP/1.0 "...)
	} else {
		b = append(b, "HTTP/1.1 "...)
	}
	b = strconv.AppendInt(b, int64(w.status), 10)
	b = append(b, ' ')
	b = append(b, status...)
	b = append(b, "\r\nContent-Type: application/json"...)
	if w.status != 204 && w.status != 304 {
		b = append(b, "\r\nContent-Length: "...)
		b = strconv.AppendInt(b, int64(len(w.body)), 10)
	}
	b = append(b, "\r\nDate: "...)
	b = time.Now().UTC().AppendFormat(b, http.TimeFormat)
	if close {
		b = append(b, "\r\nConnection: close"...)
	} else if http10 {
		b = append(b, "\r\nConnection: keep-alive"...)
	}
	return append(b, "\r\n\r\n"...)
}

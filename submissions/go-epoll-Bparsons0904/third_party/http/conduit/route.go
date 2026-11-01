package conduit

import "bytes"

// Routing follows the reference's ServeMux (Go 1.22+ patterns, a JSON 404 for
// "/"). net/http first unescapes the target's path; if that fails the request
// is a 400. The mux then matches segments of the escaped path, each
// unescaped on its own, so "%2F" inside a parameter is part of it. The escaped
// path is the target as sent when it is a valid encoding, and otherwise the
// unescaped path escaped again, where a "%2F" has become a separator. GET
// patterns match HEAD too.
//
// One difference, an accepted gap (REFERENCE-QUIRKS, accepted differences):
// the mux redirects (307) a path with empty, "." or ".." segments, "//"
// included, to its cleaned form; that is a 404 here. Clients are not
// expected to send such paths.

// segment is a path segment, still percent-encoded if enc.
type segment struct {
	b   []byte
	enc bool
}

// is reports whether s unescapes to lit.
func (s segment) is(lit string) bool {
	if !s.enc || bytes.IndexByte(s.b, '%') < 0 {
		return string(s.b) == lit
	}
	if len(s.b) > 3*len(lit) {
		return false
	}
	var buf [3 * 16]byte
	return string(pathDecode(buf[:0], s.b)) == lit
}

// uint parses the segment as the reference parses a comment id.
func (s segment) uint() (int64, bool) {
	if s.enc {
		return digitsOf(s.b, false)
	}
	return parseUint(s.b)
}

// decode copies the unescaped segment into op.
func (s segment) decode(op store) []byte {
	if !s.enc || bytes.IndexByte(s.b, '%') < 0 {
		return op.Keep(s.b)
	}
	return pathDecode(op.Alloc(len(s.b) - 2*bytes.Count(s.b, []byte("%")))[:0], s.b)
}

// route matches method and path, and sets r.ep and the path parameters.
func (r *request) route(method, path []byte) bool {
	var segs [5]segment
	n, ok := split(path, &segs)
	if !ok || !segs[0].is("api") {
		return false
	}
	get := string(method) == "GET" || string(method) == "HEAD"
	post, put, del := string(method) == "POST", string(method) == "PUT", string(method) == "DELETE"
	s1 := segs[1]
	switch n {
	case 2:
		switch {
		case s1.is("tags"):
			r.ep = pick(get, Tags)
		case s1.is("user"):
			r.ep = pick(get, GetUser) | pick(put, UpdateUser)
		case s1.is("users"):
			r.ep = pick(post, Register)
		case s1.is("articles"):
			r.ep = pick(get, ListArticles) | pick(post, CreateArticle)
		}
	case 3:
		r.param = segs[2]
		switch {
		case s1.is("users"):
			r.ep = pick(post && segs[2].is("login"), Login)
		case s1.is("profiles"):
			r.ep = pick(get, GetProfile)
		case s1.is("articles"):
			// The literal "feed" wins over {slug}, for GET only.
			if get && segs[2].is("feed") {
				r.ep = Feed
			} else {
				r.ep = pick(get, GetArticle) | pick(put, UpdateArticle) | pick(del, DeleteArticle)
			}
		}
	case 4:
		r.param = segs[2]
		s3 := segs[3]
		switch {
		case s1.is("profiles") && s3.is("follow"):
			r.ep = pick(post, Follow) | pick(del, Unfollow)
		case s1.is("articles") && s3.is("favorite"):
			r.ep = pick(post, Favorite) | pick(del, Unfavorite)
		case s1.is("articles") && s3.is("comments"):
			r.ep = pick(get, ListComments) | pick(post, CreateComment)
		}
	case 5:
		if del && s1.is("articles") && segs[3].is("comments") {
			r.ep, r.param, r.idSeg = DeleteComment, segs[2], segs[4]
		}
	}
	return r.ep != 0
}

func pick(ok bool, e Endpoint) Endpoint {
	if ok {
		return e
	}
	return 0
}

// split cuts path into segments. It fails for more than len(segs) segments
// and for an empty, "." or ".." segment, a trailing slash included.
func split(path []byte, segs *[5]segment) (int, bool) {
	enc := validEncoded(path)
	if !enc {
		// The mux sees the unescaped path escaped again: split that.
		path = pathDecode(make([]byte, 0, len(path)), path)
	}
	p := path[1:]
	n := 0
	for {
		s := p
		j := bytes.IndexByte(p, '/')
		if j >= 0 {
			s = p[:j]
		}
		if len(s) == 0 || string(s) == "." || string(s) == ".." || n == len(segs) {
			return 0, false
		}
		segs[n] = segment{s, enc}
		n++
		if j < 0 {
			return n, true
		}
		p = p[j+1:]
	}
}

// validEncoded reports whether net/url keeps the path as sent for
// EscapedPath: only characters that need no escaping in a path, sub-delims,
// ':', '@', '[', ']' and '%'.
func validEncoded(p []byte) bool {
	for _, c := range p {
		if 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || '0' <= c && c <= '9' {
			continue
		}
		switch c {
		case '-', '_', '.', '~', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', ':', '@', '[', ']', '%', '/':
		default:
			return false
		}
	}
	return true
}

// hasCTL reports whether b holds an ASCII control character, which net/url
// rejects anywhere in a request target.
func hasCTL(b []byte) bool {
	for _, c := range b {
		if c < ' ' || c == 0x7f {
			return true
		}
	}
	return false
}

// escapesOK reports whether every '%' in b starts a valid escape.
func escapesOK(b []byte) bool {
	for i := bytes.IndexByte(b, '%'); i >= 0; {
		if i+2 >= len(b) || !isHex(b[i+1]) || !isHex(b[i+2]) {
			return false
		}
		j := bytes.IndexByte(b[i+3:], '%')
		if j < 0 {
			return true
		}
		i += 3 + j
	}
	return true
}

func isHex(c byte) bool { return '0' <= c && c <= '9' || 'a' <= c && c <= 'f' || 'A' <= c && c <= 'F' }

func unhex(c byte) byte {
	switch {
	case c <= '9':
		return c - '0'
	case c <= 'F':
		return c - 'A' + 10
	default:
		return c - 'a' + 10
	}
}

// pathDecode appends s with its (valid) escapes decoded.
func pathDecode(dst, s []byte) []byte {
	for i := 0; i < len(s); i++ {
		if c := s[i]; c == '%' {
			dst = append(dst, unhex(s[i+1])<<4|unhex(s[i+2]))
			i += 2
		} else {
			dst = append(dst, c)
		}
	}
	return dst
}

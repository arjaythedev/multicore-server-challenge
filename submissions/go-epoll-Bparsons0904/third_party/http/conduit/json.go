package conduit

import (
	"bytes"
	"strings"
	"unicode/utf16"
	"unicode/utf8"
	"unsafe"
)

// This file reads JSON the way encoding/json's Unmarshal does in Go 1.27 (the
// v2 engine with the v1 options): RFC 8259 syntax, at most 10000 levels of
// nesting, invalid UTF-8 accepted and replaced by U+FFFD byte by byte, lone or
// mismatched surrogate escapes replaced by U+FFFD, and duplicate names allowed
// (the last one wins). validJSON checks a document once; everything else
// assumes a valid one.

const maxDepth = 10000

func isWS(c byte) bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' }

func skipWS(b []byte, i int) int {
	for i < len(b) && isWS(b[i]) {
		i++
	}
	return i
}

// validJSON reports whether b holds exactly one JSON value, with optional
// whitespace around it.
func validJSON(b []byte) bool {
	var objs [maxDepth/64 + 1]uint64 // bit d: the container at depth d is an object
	depth := 0
	i := skipWS(b, 0)
	for {
		// A value starts at i.
		if i >= len(b) {
			return false
		}
		switch c := b[i]; c {
		case '{', '[':
			if depth == maxDepth {
				return false
			}
			obj := c == '{'
			if obj {
				objs[depth>>6] |= 1 << (depth & 63)
			} else {
				objs[depth>>6] &^= 1 << (depth & 63)
			}
			depth++
			i = skipWS(b, i+1)
			if i < len(b) && (obj && b[i] == '}' || !obj && b[i] == ']') {
				depth--
				i++
				break // an empty container is a complete value
			}
			if obj {
				if i = scanName(b, i); i < 0 {
					return false
				}
			}
			continue
		case '"':
			if i = scanString(b, i); i < 0 {
				return false
			}
		case 't':
			if i = scanLiteral(b, i, "true"); i < 0 {
				return false
			}
		case 'f':
			if i = scanLiteral(b, i, "false"); i < 0 {
				return false
			}
		case 'n':
			if i = scanLiteral(b, i, "null"); i < 0 {
				return false
			}
		default:
			if i = scanNumber(b, i); i < 0 {
				return false
			}
		}
		// A value ended at i: close containers until one continues.
		for {
			i = skipWS(b, i)
			if depth == 0 {
				return i == len(b)
			}
			if i >= len(b) {
				return false
			}
			obj := objs[(depth-1)>>6]&(1<<((depth-1)&63)) != 0
			c := b[i]
			if c == ',' {
				i = skipWS(b, i+1)
				if obj {
					if i = scanName(b, i); i < 0 {
						return false
					}
				}
				break
			}
			if obj && c == '}' || !obj && c == ']' {
				depth--
				i++
				continue
			}
			return false
		}
	}
}

// scanName scans an object member's name and colon at b[i:] and returns where
// its value starts, or -1.
func scanName(b []byte, i int) int {
	if i >= len(b) || b[i] != '"' {
		return -1
	}
	if i = scanString(b, i); i < 0 {
		return -1
	}
	i = skipWS(b, i)
	if i >= len(b) || b[i] != ':' {
		return -1
	}
	return skipWS(b, i+1)
}

// scanString scans the string starting at b[i] == '"' and returns the index
// after its closing quote, or -1.
func scanString(b []byte, i int) int {
	for j := i + 1; j < len(b); {
		switch c := b[j]; {
		case c == '"':
			return j + 1
		case c < ' ':
			return -1
		case c == '\\':
			if j+1 >= len(b) {
				return -1
			}
			switch b[j+1] {
			case '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
				j += 2
			case 'u':
				if j+6 > len(b) {
					return -1
				}
				if _, ok := hex4(b[j+2 : j+6]); !ok {
					return -1
				}
				j += 6
			default:
				return -1
			}
		default:
			j++
		}
	}
	return -1
}

func scanLiteral(b []byte, i int, lit string) int {
	if len(b)-i < len(lit) || string(b[i:i+len(lit)]) != lit {
		return -1
	}
	return i + len(lit)
}

// scanNumber scans the longest number at b[i:] and returns its end, or -1. A
// number followed by anything but a delimiter fails later, as encoding/json
// does.
func scanNumber(b []byte, i int) int {
	if i < len(b) && b[i] == '-' {
		i++
	}
	switch {
	case i >= len(b):
		return -1
	case b[i] == '0':
		i++
	case '1' <= b[i] && b[i] <= '9':
		i = digits(b, i)
	default:
		return -1
	}
	if i < len(b) && b[i] == '.' {
		j := digits(b, i+1)
		if j == i+1 {
			return -1
		}
		i = j
	}
	if i < len(b) && (b[i] == 'e' || b[i] == 'E') {
		i++
		if i < len(b) && (b[i] == '+' || b[i] == '-') {
			i++
		}
		j := digits(b, i)
		if j == i {
			return -1
		}
		i = j
	}
	return i
}

func digits(b []byte, i int) int {
	for i < len(b) && '0' <= b[i] && b[i] <= '9' {
		i++
	}
	return i
}

// isNumber reports whether s is exactly one JSON number.
func isNumber(s []byte) bool { return len(s) > 0 && scanNumber(s, 0) == len(s) }

func hex4(b []byte) (rune, bool) {
	var r rune
	for _, c := range b[:4] {
		switch {
		case '0' <= c && c <= '9':
			c -= '0'
		case 'a' <= c && c <= 'f':
			c -= 'a' - 10
		case 'A' <= c && c <= 'F':
			c -= 'A' - 10
		default:
			return 0, false
		}
		r = r<<4 | rune(c)
	}
	return r, true
}

// The functions below take documents validJSON accepted.

// skipString returns the index after the string starting at b[i].
func skipString(b []byte, i int) int {
	for j := i + 1; ; {
		k := j + bytes.IndexByte(b[j:], '"')
		n := 0
		for b[k-1-n] == '\\' {
			n++
		}
		if n%2 == 0 {
			return k + 1
		}
		j = k + 1
	}
}

func isDelim(c byte) bool { return c == ',' || c == '}' || c == ']' || isWS(c) }

// skipValue returns the index after the value starting at b[i].
func skipValue(b []byte, i int) int {
	switch b[i] {
	case '"':
		return skipString(b, i)
	case '{', '[':
		depth := 0
		for {
			switch b[i] {
			case '"':
				i = skipString(b, i)
				continue
			case '{', '[':
				depth++
			case '}', ']':
				if depth--; depth == 0 {
					return i + 1
				}
			}
			i++
		}
	default:
		for i < len(b) && !isDelim(b[i]) {
			i++
		}
		return i
	}
}

// topValue returns the document's value without the whitespace around it.
func topValue(b []byte) []byte {
	i := skipWS(b, 0)
	return b[i:skipValue(b, i)]
}

// members iterates over an object's members.
type members struct {
	b []byte
	i int
}

// objectOf starts an iteration over v, a value, if it is an object.
func objectOf(v []byte) (members, bool) {
	if len(v) == 0 || v[0] != '{' {
		return members{}, false
	}
	return members{v, 1}, true
}

// next returns the next member's quoted name and its value.
func (m *members) next() (name, val []byte, ok bool) {
	i := skipWS(m.b, m.i)
	if m.b[i] == ',' {
		i = skipWS(m.b, i+1)
	}
	if m.b[i] == '}' {
		return nil, nil, false
	}
	e := skipString(m.b, i)
	name = m.b[i:e]
	i = skipWS(m.b, skipWS(m.b, e)+1)
	e = skipValue(m.b, i)
	m.i = e
	return name, m.b[i:e], true
}

// elements iterates over an array's elements.
type elements struct {
	b []byte
	i int
}

func arrayOf(v []byte) (elements, bool) {
	if len(v) == 0 || v[0] != '[' {
		return elements{}, false
	}
	return elements{v, 1}, true
}

func (a *elements) next() ([]byte, bool) {
	i := skipWS(a.b, a.i)
	if a.b[i] == ',' {
		i = skipWS(a.b, i+1)
	}
	if a.b[i] == ']' {
		return nil, false
	}
	e := skipValue(a.b, i)
	a.i = e
	return a.b[i:e], true
}

func isNull(v []byte) bool   { return string(v) == "null" }
func isStr(v []byte) bool    { return len(v) > 0 && v[0] == '"' }
func emptyStr(v []byte) bool { return string(v) == `""` }

// verbatim reports whether the quoted string q unquotes to its own content.
func verbatim(q []byte) bool {
	s := q[1 : len(q)-1]
	return bytes.IndexByte(s, '\\') < 0 && utf8.Valid(s)
}

// appendUnquote appends the value of the quoted string q.
func appendUnquote(dst, q []byte) []byte {
	s := q[1 : len(q)-1]
	i, n := 0, 0 // s[i:n] is pending verbatim bytes
	for n < len(s) {
		c := s[n]
		if c < utf8.RuneSelf && c != '\\' {
			n++
			continue
		}
		if c == '\\' {
			dst = append(dst, s[i:n]...)
			switch e := s[n+1]; e {
			case 'b':
				dst = append(dst, '\b')
			case 'f':
				dst = append(dst, '\f')
			case 'n':
				dst = append(dst, '\n')
			case 'r':
				dst = append(dst, '\r')
			case 't':
				dst = append(dst, '\t')
			case 'u':
				var r rune
				r, n = unescapeU(s, n)
				dst = utf8.AppendRune(dst, r)
				i = n
				continue
			default: // " \ /
				dst = append(dst, e)
			}
			n += 2
			i = n
			continue
		}
		r, size := utf8.DecodeRune(s[n:])
		if r == utf8.RuneError && size == 1 {
			dst = append(dst, s[i:n]...)
			dst = append(dst, "\uFFFD"...)
			n++
			i = n
			continue
		}
		n += size
	}
	return append(dst, s[i:n]...)
}

// hasNUL reports whether the quoted string q unquotes to a string with a NUL,
// which only the escape \u0000 spells.
func hasNUL(q []byte) bool {
	s := q[1 : len(q)-1]
	for n := 0; n < len(s); n++ {
		if s[n] != '\\' {
			continue
		}
		if s[n+1] == 'u' {
			if r, _ := hex4(s[n+2 : n+6]); r == 0 {
				return true
			}
			n += 5
		} else {
			n++
		}
	}
	return false
}

// unquotedLen returns len(appendUnquote(nil, q)).
func unquotedLen(q []byte) int {
	s := q[1 : len(q)-1]
	l := 0
	for n := 0; n < len(s); {
		c := s[n]
		switch {
		case c < utf8.RuneSelf && c != '\\':
			l++
			n++
		case c == '\\':
			if s[n+1] == 'u' {
				var r rune
				r, n = unescapeU(s, n)
				l += utf8.RuneLen(r)
			} else {
				l++
				n += 2
			}
		default:
			r, size := utf8.DecodeRune(s[n:])
			if r == utf8.RuneError && size == 1 {
				l += 3
			} else {
				l += size
			}
			n += size
		}
	}
	return l
}

// unescapeU decodes the \u escape at s[n:], with the low half that follows a
// high surrogate. Anything but a valid pair is U+FFFD, and the next escape is
// then read on its own.
func unescapeU(s []byte, n int) (rune, int) {
	r, _ := hex4(s[n+2 : n+6])
	n += 6
	if !utf16.IsSurrogate(r) {
		return r, n
	}
	if n+6 <= len(s) && s[n] == '\\' && s[n+1] == 'u' {
		r2, _ := hex4(s[n+2 : n+6])
		if d := utf16.DecodeRune(r, r2); d != utf8.RuneError {
			return d, n + 6
		}
	}
	return utf8.RuneError, n
}

// nameIs reports whether the quoted name q unquotes to name exactly. Names
// are matched this way for maps (request bodies, the JWT header).
func nameIs(q []byte, name string) bool {
	if len(q) == len(name)+2 && string(q[1:len(q)-1]) == name {
		return true
	}
	// An escape spells at least one byte in at most six.
	if len(q)-2 > 6*len(name) || bytes.IndexByte(q, '\\') < 0 && utf8.Valid(q) {
		return false
	}
	var buf [3 * 6 * 16]byte // for names of up to 16 bytes
	if 3*(len(q)-2) > len(buf) {
		return false
	}
	return string(appendUnquote(buf[:0], q)) == name
}

// nameFolds reports whether the quoted name q matches a struct field named
// name, as encoding/json matches them: exactly, or else under Unicode case
// folding (strings.EqualFold, so "ſub" and "SUB" are "sub" too).
func nameFolds(q []byte, name string) bool {
	// A folded match has at most 3 bytes per byte of name (K, the Kelvin
	// sign, matches k), each spelled in at most six.
	if len(q)-2 > 6*3*len(name) {
		return false
	}
	var buf [3 * 6 * 3 * 3]byte // for names of up to 3 bytes
	if 3*(len(q)-2) > len(buf) {
		return false
	}
	u := appendUnquote(buf[:0], q)
	return strings.EqualFold(unsafe.String(unsafe.SliceData(u), len(u)), name)
}

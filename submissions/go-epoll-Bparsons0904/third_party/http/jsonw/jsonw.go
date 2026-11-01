// Package jsonw appends JSON values to byte slices without allocating (beyond
// growing dst) and without reflection.
//
// Strings are escaped as JSON requires: '"', '\\' and control characters.
// Valid UTF-8, U+2028/U+2029 included, passes through as it is. Each byte of
// invalid UTF-8 becomes U+FFFD, as encoding/json writes it, so the output is
// always valid UTF-8 and decodes to what encoding/json's would.
//
// Shared parts of a response can be encoded once and spliced in with Raw,
// with per-request values appended around them.
package jsonw

import (
	"math/bits"
	"strconv"
	"time"
	"unicode/utf8"
)

// String appends s as a JSON string.
func String(dst []byte, s string) []byte { return appendString(dst, s) }

// Bytes appends b as a JSON string.
func Bytes(dst []byte, b []byte) []byte { return appendString(dst, b) }

// Key appends a JSON string followed by a colon.
func Key(dst []byte, k string) []byte { return append(appendString(dst, k), ':') }

// Raw appends pre-encoded JSON.
func Raw(dst []byte, b []byte) []byte { return append(dst, b...) }

// Int appends n.
func Int(dst []byte, n int64) []byte { return strconv.AppendInt(dst, n, 10) }

// Bool appends true or false.
func Bool(dst []byte, b bool) []byte {
	if b {
		return append(dst, "true"...)
	}
	return append(dst, "false"...)
}

// Null appends null.
func Null(dst []byte) []byte { return append(dst, "null"...) }

// NullString appends s, or null when valid is false (a NULL column).
func NullString(dst []byte, s string, valid bool) []byte {
	if !valid {
		return Null(dst)
	}
	return appendString(dst, s)
}

const (
	lsb = 0x0101010101010101
	msb = 0x8080808080808080
)

// mustEscape has a non-zero byte for each byte of x that is a control
// character, '"' or '\\', or from 0x80 (to check as UTF-8).
func mustEscape(x uint64) uint64 {
	ctl := (x - lsb*0x20) &^ x // high bit set: byte < 0x20
	q := x ^ lsb*'"'
	q = (q - lsb) &^ q // high bit set: byte == '"'
	b := x ^ lsb*'\\'
	b = (b - lsb) &^ b // high bit set: byte == '\\'
	return (ctl | q | b | x) & msb
}

func appendString[T string | []byte](dst []byte, s T) []byte {
	dst = append(dst, '"')
	start, i := 0, 0
	for {
		// Fast path: skip eight bytes at a time while none needs escaping.
		for i+8 <= len(s) {
			x := uint64(s[i]) | uint64(s[i+1])<<8 | uint64(s[i+2])<<16 | uint64(s[i+3])<<24 |
				uint64(s[i+4])<<32 | uint64(s[i+5])<<40 | uint64(s[i+6])<<48 | uint64(s[i+7])<<56
			if m := mustEscape(x); m != 0 {
				i += bits.TrailingZeros64(m) / 8
				break
			}
			i += 8
		}
		for i < len(s) && s[i] < utf8.RuneSelf && !escape[s[i]] {
			i++
		}
		if i >= len(s) {
			break
		}
		if s[i] >= utf8.RuneSelf {
			if n := runeLen(s, i); n > 0 {
				i += n
				continue
			}
			dst = append(dst, s[start:i]...)
			dst = append(dst, string(utf8.RuneError)...)
			i++
			start = i
			continue
		}
		dst = append(dst, s[start:i]...)
		dst = appendEscape(dst, s[i])
		i++
		start = i
	}
	dst = append(dst, s[start:]...)
	return append(dst, '"')
}

// runeLen returns the length of the valid UTF-8 sequence at s[i], a byte from
// 0x80, or 0 if there is none (utf8.DecodeRune's RuneError of size 1).
func runeLen[T string | []byte](s T, i int) int {
	cont := func(j int) bool { return j < len(s) && s[j]&0xC0 == 0x80 }
	c := s[i]
	lo, hi := byte(0x80), byte(0xBF) // range of the second byte
	switch {
	case c < 0xC2 || c > 0xF4:
		return 0
	case c < 0xE0:
		if cont(i + 1) {
			return 2
		}
		return 0
	case c == 0xE0:
		lo = 0xA0
	case c == 0xED:
		hi = 0x9F // no surrogates
	case c == 0xF0:
		lo = 0x90
	case c == 0xF4:
		hi = 0x8F
	}
	if i+1 >= len(s) || s[i+1] < lo || s[i+1] > hi || !cont(i+2) {
		return 0
	}
	if c < 0xF0 {
		return 3
	}
	if !cont(i + 3) {
		return 0
	}
	return 4
}

var escape = func() (t [256]bool) {
	for c := range 0x20 {
		t[c] = true
	}
	t['"'], t['\\'] = true, true
	return t
}()

const hex = "0123456789abcdef"

func appendEscape(dst []byte, c byte) []byte {
	switch c {
	case '"', '\\':
		return append(dst, '\\', c)
	case '\n':
		return append(dst, '\\', 'n')
	case '\r':
		return append(dst, '\\', 'r')
	case '\t':
		return append(dst, '\\', 't')
	case '\b':
		return append(dst, '\\', 'b')
	case '\f':
		return append(dst, '\\', 'f')
	}
	return append(dst, '\\', 'u', '0', '0', hex[c>>4], hex[c&0xf])
}

// Time appends t as an RFC 3339 UTC string with exactly three fractional
// digits, truncated: "2025-04-01T12:00:00.000Z".
func Time(dst []byte, t time.Time) []byte {
	return appendTime(dst, t.Unix(), int64(t.Nanosecond())/1e6)
}

// UnixMicro appends a time given in microseconds since the Unix epoch, as Time.
func UnixMicro(dst []byte, us int64) []byte {
	sec := floorDiv(us, 1e6)
	return appendTime(dst, sec, (us-sec*1e6)/1000)
}

// PostgresMicro appends a Postgres timestamp's binary value (microseconds
// since 2000-01-01 UTC), as Time.
func PostgresMicro(dst []byte, us int64) []byte { return UnixMicro(dst, us+postgresEpoch) }

const postgresEpoch = 946684800 * 1e6

// appendTime writes years 0000 to 9999; others are out of RFC 3339's range.
func appendTime(dst []byte, sec, ms int64) []byte {
	days := floorDiv(sec, 86400)
	sod := sec - days*86400
	y, m, d := civil(days)
	var b [26]byte
	b[0] = '"'
	put4(b[1:], y)
	b[5] = '-'
	put2(b[6:], m)
	b[8] = '-'
	put2(b[9:], d)
	b[11] = 'T'
	put2(b[12:], sod/3600)
	b[14] = ':'
	put2(b[15:], sod/60%60)
	b[17] = ':'
	put2(b[18:], sod%60)
	b[20] = '.'
	b[21] = byte('0' + ms/100)
	b[22] = byte('0' + ms/10%10)
	b[23] = byte('0' + ms%10)
	b[24] = 'Z'
	b[25] = '"'
	return append(dst, b[:]...)
}

// civil converts days since 1970-01-01 to a proleptic Gregorian date
// (Howard Hinnant's days_from_civil, inverted).
func civil(days int64) (y, m, d int64) {
	z := days + 719468
	era := floorDiv(z, 146097)
	doe := z - era*146097
	yoe := (doe - doe/1460 + doe/36524 - doe/146096) / 365
	doy := doe - (365*yoe + yoe/4 - yoe/100)
	mp := (5*doy + 2) / 153
	d = doy - (153*mp+2)/5 + 1
	m = mp + 3
	if mp >= 10 {
		m = mp - 9
	}
	y = yoe + era*400
	if m <= 2 {
		y++
	}
	return y, m, d
}

func floorDiv(a, b int64) int64 {
	q := a / b
	if (a%b != 0) && (a < 0) != (b < 0) {
		q--
	}
	return q
}

func put2(b []byte, v int64) {
	b[0] = byte('0' + v/10)
	b[1] = byte('0' + v%10)
}

func put4(b []byte, v int64) {
	b[0] = byte('0' + v/1000%10)
	b[1] = byte('0' + v/100%10)
	b[2] = byte('0' + v/10%10)
	b[3] = byte('0' + v%10)
}

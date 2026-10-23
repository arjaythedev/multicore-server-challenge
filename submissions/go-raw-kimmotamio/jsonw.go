package main

// jsonw.go: appending JSON straight into a byte buffer, including Postgres binary column values.

import (
	"strconv"
	"sync"
)

const hexDigits = "0123456789abcdef"

// appendJSONString appends s as a JSON string literal (quoted and escaped).
func appendJSONString(b []byte, s []byte) []byte {
	b = append(b, '"')
	start := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 0x20 && c != '"' && c != '\\' {
			continue
		}
		b = append(b, s[start:i]...)
		switch c {
		case '"':
			b = append(b, '\\', '"')
		case '\\':
			b = append(b, '\\', '\\')
		case '\n':
			b = append(b, '\\', 'n')
		case '\r':
			b = append(b, '\\', 'r')
		case '\t':
			b = append(b, '\\', 't')
		default:
			b = append(b, '\\', 'u', '0', '0', hexDigits[c>>4], hexDigits[c&0xf])
		}
		start = i + 1
	}
	b = append(b, s[start:]...)
	return append(b, '"')
}

func appendJSONStr(b []byte, s string) []byte {
	return appendJSONString(b, []byte(s))
}

// appendJSONNullable appends a string or null (nil = SQL NULL).
func appendJSONNullable(b []byte, s []byte) []byte {
	if s == nil {
		return append(b, "null"...)
	}
	return appendJSONString(b, s)
}

func appendBool(b []byte, v bool) []byte {
	if v {
		return append(b, "true"...)
	}
	return append(b, "false"...)
}

func appendInt(b []byte, v int64) []byte { return strconv.AppendInt(b, v, 10) }

// appendTextArrayJSON appends a Postgres binary text[] as a JSON array of strings.
func appendTextArrayJSON(b []byte, col []byte) []byte {
	b = append(b, '[')
	first := true
	decTextArray(col, func(e []byte) {
		if !first {
			b = append(b, ',')
		}
		first = false
		b = appendJSONNullable(b, e)
	})
	return append(b, ']')
}

// appendTimestamp formats a binary timestamptz (microseconds since 2000-01-01 UTC)
// as "YYYY-MM-DDTHH:MM:SS.mmmZ", truncated to milliseconds.
func appendTimestamp(b []byte, col []byte) []byte {
	us := decInt8(col)
	// Floor-divide into days and the microsecond of the day.
	const usPerDay = 86400 * 1000000
	days := us / usPerDay
	rem := us % usPerDay
	if rem < 0 {
		rem += usPerDay
		days--
	}
	y, m, d := civilFromDays(days + 10957) // 10957 days from 1970-01-01 to 2000-01-01
	sec := rem / 1000000
	ms := (rem % 1000000) / 1000
	h, mi, s := sec/3600, (sec%3600)/60, sec%60
	b = append(b, '"')
	b = append4(b, int(y))
	b = append(b, '-')
	b = append2(b, int(m))
	b = append(b, '-')
	b = append2(b, int(d))
	b = append(b, 'T')
	b = append2(b, int(h))
	b = append(b, ':')
	b = append2(b, int(mi))
	b = append(b, ':')
	b = append2(b, int(s))
	b = append(b, '.')
	b = append(b, byte('0'+ms/100), byte('0'+(ms/10)%10), byte('0'+ms%10))
	return append(b, 'Z', '"')
}

func append2(b []byte, v int) []byte { return append(b, byte('0'+v/10), byte('0'+v%10)) }
func append4(b []byte, v int) []byte {
	return append(b, byte('0'+v/1000), byte('0'+(v/100)%10), byte('0'+(v/10)%10), byte('0'+v%10))
}

// civilFromDays converts days since 1970-01-01 to a civil date (Howard Hinnant's algorithm).
func civilFromDays(z int64) (y, m, d int64) {
	z += 719468
	era := z / 146097
	if z < 0 && z%146097 != 0 {
		era--
	}
	doe := z - era*146097
	yoe := (doe - doe/1460 + doe/36524 - doe/146096) / 365
	y = yoe + era*400
	doy := doe - (365*yoe + yoe/4 - yoe/100)
	mp := (5*doy + 2) / 153
	d = doy - (153*mp+2)/5 + 1
	if mp < 10 {
		m = mp + 3
	} else {
		m = mp - 9
	}
	if m <= 2 {
		y++
	}
	return
}

// Response buffers: pooled, with room reserved in front for the HTTP header.
const headerRoom = 160

var bufPool = sync.Pool{New: func() any {
	b := make([]byte, headerRoom, 4096)
	return &b
}}

func getBuf() *[]byte {
	p := bufPool.Get().(*[]byte)
	*p = (*p)[:headerRoom]
	return p
}

func putBuf(p *[]byte) {
	if cap(*p) > 256<<10 {
		return
	}
	bufPool.Put(p)
}

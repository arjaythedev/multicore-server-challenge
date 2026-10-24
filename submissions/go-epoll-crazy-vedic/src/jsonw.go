package main

import (
	"encoding/binary"
	"strconv"
	"unicode/utf8"
)

// Response bodies are appended straight from PostgreSQL's binary row values
// into a buffer owned by the job slot, so steady-state requests do not build
// intermediate structs or call reflection-based encoding/json.

const hexDigits = "0123456789abcdef"

const oidText = 25

// jsonSafe marks ASCII bytes that encoding/json (with HTML escaping, the
// json.Marshal default) copies unchanged.
var jsonSafe = func() (t [utf8.RuneSelf]bool) {
	for c := 0x20; c < utf8.RuneSelf; c++ {
		t[c] = c != '"' && c != '\\' && c != '<' && c != '>' && c != '&'
	}
	return
}()

// appendJSONString matches encoding/json.Marshal's string encoding byte for byte:
// HTML-safe escapes, \b \f \n \r \t, \u00XX for other controls, U+2028/2029
// escaped and invalid UTF-8 replaced by �.
func appendJSONString[T string | []byte](dst []byte, s T) []byte {
	dst = append(dst, '"')
	start := 0
	for i := 0; i < len(s); {
		if b := s[i]; b < utf8.RuneSelf {
			if jsonSafe[b] {
				i++
				continue
			}
			dst = append(dst, s[start:i]...)
			switch b {
			case '\\', '"':
				dst = append(dst, '\\', b)
			case '\b':
				dst = append(dst, '\\', 'b')
			case '\f':
				dst = append(dst, '\\', 'f')
			case '\n':
				dst = append(dst, '\\', 'n')
			case '\r':
				dst = append(dst, '\\', 'r')
			case '\t':
				dst = append(dst, '\\', 't')
			default:
				dst = append(dst, '\\', 'u', '0', '0', hexDigits[b>>4], hexDigits[b&0xF])
			}
			i++
			start = i
			continue
		}
		var r rune
		var size int
		switch v := any(s).(type) {
		case string:
			r, size = utf8.DecodeRuneInString(v[i:])
		case []byte:
			r, size = utf8.DecodeRune(v[i:])
		}
		if r == utf8.RuneError && size == 1 {
			dst = append(dst, s[start:i]...)
			dst = append(dst, `�`...)
			i += size
			start = i
			continue
		}
		if r == ' ' || r == ' ' {
			dst = append(dst, s[start:i]...)
			dst = append(dst, '\\', 'u', '2', '0', '2', hexDigits[r&0xF])
			i += size
			start = i
			continue
		}
		i += size
	}
	dst = append(dst, s[start:]...)
	return append(dst, '"')
}

// appendNullableString writes JSON null for a SQL NULL.
func appendNullableString(dst, v []byte) []byte {
	if v == nil {
		return append(dst, "null"...)
	}
	return appendJSONString(dst, v)
}

func appendBool(dst, v []byte) []byte {
	if len(v) == 1 && v[0] != 0 {
		return append(dst, "true"...)
	}
	return append(dst, "false"...)
}

func int8Value(v []byte) int64 {
	if len(v) != 8 {
		return 0
	}
	return int64(binary.BigEndian.Uint64(v))
}

func appendInt8(dst, v []byte) []byte { return strconv.AppendInt(dst, int8Value(v), 10) }

// PostgreSQL's binary timestamptz is microseconds since 2000-01-01T00:00:00Z.
const pgEpochMillis = 946684800000

// appendTimestamp writes RFC 3339 UTC with exactly three fractional digits,
// truncated (not rounded), like time.Format("2006-01-02T15:04:05.000Z").
func appendTimestamp(dst, v []byte) []byte {
	us := int8Value(v)
	ms := us / 1000
	if us%1000 < 0 {
		ms--
	}
	ms += pgEpochMillis
	days := ms / 86400000
	rem := ms % 86400000
	if rem < 0 {
		rem += 86400000
		days--
	}
	// Howard Hinnant's civil_from_days.
	z := days + 719468
	era := z / 146097
	if z < 0 && z%146097 != 0 {
		era--
	}
	doe := z - era*146097
	yoe := (doe - doe/1460 + doe/36524 - doe/146096) / 365
	y := yoe + era*400
	doy := doe - (365*yoe + yoe/4 - yoe/100)
	mp := (5*doy + 2) / 153
	d := doy - (153*mp+2)/5 + 1
	m := mp + 3
	if m > 12 {
		m -= 12
	}
	if m <= 2 {
		y++
	}
	sec := rem / 1000
	var b [26]byte
	b[0] = '"'
	b[1], b[2], b[3], b[4] = byte('0'+y/1000%10), byte('0'+y/100%10), byte('0'+y/10%10), byte('0'+y%10)
	b[5] = '-'
	b[6], b[7] = byte('0'+m/10), byte('0'+m%10)
	b[8] = '-'
	b[9], b[10] = byte('0'+d/10), byte('0'+d%10)
	b[11] = 'T'
	h, mi, s := sec/3600, sec/60%60, sec%60
	b[12], b[13] = byte('0'+h/10), byte('0'+h%10)
	b[14] = ':'
	b[15], b[16] = byte('0'+mi/10), byte('0'+mi%10)
	b[17] = ':'
	b[18], b[19] = byte('0'+s/10), byte('0'+s%10)
	b[20] = '.'
	f := rem % 1000
	b[21], b[22], b[23] = byte('0'+f/100), byte('0'+f/10%10), byte('0'+f%10)
	b[24] = 'Z'
	b[25] = '"'
	return append(dst, b[:]...)
}

// appendTextArray writes a binary one-dimensional text[] as a JSON string
// array. An empty or malformed array writes [].
func appendTextArray(dst, v []byte) []byte {
	dst = append(dst, '[')
	if len(v) >= 12 && binary.BigEndian.Uint32(v) == 1 && len(v) >= 20 {
		n := int(int32(binary.BigEndian.Uint32(v[12:])))
		p := 20
		for i := 0; i < n && p+4 <= len(v); i++ {
			l := int(int32(binary.BigEndian.Uint32(v[p:])))
			p += 4
			if i > 0 {
				dst = append(dst, ',')
			}
			if l < 0 || p+l > len(v) {
				dst = append(dst, "null"...)
				continue
			}
			dst = appendJSONString(dst, v[p:p+l])
			p += l
		}
	}
	return append(dst, ']')
}

// ---------- binary parameter encoders ----------

func putInt8(b *[8]byte, v int64) []byte {
	binary.BigEndian.PutUint64(b[:], uint64(v))
	return b[:]
}

// appendTextArrayParam encodes a binary text[] parameter.
func appendTextArrayParam(dst []byte, items []string) []byte {
	var hdr [20]byte
	if len(items) == 0 {
		binary.BigEndian.PutUint32(hdr[0:], 0)
		binary.BigEndian.PutUint32(hdr[4:], 0)
		binary.BigEndian.PutUint32(hdr[8:], oidText)
		return append(dst, hdr[:12]...)
	}
	binary.BigEndian.PutUint32(hdr[0:], 1)
	binary.BigEndian.PutUint32(hdr[4:], 0)
	binary.BigEndian.PutUint32(hdr[8:], oidText)
	binary.BigEndian.PutUint32(hdr[12:], uint32(len(items)))
	binary.BigEndian.PutUint32(hdr[16:], 1)
	dst = append(dst, hdr[:]...)
	for _, s := range items {
		var l [4]byte
		binary.BigEndian.PutUint32(l[:], uint32(len(s)))
		dst = append(dst, l[:]...)
		dst = append(dst, s...)
	}
	return dst
}

// ---------- fixed error bodies ----------

var (
	errUnauthorized  = []byte(`{"errors":{"body":["unauthorized"]}}`)
	errNotFound      = []byte(`{"errors":{"body":["not found"]}}`)
	errArticle404    = []byte(`{"errors":{"body":["article not found"]}}`)
	errProfile404    = []byte(`{"errors":{"body":["profile not found"]}}`)
	errComment404    = []byte(`{"errors":{"body":["comment not found"]}}`)
	errNotAuthor     = []byte(`{"errors":{"body":["not the author"]}}`)
	errInvalidBody   = []byte(`{"errors":{"body":["invalid body"]}}`)
	errInternal      = []byte(`{"errors":{"body":["internal error"]}}`)
	errBusy          = []byte(`{"errors":{"body":["server busy"]}}`)
	errLimitOffset   = []byte(`{"errors":{"body":["limit must be 1-100 and offset >= 0"]}}`)
	errLogin         = []byte(`{"errors":{"body":["invalid email or password"]}}`)
	errTaken         = []byte(`{"errors":{"body":["username or email is already taken"]}}`)
	errPasswordLong  = []byte(`{"errors":{"body":["password is too long"]}}`)
	errRegisterBody  = []byte(`{"errors":{"body":["username, email and password are required"]}}`)
	errLoginBody     = []byte(`{"errors":{"body":["email and password are required"]}}`)
	errUserFields    = []byte(`{"errors":{"body":["invalid user fields"]}}`)
	errArticleBody   = []byte(`{"errors":{"body":["title, description and body are required"]}}`)
	errArticleFields = []byte(`{"errors":{"body":["title, description and body must be non-empty strings"]}}`)
	errTagList       = []byte(`{"errors":{"body":["tagList must be an array of non-empty strings"]}}`)
	errCommentBody   = []byte(`{"errors":{"body":["body is required"]}}`)
	errBadRequest    = []byte(`{"errors":{"body":["invalid request"]}}`)
)

// writeError sets an error response; used on transport error paths.
func writeError(w *response, status int, msg string) {
	b := append([]byte(`{"errors":{"body":[`), appendJSONString(nil, msg)...)
	w.status, w.body = status, append(b, "]}}"...)
}

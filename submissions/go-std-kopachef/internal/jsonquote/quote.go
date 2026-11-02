// Package jsonquote appends API-compatible JSON strings to caller-owned buffers.
package jsonquote

import (
	"encoding/json/jsontext"
	"slices"
)

// Append quotes value, copying ASCII runs in bulk. ASCII escapes use their canonical JSON form;
// Unicode and invalid UTF-8 retain the standard helper's complete behavior.
func Append(dst []byte, value string) []byte {
	start, original := len(dst), value
	dst = slices.Grow(dst, len(value)+2)
	dst = append(dst, '"')
	for len(value) > 0 {
		i := firstJSONSpecial(value)
		dst = append(dst, value[:i]...)
		if i == len(value) {
			break
		}
		c := value[i]
		switch c {
		case '"', '\\':
			dst = append(dst, '\\', c)
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
			if c >= 0x80 {
				// A partially copied/escaped prefix must not leak into fallback.
				dst, _ = jsontext.AppendQuote(dst[:start], original)
				return dst
			}
			const hex = "0123456789abcdef"
			dst = append(dst, '\\', 'u', '0', '0', hex[c>>4], hex[c&15])
		}
		value = value[i+1:]
	}
	return append(dst, '"')
}

func firstJSONSpecialScalar(value string) int {
	for i := 0; i < len(value); i++ {
		c := value[i]
		if c < 0x20 || c >= 0x80 || c == '"' || c == '\\' {
			return i
		}
	}
	return len(value)
}

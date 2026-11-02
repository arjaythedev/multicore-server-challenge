package jsonquote

import (
	"bytes"
	"encoding/binary"
	"encoding/json/jsontext"
	"fmt"
	"slices"
	"strings"
	"testing"
)

// Rejected as a default: isolated quoting was faster, but normal full-server
// trials did not establish a repeatable capacity gain. Keep the exact algorithm
// available for differential checks and future workload comparisons.
//
// Ordinary ASCII needs only its enclosing quotes. Leave escaping and invalid
// UTF-8 replacement to AppendQuote; the response remains application/json.
func appendASCIIJSONString(dst []byte, value string) []byte {
	if plainJSONASCII(value) {
		dst = slices.Grow(dst, len(value)+2)
		dst = append(dst, '"')
		dst = append(dst, value...)
		return append(dst, '"')
	}
	dst, _ = jsontext.AppendQuote(dst, value)
	return dst
}

func plainJSONASCII(value string) bool {
	const high = 0x8080808080808080
	const low = 0x0101010101010101
	i := 0
	for ; i+8 <= len(value); i += 8 {
		word := binary.LittleEndian.Uint64([]byte(value[i : i+8]))
		quote, slash := word^0x2222222222222222, word^0x5c5c5c5c5c5c5c5c
		// Subtraction detects a byte below space. Input high bits detect
		// non-ASCII. The other two tests detect a zero byte after XOR.
		// Cross-byte borrows may conservatively select the standard path.
		if ((word-0x2020202020202020)|word)&high != 0 ||
			((quote-low)&^quote)&high != 0 || ((slash-low)&^slash)&high != 0 {
			return false
		}
	}
	for ; i < len(value); i++ {
		c := value[i]
		if c < 0x20 || c >= 0x80 || c == '"' || c == '\\' {
			return false
		}
	}
	return true
}

func checkJSONString(t *testing.T, s string) {
	t.Helper()
	for _, capacity := range []int{0, 7, len(s) + 32} {
		prefix := []byte(`{"key":`)
		dst := make([]byte, len(prefix), max(len(prefix), capacity))
		copy(dst, prefix)
		want, _ := jsontext.AppendQuote(bytes.Clone(prefix), s)
		if got := appendASCIIJSONString(dst, s); !bytes.Equal(got, want) {
			t.Fatalf("input=%q capacity=%d got=%q want=%q", s, capacity, got, want)
		}
		copy(dst, prefix)
		if got := Append(dst, s); !bytes.Equal(got, want) {
			t.Fatalf("vector input=%q capacity=%d got=%q want=%q", s, capacity, got, want)
		}
	}
}

func TestJSONStringByteBoundaries(t *testing.T) {
	// Force growth after many ASCII escapes before falling back for Unicode
	// or invalid UTF-8. The caller's prefix must survive the rewind.
	for _, s := range []string{
		strings.Repeat("\x00", 256) + "λ",
		strings.Repeat("\\\"\n", 256) + "\xff",
		strings.Repeat("\t", 256) + "\u2028",
	} {
		checkJSONString(t, s)
	}
	for n := 0; n <= 65; n++ {
		checkJSONString(t, strings.Repeat("A", n))
		for i := 0; i < n; i++ {
			s := bytes.Repeat([]byte{'A'}, n)
			for c := 0; c < 256; c++ {
				s[i] = byte(c)
				checkJSONString(t, string(s))
			}
		}
	}
	// Exercise subtraction borrows across neighboring bytes and word edges.
	for _, offset := range []int{0, 1, 6, 7, 8, 15} {
		s := bytes.Repeat([]byte{' '}, 24)
		for a := 0; a < 256; a++ {
			for b := 0; b < 256; b++ {
				s[offset], s[offset+1] = byte(a), byte(b)
				checkJSONString(t, string(s))
			}
		}
	}
}

func TestJSONSpecialIndex(t *testing.T) {
	for _, n := range []int{0, 1, 7, 8, 15, 16, 17, 31, 32, 33, 47, 48, 63, 64, 65, 127, 128, 129} {
		for offset := 0; offset < 16; offset++ {
			data := bytes.Repeat([]byte{'A'}, n+offset)
			for pos := 0; pos < n; pos++ {
				for c := 0; c < 256; c++ {
					data[offset+pos] = byte(c)
					value := string(data)[offset:]
					if got, want := firstJSONSpecial(value), firstJSONSpecialScalar(value); got != want {
						t.Fatalf("length=%d offset=%d pos=%d byte=%d index=%d want=%d", n, offset, pos, c, got, want)
					}
				}
				data[offset+pos] = 'A'
			}
		}
	}
}

func FuzzJSONString(f *testing.F) {
	for _, s := range []string{"", "plain ASCII", "\"\\\n\x00", "λ 🐱\u2028\u2029", "\xff\xc0\xed\xa0\x80", strings.Repeat("a", 65), "<>&/\x7f"} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, s string) { checkJSONString(t, s) })
}

func BenchmarkJSONString(b *testing.B) {
	for _, c := range []struct{ name, value string }{
		{"empty", ""}, {"tag", "postgres"}, {"slug", "a-normal-article-title-123456"},
		{"timestamp", "2026-11-02T01:23:45.123Z"}, {"bio", "A short biography with ordinary words."},
		{"body", strings.Repeat("Ordinary words in an article body. ", 128)},
		{"paragraphs", strings.Repeat("Ordinary words in an article body.\n\n", 128)},
		{"escaped", strings.Repeat("An article with \"quotes\". ", 128)},
		{"lateUnicode", strings.Repeat("a", 4096) + "λ"},
		{"quotes", "An article with \"quotes\""}, {"unicode", "Article λ 🐱 with Unicode"},
		{"invalid", "bad\xffUTF-8"},
	} {
		for _, mode := range []string{"standard", "candidate", "vector"} {
			b.Run(fmt.Sprintf("%s/%s", c.name, mode), func(b *testing.B) {
				dst := make([]byte, 0, len(c.value)*6+2)
				b.ReportAllocs()
				b.SetBytes(int64(len(c.value)))
				if mode == "standard" {
					for b.Loop() {
						dst, _ = jsontext.AppendQuote(dst[:0], c.value)
					}
				} else if mode == "candidate" {
					for b.Loop() {
						dst = appendASCIIJSONString(dst[:0], c.value)
					}
				} else {
					for b.Loop() {
						dst = Append(dst[:0], c.value)
					}
				}
			})
		}
	}
}

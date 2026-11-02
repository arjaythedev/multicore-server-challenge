package server

import (
	"errors"
	"fmt"
	"runtime"
	"strings"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5/pgtype"
)

// Experimental row-text decoder retained for allocation benchmarks. The full
// integration snapshot is in the laboratory; production decoding is unchanged.
var rowTextStorage = envOr("ROW_TEXT_STORAGE", "standard")
var errNullRowText = errors.New("cannot scan NULL into non-null row text")

// One allocation owns the text of one decoded row. Reset always discards the
// old buffer: strings from earlier rows may still be used by HTTP handlers.
// Never copy a non-zero rowTextScanner or reuse a published string's storage.
type rowTextScanner struct {
	text   strings.Builder
	fields [7]rowTextField
}

func newRowTextScanner() *rowTextScanner {
	if rowTextStorage != "owned" {
		return nil
	}
	s := new(rowTextScanner)
	for i := range s.fields {
		s.fields[i].owner = s
	}
	return s
}

// Call before Scan, using the text columns this scanner owns. Numeric, array
// and timestamp decoding stays with pgx. No driver slice survives ScanBytes.
func (s *rowTextScanner) begin(values [][]byte, columns ...int) {
	size := 0
	for _, i := range columns {
		size += len(values[i])
	}
	s.text.Reset()
	s.text.Grow(size)
}

func (s *rowTextScanner) required(i int, target *string) any {
	f := &s.fields[i]
	f.required, f.optional = target, nil
	return f
}

func (s *rowTextScanner) optional(i int, target **string) any {
	f := &s.fields[i]
	f.required, f.optional = nil, target
	return f
}

type rowTextField struct {
	owner    *rowTextScanner
	required *string
	optional **string
}

// ScanBytes implements pgtype.BytesScanner. Copy immediately: the input is
// driver-owned and valid only until the next database method call.
func (f *rowTextField) ScanBytes(src []byte) error {
	if src == nil {
		if f.optional == nil {
			return errNullRowText
		}
		*f.optional = nil
		return nil
	}
	value := ""
	if len(src) != 0 {
		start := f.owner.text.Len()
		f.owner.text.Write(src)
		value = f.owner.text.String()[start:]
	}
	if f.optional != nil {
		// Each optional slot is distinct; reusing the scanner must not mutate
		// a pointer retained in an earlier row's profile or article body.
		optional := value
		*f.optional = &optional
	} else {
		*f.required = value
	}
	return nil
}

func useRowText(t testing.TB, mode string) {
	t.Helper()
	old := rowTextStorage
	rowTextStorage = mode
	t.Cleanup(func() { rowTextStorage = old })
}

func TestRowTextOwnership(t *testing.T) {
	useRowText(t, "owned")
	for _, format := range []int16{pgtype.TextFormatCode, pgtype.BinaryFormatCode} {
		s := newRowTextScanner()
		m := pgtype.NewMap()
		var required string
		var optional *string
		dest := []any{s.required(0, &required), s.optional(1, &optional)}
		plans := []pgtype.ScanPlan{m.PlanScan(pgtype.TextOID, format, dest[0]), m.PlanScan(pgtype.TextOID, format, dest[1])}
		var kept, wanted [][2]string
		var keptPointers []*string
		for i := range 64 {
			raw := [][]byte{[]byte(fmt.Sprintf("row %d λ \" \\ \x00 %s", i, strings.Repeat("body", i*97))), []byte(fmt.Sprintf("profile %d", i))}
			want := [2]string{string(raw[0]), string(raw[1])}
			s.begin(raw, 0, 1)
			for j, plan := range plans {
				if plan == nil {
					t.Fatal("pgx did not select a text scan plan")
				}
				if err := plan.Scan(raw[j], dest[j]); err != nil {
					t.Fatal(err)
				}
				// Driver storage can be overwritten immediately after ScanBytes.
				for k := range raw[j] {
					raw[j][k] = '!'
				}
			}
			if required != want[0] || optional == nil || *optional != want[1] {
				t.Fatal("row text borrowed driver storage")
			}
			kept = append(kept, [2]string{required, *optional})
			wanted = append(wanted, want)
			keptPointers = append(keptPointers, optional)
			if i%9 == 0 {
				runtime.GC()
			}
		}
		// Concurrent readers can retain old values while this decoder advances.
		var wg sync.WaitGroup
		wg.Add(1)
		go func() {
			defer wg.Done()
			for range 100 {
				for i, p := range keptPointers {
					if *p != wanted[i][1] || kept[i] != wanted[i] {
						t.Error("later rows changed an earlier optional slot")
						return
					}
				}
			}
		}()
		for range 100 {
			s.begin([][]byte{[]byte("later")}, 0)
			if err := plans[0].Scan([]byte("later"), dest[0]); err != nil {
				t.Fatal(err)
			}
			if err := plans[1].Scan([]byte{}, dest[1]); err != nil || optional == nil || *optional != "" {
				t.Fatal("empty nullable string was not preserved")
			}
			if err := plans[1].Scan(nil, dest[1]); err != nil || optional != nil {
				t.Fatal("NULL did not clear the previous optional value")
			}
			if err := plans[0].Scan(nil, dest[0]); err == nil {
				t.Fatal("NULL accepted for a non-null string")
			}
		}
		wg.Wait()
	}
}

type textBenchRow struct {
	values           [4]string
	body, bio, image *string
}

func BenchmarkRowText(b *testing.B) {
	for _, n := range []int{1, 32, 256} {
		for _, mode := range []string{"standard", "owned"} {
			b.Run(fmt.Sprintf("rows%d/%s", n, mode), func(b *testing.B) {
				useRowText(b, mode)
				raw := [][]byte{[]byte("an-article-123456"), []byte("A title with words"), []byte(strings.Repeat("description ", 12)), []byte("author-123"), []byte(strings.Repeat("article body\n", 96)), []byte("A biography with several ordinary words."), []byte("https://example.test/avatar.png")}
				m := pgtype.NewMap()
				out := make([]textBenchRow, n)
				var row textBenchRow
				b.ReportAllocs()
				for b.Loop() {
					s := newRowTextScanner()
					dest := [7]any{&row.values[0], &row.values[1], &row.values[2], &row.values[3], &row.body, &row.bio, &row.image}
					if s != nil {
						for i := range 4 {
							dest[i] = s.required(i, &row.values[i])
						}
						dest[4], dest[5], dest[6] = s.optional(4, &row.body), s.optional(5, &row.bio), s.optional(6, &row.image)
					}
					var plans [7]pgtype.ScanPlan
					for i := range plans {
						plans[i] = m.PlanScan(pgtype.TextOID, pgtype.TextFormatCode, dest[i])
					}
					for j := range n {
						if s != nil {
							s.begin(raw, 0, 1, 2, 3, 4, 5, 6)
						}
						for i, plan := range plans {
							if err := plan.Scan(raw[i], dest[i]); err != nil {
								b.Fatal(err)
							}
						}
						out[j] = row
					}
				}
				runtime.KeepAlive(out)
			})
		}
	}
}

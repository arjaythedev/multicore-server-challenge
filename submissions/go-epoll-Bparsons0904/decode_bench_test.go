package main

import (
	"os"
	"testing"
)

// Row decoding on captured rows: the statements run once against the database in DATABASE_URL (a seeded copy), the
// raw binary rows are kept, and the benchmark replays them through the production decoders, so it measures the
// client side only. Run with:
//
//	DATABASE_URL=postgres://... go test -run xxx -bench Decode -benchmem
type replay struct {
	rows [][][]byte
	i    int
}

func (r *replay) NextRow() bool    { r.i++; return r.i <= len(r.rows) }
func (r *replay) Values() [][]byte { return r.rows[r.i-1] }
func (r *replay) reset()           { r.i = 0 }

// capture runs sql with args on a fresh connection and returns copies of the raw rows.
func capture(b *testing.B, w *worker, sql string, args ...any) [][][]byte {
	b.Helper()
	sb := &stmtBatch{}
	var out [][][]byte
	sb.query(sql, args, func(rows *pgRows) error {
		for rows.Next() {
			row := make([][]byte, len(rows.RawValues()))
			for i, v := range rows.RawValues() {
				if v != nil {
					row[i] = append([]byte{}, v...)
				}
			}
			out = append(out, row)
		}
		return nil
	})
	if err := w.run1(sb); err != nil {
		b.Fatal(err)
	}
	return out
}

func benchWorker(b *testing.B) *worker {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		b.Skip("DATABASE_URL not set")
	}
	w := &worker{dsn: dsn}
	if err := w.reconnect(); err != nil {
		b.Fatal(err)
	}
	return w
}

func BenchmarkDecodeComments(b *testing.B) {
	w := benchWorker(b)
	var slugs []string
	for _, r := range capture(b, w, `SELECT a.slug FROM articles a WHERE EXISTS (SELECT 1 FROM comments c WHERE c.article_id = a.id) ORDER BY a.id DESC LIMIT 16`) {
		slugs = append(slugs, string(r[0]))
	}
	rows := capture(b, w, sqlComments, slugs)
	b.Logf("%d slugs, %d rows", len(slugs), len(rows))
	src := &replay{rows: rows}
	var ar arena
	var comms []commRow
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		src.reset()
		ar.reset()
		comms = comms[:0]
		span := make([]commSpan, len(slugs))
		if err := readComments(&pgRows{src: src, ar: &ar}, &comms, span); err != nil {
			b.Fatal(err)
		}
	}
	b.ReportMetric(float64(b.Elapsed().Nanoseconds())/float64(b.N)/float64(len(rows)), "ns/row")
}

func benchHeads(b *testing.B, withBody bool) {
	w := benchWorker(b)
	var ids []int64
	for _, r := range capture(b, w, `SELECT id FROM articles ORDER BY id DESC LIMIT 160`) {
		id, _ := scanInt(r[0])
		ids = append(ids, id)
	}
	rows := capture(b, w, sqlHeadsByID, ids)
	if withBody {
		var slugs []string
		for _, r := range capture(b, w, `SELECT slug FROM articles ORDER BY id DESC LIMIT 160`) {
			slugs = append(slugs, string(r[0]))
		}
		rows = capture(b, w, sqlFullBySlug, slugs)
	}
	src := &replay{rows: rows}
	var ar arena
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		src.reset()
		ar.reset()
		n := 0
		if err := readHeads(&pgRows{src: src, ar: &ar}, withBody, func(a *artRow) { n += len(a.slug) }); err != nil {
			b.Fatal(err)
		}
	}
	b.ReportMetric(float64(b.Elapsed().Nanoseconds())/float64(b.N)/float64(len(rows)), "ns/row")
}

func BenchmarkDecodeHeads(b *testing.B)     { benchHeads(b, false) }
func BenchmarkDecodeHeadsFull(b *testing.B) { benchHeads(b, true) }

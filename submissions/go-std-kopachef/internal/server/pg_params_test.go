package server

import (
	"context"
	"fmt"
	"reflect"
	"testing"

	"github.com/jackc/pgx/v5"
)

// Differently sized parameters share one pipeline. Later query construction
// must not overwrite the values already queued for earlier Bind messages.
func TestParameterBatchOwnership(t *testing.T) {
	f := newReadFixture(t, 0)
	type input struct {
		numbers []int64
		text    []string
	}
	var inputs []input
	var batch pgx.Batch
	for query, n := range []int{0, 1, 2048, 3, 8192, 100000, 2} {
		x := input{numbers: make([]int64, n), text: make([]string, n)}
		for i := range n {
			x.numbers[i] = int64(query*1000000 - i*17)
			x.text[i] = fmt.Sprintf("query-%d-value-%d-λ\\\"", query, i)
		}
		inputs = append(inputs, x)
		batch.Queue(`SELECT $1::bigint[], $2::text[]`, x.numbers, x.text)
	}
	// Preserve NULL arrays as well as empty ones across builder reuse.
	inputs = append(inputs, input{})
	batch.Queue(`SELECT $1::bigint[], $2::text[]`, []int64(nil), []string(nil))
	results := f.pool.SendBatch(context.Background(), &batch)
	defer results.Close()
	for query, want := range inputs {
		var got input
		if err := results.QueryRow().Scan(&got.numbers, &got.text); err != nil {
			t.Fatalf("query %d: %v", query, err)
		}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("query %d parameter ownership changed: lengths %d/%d, want %d/%d", query, len(got.numbers), len(got.text), len(want.numbers), len(want.text))
		}
	}
	if err := results.Close(); err != nil {
		t.Fatal(err)
	}
}

package server

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

func TestReadQueueProfiles(t *testing.T) {
	previous := profileReadBatching
	profileReadBatching = true
	defer func() { profileReadBatching = previous }()
	f := newReadFixture(t, 0)
	direct := &app{pool: f.pool}
	var cases []readCase
	for _, viewer := range []int64{0, f.readerID, f.authorID, f.readerID} {
		for _, suffix := range []string{"_0", "_1", "_missing"} {
			cases = append(cases, readCase{kind: readProfile, viewer: viewer, filter: f.cases[0].slug + suffix})
		}
	}
	check := func(mixed bool) {
		t.Helper()
		inputs := append([]readCase(nil), cases...)
		if mixed {
			inputs = append(inputs, readCase{kind: readTags})
		}
		calls := make([]*queuedRead, len(inputs))
		want := make([]*httptest.ResponseRecorder, len(inputs))
		for i, c := range inputs {
			want[i] = runReadCase(direct, c)
			calls[i] = &queuedRead{ctx: context.Background(), kind: c.kind, viewer: c.viewer,
				filter: c.filter, done: make(chan struct{})}
		}
		f.queries.n.Store(0)
		q := &readQueue{pool: f.pool, ctx: context.Background()}
		q.execute(calls)
		statements := int64(1)
		if mixed {
			statements++
		}
		if got := f.queries.n.Load(); got != statements {
			t.Fatalf("statements=%d, want %d", got, statements)
		}
		for i, call := range calls {
			<-call.done
			if call.err != nil {
				t.Fatal(call.err)
			}
			body := call.body
			if call.value != nil {
				var err error
				body, err = json.Marshal(call.value)
				if err != nil {
					t.Fatal(err)
				}
			}
			compareRead(t, call.status, body, want[i])
		}
	}
	check(false)
	check(true)
	// A later batch must see committed profile and relationship changes.
	ctx := context.Background()
	if _, err := f.pool.Exec(ctx, `UPDATE users SET bio = 'changed', image = NULL WHERE id = $1`, f.readerID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.pool.Exec(ctx, `DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2`, f.readerID, f.authorID); err != nil {
		t.Fatal(err)
	}
	check(true)

	q := newReadQueueConfig(f.pool, time.Millisecond, 32, 2, defaultReadQueueSize)
	defer q.close()
	queued := &app{pool: f.pool, reads: q}
	want := make([]*httptest.ResponseRecorder, len(cases))
	for i, c := range cases {
		want[i] = runReadCase(direct, c)
	}
	var wg sync.WaitGroup
	for i := range 64 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			index := i % len(cases)
			got := runReadCase(queued, cases[index])
			compareRead(t, got.Code, got.Body.Bytes(), want[index])
		}()
	}
	wg.Wait()
}

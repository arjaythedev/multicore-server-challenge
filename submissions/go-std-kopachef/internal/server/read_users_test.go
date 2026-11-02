package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

func TestReadQueueUsers(t *testing.T) {
	old := userReadBatching
	userReadBatching = true
	t.Cleanup(func() { userReadBatching = old })
	f := newReadFixture(t, 0)
	direct := &app{pool: f.pool}
	cases := []readCase{
		{kind: readUser, viewer: f.readerID, filter: "first-token"},
		{kind: readUser, viewer: f.authorID, filter: "null-profile-token"},
		{kind: readUser, viewer: f.readerID, filter: "different-token-same-user"},
		{kind: readUser, viewer: -12345, filter: "missing-token"},
		{kind: readUser, viewer: 0},
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
		before := f.queries.n.Load()
		(&readQueue{pool: f.pool, ctx: context.Background()}).execute(calls)
		statements := int64(1)
		if mixed {
			statements++
		}
		if got := f.queries.n.Load() - before; got != statements {
			t.Fatalf("statements=%d want=%d", got, statements)
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
			if call.status == 200 && call.kind == readUser {
				var response struct {
					User userJSON `json:"user"`
				}
				if err := json.Unmarshal(body, &response); err != nil {
					t.Fatal(err)
				}
				if response.User.Token != inputs[i].filter {
					t.Fatalf("request %d received another request's token", i)
				}
			}
		}
	}
	check(false)
	check(true)
	// Committed changes must be visible in the next batch, including NULLs.
	if _, err := f.pool.Exec(context.Background(), `UPDATE users SET username=username||'_changed',
 email=email||'.changed',bio=NULL,image='changed.png' WHERE id=$1`, f.readerID); err != nil {
		t.Fatal(err)
	}
	check(true)

	q := newReadQueueConfig(f.pool, time.Millisecond, 32, 2, 128)
	t.Cleanup(q.close)
	queued := &app{pool: f.pool, reads: q}
	var wg sync.WaitGroup
	for i := range 64 {
		c := cases[i%len(cases)]
		c.filter = fmt.Sprintf("independent-token-%d", i)
		want := runReadCase(direct, c)
		wg.Add(1)
		go func() {
			defer wg.Done()
			got := runReadCase(queued, c)
			compareRead(t, got.Code, got.Body.Bytes(), want)
		}()
	}
	wg.Wait()
	if _, err := f.pool.Exec(context.Background(), `DELETE FROM users WHERE id=$1`, f.readerID); err != nil {
		t.Fatal(err)
	}
	check(true)
}

func TestReadQueueUserCancellation(t *testing.T) {
	old := userReadBatching
	userReadBatching = true
	t.Cleanup(func() { userReadBatching = old })
	for _, admitted := range []bool{false, true} {
		t.Run(fmt.Sprint(admitted), func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			qctx, stop := context.WithCancel(context.Background())
			defer stop()
			q := &readQueue{ctx: qctx, pending: make(chan *queuedRead)}
			a := &app{reads: q}
			finished := make(chan struct{})
			go func() {
				defer close(finished)
				a.currentUser(httptest.NewRecorder(), httptest.NewRequest("GET", "/api/user", nil).WithContext(ctx), 7, "owned-token")
			}()
			var call *queuedRead
			if admitted {
				select {
				case call = <-q.pending:
				case <-time.After(time.Second):
					t.Fatal("not admitted")
				}
			}
			cancel()
			select {
			case <-finished:
			case <-time.After(time.Second):
				t.Fatal("caller did not cancel")
			}
			if call != nil {
				q.execute([]*queuedRead{call}) // Canceled work never touches the nil pool.
				<-call.done
				if !errors.Is(call.err, context.Canceled) {
					t.Fatal(call.err)
				}
			}
		})
	}
}

package server

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"testing"
	"time"
)

func TestReadQueueIndependentRelease(t *testing.T) {
	previous := earlyReadRelease
	earlyReadRelease = true
	defer func() { earlyReadRelease = previous }()
	f := newReadFixture(t, 3)
	cases := []readCase{{kind: readTags}, {kind: readComments, slug: f.cases[0].slug},
		{kind: readUser, viewer: f.readerID, filter: "per-request-token"},
		{kind: readUser, viewer: -12345, filter: "missing-user-token"},
		{kind: readProfile, viewer: f.readerID, filter: f.cases[0].slug + "_0"},
		{kind: readArticle, slug: f.cases[0].slug + "_missing"},
		{kind: readAuthor, filter: f.cases[0].slug + "_missing", limit: 10},
		{kind: readArticle, viewer: f.readerID, slug: f.cases[0].slug}}
	want := make([]*httptest.ResponseRecorder, len(cases))
	calls := make([]*queuedRead, len(cases))
	for i, c := range cases {
		want[i] = runReadCase(&app{pool: f.pool}, c)
		calls[i] = &queuedRead{ctx: context.Background(), kind: c.kind, viewer: c.viewer,
			slug: c.slug, filter: c.filter, limit: c.limit, offset: c.offset, done: make(chan struct{})}
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	blocked, release, finished := make(chan struct{}), make(chan struct{}), make(chan struct{})
	batches := 0
	f.queries.onBatchEnd = func() {
		batches++
		if batches == 2 {
			close(blocked)
			select {
			case <-release:
			case <-ctx.Done():
			}
		}
	}
	defer func() {
		cancel()
		<-finished
		f.queries.onBatchEnd = nil
	}()
	go func() {
		defer close(finished)
		(&readQueue{pool: f.pool, ctx: ctx}).execute(calls)
	}()
	select {
	case <-blocked:
	case <-time.After(5 * time.Second):
		t.Fatal("enrichment did not reach the publication barrier")
	}
	for i, call := range calls[:len(calls)-1] {
		select {
		case <-call.done:
		default:
			t.Fatalf("independent read %d waited for article enrichment", i)
		}
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
	select {
	case <-calls[len(calls)-1].done:
		t.Fatal("article response published before its batch closed")
	default:
	}
	close(release)
	<-finished
}

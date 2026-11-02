package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// The first groups complete, then a later SELECT raises a runtime SQL error.
// A tracer barrier holds the worker at that error while handlers take ownership
// of the already completed responses. This also verifies that an error is not
// discovered during statement preparation before any groups can complete.
func TestStreamReadLaterSQLFailure(t *testing.T) {
	oldStream, oldEarly := streamReadRelease, earlyReadRelease
	earlyReadRelease = true
	t.Cleanup(func() { streamReadRelease, earlyReadRelease = oldStream, oldEarly })
	for _, stream := range []bool{false, true} {
		t.Run(fmt.Sprint(stream), func(t *testing.T) {
			streamReadRelease = stream
			f := newReadFixture(t, 3)
			cases := []readCase{
				{kind: readUser, viewer: f.readerID, filter: "independent token"},
				{kind: readUser, viewer: -12345, filter: "missing user token"},
				{kind: readTags},
				{kind: readComments, slug: f.cases[0].slug, viewer: f.readerID},
				{kind: readComments, slug: "missing_comments"},
				{kind: readProfile, viewer: f.readerID, filter: f.cases[0].slug + "_0"},
				{kind: readProfile, filter: "missing_profile"},
				{kind: readArticle, slug: "missing_article"},
			}
			want := make([]*httptest.ResponseRecorder, len(cases))
			var calls []*queuedRead
			for i, c := range cases {
				want[i] = runReadCase(&app{pool: f.pool}, c)
				calls = append(calls, &queuedRead{ctx: context.Background(), kind: c.kind, viewer: c.viewer,
					slug: c.slug, filter: c.filter, done: make(chan struct{})})
			}
			independent := len(calls)
			calls = append(calls,
				&queuedRead{ctx: context.Background(), kind: readArticle, slug: f.cases[0].slug, done: make(chan struct{})},
				&queuedRead{ctx: context.Background(), kind: readArticle, articleIDs: []int64{f.articleID}, status: 201, done: make(chan struct{})},
				&queuedRead{ctx: context.Background(), kind: readGlobal, limit: 10, done: make(chan struct{})})
			canceled, cancelCaller := context.WithCancel(context.Background())
			cancelCaller()
			calls = append(calls, &queuedRead{ctx: canceled, kind: readTags, done: make(chan struct{})})
			oldQuery := pageQueries[readGlobal]
			badSQL := `SELECT r.ord, ARRAY[]::bigint[],1::bigint/(r.off-r.off)
 FROM unnest($1::bigint[],$2::bigint[],$3::text[],$4::bigint[])
 WITH ORDINALITY r(lim,off,filter,viewer,ord)`
			pageQueries[readGlobal] = badSQL
			defer func() { pageQueries[readGlobal] = oldQuery }()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			blocked, release, finished := make(chan struct{}), make(chan struct{}), make(chan struct{})
			f.queries.onBatchQuery = func(data pgx.TraceBatchQueryData) {
				if data.SQL == badSQL {
					close(blocked)
					select {
					case <-release:
					case <-ctx.Done():
					}
				}
			}
			defer func() { cancel(); <-finished; f.queries.onBatchQuery = nil }()
			go func() {
				defer close(finished)
				(&readQueue{pool: f.pool, ctx: ctx}).execute(calls)
			}()
			select {
			case <-blocked:
			case <-time.After(5 * time.Second):
				t.Fatal("later SELECT did not reach its runtime-error barrier")
			}
			for i, call := range calls[:independent] {
				published := false
				select {
				case <-call.done:
					published = true
				default:
				}
				if published != stream {
					t.Fatalf("read %d published=%v stream=%v", i, published, stream)
				}
				if !published {
					continue
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
			for _, call := range calls[independent:] {
				select {
				case <-call.done:
					t.Fatal("unfinished or canceled read published before final handling")
				default:
				}
			}
			owned := errors.New("handler owns this result")
			if stream {
				// The worker must neither read nor write these fields after done.
				calls[0].err, calls[0].status, calls[0].value = owned, 418, "owned"
				calls[0].body, calls[0].articleIDs = []byte("owned"), []int64{-12345}
			}
			close(release)
			<-finished
			for i, call := range calls {
				<-call.done // A second close would already have panicked in the worker.
				if stream && i < independent {
					if i == 0 {
						if call.err != owned || call.status != 418 || call.value != "owned" || string(call.body) != "owned" || call.articleIDs[0] != -12345 {
							t.Fatal("worker touched published result")
						}
					} else if call.err != nil {
						t.Fatalf("published read %d overwritten: %v", i, call.err)
					}
				} else if i == len(calls)-1 {
					if !errors.Is(call.err, context.Canceled) {
						t.Fatal(call.err)
					}
				} else {
					var pgerr *pgconn.PgError
					if !errors.As(call.err, &pgerr) || pgerr.Code != "22012" {
						t.Fatalf("unfinished read %d error=%v", i, call.err)
					}
				}
			}
			var one int
			if err := f.pool.QueryRow(context.Background(), "SELECT 1").Scan(&one); err != nil || one != 1 {
				t.Fatalf("connection reuse: %v", err)
			}
		})
	}
}

package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http/httptest"
	"os"
	"reflect"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Count completed SQL statements at the driver boundary, including batch
// statements, so the experiment measures the actual work sent to PostgreSQL.
type queryCounter struct {
	n            atomic.Int64
	onBatchEnd   func()
	onBatchQuery func(pgx.TraceBatchQueryData)
}

func (*queryCounter) TraceQueryStart(ctx context.Context, _ *pgx.Conn, _ pgx.TraceQueryStartData) context.Context {
	return ctx
}
func (c *queryCounter) TraceQueryEnd(context.Context, *pgx.Conn, pgx.TraceQueryEndData) { c.n.Add(1) }
func (*queryCounter) TraceBatchStart(ctx context.Context, _ *pgx.Conn, _ pgx.TraceBatchStartData) context.Context {
	return ctx
}
func (c *queryCounter) TraceBatchQuery(_ context.Context, _ *pgx.Conn, data pgx.TraceBatchQueryData) {
	c.n.Add(1)
	if c.onBatchQuery != nil {
		c.onBatchQuery(data)
	}
}
func (c *queryCounter) TraceBatchEnd(context.Context, *pgx.Conn, pgx.TraceBatchEndData) {
	if c.onBatchEnd != nil {
		c.onBatchEnd()
	}
}

type readCase struct {
	kind          readKind
	viewer        int64
	slug          string
	limit, offset int64
	filter        string
}

type readFixture struct {
	pool                          *pgxpool.Pool
	queries                       *queryCounter
	cases                         []readCase
	articleID, readerID, authorID int64
	tags                          []string
}

func newReadFixture(tb testing.TB, commentCount int) *readFixture {
	tb.Helper()
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		tb.Skip("set TEST_DATABASE_URL to a challenge dev database")
	}
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		tb.Fatal(err)
	}
	f := &readFixture{queries: &queryCounter{}}
	cfg.ConnConfig.Tracer = f.queries
	f.pool, err = pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		tb.Fatal(err)
	}
	tb.Cleanup(f.pool.Close)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	tx, err := f.pool.Begin(ctx)
	if err != nil {
		tb.Fatal(err)
	}
	defer tx.Rollback(ctx)
	prefix := fmt.Sprintf("readq_%d", time.Now().UnixNano())
	for i, id := range []*int64{&f.authorID, &f.readerID} {
		name := fmt.Sprintf("%s_%d", prefix, i)
		err = tx.QueryRow(ctx, `INSERT INTO users (username, email, password_hash)
 VALUES ($1, $1 || '@example.test', (SELECT password_hash FROM users WHERE id = 1)) RETURNING id`, name).Scan(id)
		if err != nil {
			tb.Fatal(err)
		}
	}
	// Alternate NULL and present profile fields while scanning comments.
	if _, err = tx.Exec(ctx, `UPDATE users SET bio = 'reader bio', image = 'reader.png' WHERE id = $1`, f.readerID); err != nil {
		tb.Fatal(err)
	}
	for i, slug := range []string{prefix, prefix + "_empty"} {
		var id int64
		err = tx.QueryRow(ctx, `INSERT INTO articles (slug, author_id, title, description, body, created_at, updated_at)
 VALUES ($1, $2, 'a "quoted" title λ', 'description', 'body', '2025-04-01T12:00:00.123456Z', '2025-04-01T12:00:00.123456Z')
 RETURNING id`, slug, f.authorID).Scan(&id)
		if err != nil {
			tb.Fatal(err)
		}
		if i == 0 {
			f.articleID = id
		}
	}
	f.tags = []string{prefix + "_z", prefix + "_a", prefix + "_new"}
	_, err = tx.Exec(ctx, `INSERT INTO tags (name) VALUES ($1), ($2);
`, f.tags[0], f.tags[1])
	if err != nil {
		tb.Fatal(err)
	}
	_, err = tx.Exec(ctx, `INSERT INTO article_tags (article_id, tag_id)
 SELECT $1, id FROM tags WHERE name = ANY($2::text[])`, f.articleID, f.tags[:2])
	if err != nil {
		tb.Fatal(err)
	}
	_, err = tx.Exec(ctx, `INSERT INTO comments (article_id, author_id, body, created_at, updated_at)
 SELECT $1, CASE WHEN i % 2 = 0 THEN $2::bigint ELSE $3::bigint END, 'comment ' || i,
	 '2025-04-01T12:00:00.987654Z', '2025-04-01T12:00:00.987654Z' FROM generate_series(1,$4::int) i`, f.articleID, f.authorID, f.readerID, commentCount)
	if err != nil {
		tb.Fatal(err)
	}
	_, err = tx.Exec(ctx, `INSERT INTO favorites (user_id, article_id) VALUES ($1, $2)`, f.readerID, f.articleID)
	if err != nil {
		tb.Fatal(err)
	}
	_, err = tx.Exec(ctx, `INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2)`, f.readerID, f.authorID)
	if err != nil {
		tb.Fatal(err)
	}
	if err = tx.Commit(ctx); err != nil {
		tb.Fatal(err)
	}
	tb.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if _, err := f.pool.Exec(ctx, `DELETE FROM users WHERE id = ANY($1::bigint[])`, []int64{f.readerID, f.authorID}); err != nil {
			tb.Error(err)
		}
		if _, err := f.pool.Exec(ctx, `DELETE FROM tags WHERE name = ANY($1::text[])`, f.tags); err != nil {
			tb.Error(err)
		}
	})
	for _, viewer := range []int64{0, f.readerID, f.authorID} {
		f.cases = append(f.cases, readCase{kind: readArticle, viewer: viewer, slug: prefix}, readCase{kind: readComments, viewer: viewer, slug: prefix})
		f.cases = append(f.cases,
			readCase{kind: readGlobal, viewer: viewer, limit: 10},
			readCase{kind: readTag, viewer: viewer, limit: 10, filter: f.tags[0]},
			readCase{kind: readAuthor, viewer: viewer, limit: 1, filter: prefix + "_0"},
			readCase{kind: readAuthor, viewer: viewer, limit: 1, offset: 1, filter: prefix + "_0"},
			readCase{kind: readAuthor, viewer: viewer, limit: 10, filter: prefix + "_0"},
			readCase{kind: readFavorite, viewer: viewer, limit: 10, filter: prefix + "_1"},
			readCase{kind: readFeed, viewer: viewer, limit: 10})
	}
	f.cases = append(f.cases, readCase{kind: readTags}, readCase{kind: readTags},
		readCase{kind: readArticle, slug: prefix + "_empty"}, readCase{kind: readComments, slug: prefix + "_empty"},
		readCase{kind: readArticle, viewer: f.readerID, slug: prefix + "_missing"}, readCase{kind: readComments, viewer: f.readerID, slug: prefix + "_missing"},
		readCase{kind: readGlobal, limit: 10, offset: 1001},
		readCase{kind: readGlobal, limit: 10, offset: 1000000},
		readCase{kind: readTag, limit: 10, filter: prefix + "_missing"},
		readCase{kind: readAuthor, limit: 10, filter: prefix + "_missing"},
		readCase{kind: readFavorite, limit: 10, filter: prefix + "_missing"})
	return f
}

func runReadCase(a *app, c readCase) *httptest.ResponseRecorder {
	r := httptest.NewRequest("GET", "/", nil)
	r.SetPathValue("slug", c.slug)
	w := httptest.NewRecorder()
	switch c.kind {
	case readUser:
		a.currentUser(w, r, c.viewer, c.filter)
	case readTags:
		a.tags(w, r)
	case readArticle:
		a.getArticle(w, r, c.viewer, "")
	case readComments:
		a.listComments(w, r, c.viewer, "")
	case readProfile:
		r.SetPathValue("username", c.filter)
		a.getProfile(w, r, c.viewer, "")
	default:
		list, count := listAll, countAll
		var filter any
		switch c.kind {
		case readTag:
			list, count, filter = listByTag, countByTag, c.filter
		case readAuthor:
			list, count, filter = listByAuthor, countByAuthor, c.filter
		case readFavorite:
			list, count, filter = listByFavorite, countByFavorite, c.filter
		case readFeed:
			list, count = listFeed, countFeed
		}
		a.writeList(w, r, list, count, c.viewer, c.limit, c.offset, filter)
	}
	return w
}

func compareRead(t *testing.T, status int, body []byte, want *httptest.ResponseRecorder) {
	t.Helper()
	var gotJSON, wantJSON any
	if err := json.Unmarshal(body, &gotJSON); err != nil {
		t.Errorf("decode response: %v", err)
		return
	}
	if err := json.Unmarshal(want.Body.Bytes(), &wantJSON); err != nil {
		t.Fatal(err)
	}
	if status != want.Code || !reflect.DeepEqual(gotJSON, wantJSON) {
		t.Errorf("batched read differs from direct read: status %d, want %d; bodies equal: %v", status, want.Code, reflect.DeepEqual(gotJSON, wantJSON))
	}
}

func TestReadQueueMixedBatch(t *testing.T) {
	f := newReadFixture(t, 103)
	a := &app{pool: f.pool}
	q := &readQueue{pool: f.pool, ctx: context.Background()}
	// Anchor pointer ownership and NULL handling to fixture values, rather
	// than relying only on equivalence between the two scanner callers.
	initial := runReadCase(a, readCase{kind: readComments, viewer: f.readerID, slug: f.cases[0].slug})
	var decoded struct {
		Comments []struct{ Author profileJSON }
	}
	if err := json.Unmarshal(initial.Body.Bytes(), &decoded); err != nil {
		t.Fatal(err)
	}
	if len(decoded.Comments) != 100 {
		t.Fatalf("initial comments = %d, want 100", len(decoded.Comments))
	}
	bio, image := "reader bio", "reader.png"
	for i, want := range []profileJSON{
		{Username: f.cases[0].slug + "_1", Bio: &bio, Image: &image},
		{Username: f.cases[0].slug + "_0", Following: true},
		{Username: f.cases[0].slug + "_1", Bio: &bio, Image: &image},
	} {
		if got := decoded.Comments[i].Author; !reflect.DeepEqual(got, want) {
			t.Fatalf("comment %d author = %+v, want %+v", i, got, want)
		}
	}
	check := func(size int) {
		want := make([]*httptest.ResponseRecorder, size)
		calls := make([]*queuedRead, size)
		f.queries.n.Store(0)
		var directStatements int64
		for i := range calls {
			c := f.cases[i%len(f.cases)]
			want[i] = runReadCase(a, c)
			calls[i] = &queuedRead{ctx: context.Background(), kind: c.kind, viewer: c.viewer, slug: c.slug,
				limit: c.limit, offset: c.offset, filter: c.filter, done: make(chan struct{})}
			directStatements++
			if c.kind >= readGlobal {
				directStatements++
			}
		}
		if n := f.queries.n.Swap(0); n != directStatements {
			t.Fatalf("direct statements = %d, want %d", n, directStatements)
		}
		q.execute(calls)
		wantStatements := int64(9)
		if size == 64 {
			wantStatements = 10
		} // Empty/missing threads occur once; the populated thread repeats.
		if n := f.queries.n.Load(); n != wantStatements {
			t.Fatalf("batch statements = %d, want %d", n, wantStatements)
		}
		for i, call := range calls {
			<-call.done
			if call.err != nil {
				t.Fatalf("request %d: %v", i, call.err)
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
	check(64)
	check(maxReadBatchSize)
	// A later batch must reread both article state and the tag dictionary.
	ctx := context.Background()
	if _, err := f.pool.Exec(ctx, `UPDATE articles SET title = 'changed' WHERE id = $1`, f.articleID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.pool.Exec(ctx, `DELETE FROM favorites WHERE user_id = $1 AND article_id = $2`, f.readerID, f.articleID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.pool.Exec(ctx, `DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2`, f.readerID, f.authorID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.pool.Exec(ctx, `INSERT INTO tags (name) VALUES ($1)`, f.tags[2]); err != nil {
		t.Fatal(err)
	}
	if _, err := f.pool.Exec(ctx, `UPDATE comments SET body = 'changed comment'
 WHERE id = (SELECT max(id) FROM comments WHERE article_id = $1)`, f.articleID); err != nil {
		t.Fatal(err)
	}
	check(64)
	check(maxReadBatchSize)
}

func TestReadQueueConcurrent(t *testing.T) {
	testReadQueueConcurrent(t, newReadQueueConfig)
}

func testReadQueueConcurrent(t *testing.T, newQueue func(*pgxpool.Pool, time.Duration, int, int, int) *readQueue) {
	f := newReadFixture(t, 103)
	direct := &app{pool: f.pool}
	want := make([]*httptest.ResponseRecorder, len(f.cases))
	for i, c := range f.cases {
		want[i] = runReadCase(direct, c)
	}
	for _, config := range []struct{ size, workers, queue int }{{64, 2, defaultReadQueueSize}, {maxReadBatchSize, 4, defaultReadQueueSize}, {512, 6, 32768}} {
		for _, wait := range []time.Duration{0, defaultReadBatchWaitUS * time.Microsecond} {
			t.Run(fmt.Sprintf("batch%d-workers%d-queue%d-wait%s", config.size, config.workers, config.queue, wait), func(t *testing.T) {
				q := newQueue(f.pool, wait, config.size, config.workers, config.queue)
				defer q.close()
				a := &app{pool: f.pool, reads: q}
				var wg sync.WaitGroup
				for i := range config.size {
					wg.Add(1)
					go func() {
						defer wg.Done()
						c := i % len(f.cases)
						got := runReadCase(a, f.cases[c])
						compareRead(t, got.Code, got.Body.Bytes(), want[c])
					}()
				}
				wg.Wait()
			})
		}
	}
}

func TestReadQueueKnownArticles(t *testing.T) {
	f := newReadFixture(t, 3)
	direct := &app{pool: f.pool}
	q := &readQueue{pool: f.pool, ctx: context.Background()}
	var calls []*queuedRead
	var want []*httptest.ResponseRecorder
	for _, test := range []struct {
		id, viewer int64
		status     int
	}{
		{f.articleID, f.readerID, 201},
		{f.articleID, f.authorID, 200},
		{f.articleID, 0, 200},
		{-1, f.readerID, 201},
	} {
		w := httptest.NewRecorder()
		r := httptest.NewRequest("GET", "/", nil)
		direct.writeFullArticle(w, r, test.status, articleByID, test.viewer, test.id)
		want = append(want, w)
		calls = append(calls, &queuedRead{ctx: context.Background(), kind: readArticle,
			viewer: test.viewer, articleIDs: []int64{test.id}, status: test.status, done: make(chan struct{})})
	}
	f.queries.n.Store(0)
	q.execute(calls) // No first-stage statement: all callers already know IDs.
	if got := f.queries.n.Load(); got != 1 {
		t.Fatalf("known-ID statements = %d, want 1", got)
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

func TestReadQueueCanceledCaller(t *testing.T) {
	q := &readQueue{pending: make(chan *queuedRead, 1), ctx: context.Background()}
	a := &app{reads: q}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() {
		defer close(done)
		a.serveQueuedRead(httptest.NewRecorder(), httptest.NewRequest("GET", "/", nil).WithContext(ctx), readTags, 0)
	}()
	call := <-q.pending
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("canceled caller stayed blocked")
	}
	q.execute([]*queuedRead{call}) // No pool: a canceled request must not query.
	<-call.done
	if !errors.Is(call.err, context.Canceled) {
		t.Fatalf("error = %v, want canceled", call.err)
	}
}

func TestReadQueueDatabaseFailure(t *testing.T) {
	pool, err := pgxpool.New(context.Background(), "postgres://127.0.0.1/unused?sslmode=disable")
	if err != nil {
		t.Fatal(err)
	}
	pool.Close() // Fail immediately without connecting to a database.
	q := &readQueue{pool: pool, ctx: context.Background()}
	calls := make([]*queuedRead, readKinds)
	for kind := range calls {
		calls[kind] = &queuedRead{ctx: context.Background(), kind: readKind(kind), done: make(chan struct{})}
	}
	q.execute(calls)
	for i, call := range calls {
		<-call.done
		if call.err == nil {
			t.Errorf("request %d succeeded after database failure", i)
		}
	}
}

func TestReadQueueAnonymousEnrichment(t *testing.T) {
	f := newReadFixture(t, 0)
	direct := &app{pool: f.pool}
	q := &readQueue{pool: f.pool, ctx: context.Background()}
	cases := []readCase{
		{kind: readArticle, slug: f.cases[0].slug},
		{kind: readGlobal, limit: 10},
	}
	want := make([]*httptest.ResponseRecorder, len(cases))
	calls := make([]*queuedRead, len(cases))
	for i, c := range cases {
		want[i] = runReadCase(direct, c)
		calls[i] = &queuedRead{ctx: context.Background(), kind: c.kind, slug: c.slug, limit: c.limit, done: make(chan struct{})}
	}
	f.queries.n.Store(0)
	q.execute(calls)
	// Article IDs, global page/count, metadata. Anonymous requests supply no
	// viewer flag pairs, including when full and list responses overlap.
	if n := f.queries.n.Load(); n != 3 {
		t.Fatalf("anonymous batch statements = %d, want 3", n)
	}
	for i, call := range calls {
		if call.err != nil {
			t.Fatal(call.err)
		}
		body, err := json.Marshal(call.value)
		if err != nil {
			t.Fatal(err)
		}
		compareRead(t, call.status, body, want[i])
	}
}

func TestReadQueueEnrichmentFailure(t *testing.T) {
	f := newReadFixture(t, 0)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	// Cancel after IDs have been consumed, before enrichment starts.
	// The second stage must fail without publishing partially built results.
	f.queries.onBatchEnd = cancel
	defer func() { f.queries.onBatchEnd = nil }()
	q := &readQueue{pool: f.pool, ctx: ctx}
	call := &queuedRead{ctx: context.Background(), kind: readArticle, slug: f.cases[0].slug, done: make(chan struct{})}
	q.execute([]*queuedRead{call})
	<-call.done
	if len(call.articleIDs) != 1 || call.err == nil {
		t.Fatalf("second stage: IDs=%v, error=%v", call.articleIDs, call.err)
	}
}

// A short comparison exercises the real handlers at 64 concurrent requests,
// using the small dev database. It is not a challenge capacity measurement.
func BenchmarkSharedReads(b *testing.B) {
	f := newReadFixture(b, 5)
	for _, batched := range []bool{false, true} {
		name := "direct"
		if batched {
			name = "queued"
		}
		b.Run(name, func(b *testing.B) {
			a := &app{pool: f.pool}
			if batched {
				a.reads = newReadQueue(f.pool, defaultReadBatchWaitUS*time.Microsecond)
				defer a.reads.close()
			}
			f.queries.n.Store(0)
			b.ReportAllocs()
			b.ResetTimer()
			for range b.N {
				var wg sync.WaitGroup
				for i := range defaultReadBatchSize {
					wg.Add(1)
					go func() {
						defer wg.Done()
						w := runReadCase(a, f.cases[i%len(f.cases)])
						if w.Code != 200 && w.Code != 404 {
							b.Errorf("status %d: %s", w.Code, w.Body.String())
						}
					}()
				}
				wg.Wait()
			}
			b.StopTimer()
			n := float64(b.N * defaultReadBatchSize)
			b.ReportMetric(n/b.Elapsed().Seconds(), "requests/s")
			b.ReportMetric(float64(f.queries.n.Load())/n, "SQL/req")
		})
	}
}

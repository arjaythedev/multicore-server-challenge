package server

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"testing"
)

func TestReadQueueSparseArticleFlags(t *testing.T) {
	f := newReadFixture(t, 0)
	q := &readQueue{pool: f.pool, ctx: context.Background()}
	a := &app{pool: f.pool}
	for _, pair := range [][2]bool{{true, true}, {false, true}, {true, false}, {false, false}} {
		ctx := context.Background()
		if _, err := f.pool.Exec(ctx, `DELETE FROM favorites WHERE user_id=$1 AND article_id=$2`, f.readerID, f.articleID); err != nil {
			t.Fatal(err)
		}
		if _, err := f.pool.Exec(ctx, `DELETE FROM follows WHERE follower_id=$1 AND followee_id=$2`, f.readerID, f.authorID); err != nil {
			t.Fatal(err)
		}
		if pair[0] {
			if _, err := f.pool.Exec(ctx, `INSERT INTO favorites (user_id,article_id) VALUES ($1,$2)`, f.readerID, f.articleID); err != nil {
				t.Fatal(err)
			}
		}
		if pair[1] {
			if _, err := f.pool.Exec(ctx, `INSERT INTO follows (follower_id,followee_id) VALUES ($1,$2)`, f.readerID, f.authorID); err != nil {
				t.Fatal(err)
			}
		}
		var calls []*queuedRead
		var want []*httptest.ResponseRecorder
		// Duplicate viewer/article pairs remain correct without an input map.
		for _, viewer := range []int64{f.readerID, f.authorID, 0, f.readerID} {
			want = append(want, runReadCase(a, readCase{kind: readArticle, viewer: viewer, slug: f.cases[0].slug}))
			calls = append(calls, &queuedRead{ctx: ctx, kind: readArticle, viewer: viewer, articleIDs: []int64{f.articleID}, status: 200, done: make(chan struct{})})
		}
		f.queries.n.Store(0)
		q.execute(calls)
		if n := f.queries.n.Load(); n != 1 {
			t.Fatalf("article statements = %d, want 1", n)
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
			var decoded struct {
				Article articleJSON `json:"article"`
			}
			if err := json.Unmarshal(body, &decoded); err != nil {
				t.Fatal(err)
			}
			if i == 0 && (decoded.Article.Favorited != pair[0] || decoded.Article.Author.Following != pair[1]) {
				t.Fatalf("flags = %v,%v, want %v", decoded.Article.Favorited, decoded.Article.Author.Following, pair)
			}
		}
	}
}

func TestSharedCommentOrdering(t *testing.T) {
	f := newReadFixture(t, 103)
	// All these timestamps truncate to the same millisecond. The larger ID
	// is older, so sorting by formatted JSON time would give the wrong answer.
	var newestID int64
	err := f.pool.QueryRow(context.Background(), `WITH ids AS (
 SELECT id, row_number() OVER (ORDER BY id DESC) AS n FROM comments WHERE article_id=$1
 ), changed AS (
 UPDATE comments c SET created_at=CASE WHEN ids.n=1 THEN '2025-04-01T12:00:00.987653Z'::timestamptz
 ELSE '2025-04-01T12:00:00.987655Z'::timestamptz END
 FROM ids WHERE c.id=ids.id AND ids.n<=2 RETURNING c.id, c.created_at
 ) SELECT id FROM changed ORDER BY created_at DESC LIMIT 1`, f.articleID).Scan(&newestID)
	if err != nil {
		t.Fatal(err)
	}
	a := &app{pool: f.pool}
	q := &readQueue{pool: f.pool, ctx: context.Background()}
	cases := []readCase{
		{kind: readComments, viewer: f.readerID, slug: f.cases[0].slug},
		{kind: readComments, viewer: f.authorID, slug: f.cases[0].slug},
		{kind: readComments, slug: f.cases[0].slug},
		{kind: readComments, slug: f.cases[0].slug + "_empty"},
		{kind: readComments, slug: f.cases[0].slug + "_missing"},
	}
	var calls []*queuedRead
	var want []*httptest.ResponseRecorder
	for _, c := range cases {
		want = append(want, runReadCase(a, c))
		calls = append(calls, &queuedRead{ctx: context.Background(), kind: c.kind, viewer: c.viewer, slug: c.slug, done: make(chan struct{})})
	}
	f.queries.n.Store(0)
	q.execute(calls)
	if n := f.queries.n.Load(); n != 2 {
		t.Fatalf("mixed unique/shared comment statements = %d, want 2", n)
	}
	for i, call := range calls {
		if call.err != nil {
			t.Fatal(call.err)
		}
		body := call.body
		if call.value != nil {
			body, err = json.Marshal(call.value)
			if err != nil {
				t.Fatal(err)
			}
		}
		compareRead(t, call.status, body, want[i])
		if i < 3 {
			var decoded struct {
				Comments []commentJSON `json:"comments"`
			}
			if err := json.Unmarshal(body, &decoded); err != nil {
				t.Fatal(err)
			}
			if len(decoded.Comments) != 100 || decoded.Comments[0].ID != newestID {
				t.Fatal("newest-100 comment ordering differs")
			}
		}
	}
}

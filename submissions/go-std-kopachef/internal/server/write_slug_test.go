package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func slugCommentJob(slug string, author int64, body string) (*writeJob, *commentJSON) {
	c := new(commentJSON)
	created, updated := new(time.Time), new(time.Time)
	job := &writeJob{ctx: context.Background(), done: make(chan struct{}),
		sql: insertCommentBySlugSQL, args: []any{slug, author, body},
		dest: []any{&c.ID, &c.Body, created, updated, &c.Author.Username, &c.Author.Bio, &c.Author.Image}}
	return job, c
}

func TestSlugWriteCohortTargets(t *testing.T) {
	f := newReadFixture(t, 0)
	ctx := context.Background()
	q := &writeQueue{pool: f.pool, ctx: ctx}
	slug := f.cases[0].slug
	var ids [5]int64
	var jobs []*writeJob
	for i, insert := range []bool{false, false, true, true} {
		jobs = append(jobs, &writeJob{ctx: ctx, done: make(chan struct{}),
			sql: favoriteBySlugStatement(insert), args: []any{f.readerID, slug}, dest: []any{&ids[i]}})
	}
	missing := &writeJob{ctx: ctx, done: make(chan struct{}), sql: insertFavoriteBySlugSQL,
		args: []any{f.readerID, slug + "_missing"}, dest: []any{&ids[4]}}
	comment, c := slugCommentJob(slug, f.authorID, "target lookup")
	jobs = append(jobs, missing, comment)
	q.execute(jobs)
	for i, job := range jobs {
		<-job.done
		if job == missing {
			if !errors.Is(job.err, pgx.ErrNoRows) {
				t.Fatalf("missing slug error = %v", job.err)
			}
		} else if job.err != nil {
			t.Fatalf("job %d: %v", i, job.err)
		}
	}
	for _, id := range ids[:4] {
		if id != f.articleID {
			t.Fatalf("favorite returned target ID %d, want %d", id, f.articleID)
		}
	}
	var favorites, comments int
	if err := f.pool.QueryRow(ctx, `SELECT
 (SELECT count(*) FROM favorites WHERE user_id=$1 AND article_id=$2),
 (SELECT count(*) FROM comments WHERE article_id=$2)`, f.readerID, f.articleID).Scan(&favorites, &comments); err != nil {
		t.Fatal(err)
	}
	if favorites != 1 || comments != 1 || c.ID == 0 || c.Body != "target lookup" || c.Author.Bio != nil || c.Author.Image != nil {
		t.Fatalf("favorites=%d comments=%d comment=%+v", favorites, comments, c)
	}
}

func TestSlugWriteRollbackNonIdempotent(t *testing.T) {
	f := newReadFixture(t, 0)
	ctx := context.Background()
	q := &writeQueue{pool: f.pool, ctx: ctx}
	slug := f.cases[0].slug
	first, c1 := slugCommentJob(slug, f.authorID, "first")
	var target int64
	bad := &writeJob{ctx: ctx, done: make(chan struct{}), sql: insertFavoriteBySlugSQL,
		args: []any{int64(-12345), slug}, dest: []any{&target}}
	last, c2 := slugCommentJob(slug, f.readerID, "last")
	q.execute([]*writeJob{first, bad, last})
	for _, job := range []*writeJob{first, bad, last} {
		<-job.done
	}
	var databaseError *pgconn.PgError
	if first.err != nil || last.err != nil || !errors.As(bad.err, &databaseError) || databaseError.Code != "23503" {
		t.Fatalf("first=%v bad=%v last=%v", first.err, bad.err, last.err)
	}
	other, err := pgx.ConnectConfig(ctx, f.pool.Config().ConnConfig.Copy())
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close(ctx)
	var count, matching int
	if err := other.QueryRow(ctx, `SELECT count(*),count(*) FILTER (WHERE id=ANY($2::bigint[]))
 FROM comments WHERE article_id=$1`, f.articleID, []int64{c1.ID, c2.ID}).Scan(&count, &matching); err != nil {
		t.Fatal(err)
	}
	if count != 2 || matching != 2 {
		t.Fatalf("committed comments=%d returned IDs matching=%d; want 2 each", count, matching)
	}
}

func TestSlugWriteHandlers(t *testing.T) {
	old := writeSlugLookup
	writeSlugLookup = true
	t.Cleanup(func() { writeSlugLookup = old })
	f := newReadFixture(t, 0)
	a := &app{pool: f.pool, writes: newWriteQueueConfig(f.pool, 0, 2),
		reads: newReadQueueConfig(f.pool, 0, 8, 1, 16)}
	t.Cleanup(a.reads.close)
	t.Cleanup(a.writes.close)
	slug := f.cases[0].slug
	for _, insert := range []bool{false, false, true, true} {
		r := httptest.NewRequest(http.MethodPost, "/", nil)
		r.SetPathValue("slug", slug)
		w := httptest.NewRecorder()
		before := f.queries.n.Load()
		a.favorite(insert)(w, r, f.readerID, "")
		if w.Code != http.StatusOK || f.queries.n.Load()-before != 2 {
			t.Fatalf("favorite status=%d SQL statements=%d body=%s", w.Code, f.queries.n.Load()-before, w.Body.String())
		}
		var response struct {
			Article articleJSON `json:"article"`
		}
		if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil || response.Article.Favorited != insert {
			t.Fatalf("favorite response=%+v error=%v", response, err)
		}
	}
	for _, missing := range []bool{false, true} {
		r := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{"comment":{"body":"fresh comment"}}`))
		target := slug
		if missing {
			target += "_missing"
		}
		r.SetPathValue("slug", target)
		w := httptest.NewRecorder()
		before := f.queries.n.Load()
		a.createComment(w, r, f.authorID, "")
		want := http.StatusCreated
		if missing {
			want = http.StatusNotFound
		}
		if w.Code != want || f.queries.n.Load()-before != 1 {
			t.Fatalf("comment status=%d SQL statements=%d body=%s", w.Code, f.queries.n.Load()-before, w.Body.String())
		}
	}
	for _, insert := range []bool{false, true} {
		r := httptest.NewRequest(http.MethodPost, "/", nil)
		r.SetPathValue("slug", slug+"_missing")
		w := httptest.NewRecorder()
		before := f.queries.n.Load()
		a.favorite(insert)(w, r, f.readerID, "")
		if w.Code != http.StatusNotFound || f.queries.n.Load()-before != 1 {
			t.Fatalf("missing favorite status=%d SQL statements=%d body=%s", w.Code, f.queries.n.Load()-before, w.Body.String())
		}
	}
	if _, err := f.pool.Exec(context.Background(), `UPDATE articles SET slug=$2 WHERE id=$1`, f.articleID, slug+"_renamed"); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{slug, slug + "_renamed"} {
		r := httptest.NewRequest(http.MethodPost, "/", nil)
		r.SetPathValue("slug", name)
		w := httptest.NewRecorder()
		a.favorite(true)(w, r, f.readerID, "")
		want := http.StatusOK
		if name == slug {
			want = http.StatusNotFound
		}
		if w.Code != want {
			t.Fatalf("slug %q status=%d body=%s", name, w.Code, w.Body.String())
		}
	}
}

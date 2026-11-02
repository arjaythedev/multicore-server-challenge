package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func followUsernameJob(insert bool, viewer int64, name string) (*writeJob, *profileJSON) {
	p := new(profileJSON)
	return &writeJob{ctx: context.Background(), done: make(chan struct{}),
		sql: followByUsernameStatement(insert), args: []any{viewer, name},
		dest: []any{&p.Username, &p.Bio, &p.Image}}, p
}

func TestFollowLookupCohort(t *testing.T) {
	f := newReadFixture(t, 0)
	name := f.cases[0].slug + "_0"
	var jobs []*writeJob
	for _, insert := range []bool{false, false, true, true} {
		job, _ := followUsernameJob(insert, f.readerID, name)
		jobs = append(jobs, job)
	}
	missing, _ := followUsernameJob(true, f.readerID, name+"_missing")
	comment, id := commentWriteJob(f, f.readerID, "mixed follow cohort")
	jobs = append(jobs, missing, comment)
	q := &writeQueue{pool: f.pool, ctx: context.Background()}
	q.execute(jobs)
	for _, job := range jobs {
		<-job.done
		if job == missing {
			if !errors.Is(job.err, pgx.ErrNoRows) {
				t.Fatalf("missing target: %v", job.err)
			}
		} else if job.err != nil {
			t.Fatal(job.err)
		}
	}
	var count int
	if err := f.pool.QueryRow(context.Background(), `SELECT count(*) FROM follows WHERE follower_id=$1 AND followee_id=$2`,
		f.readerID, f.authorID).Scan(&count); err != nil || count != 1 || *id == 0 {
		t.Fatalf("ordered follows=%d comment=%d err=%v", count, *id, err)
	}
}

func TestFollowLookupRollback(t *testing.T) {
	f := newReadFixture(t, 0)
	ctx := context.Background()
	name := f.cases[0].slug + "_0"
	first, _ := followUsernameJob(false, f.readerID, name)
	bad, _ := followUsernameJob(true, -12345, name)
	last, id := commentWriteJob(f, f.readerID, "retry only after rollback")
	q := &writeQueue{pool: f.pool, ctx: ctx}
	q.execute([]*writeJob{first, bad, last})
	var pgerr *pgconn.PgError
	if first.err != nil || last.err != nil || !errors.As(bad.err, &pgerr) || pgerr.Code != "23503" {
		t.Fatalf("first=%v bad=%v last=%v", first.err, bad.err, last.err)
	}
	var follows, comments int
	if err := f.pool.QueryRow(ctx, `SELECT
 (SELECT count(*) FROM follows WHERE follower_id=$1 AND followee_id=$2),
 (SELECT count(*) FROM comments WHERE article_id=$3 AND id=$4)`,
		f.readerID, f.authorID, f.articleID, *id).Scan(&follows, &comments); err != nil || follows != 0 || comments != 1 {
		t.Fatalf("follows=%d matching comments=%d err=%v", follows, comments, err)
	}
	if err := f.pool.QueryRow(ctx, `SELECT count(*) FROM comments WHERE article_id=$1`, f.articleID).Scan(&comments); err != nil || comments != 1 {
		t.Fatalf("committed comments=%d err=%v", comments, err)
	}
}

func TestFollowLookupHandlers(t *testing.T) {
	old := writeFollowLookup
	writeFollowLookup = true
	t.Cleanup(func() { writeFollowLookup = old })
	f := newReadFixture(t, 0)
	ctx := context.Background()
	a := &app{pool: f.pool, writes: newWriteQueueConfig(f.pool, 0, 2)}
	t.Cleanup(a.writes.close)
	for _, target := range []struct {
		id   int64
		name string
		bio  string
	}{
		{f.authorID, f.cases[0].slug + "_0", ""},
		{f.readerID, f.cases[0].slug + "_1", "reader bio"}, // self-follow remains permitted.
	} {
		for _, insert := range []bool{false, false, true, true} {
			r := httptest.NewRequest(http.MethodPost, "/", nil)
			r.SetPathValue("username", target.name)
			w := httptest.NewRecorder()
			before := f.queries.n.Load()
			a.follow(insert)(w, r, f.readerID, "")
			if w.Code != http.StatusOK || f.queries.n.Load()-before != 1 {
				t.Fatalf("status=%d statements=%d body=%s", w.Code, f.queries.n.Load()-before, w.Body.String())
			}
			var response struct {
				Profile profileJSON `json:"profile"`
			}
			if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
				t.Fatal(err)
			}
			p := response.Profile
			if p.Username != target.name || p.Following != insert || (p.Bio == nil) != (target.bio == "") ||
				p.Bio != nil && (*p.Bio != target.bio || p.Image == nil || *p.Image != "reader.png") || target.bio == "" && p.Image != nil {
				t.Fatalf("target=%+v response=%+v", target, p)
			}
			var exists bool
			if err := f.pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM follows WHERE follower_id=$1 AND followee_id=$2)`,
				f.readerID, target.id).Scan(&exists); err != nil || exists != insert {
				t.Fatalf("committed following=%v want=%v err=%v", exists, insert, err)
			}
		}
	}
	// Neither lookup results nor profile fields survive between requests.
	name := f.cases[0].slug + "_0"
	if _, err := f.pool.Exec(ctx, `UPDATE users SET username=$2,bio='changed',image=NULL WHERE id=$1`, f.authorID, name+"_renamed"); err != nil {
		t.Fatal(err)
	}
	for _, insert := range []bool{false, true} {
		for _, name := range []string{name, name + "_renamed"} {
			r := httptest.NewRequest(http.MethodPost, "/", nil)
			r.SetPathValue("username", name)
			w := httptest.NewRecorder()
			a.follow(insert)(w, r, f.readerID, "")
			if name == f.cases[0].slug+"_0" {
				if w.Code != http.StatusNotFound {
					t.Fatalf("old name status=%d body=%s", w.Code, w.Body.String())
				}
			} else {
				var response struct {
					Profile profileJSON `json:"profile"`
				}
				if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil || w.Code != http.StatusOK ||
					response.Profile.Bio == nil || *response.Profile.Bio != "changed" || response.Profile.Image != nil {
					t.Fatalf("renamed profile=%+v status=%d err=%v", response, w.Code, err)
				}
			}
		}
	}
}

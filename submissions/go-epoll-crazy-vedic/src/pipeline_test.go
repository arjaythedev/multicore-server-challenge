package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"testing"
	"time"
)

func dispatcherForTest(t *testing.T) (*dbDispatcher, *eventLoop) {
	t.Helper()
	if os.Getenv("TEST_DATABASE_URL") == "" {
		t.Skip("set TEST_DATABASE_URL to a disposable seeded database")
	}
	cfg, err := postgresConfig(os.Getenv("TEST_DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	s := &reactorServer{}
	d := newDBDispatcher(s, dbConfig{readConns: 2, writeConns: 1, pipelineDepth: 2, readBatch: 32, writeBatch: 32,
		readQueue: 64, writeQueue: 64, bcryptQueue: 64, bcryptWorkers: 1, sharedReads: true,
		queueTimeout: time.Second * 10, execTimeout: time.Second * 10, reconnectMin: time.Millisecond, reconnectMax: time.Millisecond * 5}, cfg, []byte("test"))
	owner := &eventLoop{completed: make(chan *reactorJob, 128), wakeFD: -1}
	owner.notified.Store(true)
	for _, w := range d.workers {
		if err := w.connect(context.Background()); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() {
			if w.pipe != nil {
				_ = w.pipe.Close()
			}
			if w.pg != nil {
				_ = w.pg.Close(context.Background())
			}
		})
	}
	return d, owner
}

func commentJob(owner *eventLoop, slug, body string, viewer int64) *reactorJob {
	j := &reactorJob{owner: owner, enqueued: monoNow()}
	j.db.route, j.db.stmt, j.db.viewer = rCreateComment, stCommentCreate, viewer
	j.db.addText(slug)
	j.db.addInt(viewer)
	j.db.addText(body)
	return j
}

func TestPipelineRollbackIsolationAndLaterFlight(t *testing.T) {
	c := databaseForTest(t)
	d, owner := dispatcherForTest(t)
	w := d.workers[len(d.workers)-1]
	slug := string(execTestSQL(t, c, "SELECT slug FROM articles ORDER BY id DESC LIMIT 1")[0].Rows[0][0])
	body := fmt.Sprintf("zenith_rollback_%d", time.Now().UnixNano())
	jobs := []*reactorJob{commentJob(owner, slug, body, 1), commentJob(owner, slug, body, 999999999), commentJob(owner, slug, body, 2)}
	w.send(jobs, false)
	tail := commentJob(owner, slug, body+"_tail", 1)
	w.send([]*reactorJob{tail}, false)
	if len(owner.completed) != 0 {
		t.Fatal("response released before synchronization")
	}
	w.receive()
	if len(w.retry) != 3 || len(owner.completed) != 0 {
		t.Fatal("failed group partially responded")
	}
	count := string(execTestSQL(t, c, "SELECT count(*) FROM comments WHERE body='"+body+"'")[0].Rows[0][0])
	if count != "0" {
		t.Fatal("failed group committed a write")
	}
	w.receive() // the next transaction has its own synchronization boundary
	if tail.response.status != 201 {
		t.Fatal("later flight was corrupted by prior error")
	}
	w.restartPipeline()
	retry := append([]*reactorJob(nil), w.retry...)
	w.retry = nil
	for _, j := range retry {
		w.send([]*reactorJob{j}, true)
		w.receive()
		if w.restart {
			w.restartPipeline()
		}
	}
	if jobs[0].response.status != 201 || jobs[1].response.status != 500 || jobs[2].response.status != 201 {
		t.Fatal("retry did not isolate invalid write")
	}
	count = string(execTestSQL(t, c, "SELECT count(*) FROM comments WHERE body='"+body+"'")[0].Rows[0][0])
	if count != "2" || len(owner.completed) != 4 {
		t.Fatal("retry lost or duplicated a write/response")
	}
}

func TestReadFailureDrainsAndReconnects(t *testing.T) {
	d, owner := dispatcherForTest(t)
	w := d.readers[0]
	oldPID := w.pg.PID()
	a, b, c := readJob(stTags, 0, 0, 0, ""), readJob(stTags, 0, 0, 0, ""), &reactorJob{}
	c.db.route, c.db.stmt = rCurrentUser, stUserByID
	c.db.addBytes([]byte{1}) // invalid binary bigint causes a real SQL error
	for _, j := range []*reactorJob{a, b, c} {
		j.owner = owner
		j.enqueued = monoNow()
	}
	w.send([]*reactorJob{a, b, c}, false)
	w.receive()
	if len(owner.completed) != 0 || len(w.retry) != 3 {
		t.Fatal("read batch responded before its failed boundary")
	}
	retry := append([]*reactorJob(nil), w.retry...)
	w.retry = nil
	for _, j := range retry {
		w.send([]*reactorJob{j}, true)
		w.receive()
	}
	if a.response.status != 200 || b.response.status != 200 || c.response.status != 500 || len(owner.completed) != 3 {
		t.Fatal("read recovery lost a recipient")
	}
	if w.pg.PID() == oldPID {
		t.Fatal("cached-description failure reused a corrupted pipeline")
	}
}

func TestFavoriteResponsesShareCommitBoundary(t *testing.T) {
	c := databaseForTest(t)
	d, owner := dispatcherForTest(t)
	writer := d.workers[len(d.workers)-1]
	slug := fmt.Sprintf("zenith_snapshot_%d", time.Now().UnixNano())
	execTestSQL(t, c, "INSERT INTO articles(slug,author_id,title,description,body) VALUES('"+slug+"',1,'t','d','b')")
	var jobs []*reactorJob
	for _, viewer := range []int64{1, 2} {
		j := &reactorJob{owner: owner, enqueued: monoNow()}
		j.db.route, j.db.stmt, j.db.viewer = rFavorite, stFavorite, viewer
		j.db.addInt(viewer)
		j.db.addText(slug)
		jobs = append(jobs, j)
	}
	writer.send(jobs, false)
	f := &writer.ring[writer.head]
	if len(f.ops) != 4 || f.ops[0].stmt != stFavorite || f.ops[1].stmt != stFavorite ||
		f.ops[2].stmt != stArticleBySlug || !f.ops[2].articleReply ||
		f.ops[3].stmt != stArticleBySlug || !f.ops[3].articleReply {
		t.Fatal("favorite response reads were not appended after the writes in the same flight")
	}
	if len(owner.completed) != 0 {
		t.Fatal("favorite response released before the shared Sync")
	}
	writer.receive()
	if len(owner.completed) != len(jobs) || len(writer.followups) != 0 {
		t.Fatal("favorite response did not complete at its write Sync")
	}
	for _, j := range jobs {
		var out struct {
			Article struct {
				FavoritesCount int  `json:"favoritesCount"`
				Favorited      bool `json:"favorited"`
			} `json:"article"`
		}
		if err := json.Unmarshal(j.response.body, &out); err != nil {
			t.Fatal(err)
		}
		if j.response.status != 200 || out.Article.FavoritesCount != 2 || !out.Article.Favorited {
			t.Fatalf("stale mutation result: %s", j.response.body)
		}
	}
	for batch := range 2 {
		comments := make([]*reactorJob, 4)
		for i := range comments {
			comments[i] = commentJob(owner, slug, fmt.Sprintf("zenith_after_favorite_%d_%d_%d", time.Now().UnixNano(), batch, i), 1)
			comments[i].enqueued = monoNow()
		}
		writer.send(comments, false)
		f = &writer.ring[writer.head]
		if len(f.ops) != len(comments) {
			t.Fatalf("got %d comment operations, want %d", len(f.ops), len(comments))
		}
		for _, op := range f.ops {
			if op.articleReply || op.stmt != stCommentCreate {
				t.Fatal("reused write operation retained a favorite response flag")
			}
		}
		writer.receive()
	}
}

func TestArticleUpdateResponseUsesWriterPostCommitRead(t *testing.T) {
	c := databaseForTest(t)
	d, owner := dispatcherForTest(t)
	writer := d.workers[len(d.workers)-1]
	slug := fmt.Sprintf("zenith_update_snapshot_%d", time.Now().UnixNano())
	execTestSQL(t, c, "INSERT INTO articles(slug,author_id,title,description,body) VALUES('"+slug+"',1,'old','d','b')")
	title := "new"
	j := &reactorJob{owner: owner, enqueued: monoNow()}
	j.db.route, j.db.stmt, j.db.viewer = rUpdateArticle, stArticleUpdate, 1
	j.db.addText(slug)
	j.db.addOptText(&title)
	j.db.addOptText(nil)
	j.db.addOptText(nil)
	j.db.addInt(1)
	writer.send([]*reactorJob{j}, false)
	writer.receive()
	if len(owner.completed) != 0 || len(writer.followups) != 1 {
		t.Fatal("article update did not wait for its writer follow-up")
	}
	if !writer.sendFollowups() {
		t.Fatal("writer did not send the article response read")
	}
	writer.receive()
	var out struct {
		Article struct {
			Title string `json:"title"`
			Slug  string `json:"slug"`
		} `json:"article"`
	}
	if err := json.Unmarshal(j.response.body, &out); err != nil {
		t.Fatal(err)
	}
	if j.response.status != 200 || out.Article.Title != "new" || out.Article.Slug == slug {
		t.Fatalf("updated article response is stale: %s", j.response.body)
	}
}

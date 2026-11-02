package server

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func commentWriteJob(f *readFixture, author int64, body string) (*writeJob, *int64) {
	id := new(int64)
	return &writeJob{ctx: context.Background(), done: make(chan struct{}),
		sql:  `INSERT INTO comments (article_id, author_id, body) VALUES ($1,$2,$3) RETURNING id`,
		args: []any{f.articleID, author, body}, dest: []any{id}}, id
}

func TestWriteQueueRollbackNonIdempotent(t *testing.T) {
	f := newReadFixture(t, 0)
	ctx := context.Background()
	q := &writeQueue{pool: f.pool, ctx: ctx}
	first, firstID := commentWriteJob(f, f.authorID, "first")
	bad, _ := commentWriteJob(f, -12345, "bad foreign key")
	last, lastID := commentWriteJob(f, f.readerID, "last")
	q.execute([]*writeJob{first, bad, last})
	for _, job := range []*writeJob{first, bad, last} {
		<-job.done
	}
	var pgError *pgconn.PgError
	if first.err != nil || last.err != nil || !errors.As(bad.err, &pgError) || pgError.Code != "23503" {
		t.Fatalf("first=%v bad=%v last=%v", first.err, bad.err, last.err)
	}
	// A new connection observes only the two committed retry inserts, never
	// an extra copy of the first provisional RETURNING result.
	other, err := pgx.ConnectConfig(ctx, f.pool.Config().ConnConfig.Copy())
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close(ctx)
	var count, matching int
	if err := other.QueryRow(ctx, `SELECT count(*), count(*) FILTER (WHERE id = ANY($2::bigint[]))
 FROM comments WHERE article_id=$1`, f.articleID, []int64{*firstID, *lastID}).Scan(&count, &matching); err != nil {
		t.Fatal(err)
	}
	if count != 2 || matching != 2 {
		t.Fatalf("comments=%d, returned IDs matching=%d; want 2 each", count, matching)
	}
}

func TestWriteQueueWaitsForCommit(t *testing.T) {
	for _, mode := range []string{"values", "slug", "username"} {
		t.Run(mode, func(t *testing.T) {
			assertWriteQueueWaitsForCommit(t, mode)
		})
	}
}

func assertWriteQueueWaitsForCommit(t *testing.T, mode string) {
	t.Helper()
	f := newReadFixture(t, 0)
	ctx := context.Background()
	other, err := pgx.ConnectConfig(ctx, f.pool.Config().ConnConfig.Copy())
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close(ctx)
	key := time.Now().UnixNano()
	if _, err := other.Exec(ctx, `SELECT pg_advisory_lock($1)`, key); err != nil {
		t.Fatal(err)
	}
	defer other.Exec(ctx, `SELECT pg_advisory_unlock($1)`, key)
	var first *writeJob
	countSQL := `SELECT count(*) FROM comments WHERE article_id=$1`
	countArgs := []any{f.articleID}
	if mode == "username" {
		first, _ = followUsernameJob(true, f.readerID, f.cases[0].slug+"_1")
		countSQL = `SELECT count(*) FROM follows WHERE follower_id=$1 AND followee_id=$1`
		countArgs = []any{f.readerID}
	} else if mode == "slug" {
		first, _ = slugCommentJob(f.cases[0].slug, f.authorID, "commit barrier")
	} else {
		first, _ = commentWriteJob(f, f.authorID, "commit barrier")
	}
	barrier := &writeJob{ctx: ctx, done: make(chan struct{}), sql: `SELECT pg_advisory_xact_lock($1)`, args: []any{key}}
	q := &writeQueue{pool: f.pool, ctx: ctx}
	finished := make(chan struct{})
	go func() { q.execute([]*writeJob{first, barrier}); close(finished) }()
	deadline := time.Now().Add(3 * time.Second)
	for {
		var blocked bool
		if err := other.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM pg_stat_activity
 WHERE datname=current_database() AND wait_event='advisory' AND query=$1)`, barrier.sql).Scan(&blocked); err != nil {
			t.Fatal(err)
		}
		if blocked {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("batch did not reach the commit barrier")
		}
		time.Sleep(time.Millisecond)
	}
	select {
	case <-first.done:
		t.Fatal("published a provisional insert before the batch committed")
	default:
	}
	var count int
	if err := other.QueryRow(ctx, countSQL, countArgs...).Scan(&count); err != nil || count != 0 {
		t.Fatalf("provisional insert visible: count=%d err=%v", count, err)
	}
	if _, err := other.Exec(ctx, `SELECT pg_advisory_unlock($1)`, key); err != nil {
		t.Fatal(err)
	}
	<-finished
	if first.err != nil || barrier.err != nil {
		t.Fatalf("insert=%v barrier=%v", first.err, barrier.err)
	}
	if err := other.QueryRow(ctx, countSQL, countArgs...).Scan(&count); err != nil || count != 1 {
		t.Fatalf("committed insert absent: count=%d err=%v", count, err)
	}
}

func TestWriteQueueMixedResults(t *testing.T) {
	f := newReadFixture(t, 0)
	ctx := context.Background()
	q := &writeQueue{pool: f.pool, ctx: ctx}
	comment, id := commentWriteJob(f, f.authorID, "mixed")
	var missing int64
	noRows := &writeJob{ctx: ctx, done: make(chan struct{}),
		sql: `UPDATE comments SET body=body WHERE id=-1 RETURNING id`, dest: []any{&missing}}
	del := &writeJob{ctx: ctx, done: make(chan struct{}), sql: deleteFavoriteSQL, args: []any{f.readerID, f.articleID}}
	add := &writeJob{ctx: ctx, done: make(chan struct{}), sql: insertFavoriteSQL, args: []any{f.readerID, f.articleID}}
	q.execute([]*writeJob{comment, noRows, del, add})
	if comment.err != nil || *id == 0 || !errors.Is(noRows.err, pgx.ErrNoRows) || del.err != nil || add.err != nil {
		t.Fatalf("comment=%v id=%d noRows=%v del=%v add=%v", comment.err, *id, noRows.err, del.err, add.err)
	}
	var favorited bool
	if err := f.pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM favorites WHERE user_id=$1 AND article_id=$2)`, f.readerID, f.articleID).Scan(&favorited); err != nil || !favorited {
		t.Fatalf("ordered delete/add favorite=%v err=%v", favorited, err)
	}
}

func TestWriteQueueConcurrent(t *testing.T) {
	f := newReadFixture(t, 0)
	q := newWriteQueueConfig(f.pool, time.Millisecond, 4)
	defer q.close()
	var wg sync.WaitGroup
	for range 64 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			job, id := commentWriteJob(f, f.authorID, "concurrent")
			if err := q.apply(job.ctx, job.sql, job.args, job.dest); err != nil || *id == 0 {
				t.Errorf("insert id=%d err=%v", *id, err)
			}
		}()
	}
	wg.Wait()
	var count int
	if err := f.pool.QueryRow(context.Background(), `SELECT count(*) FROM comments WHERE article_id=$1`, f.articleID).Scan(&count); err != nil || count != 64 {
		t.Fatalf("concurrent count=%d err=%v", count, err)
	}
}

func TestWriteQueueCanceledAndClosed(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	q := &writeQueue{ctx: context.Background(), pending: make(chan *writeJob)}
	finished := make(chan error, 1)
	go func() { finished <- q.apply(ctx, "unused", nil, nil) }()
	job := <-q.pending
	cancel()
	if err := <-finished; !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	q.execute([]*writeJob{job}) // A canceled job never touches the nil pool.
	<-job.done
	closed := newWriteQueue(nil, time.Millisecond)
	closed.close()
	if err := closed.apply(context.Background(), "unused", nil, nil); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
}

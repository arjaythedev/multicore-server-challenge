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

func favoriteTestJob(viewer, article int64, insert bool) *favoriteJob {
	return &favoriteJob{ctx: context.Background(), viewer: viewer, article: article, insert: insert, done: make(chan struct{})}
}

func TestFavoriteQueueCommitAndIsolation(t *testing.T) {
	f := newReadFixture(t, 0)
	ctx := context.Background()
	other, err := pgx.ConnectConfig(ctx, f.pool.Config().ConnConfig.Copy())
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close(ctx)
	q := &favoriteQueue{pool: f.pool, ctx: ctx}
	check := func(viewer int64, want bool) {
		t.Helper()
		var exists bool
		if err := other.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM favorites WHERE user_id=$1 AND article_id=$2)`, viewer, f.articleID).Scan(&exists); err != nil {
			t.Fatal(err)
		}
		if exists != want {
			t.Fatalf("committed viewer %d favorite=%v, want %v", viewer, exists, want)
		}
	}
	first, second := favoriteTestJob(f.readerID, f.articleID, false), favoriteTestJob(f.authorID, f.articleID, true)
	q.execute([]*favoriteJob{first, second})
	for _, job := range []*favoriteJob{first, second} {
		<-job.done
		if job.err != nil {
			t.Fatal(job.err)
		}
	}
	check(f.readerID, false)
	check(f.authorID, true)

	// The middle FK failure must roll back its whole cohort. Retrying each
	// request preserves the valid writes and reports only the invalid one.
	first = favoriteTestJob(f.readerID, f.articleID, true)
	bad := favoriteTestJob(-12345, f.articleID, true)
	second = favoriteTestJob(f.authorID, f.articleID, false)
	q.execute([]*favoriteJob{first, bad, second})
	for _, job := range []*favoriteJob{first, bad, second} {
		<-job.done
	}
	var pgError *pgconn.PgError
	if first.err != nil || second.err != nil || !errors.As(bad.err, &pgError) || pgError.Code != "23503" {
		t.Fatalf("isolated results: first=%v bad=%v second=%v", first.err, bad.err, second.err)
	}
	check(f.readerID, true)
	check(f.authorID, false)
}

func TestFavoriteQueueConcurrent(t *testing.T) {
	f := newReadFixture(t, 0)
	q := newFavoriteQueue(f.pool, time.Millisecond)
	defer q.close()
	var wg sync.WaitGroup
	for range 64 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := q.apply(context.Background(), f.readerID, f.articleID, true); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
}

func TestFavoriteQueueCallerCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	q := &favoriteQueue{ctx: context.Background(), pending: make(chan *favoriteJob)}
	finished := make(chan error, 1)
	go func() { finished <- q.apply(ctx, 1, 1, true) }()
	job := <-q.pending
	cancel()
	select {
	case err := <-finished:
		if !errors.Is(err, context.Canceled) {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("canceled favorite request stayed blocked")
	}
	q.execute([]*favoriteJob{job}) // No pool: canceled work must issue no SQL.
	<-job.done
}

func TestWriteRetryClassification(t *testing.T) {
	for _, row := range []struct {
		code, severity string
		want           bool
	}{{"23503", "ERROR", true}, {"23505", "ERROR", true}, {"40001", "ERROR", true},
		{"40P01", "ERROR", true}, {"40003", "ERROR", false}, {"08006", "FATAL", false},
		{"57P01", "FATAL", false}, {"23503", "FATAL", false}, {"42601", "ERROR", false}} {
		err := &pgconn.PgError{Code: row.code, Severity: row.severity}
		if got := retryWriteCohort(err); got != row.want {
			t.Errorf("%s %s retry=%v, want %v", row.severity, row.code, got, row.want)
		}
	}
	if retryWriteCohort(context.Canceled) || retryWriteCohort(errors.New("connection lost")) || retryWriteCohort(nil) {
		t.Fatal("retried an uncertain or canceled operation")
	}
}

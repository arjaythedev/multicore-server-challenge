package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type readKind uint8

// Profile reads share the first-stage batch and are published before enrichment.
var profileReadBatching = envOr("PROFILE_READ_BATCHING", "1") != "0"
var userReadBatching = envOr("USER_READ_BATCHING", "0") == "1"
var earlyReadRelease = envOr("READ_EARLY_RELEASE", "1") != "0"
var streamReadRelease = envOr("READ_STREAM_RELEASE", "0") == "1"

const (
	// If current-user batching is enabled, decode its short SELECT first.
	readUser readKind = iota
	readTags
	readArticle
	readComments
	readProfile
	readGlobal
	readTag
	readAuthor
	readFavorite
	readFeed
	readKinds
	defaultReadBatchSize   = 512
	maxReadBatchSize       = 2048
	defaultReadWorkers     = 4
	defaultReadQueueSize   = 1024
	defaultReadBatchWaitUS = 8000
)

type queuedRead struct {
	ctx        context.Context
	kind       readKind
	viewer     int64
	slug       string
	limit      int64
	offset     int64
	filter     string // Page/profile argument, or the presented token for readUser.
	articleIDs []int64
	count      int64
	done       chan struct{}
	status     int
	value      any
	body       []byte
	err        error
}

// One collector fills batches while workers execute SQL and decode rows.
// Collection is bounded by batchWait; a full batch dispatches immediately.
type readQueue struct {
	pool        *pgxpool.Pool
	pending     chan *queuedRead
	work        chan []*queuedRead
	ctx         context.Context
	cancel      context.CancelFunc
	workers     sync.WaitGroup
	batchWait   time.Duration
	batchSize   int
	workerCount int
}

func newReadQueue(pool *pgxpool.Pool, batchWait time.Duration) *readQueue {
	return newReadQueueConfig(pool, batchWait, defaultReadBatchSize, defaultReadWorkers, defaultReadQueueSize)
}

func newReadQueueConfig(pool *pgxpool.Pool, batchWait time.Duration, batchSize, workerCount, queueSize int) *readQueue {
	ctx, cancel := context.WithCancel(context.Background())
	q := &readQueue{pool: pool, pending: make(chan *queuedRead, queueSize), work: make(chan []*queuedRead),
		ctx: ctx, cancel: cancel, batchWait: batchWait, batchSize: batchSize, workerCount: workerCount}
	q.workers.Add(1)
	if envOr("READ_WAIT_FILL", "0") == "1" {
		go q.collectWhileWaiting()
	} else {
		go q.collect()
	}
	for range workerCount {
		q.workers.Add(1)
		go q.run()
	}
	return q
}

func (q *readQueue) close() {
	q.cancel()
	q.workers.Wait()
}

func (a *app) serveQueuedRead(w http.ResponseWriter, r *http.Request, kind readKind, viewer int64) {
	call := &queuedRead{ctx: r.Context(), kind: kind, viewer: viewer, slug: r.PathValue("slug"), done: make(chan struct{})}
	a.serveReadCall(w, r, call)
}

func (a *app) serveReadCall(w http.ResponseWriter, r *http.Request, call *queuedRead) {
	a.serveReadCallContext(w, r.Context(), call)
}

func (a *app) serveReadCallContext(w http.ResponseWriter, ctx context.Context, call *queuedRead) {
	select {
	case a.reads.pending <- call:
	case <-ctx.Done():
		return
	case <-a.reads.ctx.Done():
		internalError(w, a.reads.ctx.Err())
		return
	}
	select {
	case <-call.done:
		if call.err != nil {
			internalError(w, call.err)
			return
		}
		if call.value != nil {
			writeJSON(w, call.status, call.value)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(call.status)
		_, _ = w.Write(call.body)
	case <-ctx.Done():
	case <-a.reads.ctx.Done():
		internalError(w, a.reads.ctx.Err())
	}
}

func (q *readQueue) run() {
	defer q.workers.Done()
	for {
		select {
		case batch := <-q.work:
			q.execute(batch)
			clear(batch) // No request or database result survives this active batch.
		case <-q.ctx.Done():
			return
		}
	}
}

func (q *readQueue) collect() {
	defer q.workers.Done()
	timer := time.NewTimer(time.Hour)
	timer.Stop()
	defer timer.Stop()
	for {
		batch := make([]*queuedRead, 0, q.batchSize)
		select {
		case first := <-q.pending:
			batch = append(batch, first)
		case <-q.ctx.Done():
			return
		}
		if q.batchWait > 0 {
			timer.Reset(q.batchWait)
		}
	drain:
		for len(batch) < q.batchSize {
			if q.batchWait > 0 {
				select {
				case call := <-q.pending:
					batch = append(batch, call)
				case <-timer.C:
					break drain
				case <-q.ctx.Done():
					return
				}
				continue
			}
			select {
			case call := <-q.pending:
				batch = append(batch, call)
			default:
				break drain
			}
		}
		timer.Stop()
		select {
		case q.work <- batch:
		case <-q.ctx.Done():
			return
		}
	}
}

func arrayReadSQL(query string) string {
	return `SELECT r.ord, x.* FROM unnest($1::bigint[], $2::text[])
 WITH ORDINALITY AS r(viewer, slug, ord) CROSS JOIN LATERAL (` +
		strings.NewReplacer("$1", "r.viewer", "$2", "r.slug").Replace(query) + `) x`
}

var arrayCommentsSQL = arrayReadSQL(commentsSelect) + ` ORDER BY r.ord, x.created_at DESC, x.id DESC`
var arrayProfileSQL = arrayReadSQL(profileSelect)

const arrayUserSQL = `SELECT r.ord,u.id,u.username,u.email,u.bio,u.image
 FROM unnest($1::bigint[]) WITH ORDINALITY r(viewer,ord)
 JOIN users u ON u.id=r.viewer`

const arrayArticleSQL = `SELECT r.ord, a.id FROM unnest($1::text[]) WITH ORDINALITY r(slug, ord)
 JOIN articles a ON a.slug = r.slug`

func (q *readQueue) execute(calls []*queuedRead) {
	stream := earlyReadRelease && streamReadRelease
	var retained []*queuedRead
	if stream {
		retained = make([]*queuedRead, 0, len(calls))
	}
	var groups [readKinds][]*queuedRead
	for _, call := range calls {
		call.err = call.ctx.Err()
		if call.err == nil {
			if call.kind == readArticle && len(call.articleIDs) > 0 {
				// Committed mutation responses already know the ID and retain
				// their success status (201 for creation, otherwise 200).
				if stream {
					retained = append(retained, call)
				}
				continue
			}
			call.status = http.StatusNotFound
			if call.kind == readUser {
				call.status = http.StatusUnauthorized
				call.body = []byte(`{"errors":{"body":["unauthorized"]}}`)
			} else if call.kind == readProfile {
				call.body = []byte(`{"errors":{"body":["profile not found"]}}`)
			} else {
				call.body = []byte(`{"errors":{"body":["article not found"]}}`)
			}
			groups[call.kind] = append(groups[call.kind], call)
		} else if stream {
			retained = append(retained, call)
		}
	}
	var batch pgx.Batch
	var pages [readKinds]*pageGroup
	var comments *commentBatch
	for kind, group := range groups {
		if len(group) == 0 {
			continue
		}
		if readKind(kind) == readTags {
			batch.Queue(`SELECT name FROM tags ORDER BY name`)
			continue
		}
		if readKind(kind) == readUser {
			viewers := make([]int64, len(group))
			for i, call := range group {
				viewers[i] = call.viewer
			}
			batch.Queue(arrayUserSQL, viewers)
			continue
		}
		if readKind(kind) >= readGlobal {
			pages[kind] = queuePages(&batch, readKind(kind), group)
			continue
		}
		if readKind(kind) == readComments {
			comments = queueComments(&batch, group)
			continue
		}
		if readKind(kind) == readProfile {
			viewers, names := make([]int64, len(group)), make([]string, len(group))
			for i, call := range group {
				viewers[i], names[i] = call.viewer, call.filter
			}
			batch.Queue(arrayProfileSQL, viewers, names)
			continue
		}
		slugs := make([]string, len(group))
		for i, call := range group {
			slugs[i] = call.slug
		}
		batch.Queue(arrayArticleSQL, slugs)
	}
	var err error
	ctx, cancel := context.WithTimeout(q.ctx, 5*time.Second)
	if batch.Len() > 0 {
		results := q.pool.SendBatch(ctx, &batch)
		for kind, group := range groups {
			if len(group) == 0 {
				continue
			}
			if readKind(kind) == readComments {
				err = comments.decode(results)
			} else {
				var rows pgx.Rows
				rows, err = results.Query()
				if err == nil {
					if pages[kind] != nil {
						err = pages[kind].decode(group, rows)
					} else {
						err = decodeReadGroup(readKind(kind), group, rows)
					}
				}
			}
			if err != nil {
				break
			}
			if stream {
				// Stage one contains only independent SELECTs. A fully decoded
				// read needs no later statement or write commit. Transfer ownership
				// now, and remove the entire decoded group from later error handling.
				for _, call := range group {
					if len(call.articleIDs) == 0 {
						close(call.done)
					} else {
						retained = append(retained, call)
					}
				}
				groups[kind] = nil
			}
		}
		if closeErr := results.Close(); err == nil {
			err = closeErr
		}
	}
	if stream {
		// On failure, retain every undecoded group. Published calls are absent
		// and must never be read, overwritten or closed again by this worker.
		for _, group := range groups {
			retained = append(retained, group...)
		}
		calls = retained
	}
	if err == nil {
		if earlyReadRelease && !stream {
			// Independent responses are complete after stage one has released
			// its connection. Keep them out of enrichment: closing done transfers
			// ownership, including error/status fields, to their handlers.
			articles := make([]*queuedRead, 0, len(calls))
			for _, call := range calls {
				if call.err != nil || len(call.articleIDs) == 0 {
					close(call.done)
				} else {
					articles = append(articles, call)
				}
			}
			calls = articles
		}
		_, err = q.enrichArticles(ctx, calls)
	}
	cancel()
	// Release the connection before handing typed results to request goroutines
	// for serialization. Closing done transfers ownership; canceled callers
	// leave their result for GC once the worker clears its batch references.
	for _, call := range calls {
		if call.err == nil {
			call.err = err
		}
		close(call.done)
	}
}

// Prefix the typed decoder with one ordinal column. The fixed destination
// buffer fits the 8-column comment row and the one-column article ID row.
type numberedRow struct {
	pgx.Rows
	ordinal int64
	dest    [9]any
}

func (r *numberedRow) Scan(dest ...any) error {
	r.dest[0] = &r.ordinal
	copy(r.dest[1:], dest)
	return r.Rows.Scan(r.dest[:len(dest)+1]...)
}

func (r *numberedRow) index(n int) (int, error) {
	if r.ordinal < 1 || r.ordinal > int64(n) {
		return 0, errors.New("invalid read batch ordinal")
	}
	return int(r.ordinal - 1), nil
}

func decodeReadGroup(kind readKind, group []*queuedRead, rows pgx.Rows) error {
	defer rows.Close()
	if kind == readUser {
		row := numberedRow{Rows: rows}
		var id int64
		for rows.Next() {
			var u userJSON
			if err := row.Scan(&id, &u.Username, &u.Email, &u.Bio, &u.Image); err != nil {
				return err
			}
			i, err := row.index(len(group))
			if err != nil {
				return err
			}
			u.Token = group[i].filter
			group[i].status, group[i].body = http.StatusOK, nil
			group[i].value = struct {
				User userJSON `json:"user"`
			}{u}
		}
		return rows.Err()
	}
	if kind == readProfile {
		row := numberedRow{Rows: rows}
		var id int64
		for rows.Next() {
			var p profileJSON
			if err := row.Scan(&id, &p.Username, &p.Bio, &p.Image, &p.Following); err != nil {
				return err
			}
			i, err := row.index(len(group))
			if err != nil {
				return err
			}
			group[i].status, group[i].body = http.StatusOK, nil
			group[i].value = struct {
				Profile profileJSON `json:"profile"`
			}{p}
		}
		return rows.Err()
	}
	if kind == readTags {
		names, err := pgx.CollectRows(rows, pgx.RowTo[string])
		if err != nil {
			return err
		}
		if names == nil {
			names = []string{}
		}
		body, err := json.Marshal(struct {
			Tags []string `json:"tags"`
		}{names})
		for _, call := range group {
			call.status, call.body = http.StatusOK, body
		}
		return err
	}
	var comments [][]commentJSON
	var scanner *commentScanner
	if kind == readComments {
		comments = make([][]commentJSON, len(group))
		scanner = newCommentScanner()
	}
	row := numberedRow{Rows: rows}
	var id int64
	for rows.Next() {
		var err error
		var comment commentJSON
		var present bool
		if kind == readArticle {
			err = row.Scan(&id)
		} else {
			comment, present, err = scanner.scan(&row)
		}
		if err != nil {
			return err
		}
		i, err := row.index(len(group))
		if err != nil {
			return err
		}
		if kind == readArticle {
			group[i].articleIDs = []int64{id}
		} else {
			if comments[i] == nil {
				comments[i] = []commentJSON{}
			}
			if present {
				comments[i] = append(comments[i], comment)
			}
		}
		group[i].status, group[i].body = http.StatusOK, nil
	}
	if kind == readComments {
		for i, call := range group {
			if call.status == http.StatusOK {
				call.value = struct {
					Comments []commentJSON `json:"comments"`
				}{comments[i]}
			}
		}
	}
	return rows.Err()
}

package main

// Shared reads borrow only requests already collected into this execution.
// No result is kept for a subsequent request. The SQL design is informed by
// rust-tokio-Scooter1337's MIT-licensed read_batch.rs; see ATTRIBUTION.md.

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5/pgconn"
)

type readOperation struct {
	start, count int
	stmt         stmtID
	shared       bool
	articleReply bool      // read the Article response after a favorite mutation
	args         [4][]byte // reusable binary arrays, owned by this pipeline flight
}

var sharedReads = func() [firstWriteStmt]string {
	var out [firstWriteStmt]string
	for _, id := range []stmtID{stListAll, stListTag, stListAuthor, stListFavorite} {
		out[id] = sharedListSQL(id)
	}
	out[stArticleBySlug] = sharedArticleSQL()
	out[stArticleByID] = sharedArticleSQLFor(stArticleByID)
	out[stComments] = sharedCommentsSQL()
	return out
}()

func requestArrays(id stmtID) string {
	args, names := make([]string, len(stmts[id].params)), make([]string, len(stmts[id].params))
	for i, kind := range stmts[id].params {
		typ := "bigint"
		if kind == 't' {
			typ = "text"
		}
		args[i], names[i] = fmt.Sprintf("$%d::%s[]", i+1, typ), fmt.Sprintf("p%d", i+1)
	}
	return "SELECT * FROM unnest(" + strings.Join(args, ",") + ") WITH ORDINALITY AS r(" + strings.Join(names, ",") + ",ord)"
}

// The page and capped count depend on filters/limits, while membership flags
// depend on the viewer. Keep those dependencies separate within this statement.
func sharedListSQL(id stmtID) string {
	var page, count string
	filtered := id != stListAll
	switch id {
	case stListAll:
		page = `SELECT id FROM (SELECT id FROM articles ORDER BY id DESC OFFSET k.p3 LIMIT 100) p ORDER BY id DESC LIMIT k.p2`
		count = countAll
	case stListTag:
		page = `SELECT article_id AS id FROM article_tags WHERE tag_id=(SELECT id FROM tags WHERE name=k.p4) ORDER BY article_id DESC LIMIT k.p2 OFFSET k.p3`
		count = strings.ReplaceAll(countByTag, "$1", "selector.p4")
	case stListAuthor:
		page = `SELECT id FROM articles WHERE author_id=(SELECT id FROM users WHERE username=k.p4) ORDER BY id DESC LIMIT k.p2 OFFSET k.p3`
		count = strings.ReplaceAll(countByAuthor, "$1", "selector.p4")
	case stListFavorite:
		page = `SELECT article_id AS id FROM favorites WHERE user_id=(SELECT id FROM users WHERE username=k.p4) ORDER BY article_id DESC LIMIT k.p2 OFFSET k.p3`
		count = strings.ReplaceAll(countByFavorite, "$1", "selector.p4")
	default:
		panic("not a shared list")
	}
	if filtered {
		page = "SELECT id FROM (" + page + ") bounded LIMIT 100"
	}
	keys, pageJoin := "p2,p3", "p.p2=r.p2 AND p.p3=r.p3"
	totals, totalJoin := "SELECT count AS n FROM ("+count+") c", "CROSS JOIN totals c"
	if filtered {
		keys += ",p4"
		pageJoin += " AND p.p4=r.p4"
		totals = "SELECT selector.p4,c.count AS n FROM (SELECT DISTINCT p4 FROM requests) selector CROSS JOIN LATERAL (" + count + ") c"
		totalJoin = "JOIN totals c ON c.p4=r.p4"
	}
	return `WITH requests AS MATERIALIZED (` + requestArrays(id) + `),
 keys AS MATERIALIZED (SELECT DISTINCT ` + keys + ` FROM requests),
 totals AS MATERIALIZED (` + totals + `),
 pages AS MATERIALIZED (SELECT k.*,p.id FROM keys k LEFT JOIN LATERAL (` + page + `) p ON true),
 ids AS (SELECT DISTINCT id FROM pages WHERE id IS NOT NULL),
 ` + metadataCTEs("ids", false) + `
 SELECT c.n,e.id,e.slug,e.title,e.description,e.created_at,e.updated_at,e.tags,e.fc,
 EXISTS(SELECT 1 FROM favorites f WHERE f.article_id=e.id AND f.user_id=r.p1),
 e.username,e.bio,e.image,
 EXISTS(SELECT 1 FROM follows fo WHERE fo.follower_id=r.p1 AND fo.followee_id=e.author_id),r.ord::bigint
 FROM requests r JOIN pages p ON ` + pageJoin + ` ` + totalJoin + `
 LEFT JOIN enriched e ON e.id=p.id ORDER BY r.ord,e.id DESC`
}

func sharedArticleSQL() string { return sharedArticleSQLFor(stArticleBySlug) }
func sharedArticleSQLFor(id stmtID) string {
	key := "a.slug"
	if id == stArticleByID {
		key = "a.id"
	}
	join := "e.slug"
	if id == stArticleByID {
		join = "e.id"
	}
	return `WITH requests AS MATERIALIZED (` + requestArrays(id) + `),
 keys AS (SELECT DISTINCT p2 FROM requests), ids AS (SELECT a.id FROM keys k JOIN articles a ON ` + key + `=k.p2),
 ` + metadataCTEs("ids", true) + `
 SELECT e.id,e.slug,e.title,e.description,e.body,e.created_at,e.updated_at,e.tags,e.fc,
 EXISTS(SELECT 1 FROM favorites f WHERE f.article_id=e.id AND f.user_id=r.p1),
 e.username,e.bio,e.image,
 EXISTS(SELECT 1 FROM follows fo WHERE fo.follower_id=r.p1 AND fo.followee_id=e.author_id),r.ord::bigint
 FROM requests r JOIN enriched e ON ` + join + `=r.p2 ORDER BY r.ord`
}

func sharedCommentsSQL() string {
	return `WITH requests AS MATERIALIZED (` + requestArrays(stComments) + `),
 keys AS (SELECT DISTINCT p2 FROM requests),
 threads AS MATERIALIZED (SELECT k.p2,a.id FROM keys k JOIN articles a ON a.slug=k.p2),
 comments_page AS MATERIALIZED (
 SELECT t.p2,c.* FROM threads t CROSS JOIN LATERAL (
 SELECT c.id,c.body,c.created_at,c.updated_at,c.author_id,u.username,u.bio,u.image
 FROM comments c JOIN users u ON u.id=c.author_id WHERE c.article_id=t.id
 ORDER BY c.created_at DESC,c.id DESC LIMIT 100) c)
 SELECT c.id,c.body,c.created_at,c.updated_at,c.username,c.bio,c.image,
 EXISTS(SELECT 1 FROM follows fo WHERE fo.follower_id=r.p1 AND fo.followee_id=c.author_id),r.ord::bigint
 FROM requests r JOIN threads t ON t.p2=r.p2 LEFT JOIN comments_page c ON c.p2=t.p2
 ORDER BY r.ord,c.created_at DESC,c.id DESC`
}

// Overlap is observed from these requests, never inferred from seeded data.
func usefulSharing(jobs []*reactorJob) bool {
	if len(jobs) < 2 {
		return false
	}
	if jobs[0].db.stmt == stTags {
		return true
	}
	unique := 0
	for i, j := range jobs {
		duplicate := false
		for _, previous := range jobs[:i] {
			same := true
			for p := 1; p < j.db.nparams; p++ {
				if !bytes.Equal(j.db.params[p], previous.db.params[p]) {
					same = false
					break
				}
			}
			if same {
				duplicate = true
				break
			}
		}
		if !duplicate {
			unique++
		}
	}
	switch jobs[0].db.stmt {
	case stListAll:
		return unique < len(jobs)
	case stListTag:
		return unique*3 <= len(jobs)*2
	case stListAuthor, stListFavorite:
		return unique*2 <= len(jobs) || len(jobs) >= 4 && unique*4 <= len(jobs)*3
	default:
		return unique*2 <= len(jobs)
	}
}

func encodeArray(dst []byte, jobs []*reactorJob, param int, oid uint32) []byte {
	dst = binary.BigEndian.AppendUint32(dst[:0], 1) // one dimension
	dst = binary.BigEndian.AppendUint32(dst, 1)     // NULLs permitted
	dst = binary.BigEndian.AppendUint32(dst, oid)
	dst = binary.BigEndian.AppendUint32(dst, uint32(len(jobs)))
	dst = binary.BigEndian.AppendUint32(dst, 1) // lower bound
	for _, j := range jobs {
		v := j.db.params[param]
		if v == nil {
			dst = binary.BigEndian.AppendUint32(dst, ^uint32(0))
			continue
		}
		dst = binary.BigEndian.AppendUint32(dst, uint32(len(v)))
		dst = append(dst, v...)
	}
	return dst
}

// ordinalRows retains one lookahead row without copying PostgreSQL buffers.
// Every encoder finishes before NextRow is called for the next recipient.
type ordinalRows struct {
	rr      *pgconn.ResultReader
	ordinal int64
	last    int64
	max     int64
	pending bool
	ended   bool
	values  [][]byte
	err     error
}

func (r *ordinalRows) NextRow() bool {
	if r.err != nil || r.ended {
		return false
	}
	if !r.pending {
		if !r.rr.NextRow() {
			r.ended = true
			return false
		}
		v := r.rr.Values()
		if len(v) == 0 || len(v[len(v)-1]) != 8 {
			r.err = errors.New("invalid shared-read ordinal")
			return false
		}
		ord := int8Value(v[len(v)-1])
		if ord < r.ordinal || ord < r.last || ord > r.max {
			r.err = errors.New("shared-read ordinal out of order")
			return false
		}
		r.last, r.values, r.pending = ord, v[:len(v)-1], true
	}
	if r.last != r.ordinal {
		return false
	}
	r.pending = false
	return true
}

func (r *ordinalRows) Values() [][]byte { return r.values }

func (w *worker) finishShared(jobs []*reactorJob, rr *pgconn.ResultReader) error {
	if jobs[0].db.stmt == stTags {
		act, err := w.safeFinish(jobs[0], rr)
		if err != nil {
			return err
		}
		jobs[0].db.next = act
		for _, j := range jobs[1:] {
			j.db.out = append(j.db.out[:0], jobs[0].response.body...)
			j.body(jobs[0].response.status)
			j.db.next = actDone
		}
		return nil
	}
	rows := ordinalRows{rr: rr, max: int64(len(jobs))}
	for i, j := range jobs {
		rows.ordinal = int64(i + 1)
		j.db.next = w.finishRows(j, &rows)
		// Single-row handlers need not call NextRow again. Drain to the next
		// ordinal without letting their borrowed columns outlive this step.
		for rows.NextRow() {
		}
		if rows.err != nil {
			_, _ = rr.Close()
			return rows.err
		}
	}
	_, err := rr.Close()
	return err
}

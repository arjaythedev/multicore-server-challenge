package server

import (
	"errors"
	"net/http"
	"slices"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

// Thread data and viewer flags share one statement snapshot. The first row
// shape contains each distinct thread's newest 100 comments; the second shape
// contains each viewer/author follow flag. Empty threads retain a NULL sentinel
// and missing articles produce no row. All sharing ends with this active batch.
const sharedCommentsSQL = `WITH data AS MATERIALIZED (
 SELECT r.ord, c.id, c.body, c.created_at, c.updated_at, c.author_id,
 u.username, u.bio, u.image
 FROM unnest($1::text[]) WITH ORDINALITY r(slug, ord)
 JOIN articles a ON a.slug = r.slug
 LEFT JOIN LATERAL (
   SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id
   FROM comments c WHERE c.article_id = a.id
   ORDER BY c.created_at DESC, c.id DESC LIMIT 100
 ) c ON true
 LEFT JOIN users u ON u.id = c.author_id
 ), refs AS (
 SELECT r.viewer, d.author_id
 FROM unnest($2::bigint[], $3::bigint[]) r(viewer, ord)
 JOIN data d ON d.ord = r.ord WHERE d.id IS NOT NULL
 )
 SELECT false, d.ord, d.id, d.body, d.created_at, d.updated_at, d.author_id,
 d.username, d.bio, d.image, NULL::bigint, false FROM data d
 UNION ALL
 SELECT true, NULL::bigint, NULL::bigint, NULL::text, NULL::timestamptz, NULL::timestamptz,
 r.author_id, NULL::text, NULL::text, NULL::text, r.viewer, true
 FROM refs r JOIN follows f ON f.follower_id = r.viewer AND f.followee_id = r.author_id`

type commentGroup struct {
	threads []string
	forCall []int
}

// Only repeated threads need materialization and viewer overlays. Unique
// threads keep the direct row shape and its single decoding pass.
type commentBatch struct {
	direct, shared []*queuedRead
	group          *commentGroup
}

func queueComments(batch *pgx.Batch, calls []*queuedRead) *commentBatch {
	b := new(commentBatch)
	counts := make(map[string]int)
	for _, call := range calls {
		counts[call.slug]++
	}
	for _, call := range calls {
		if counts[call.slug] == 1 {
			b.direct = append(b.direct, call)
		} else {
			b.shared = append(b.shared, call)
		}
	}
	if len(b.direct) > 0 {
		viewers, slugs := make([]int64, len(b.direct)), make([]string, len(b.direct))
		for i, call := range b.direct {
			viewers[i], slugs[i] = call.viewer, call.slug
		}
		batch.Queue(arrayCommentsSQL, viewers, slugs)
	}
	if len(b.shared) > 0 {
		b.group = queueSharedComments(batch, b.shared)
	}
	return b
}

func (b *commentBatch) decode(results pgx.BatchResults) error {
	if len(b.direct) > 0 {
		rows, err := results.Query()
		if err != nil {
			return err
		}
		if err := decodeReadGroup(readComments, b.direct, rows); err != nil {
			return err
		}
	}
	if b.group != nil {
		rows, err := results.Query()
		if err != nil {
			return err
		}
		return b.group.decode(b.shared, rows)
	}
	return nil
}

func queueSharedComments(batch *pgx.Batch, calls []*queuedRead) *commentGroup {
	g := &commentGroup{forCall: make([]int, len(calls))}
	threads := make(map[string]int)
	pairs := make(map[[2]int64]struct{})
	var viewers, ordinals []int64
	for i, call := range calls {
		thread, present := threads[call.slug]
		if !present {
			thread = len(g.threads)
			threads[call.slug] = thread
			g.threads = append(g.threads, call.slug)
		}
		g.forCall[i] = thread
		if call.viewer != 0 {
			key := [2]int64{call.viewer, int64(thread + 1)}
			if _, present := pairs[key]; !present {
				pairs[key] = struct{}{}
				viewers, ordinals = append(viewers, key[0]), append(ordinals, key[1])
			}
		}
	}
	batch.Queue(sharedCommentsSQL, g.threads, viewers, ordinals)
	return g
}

type commentMetadata struct {
	value   commentJSON
	author  int64
	created time.Time
}

type commentViewerAuthor struct{ viewer, author int64 }

func (g *commentGroup) decode(calls []*queuedRead, rows pgx.Rows) error {
	defer rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	if len(rows.FieldDescriptions()) != 12 {
		return errors.New("invalid shared comment columns")
	}
	threads := make([][]commentMetadata, len(g.threads))
	following := make(map[commentViewerAuthor]bool)
	var isFlags, follows bool
	var ordinal, viewer, author int64
	var metadata commentMetadata
	var updated time.Time
	kindPlan := (pgtype.BoolCodec{}).PlanScan(nil, pgtype.BoolOID, rows.FieldDescriptions()[0].Format, &isFlags)
	var dataDest, flagDest, emptyDest [12]any
	dataDest[1], dataDest[2], dataDest[3] = &ordinal, &metadata.value.ID, &metadata.value.Body
	dataDest[4], dataDest[5], dataDest[6] = &metadata.created, &updated, &metadata.author
	dataDest[7], dataDest[8], dataDest[9] = &metadata.value.Author.Username, &metadata.value.Author.Bio, &metadata.value.Author.Image
	flagDest[6], flagDest[10], flagDest[11] = &author, &viewer, &follows
	emptyDest[1] = &ordinal
	for rows.Next() {
		if err := kindPlan.Scan(rows.RawValues()[0], &isFlags); err != nil {
			return err
		}
		if isFlags {
			if err := rows.Scan(flagDest[:]...); err != nil {
				return err
			}
			following[commentViewerAuthor{viewer, author}] = follows
			continue
		}
		empty := rows.RawValues()[2] == nil
		if empty {
			if err := rows.Scan(emptyDest[:]...); err != nil {
				return err
			}
		} else {
			if err := rows.Scan(dataDest[:]...); err != nil {
				return err
			}
		}
		if ordinal < 1 || ordinal > int64(len(threads)) {
			return errors.New("invalid comment thread ordinal")
		}
		i := ordinal - 1
		if threads[i] == nil {
			threads[i] = make([]commentMetadata, 0)
		}
		if !empty {
			metadata.value.CreatedAt, metadata.value.UpdatedAt = ts(metadata.created), ts(updated)
			threads[i] = append(threads[i], metadata)
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	for _, thread := range threads {
		// UNION output order is unspecified. Sort the bounded unique threads
		// with full timestamp precision, before millisecond JSON truncation.
		slices.SortFunc(thread, func(a, b commentMetadata) int {
			if n := b.created.Compare(a.created); n != 0 {
				return n
			}
			if a.value.ID > b.value.ID {
				return -1
			}
			if a.value.ID < b.value.ID {
				return 1
			}
			return 0
		})
	}
	for i, call := range calls {
		thread := threads[g.forCall[i]]
		if thread == nil {
			continue
		}
		output := make([]commentJSON, len(thread))
		for j := range thread {
			output[j] = thread[j].value
			output[j].Author.Following = following[commentViewerAuthor{call.viewer, thread[j].author}]
		}
		call.status, call.body = http.StatusOK, nil
		call.value = struct {
			Comments []commentJSON `json:"comments"`
		}{output}
	}
	return nil
}

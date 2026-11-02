package server

import (
	"context"
	"errors"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

// Page selection does not depend on the viewing user, except for feeds.
// Identical pages in this active batch share one ID lookup and capped count.
type pageKey struct {
	limit, offset, viewer int64
	filter                string
}

type pageResult struct {
	key   pageKey
	ids   []int64
	count int64
}

type pageGroup struct {
	pages   []pageResult
	forCall []int
}

type articleListJSON struct {
	Articles      []articleJSON `json:"articles"`
	ArticlesCount int64         `json:"articlesCount"`
}

// The page and count return even for an empty page. In particular, a capped
// count of 1000 does not imply that offsets >= 1000 have no articles.
var pageQueries = func() [readKinds]string {
	var queries [readKinds]string
	for kind, spec := range map[readKind]struct{ ids, count string }{
		readGlobal: {`SELECT a.id FROM articles a ORDER BY a.id DESC LIMIT r.lim OFFSET r.off`, countAll},
		readTag: {`SELECT at.article_id FROM article_tags at
 WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.filter)
 ORDER BY at.article_id DESC LIMIT r.lim OFFSET r.off`, strings.ReplaceAll(countByTag, "$1", "r.filter")},
		readAuthor: {`SELECT a.id FROM articles a
 WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = r.filter)
 ORDER BY a.id DESC LIMIT r.lim OFFSET r.off`, strings.ReplaceAll(countByAuthor, "$1", "r.filter")},
		readFavorite: {`SELECT f.article_id FROM favorites f
 WHERE f.user_id = (SELECT u.id FROM users u WHERE u.username = r.filter)
 ORDER BY f.article_id DESC LIMIT r.lim OFFSET r.off`, strings.ReplaceAll(countByFavorite, "$1", "r.filter")},
		readFeed: {`SELECT x.id FROM follows fo CROSS JOIN LATERAL (
 SELECT a.id FROM articles a WHERE a.author_id = fo.followee_id
 ORDER BY a.id DESC LIMIT (r.lim::int + r.off::int)
 ) x WHERE fo.follower_id = r.viewer ORDER BY x.id DESC LIMIT r.lim OFFSET r.off`, strings.ReplaceAll(countFeed, "$1", "r.viewer")},
	} {
		queries[kind] = `SELECT r.ord, ARRAY(` + spec.ids + `), (` + spec.count + `)
 FROM unnest($1::bigint[], $2::bigint[], $3::text[], $4::bigint[])
 WITH ORDINALITY r(lim, off, filter, viewer, ord)`
	}
	return queries
}()

func queuePages(batch *pgx.Batch, kind readKind, calls []*queuedRead) *pageGroup {
	g := &pageGroup{forCall: make([]int, len(calls))}
	indices := make(map[pageKey]int, len(calls))
	for i, call := range calls {
		key := pageKey{limit: call.limit, offset: call.offset, filter: call.filter}
		if kind == readFeed {
			key.viewer = call.viewer
		}
		index, exists := indices[key]
		if !exists {
			index = len(g.pages)
			indices[key] = index
			g.pages = append(g.pages, pageResult{key: key})
		}
		g.forCall[i] = index
	}
	limits, offsets := make([]int64, len(g.pages)), make([]int64, len(g.pages))
	filters, viewers := make([]string, len(g.pages)), make([]int64, len(g.pages))
	for i, page := range g.pages {
		limits[i], offsets[i], filters[i], viewers[i] = page.key.limit, page.key.offset, page.key.filter, page.key.viewer
	}
	batch.Queue(pageQueries[kind], limits, offsets, filters, viewers)
	return g
}

func (g *pageGroup) decode(calls []*queuedRead, rows pgx.Rows) error {
	defer rows.Close()
	for rows.Next() {
		var ordinal, count int64
		var ids []int64
		if err := rows.Scan(&ordinal, &ids, &count); err != nil {
			return err
		}
		if ordinal < 1 || ordinal > int64(len(g.pages)) {
			return errors.New("invalid page batch ordinal")
		}
		g.pages[ordinal-1].ids, g.pages[ordinal-1].count = ids, count
	}
	if err := rows.Err(); err != nil {
		return err
	}
	for i, call := range calls {
		page := g.pages[g.forCall[i]]
		call.status, call.body, call.articleIDs, call.count = http.StatusOK, nil, page.ids, page.count
		call.value = articleListJSON{Articles: []articleJSON{}, ArticlesCount: page.count}
	}
	return nil
}

// Only requested full-article bodies cross the wire. List responses share
// immutable metadata and tags, then copy the struct to apply viewer flags.
const sharedArticleSQL = `WITH data AS MATERIALIZED (
 SELECT a.id, a.author_id, a.slug, a.title, a.description,
 CASE WHEN a.id = ANY($2::bigint[]) THEN a.body END AS body, a.created_at, a.updated_at,
 ` + articleTagNames + ` AS tag_list,
 (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, u.username, u.bio, u.image
 FROM unnest($1::bigint[]) r(id) JOIN articles a ON a.id = r.id
 JOIN users u ON u.id = a.author_id
 ) SELECT false, d.id, d.slug, d.title, d.description, d.body, d.created_at, d.updated_at,
 d.tag_list, d.favorites_count, d.username, d.bio, d.image, NULL::bigint, false, false FROM data d
 UNION ALL
 SELECT true, r.id, NULL::text, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz,
 NULL::text[], NULL::bigint, NULL::text, NULL::text, NULL::text, r.viewer,
 f.article_id IS NOT NULL, fo.followee_id IS NOT NULL
 FROM unnest($3::bigint[], $4::bigint[]) r(viewer, id) JOIN data d ON d.id = r.id
 LEFT JOIN favorites f ON f.user_id = r.viewer AND f.article_id = r.id
 LEFT JOIN follows fo ON fo.follower_id = r.viewer AND fo.followee_id = d.author_id
 WHERE f.article_id IS NOT NULL OR fo.followee_id IS NOT NULL`

type articleViewer struct{ viewer, id int64 }
type articleFlags struct{ favorited, following bool }

// Ordering the distinct metadata lookups does not change response ordering:
// each response is assembled below from its original articleIDs.
var sortReadArticleIDs = envOr("READ_SORT_IDS", "0") == "1"

func (q *readQueue) enrichArticles(ctx context.Context, calls []*queuedRead) (int, error) {
	wanted := make(map[int64]bool)
	flags := make(map[articleViewer]articleFlags)
	var refs, pairs int
	for _, call := range calls {
		if call.err != nil {
			continue
		}
		if err := call.ctx.Err(); err != nil {
			call.err = err
			continue
		}
		for _, id := range call.articleIDs {
			refs++
			wanted[id] = wanted[id] || call.kind == readArticle
		}
		if call.viewer != 0 {
			pairs += len(call.articleIDs)
		}
	}
	if refs == 0 {
		return 0, nil
	}
	ids, fullIDs := make([]int64, 0, len(wanted)), make([]int64, 0)
	for id, full := range wanted {
		ids = append(ids, id)
		if full {
			fullIDs = append(fullIDs, id)
		}
	}
	if sortReadArticleIDs {
		slices.Sort(ids)
	}
	// The decoded struct already escapes through Rows.Scan. Store its pointer
	// so the map does not allocate a second, indirect copy of this large value.
	articles := make(map[int64]*articleJSON, len(wanted))
	viewers, targets := make([]int64, 0, pairs), make([]int64, 0, pairs)
	for _, call := range calls {
		if call.err != nil || call.viewer == 0 {
			continue
		}
		for range call.articleIDs {
			viewers = append(viewers, call.viewer)
		}
		targets = append(targets, call.articleIDs...)
	}
	var batch pgx.Batch
	// Metadata and flags use one snapshot and reuse the same article lookup.
	// The leading boolean identifies the two row shapes. NULL destinations
	// skip the unused columns without decoding or allocating their values.
	query := sharedArticleSQL
	if readArticleTagDictionary {
		query = sharedArticleDictionarySQL
	}
	batch.Queue(query, ids, fullIDs, viewers, targets).Query(func(rows pgx.Rows) error {
		if err := rows.Err(); err != nil {
			return err
		}
		if readArticleTagDictionary {
			var err error
			_, err = decodeDictionaryArticles(rows, articles, flags, len(wanted))
			return err
		}
		if len(rows.FieldDescriptions()) != 16 {
			return errors.New("invalid shared article columns")
		}
		var isFlags bool
		kindPlan := (pgtype.BoolCodec{}).PlanScan(nil, pgtype.BoolOID, rows.FieldDescriptions()[0].Format, &isFlags)
		var id int64
		var created, updated time.Time
		var dest [16]any
		dest[1], dest[6], dest[7] = &id, &created, &updated
		var key articleViewer
		var value articleFlags
		var flagDest [16]any
		flagDest[1], flagDest[13], flagDest[14], flagDest[15] = &key.id, &key.viewer, &value.favorited, &value.following
		for rows.Next() {
			if err := kindPlan.Scan(rows.RawValues()[0], &isFlags); err != nil {
				return err
			}
			if isFlags {
				if err := rows.Scan(flagDest[:]...); err != nil {
					return err
				}
				flags[key] = value
				continue
			}
			x := new(articleJSON)
			dest[2], dest[3], dest[4], dest[5] = &x.Slug, &x.Title, &x.Description, &x.Body
			dest[8], dest[9] = &x.TagList, &x.FavoritesCount
			dest[10], dest[11], dest[12] = &x.Author.Username, &x.Author.Bio, &x.Author.Image
			if err := rows.Scan(dest[:]...); err != nil {
				return err
			}
			x.CreatedAt, x.UpdatedAt = ts(created), ts(updated)
			if x.TagList == nil {
				x.TagList = []string{}
			}
			articles[id] = x
		}
		return rows.Err()
	})
	if err := q.pool.SendBatch(ctx, &batch).Close(); err != nil {
		return batch.Len(), err
	}
	for _, call := range calls {
		if call.err != nil || len(call.articleIDs) == 0 {
			continue
		}
		if call.kind == readArticle {
			id := call.articleIDs[0]
			stored, present := articles[id]
			if !present {
				call.status, call.value = http.StatusNotFound, nil
				call.body = []byte(`{"errors":{"body":["article not found"]}}`)
				continue
			}
			viewerFlags := flags[articleViewer{call.viewer, id}]
			call.value = articleViewResponse{articleView{metadata: stored, flags: viewerFlags, full: true}}
			continue
		}
		output := make([]articleView, 0, len(call.articleIDs))
		for _, id := range call.articleIDs {
			stored, present := articles[id]
			if !present {
				continue // An article may have been deleted since page selection.
			}
			viewerFlags := flags[articleViewer{call.viewer, id}]
			output = append(output, articleView{metadata: stored, flags: viewerFlags})
		}
		call.value = articleViewList{articles: output, count: call.count}
	}
	return batch.Len(), nil
}

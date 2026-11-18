package server

import (
	"errors"
	"slices"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

var readArticleTagDictionary = envOr("READ_TAG_DICTIONARY", "0") == "1"

// NULL in the leading boolean marks the dictionary. Its two parallel arrays
// carry PostgreSQL's name order, so Go need not reproduce the DB collation.
// All three row shapes use one statement snapshot; result order is immaterial.
const sharedArticleDictionarySQL = `WITH data AS MATERIALIZED (
 SELECT a.id, a.author_id, a.slug, a.title, a.description,
 CASE WHEN a.id = ANY($2::bigint[]) THEN a.body END AS body, a.created_at, a.updated_at,
 ARRAY(SELECT at.tag_id FROM article_tags at WHERE at.article_id = a.id) AS tag_list,
 (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, u.username, u.bio, u.image
 FROM unnest($1::bigint[]) r(id) JOIN articles a ON a.id = r.id
 JOIN users u ON u.id = a.author_id
 ) SELECT NULL::boolean, NULL::bigint, NULL::text, NULL::text, NULL::text, NULL::text,
 NULL::timestamptz, NULL::timestamptz, array_agg(t.id ORDER BY t.name), NULL::bigint,
 NULL::text, NULL::text, NULL::text, NULL::bigint, false, false,
 array_agg(t.name ORDER BY t.name) FROM tags t
 UNION ALL
 SELECT false, d.id, d.slug, d.title, d.description, d.body, d.created_at, d.updated_at,
 d.tag_list, d.favorites_count, d.username, d.bio, d.image, NULL::bigint, false, false, NULL::text[] FROM data d
 UNION ALL
 SELECT true, r.id, NULL::text, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz,
 NULL::bigint[], NULL::bigint, NULL::text, NULL::text, NULL::text, r.viewer,
 f.article_id IS NOT NULL, fo.followee_id IS NOT NULL, NULL::text[]
 FROM unnest($3::bigint[], $4::bigint[]) r(viewer, id) JOIN data d ON d.id = r.id
 LEFT JOIN favorites f ON f.user_id = r.viewer AND f.article_id = r.id
 LEFT JOIN follows fo ON fo.follower_id = r.viewer AND fo.followee_id = d.author_id
 WHERE f.article_id IS NOT NULL OR fo.followee_id IS NOT NULL`

// Append each metadata row's tag IDs to one batch-owned array. pgx's ordinary
// []int64 destination allocates an array for every row, even when reused.
// Each ScanIndex pointer is obtained after any growth, before this row scans.
type articleTagIDs struct {
	values []int64
	start  int
	scalar int64
}

func (a *articleTagIDs) SetDimensions(dimensions []pgtype.ArrayDimension) error {
	if dimensions == nil || len(dimensions) > 1 {
		return errors.New("invalid article tag array dimensions")
	}
	n := 0
	if len(dimensions) == 1 {
		n = int(dimensions[0].Length)
		if n < 0 {
			return errors.New("invalid article tag array length")
		}
	}
	a.start = len(a.values)
	a.values = slices.Grow(a.values, n)
	a.values = a.values[:a.start+n]
	return nil
}

func (a *articleTagIDs) ScanIndex(i int) any { return &a.values[a.start+i] }
func (a *articleTagIDs) ScanIndexType() any  { return &a.scalar }

// Once the dictionary arrives, translate IDs directly into a reusable rank
// array while pgx scans. Only the final immutable name slice belongs to a row.
type articleTagRanks struct {
	byID   map[int64]int
	values []int
	index  int
}

func (a *articleTagRanks) SetDimensions(dimensions []pgtype.ArrayDimension) error {
	if dimensions == nil || len(dimensions) > 1 {
		return errors.New("invalid article tag array dimensions")
	}
	n := 0
	if len(dimensions) == 1 {
		n = int(dimensions[0].Length)
		if n < 0 {
			return errors.New("invalid article tag array length")
		}
	}
	a.values = slices.Grow(a.values[:0], n)[:n]
	return nil
}

func (a *articleTagRanks) ScanIndex(i int) any { a.index = i; return a }
func (a *articleTagRanks) ScanIndexType() any  { return a }
func (a *articleTagRanks) ScanInt64(value pgtype.Int8) error {
	if !value.Valid {
		return errors.New("NULL article tag ID")
	}
	rank, exists := a.byID[value.Int64]
	if !exists {
		return errors.New("article tag missing from dictionary")
	}
	a.values[a.index] = rank
	return nil
}

func articleNamesByRank(ranks []int, names []string) []string {
	slices.Sort(ranks)
	result := make([]string, len(ranks))
	for i, rank := range ranks {
		result[i] = names[rank]
	}
	return result
}

func decodeDictionaryArticles(rows pgx.Rows, articles map[int64]*articleJSON, flags map[articleViewer]articleFlags, requested int) (int, error) {
	if len(rows.FieldDescriptions()) != 17 {
		return 0, errors.New("invalid dictionary article columns")
	}
	var marker pgtype.Bool
	kindPlan := (pgtype.BoolCodec{}).PlanScan(nil, pgtype.BoolOID, rows.FieldDescriptions()[0].Format, &marker)
	var id int64
	var created, updated time.Time
	var ids *articleTagIDs
	var ranks articleTagRanks
	type pendingTags struct {
		article    *articleJSON
		start, end int
	}
	var pending []pendingTags
	var dest [17]any
	dest[1], dest[6], dest[7] = &id, &created, &updated
	var key articleViewer
	var value articleFlags
	var flagDest [17]any
	flagDest[1], flagDest[13], flagDest[14], flagDest[15] = &key.id, &key.viewer, &value.favorited, &value.following
	var dictionaryIDs []int64
	var dictionaryNames []string
	var dictionaryDest [17]any
	dictionaryDest[8], dictionaryDest[16] = &dictionaryIDs, &dictionaryNames
	seenDictionary, flagRows := false, 0
	for rows.Next() {
		if err := kindPlan.Scan(rows.RawValues()[0], &marker); err != nil {
			return 0, err
		}
		if !marker.Valid {
			if seenDictionary {
				return 0, errors.New("duplicate article tag dictionary")
			}
			if err := rows.Scan(dictionaryDest[:]...); err != nil {
				return 0, err
			}
			if len(dictionaryIDs) != len(dictionaryNames) {
				return 0, errors.New("invalid article tag dictionary")
			}
			ranks.byID = make(map[int64]int, len(dictionaryIDs))
			for rank, id := range dictionaryIDs {
				if _, exists := ranks.byID[id]; exists {
					return 0, errors.New("duplicate article tag ID")
				}
				ranks.byID[id] = rank
			}
			seenDictionary = true
			continue
		}
		if marker.Bool {
			if err := rows.Scan(flagDest[:]...); err != nil {
				return 0, err
			}
			flags[key] = value
			flagRows++
			continue
		}
		x := new(articleJSON)
		if seenDictionary {
			dest[8] = &ranks
		} else {
			// SQL does not promise UNION ALL row order. Keep an owned fallback
			// when metadata precedes the dictionary; allocate it only then.
			if ids == nil {
				ids = &articleTagIDs{values: make([]int64, 0, requested*3)}
				pending = make([]pendingTags, 0, requested)
			}
			dest[8] = ids
		}
		dest[2], dest[3], dest[4], dest[5] = &x.Slug, &x.Title, &x.Description, &x.Body
		dest[9], dest[10], dest[11], dest[12] = &x.FavoritesCount, &x.Author.Username, &x.Author.Bio, &x.Author.Image
		if err := rows.Scan(dest[:]...); err != nil {
			return 0, err
		}
		x.CreatedAt, x.UpdatedAt = ts(created), ts(updated)
		articles[id] = x
		if seenDictionary {
			x.TagList = articleNamesByRank(ranks.values, dictionaryNames)
		} else {
			pending = append(pending, pendingTags{x, ids.start, len(ids.values)})
		}
	}
	if err := rows.Err(); err != nil {
		return 0, err
	}
	if !seenDictionary {
		return 0, errors.New("invalid article tag dictionary")
	}
	for _, item := range pending {
		ranks.values = ranks.values[:0]
		for _, id := range ids.values[item.start:item.end] {
			rank, exists := ranks.byID[id]
			if !exists {
				return 0, errors.New("article tag missing from dictionary")
			}
			ranks.values = append(ranks.values, rank)
		}
		item.article.TagList = articleNamesByRank(ranks.values, dictionaryNames)
	}
	return flagRows, nil
}

package main

import (
	"slices"

	"multicorelab/http/conduit"
)

// The decomposed forms (experiments/sql-rewrite, forms CU and C). A flush asks Postgres in two round trips:
//  1. the ids of every page of every list and feed (one LATERAL statement per kind for all pages, one for all
//     counts), and the heads of the single articles asked for;
//  2. for the union of the ids, one statement each for the heads, the tag lists and the favorites counts, and
//     one for the viewers' favorited/following flags.
// Everything is keyed by article id, so an article that appears in several lists is read once. All of it
// lives only until the responses of the flush are encoded.

const (
	famGlobal = int(conduit.NoFilter)
	famTag    = int(conduit.ByTag)
	famAuthor = int(conduit.ByAuthor)
	famFav    = int(conduit.ByFavorited)
	famFeed   = 4
	nFams     = 5
)

// pageKey identifies one page: the filter value (or the viewer, for the feed), offset and limit.
type pageKey struct {
	v        string
	viewer   int64
	off, lim int64
}

type famCount struct {
	v      string
	viewer int64
}

var famLateral = [nFams]string{
	famGlobal: `SELECT a.id FROM articles a ORDER BY a.id DESC LIMIT k.lim OFFSET k.off`,
	famTag: `SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = k.v)
 ORDER BY at.article_id DESC LIMIT k.lim OFFSET k.off`,
	famAuthor: `SELECT a.id FROM articles a WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = k.v)
 ORDER BY a.id DESC LIMIT k.lim OFFSET k.off`,
	famFav: `SELECT f.article_id AS id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = k.v)
 ORDER BY f.article_id DESC LIMIT k.lim OFFSET k.off`,
	famFeed: `SELECT x.id FROM follows fo CROSS JOIN LATERAL
    (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT (k.lim::int + k.off::int)) x
  WHERE fo.follower_id = k.v ORDER BY x.id DESC LIMIT k.lim OFFSET k.off`,
}

var famCountSQL = [nFams]string{
	// The global and tag counts are capped at 1000: an existence probe at offset 999 settles the capped case
	// without counting a thousand index entries. Author, favorited and feed counts keep the LIMIT form, where the
	// probe is no cheaper.
	famGlobal: `SELECT CASE WHEN EXISTS (SELECT 1 FROM articles OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM articles) END`,
	famTag: `SELECT CASE WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = k.v) OFFSET 999 LIMIT 1) THEN 1000::bigint
             ELSE (SELECT count(*) FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = k.v)) END`,
	famAuthor: `SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = k.v) LIMIT 1000) s`,
	famFav:    `SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = k.v) LIMIT 1000) s`,
	famFeed:   `SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = k.v) LIMIT 1000) s`,
}

var famPageSQL, famCountsSQL [nFams]string

func init() {
	for f := 0; f < nFams; f++ {
		typ := "text"
		if f == famFeed {
			typ = "bigint"
		}
		famPageSQL[f] = `SELECT k.ord, x.id FROM unnest($1::` + typ + `[], $2::bigint[], $3::bigint[]) WITH ORDINALITY AS k(v, off, lim, ord)
 CROSS JOIN LATERAL (` + famLateral[f] + `) x`
		if f != famGlobal {
			famCountsSQL[f] = `SELECT k.ord, (` + famCountSQL[f] + `) FROM unnest($1::` + typ + `[]) WITH ORDINALITY AS k(v, ord)`
		}
	}
}

const (
	headColumns   = `a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, u.username, u.bio, u.image, a.author_id`
	sqlHeadsByID  = `SELECT ` + headColumns + ` FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = ANY($1::bigint[])`
	sqlFullBySlug = `SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, u.username, u.bio, u.image, a.author_id
  FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = ANY($1::text[])`
	// The tag name comes from a scalar subplan: cheaper than joining tags (sql-session-levers, 29.5 to 19.9 us).
	// Tag names come from a per-flush dictionary (tagdict.go), ranked by the database's own order: correct under
	// any collation and cheaper than aggregating names in SQL.
	sqlTagIDs    = `SELECT article_id, tag_id FROM article_tags WHERE article_id = ANY($1::bigint[])`
	sqlFavCounts = `SELECT f.article_id, count(*) FROM favorites f WHERE f.article_id = ANY($1::bigint[]) GROUP BY f.article_id`
	// Flags at their real granularity: favorites per (viewer, article), following per (viewer, author). The favorite
	// probe is a plain join (favorites_pkey is unique, so one row per pair). In a feed following is known to be true, so only favorites are probed there.
	sqlFavs = `SELECT p.ord FROM unnest($1::bigint[], $2::bigint[]) WITH ORDINALITY AS p(v, a, ord)
  JOIN favorites f ON f.user_id = p.v AND f.article_id = p.a`
	// Following for (viewer, author) pairs already known, from the single-article rows of the first round.
	sqlFollowsByAuthor = `SELECT p.v, p.au FROM (SELECT DISTINCT v, au FROM unnest($1::bigint[], $2::bigint[]) AS d(v, au) OFFSET 0) p
 WHERE EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = p.v AND fo.followee_id = p.au)`
	// Following for list articles, whose authors arrive in the same round: the authors are looked up and
	// deduplicated per viewer here, so an author's page costs one probe, not one per article.
	sqlFollowsByArticle = `SELECT p.v, p.au FROM (SELECT DISTINCT d.v, x.author_id AS au
    FROM unnest($1::bigint[], $2::bigint[]) AS d(v, a) JOIN articles x ON x.id = d.a OFFSET 0) p
 WHERE EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = p.v AND fo.followee_id = p.au)`
)

// scanHead reads the columns of headColumns (plus the body for the single-article views).
func scanHead(rows *pgRows, withBody bool, a *artRow) {
	a.id, a.slug, a.title, a.desc = rows.i64(0), rows.str(1), rows.str(2), rows.str(3)
	i := 4
	if withBody {
		a.body = rows.str(i)
		i++
	}
	a.created, a.updated = rows.micros(i), rows.micros(i+1)
	a.username, a.bio, a.image, a.authorID = rows.str(i+2), rows.nstr(i+3), rows.nstr(i+4), rows.i64(i+5)
}

type idPair struct{ viewer, art int64 }

// stage2 is what a decomposed group still needs after the first round trip.
type stage2 struct {
	ops []*opState
	run func(sb *stmtBatch) (fin func())
}

// qDecomposed queues the first-round statements of every list, feed and single-article request of the flush and
// returns the second round.
func (w *worker) qDecomposed(sb *stmtBatch, lists, feeds, bySlug []*opState) *stage2 {
	if len(lists)+len(feeds)+len(bySlug) == 0 {
		return &stage2{}
	}
	var fam [nFams]struct {
		keys   []pageKey
		idx    map[pageKey]int
		pages  [][]int64
		spans  []span // each page's ids as slots of the flush's article table, in flat
		ckeys  []famCount
		cidx   map[famCount]int
		counts []int64
	}
	for i := range fam {
		fam[i].idx, fam[i].cidx = map[pageKey]int{}, map[famCount]int{}
	}
	var all []*opState
	var famReqs [nFams]int
	add := func(s *opState, f int, pk pageKey, ck famCount) {
		famReqs[f]++
		r := &fam[f]
		s.slot, s.slot2 = slotOf(r.idx, &r.keys, pk, w.share), slotOf(r.cidx, &r.ckeys, ck, w.share)
		all = append(all, s)
	}
	for _, s := range lists {
		c := s.c
		add(s, int(c.Filter), pageKey{v: string(c.FilterValue), off: c.Offset, lim: c.Limit}, famCount{v: string(c.FilterValue)})
	}
	for _, s := range feeds {
		c := s.c
		add(s, famFeed, pageKey{viewer: c.Viewer, off: c.Offset, lim: c.Limit}, famCount{viewer: c.Viewer})
	}
	for f := range fam {
		r := &fam[f]
		if len(r.keys) == 0 {
			continue
		}
		statFam(f, famReqs[f], len(r.keys))
		statFam(nFams+f, famReqs[f], len(r.ckeys))
		r.pages = make([][]int64, len(r.keys))
		r.counts = make([]int64, len(r.ckeys))
		offs, lims := make([]int64, len(r.keys)), make([]int64, len(r.keys))
		var vals any
		if f == famFeed {
			v := make([]int64, len(r.keys))
			for i, k := range r.keys {
				v[i] = k.viewer
			}
			vals = v
		} else {
			v := make([]string, len(r.keys))
			for i, k := range r.keys {
				v[i] = k.v
			}
			vals = v
		}
		for i, k := range r.keys {
			offs[i], lims[i] = k.off, k.lim
		}
		pages := r.pages
		sb.query(famPageSQL[f], []any{vals, offs, lims}, func(rows *pgRows) error {
			for rows.Next() {
				ord := rows.i64(0) - 1
				pages[ord] = append(pages[ord], rows.i64(1))
			}
			return rows.err
		})
		counts := r.counts
		if f == famGlobal {
			// Every global count key is the same query: one execution per key, or one in all when shared.
			for i := range counts {
				sb.query(famCountSQL[f], nil, readCount(&counts[i]))
			}
			continue
		}
		var cv any
		if f == famFeed {
			v := make([]int64, len(r.ckeys))
			for i, k := range r.ckeys {
				v[i] = k.viewer
			}
			cv = v
		} else {
			v := make([]string, len(r.ckeys))
			for i, k := range r.ckeys {
				v[i] = k.v
			}
			cv = v
		}
		sb.query(famCountsSQL[f], []any{cv}, func(rows *pgRows) error {
			for rows.Next() {
				counts[rows.i64(0)-1] = rows.i64(1)
			}
			return rows.err
		})
	}

	// Single articles: the full head, by slug or by id.
	slugSlot := map[string]int{}
	var slugs []string
	for _, s := range bySlug {
		s.slot = slotOf(slugSlot, &slugs, string(s.c.Slug), w.share)
	}
	var singles []*artRow
	bySlugRow := map[string]*artRow{}
	readFull := func(rows *pgRows) error {
		return readHeads(rows, true, func(a *artRow) {
			singles = append(singles, a)
			bySlugRow[a.slug] = a
		})
	}
	if len(slugs) > 0 {
		sb.query(sqlFullBySlug, []any{slugs}, readFull)
	}

	statFam(famStatArticles, len(bySlug), len(slugs))
	ops := slices.Concat(all, bySlug)
	return &stage2{ops: ops, run: func(sb2 *stmtBatch) func() {
		// The articles the responses need, once each: the list pages' first, then the single views'.
		tab := &w.tab
		tab.reset()
		flat := w.flat[:0]
		pageIDs := 0
		for f := range fam {
			r := &fam[f]
			r.spans = make([]span, len(r.pages))
			for i, pg := range r.pages {
				slices.Sort(pg)
				slices.Reverse(pg)
				r.spans[i].lo = len(flat)
				for _, id := range pg {
					flat = append(flat, tab.add(id))
				}
				r.spans[i].hi = len(flat)
				pageIDs += len(pg)
			}
		}
		w.flat = flat
		nList := len(tab.ids)
		for _, a := range singles {
			tab.add(a.id)
		}
		lids, ids := tab.ids[:nList], tab.ids
		statFam(famStatIDs, pageIDs+len(singles), len(ids))
		// Flag probes: favorites per distinct (viewer, article); following per distinct (viewer, author), by
		// author id for the single articles and by article id for list pages (the feed needs none).
		favSlot := map[idPair]int{}
		var favPairs []idPair
		favRef := w.favRef[:0] // per list request with a viewer: the favorites probe of each page position
		favReqs := 0
		folListSlot := map[idPair]int{}
		var folList []idPair
		folListReqs := 0
		folDirSlot := map[idPair]int{}
		var folDir []idPair
		folDirReqs := 0
		famOf := func(s *opState) int {
			if s.c.Endpoint == conduit.Feed {
				return famFeed
			}
			return int(s.c.Filter)
		}
		for _, s := range all {
			if s.c.Viewer == 0 {
				continue
			}
			feed := s.c.Endpoint == conduit.Feed
			s.favLo = len(favRef)
			for _, id := range fam[famOf(s)].pages[s.slot] {
				favReqs++
				favRef = append(favRef, int32(slotOf(favSlot, &favPairs, idPair{s.c.Viewer, id}, w.share)))
				if !feed {
					folListReqs++
					slotOf(folListSlot, &folList, idPair{s.c.Viewer, id}, w.share)
				}
			}
		}
		w.favRef = favRef
		for _, s := range bySlug {
			s.slot2 = -1
			if a := bySlugRow[string(s.c.Slug)]; a != nil && s.c.Viewer != 0 {
				favReqs++
				s.slot2 = slotOf(favSlot, &favPairs, idPair{s.c.Viewer, a.id}, w.share)
				folDirReqs++
				slotOf(folDirSlot, &folDir, idPair{s.c.Viewer, a.authorID}, w.share)
			}
		}
		statFam(famStatFlagsFav, favReqs, len(favPairs))
		statFam(famStatFlagsFol, folListReqs+folDirReqs, len(folList)+len(folDir))

		tab.size()
		favHit := fit(w.favHit, len(favPairs))
		w.favHit = favHit
		followed := map[idPair]bool{} // (viewer, author)
		var tagPairs []tagPair
		if len(lids) > 0 {
			sb2.query(sqlHeadsByID, []any{lids}, func(rows *pgRows) error {
				return readHeads(rows, false, func(a *artRow) { tab.head[tab.slot[a.id]] = a })
			})
		}
		if len(ids) > 0 {
			// The tag ids first, then (unless this flush already read it for the tag list) the dictionary: a tag
			// created in between is then in the dictionary.
			tagPairs = w.tagPairs[:0]
			sb2.query(sqlTagIDs, []any{ids}, func(rows *pgRows) error {
				for rows.Next() {
					tagPairs = append(tagPairs, tagPair{tab.slot[rows.i64(0)], rows.i64(1)})
				}
				return rows.err
			})
			if !w.dict.ok {
				sb2.query(sqlTagDict, nil, w.readDict)
			}
			sb2.query(sqlFavCounts, []any{ids}, func(rows *pgRows) error {
				for rows.Next() {
					tab.favs[tab.slot[rows.i64(0)]] = rows.i64(1)
				}
				return rows.err
			})
		}
		if len(favPairs) > 0 {
			vs, as := pairArrays(favPairs)
			sb2.query(sqlFavs, []any{vs, as}, func(rows *pgRows) error {
				for rows.Next() {
					favHit[rows.i64(0)-1] = true
				}
				return rows.err
			})
		}
		readFollowed := func(rows *pgRows) error {
			for rows.Next() {
				followed[idPair{rows.i64(0), rows.i64(1)}] = true
			}
			return rows.err
		}
		if len(folDir) > 0 {
			vs, as := pairArrays(folDir)
			sb2.query(sqlFollowsByAuthor, []any{vs, as}, readFollowed)
		}
		if len(folList) > 0 {
			vs, as := pairArrays(folList)
			sb2.query(sqlFollowsByArticle, []any{vs, as}, readFollowed)
		}

		return func() {
			if len(ids) > 0 {
				w.tagPairs = tagPairs[:0]
				if !w.assembleTags(tab, tagPairs) {
					failAll(ops, 500, "internal error")
					return
				}
			}
			for _, s := range all {
				feed := s.c.Endpoint == conduit.Feed
				f := famOf(s)
				viewer := s.c.Viewer
				sp := fam[f].spans[s.slot]
				op := s.op
				op.Resp = append(op.Resp, `{"articles":[`...)
				first := true
				for k, ps := range flat[sp.lo:sp.hi] {
					h := tab.head[ps]
					if h == nil {
						continue
					}
					v := artView{tags: tab.tags[ps], favCount: tab.favs[ps]}
					if viewer != 0 {
						v.favorited = favHit[favRef[s.favLo+k]]
						v.following = feed || followed[idPair{viewer, h.authorID}]
					}
					if !first {
						op.Resp = append(op.Resp, ',')
					}
					first = false
					if w.share {
						op.Resp = tab.appendList(op.Resp, ps, v)
					} else {
						op.Resp = appendArticleView(op.Resp, h, v, false)
					}
				}
				finishList(s, fam[f].counts[s.slot2])
			}
			for _, s := range bySlug {
				op := s.op
				base := bySlugRow[string(s.c.Slug)]
				if base == nil {
					conduit.Fail(op, 404, "article not found")
					s.done()
					continue
				}
				ps := tab.slot[base.id]
				v := artView{tags: tab.tags[ps], favCount: tab.favs[ps]}
				if s.c.Viewer != 0 {
					v.favorited = s.slot2 >= 0 && favHit[s.slot2]
					v.following = followed[idPair{s.c.Viewer, base.authorID}]
				}
				op.Resp = append(op.Resp, `{"article":`...)
				op.Resp = appendArticleView(op.Resp, base, v, true)
				op.Resp = append(op.Resp, '}')
				s.done()
			}
		}
	}}
}

// span is a half-open range of a flush's flat slice.
type span struct{ lo, hi int }

func pairArrays(pairs []idPair) (vs, as []int64) {
	vs, as = make([]int64, len(pairs)), make([]int64, len(pairs))
	for i, p := range pairs {
		vs[i], as[i] = p.viewer, p.art
	}
	return
}

// readHeads reads article rows (scanHead's columns) and hands each to put.
func readHeads(rows *pgRows, withBody bool, put func(*artRow)) error {
	for rows.Next() {
		a := rows.ar.newArt()
		scanHead(rows, withBody, a)
		if rows.err != nil {
			return rows.err
		}
		put(a)
	}
	return nil
}

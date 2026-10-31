package main

import (
	"cmp"
	"encoding/binary"
	"slices"

	"github.com/jackc/pgx/v5"
)

type readKind int32

const (
	readArticle readKind = iota
	readAll
	readTag
	readAuthor
	readFavorited
	readFeed
	readComments
)

// read is one request served by the articles statement.
type read struct {
	k      readKind
	viewer int64
	limit  int64
	offset int64
	key    string

	article  found[Article]
	list     articleList
	comments found[[]Comment]
	err      error
	done     chan struct{}

	// filled while the batch is answered: the page, and which of it the viewer favorited
	ids  []int64
	favs []int64
	c, w int
}

// sqlArticles answers every article, comments, list and feed read of a batch in one execution:
//   - t=1, the page of each read ($1-$5) as article ids, with those its viewer favorited;
//   - t=2, each distinct count ($6-$8);
//   - t=3, each distinct article on any page, once, with its tag ids and the body only when an article read wants it;
//   - t=4, each distinct viewer's followees ($9), so following is answered in Go;
//   - t=5, the comments of each distinct slug ($10), or one row with a NULL id when there are none;
//   - t=6, every tag with its rank by name, so tag lists sort in the database's collation.
//
// Feeds share the followees that at least $11 feeds of the batch follow. A feed's count adds their
// capped counts, each counted once, then walks the rest of its followees for what is left. Each of
// them also lists its newest $12 articles once: the (limit+offset)-th of those is a floor for the
// page of every feed following it, so a single index scan over all its followees stops there.
const sqlArticles = `WITH q AS (
  SELECT * FROM unnest($1::int4[], $2::text[], $3::int8[], $4::int8[], $5::int8[]) WITH ORDINALITY AS q(k, key, v, lim, off, i)
),
fp AS MATERIALIZED (
  SELECT pf.f, ARRAY(SELECT a.id FROM articles a WHERE a.author_id = pf.f ORDER BY a.id DESC LIMIT $12) AS top
    FROM (SELECT fo.followee_id AS f FROM q CROSS JOIN LATERAL (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = q.v) fo
           WHERE q.k = 5 GROUP BY 1 HAVING count(*) >= $11) pf
),
req AS MATERIALIZED (
  SELECT p.i, p.k, p.ids, CASE WHEN p.v <> 0 AND cardinality(p.ids) > 0
           THEN ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = p.v AND f.article_id = ANY(p.ids)) END AS favs
    FROM (
      SELECT q.i, q.k, q.v, ARRAY(SELECT a.id FROM articles a WHERE a.slug = q.key) AS ids FROM q WHERE q.k = 0
      UNION ALL
      SELECT q.i, q.k, q.v, ARRAY(SELECT a.id FROM articles a ORDER BY a.id DESC LIMIT q.lim OFFSET q.off) FROM q WHERE q.k = 1
      UNION ALL
      SELECT q.i, q.k, q.v, ARRAY(SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = q.key)
         ORDER BY at.article_id DESC LIMIT q.lim OFFSET q.off) FROM q WHERE q.k = 2
      UNION ALL
      SELECT q.i, q.k, q.v, ARRAY(SELECT a.id FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = q.key)
         ORDER BY a.id DESC LIMIT q.lim OFFSET q.off) FROM q WHERE q.k = 3
      UNION ALL
      SELECT q.i, q.k, q.v, ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT u.id FROM users u WHERE u.username = q.key)
         ORDER BY f.article_id DESC LIMIT q.lim OFFSET q.off) FROM q WHERE q.k = 4
      UNION ALL
      SELECT q.i, q.k, q.v, (
        SELECT CASE WHEN fl.floor IS NULL
                 THEN ARRAY(SELECT y.id FROM unnest(fl.fs) fo(f) CROSS JOIN LATERAL
                       (SELECT a.id FROM articles a WHERE a.author_id = fo.f ORDER BY a.id DESC LIMIT q.lim + q.off) y
                       ORDER BY y.id DESC LIMIT q.lim OFFSET q.off)
                 ELSE ARRAY(SELECT a.id FROM articles a WHERE a.author_id = ANY(fl.fs) AND a.id >= fl.floor
                       ORDER BY a.id DESC LIMIT q.lim OFFSET q.off)
               END
          FROM (SELECT array_agg(fo.followee_id) AS fs, max(p.top[q.lim + q.off]) AS floor
                  FROM follows fo LEFT JOIN fp p ON p.f = fo.followee_id WHERE fo.follower_id = q.v) fl)
        FROM q WHERE q.k = 5
    ) p
),
d AS (SELECT x.id, bool_or(req.k = 0) AS wb FROM req CROSS JOIN LATERAL unnest(req.ids) AS x(id) GROUP BY x.id),
c AS (SELECT * FROM unnest($6::int4[], $7::text[], $8::int8[]) WITH ORDINALITY AS c(k, key, v, c)),
pop AS MATERIALIZED (
  SELECT fo.f, (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = fo.f LIMIT 1000) s) AS n
    FROM c CROSS JOIN LATERAL (SELECT fo.followee_id AS f FROM follows fo WHERE fo.follower_id = c.v) fo
   WHERE c.k = 5 GROUP BY fo.f HAVING count(*) >= $11
)
SELECT 1 AS t, req.i AS x, NULL::int8 AS id, NULL::int8 AS n, NULL::text AS slug, NULL::text AS title, NULL::text AS description,
       NULL::text AS body, NULL::timestamptz AS created_at, NULL::timestamptz AS updated_at, NULL::int4[] AS tags,
       NULL::int8 AS author_id, NULL::text AS username, NULL::text AS bio, NULL::text AS image, req.ids, req.favs
  FROM req
UNION ALL
SELECT 2, c.c, NULL, CASE c.k
         WHEN 1 THEN (SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s)
         WHEN 2 THEN (SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = c.key) LIMIT 1000) s)
         WHEN 3 THEN (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = c.key) LIMIT 1000) s)
         WHEN 4 THEN (SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT u.id FROM users u WHERE u.username = c.key) LIMIT 1000) s)
         ELSE (SELECT least(1000, s.n + (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = ANY(s.rest) LIMIT greatest(0, 1000 - s.n)) z))
                 FROM (SELECT coalesce(sum(p.n), 0) AS n, array_agg(fo.followee_id) FILTER (WHERE p.f IS NULL) AS rest
                         FROM follows fo LEFT JOIN pop p ON p.f = fo.followee_id WHERE fo.follower_id = c.v) s)
       END, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
  FROM c
UNION ALL
SELECT 3, NULL, a.id, a.favs, a.slug, a.title, a.description, CASE WHEN d.wb THEN a.body END, a.created_at, a.updated_at,
       a.tags, a.author_id, a.username, a.bio, a.image, NULL, NULL
  FROM d CROSS JOIN LATERAL (
    SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, a.author_id, u.username, u.bio, u.image,
           (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favs,
           ARRAY(SELECT at.tag_id FROM article_tags at WHERE at.article_id = a.id) AS tags
      FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = d.id) a
UNION ALL
SELECT 4, w.w, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
       ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = w.v ORDER BY 1), NULL
  FROM unnest($9::int8[]) WITH ORDINALITY AS w(v, w)
UNION ALL
SELECT 5, s.s, c.id, NULL, NULL, NULL, NULL, c.body, c.created_at, c.updated_at, NULL, c.author_id, c.username, c.bio, c.image, NULL, NULL
  FROM unnest($10::text[]) WITH ORDINALITY AS s(slug, s)
  CROSS JOIN LATERAL (SELECT a.id FROM articles a WHERE a.slug = s.slug) a
  LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image
                       FROM comments c JOIN users u ON u.id = c.author_id WHERE c.article_id = a.id
                      ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true
UNION ALL
SELECT 6, t.id, NULL, row_number() OVER (ORDER BY t.name), t.name, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
  FROM tags t WHERE EXISTS (SELECT 1 FROM d)`

// articles queues reads for sqlArticles.
type articles struct {
	queue chan *read
	wake  func()
}

func (b *articles) do(r *read) error {
	r.done = donePool.Get().(chan struct{})
	b.queue <- r
	b.wake()
	<-r.done
	donePool.Put(r.done)
	return r.err
}

func (b *articles) bind(wake func()) {
	b.queue = make(chan *read, 1<<16)
	b.wake = wake
}

func (b *articles) pending() bool { return len(b.queue) > 0 }

// maxArticleBatch bounds the reads of one articles statement. Bigger batches share more, but past this
// one holds its reads too long.
const maxArticleBatch = 1536

// maxTop bounds the newest articles listed per shared followee. A feed reaching past it has no floor
// and walks each followee instead.
const maxTop = 200

type countKey struct {
	k   readKind
	key string
	v   int64
}

type detail struct {
	Article
	author int64
	tags   []int32
}

type tag struct {
	rank int64
	name string
}

type commentRow struct {
	Comment
	author int64
}

func (b *articles) take(pl *pgx.Batch) func(pgx.BatchResults) {
	n := min(len(b.queue), maxArticleBatch)
	if n == 0 {
		return nil
	}
	calls := make([]*read, n)
	for i := range calls {
		calls[i] = <-b.queue
	}

	var (
		qk             []int32
		qkey           []string
		qv, qlim, qoff []int64
		reqs           []*read
		ck             []int32
		ckey           []string
		cv             []int64
		views          []int64
		slugs          []string
		counts         = map[countKey]int{}
		viewers        = map[int64]int{}
		slugIdx        = map[string]int{}
		feeds, top     int64
		slugOf         = make([]int, n)
		rows           int
	)
	for j, r := range calls {
		r.w = -1
		if r.viewer != 0 {
			w, ok := viewers[r.viewer]
			if !ok {
				w = len(views)
				viewers[r.viewer] = w
				views = append(views, r.viewer)
			}
			r.w = w
		}
		if r.k == readComments {
			s, ok := slugIdx[r.key]
			if !ok {
				s = len(slugs)
				slugIdx[r.key] = s
				slugs = append(slugs, r.key)
			}
			slugOf[j] = s
			continue
		}
		qk = append(qk, int32(r.k))
		qkey = append(qkey, r.key)
		qv = append(qv, r.viewer)
		qlim = append(qlim, r.limit)
		qoff = append(qoff, r.offset)
		if r.k == readFeed {
			top = max(top, min(r.limit+r.offset, maxTop))
		}
		reqs = append(reqs, r)
		rows += int(r.limit)
		if r.k == readArticle {
			continue
		}
		key := countKey{k: r.k, key: r.key}
		if r.k == readFeed {
			key = countKey{k: r.k, v: r.viewer}
		}
		c, ok := counts[key]
		if !ok {
			c = len(ck)
			counts[key] = c
			ck = append(ck, int32(key.k))
			ckey = append(ckey, key.key)
			cv = append(cv, key.v)
			if key.k == readFeed {
				feeds++
			}
		}
		r.c = c
	}
	pl.Queue(sqlArticles, qk, qkey, qv, qlim, qoff, ck, ckey, cv, views, slugs, popular(feeds), top)

	return func(br pgx.BatchResults) {
		res := result{
			tags:      make(map[int64]tag, 256),
			counts:    make([]int64, len(ck)),
			details:   make(map[int64]*detail, min(rows, 2048)),
			followees: make([][]int64, len(views)),
			comments:  make([][]commentRow, len(slugs)),
			found:     make([]bool, len(slugs)),
		}
		rs, err := br.Query()
		if err == nil {
			err = res.scan(rs, reqs)
			rs.Close()
			if err == nil {
				err = rs.Err()
			}
		}
		for j, r := range calls {
			if err != nil {
				r.err = err
			} else {
				res.answer(r, slugOf[j])
			}
			r.done <- struct{}{}
		}
	}
}

// popular is how many feeds of a batch must follow an author for its count and newest articles to be
// shared, about the square root of the feeds in the batch.
func popular(feeds int64) int64 {
	t := int64(3)
	for (t-1)*(t-1) < feeds {
		t++
	}
	return t
}

type result struct {
	tags      map[int64]tag
	counts    []int64
	details   map[int64]*detail
	followees [][]int64
	comments  [][]commentRow
	found     []bool
}

func (res *result) scan(rows pgx.Rows, reqs []*read) error {
	var (
		x, id, n, author int64
		d                *detail
		c                commentRow
		ids, favs        []int64
		t                tag
	)
	page := []any{nil, &x, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, &ids, &favs}
	count := []any{nil, &x, nil, &n, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil}
	viewer := []any{nil, &x, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, &ids, nil}
	none := []any{nil, &x, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil}
	tg := []any{nil, &x, nil, &t.rank, &t.name, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil}
	art := make([]any, 17)
	cmt := []any{nil, &x, &c.ID, nil, nil, nil, nil, &c.Body, &c.CreatedAt, &c.UpdatedAt, nil, &c.author,
		&c.Author.Username, &c.Author.Bio, &c.Author.Image, nil, nil}
	for rows.Next() {
		raw := rows.RawValues()
		switch binary.BigEndian.Uint32(raw[0]) {
		case 1:
			ids, favs = nil, nil
			if err := rows.Scan(page...); err != nil {
				return err
			}
			r := reqs[x-1]
			r.ids, r.favs = ids, favs
		case 2:
			if err := rows.Scan(count...); err != nil {
				return err
			}
			res.counts[x-1] = n
		case 3:
			d = &detail{}
			a := &d.Article
			art = append(art[:0], nil, nil, &id, &a.FavoritesCount, &a.Slug, &a.Title, &a.Description, nullString{&a.Body},
				&a.CreatedAt, &a.UpdatedAt, &d.tags, &author, &a.Author.Username, &a.Author.Bio, &a.Author.Image, nil, nil)
			if err := rows.Scan(art...); err != nil {
				return err
			}
			d.author = author
			res.details[id] = d
		case 4:
			ids = nil
			if err := rows.Scan(viewer...); err != nil {
				return err
			}
			res.followees[x-1] = ids
		case 5:
			if raw[2] == nil {
				if err := rows.Scan(none...); err != nil {
					return err
				}
				res.found[x-1] = true
				continue
			}
			c = commentRow{}
			if err := rows.Scan(cmt...); err != nil {
				return err
			}
			res.found[x-1] = true
			res.comments[x-1] = append(res.comments[x-1], c)
		case 6:
			if err := rows.Scan(tg...); err != nil {
				return err
			}
			res.tags[x] = t
		}
	}
	for _, d := range res.details {
		slices.SortFunc(d.tags, func(a, b int32) int { return cmp.Compare(res.tags[int64(a)].rank, res.tags[int64(b)].rank) })
		d.TagList = make([]string, len(d.tags))
		for i, id := range d.tags {
			d.TagList[i] = res.tags[int64(id)].name
		}
	}
	return nil
}

func (res *result) following(r *read, author int64) bool {
	if r.w < 0 {
		return false
	}
	_, ok := slices.BinarySearch(res.followees[r.w], author)
	return ok
}

func (res *result) answer(r *read, slug int) {
	switch r.k {
	case readArticle:
		if len(r.ids) == 0 {
			return
		}
		d := res.details[r.ids[0]]
		a := d.Article
		a.Favorited = len(r.favs) > 0
		a.Author.Following = res.following(r, d.author)
		r.article = found[Article]{a, true}
	case readComments:
		if !res.found[slug] {
			return
		}
		src := res.comments[slug]
		cs := make([]Comment, len(src))
		for i := range src {
			cs[i] = src[i].Comment
			cs[i].Author.Following = res.following(r, src[i].author)
		}
		sortComments(cs)
		r.comments = found[[]Comment]{cs, true}
	default:
		items := make([]ArticleItem, len(r.ids))
		for i, id := range r.ids {
			d := res.details[id]
			items[i] = d.ArticleItem
			items[i].Favorited = slices.Contains(r.favs, id)
			items[i].Author.Following = res.following(r, d.author)
		}
		r.list = articleList{Articles: items, ArticlesCount: res.counts[r.c]}
	}
}

func (s *store) article(viewer int64, slug string) (found[Article], error) {
	r := &read{k: readArticle, viewer: viewer, limit: 1, key: slug}
	err := s.articles.do(r)
	return r.article, err
}

func (s *store) comments(viewer int64, slug string) (found[[]Comment], error) {
	r := &read{k: readComments, viewer: viewer, key: slug}
	err := s.articles.do(r)
	return r.comments, err
}

func (s *store) list(k readKind, q listQuery) (articleList, error) {
	r := &read{k: k, viewer: q.viewer, limit: q.limit, offset: q.offset, key: q.key}
	err := s.articles.do(r)
	return r.list, err
}

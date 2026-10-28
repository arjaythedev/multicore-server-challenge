package main

// cross.go: every read kind waiting together runs as ONE statement.
//
// Each kind gets its own five parameter arrays (ordinal, viewer, limit, offset, string). The statement
// resolves every list page and article page to article ids, then reads each distinct article's
// viewer-independent data (tags, favorite count, author) once for the whole statement, whichever
// endpoints asked for it; each distinct article's comment thread is read once too. Per request it
// returns only its page of ids and its viewer's favorited / followed ids among them (one primary-key
// range scan per request instead of a probe per row). The responses are assembled here from those rows.
// Rows are tagged by type (column 0) and request ordinal (column 1).

import (
	"bytes"
	"encoding/binary"
	"slices"
	"strconv"
	"strings"
)

const (
	tArt      = 1 // per distinct article: id, slug, title, description, body (article pages only), times, tags, fc, author
	tPage     = 2 // per list / article request: i, ids, favorited ids, followed author ids
	tCount    = 3 // per list request: i, n
	tComment  = 4 // per comment of each distinct article: article id, comment columns, author
	tComments = 5 // per comments request: i, article id, followed comment author ids
	tProfile  = 6
	tUser     = 7
	tLogin    = 8
	tTags     = 9
)

// Output columns: name and type, in order.
var crossCols = [][2]string{
	{"t", "int4"}, {"i", "int4"}, {"id", "int8"}, {"slug", "text"}, {"title", "text"}, {"description", "text"},
	{"body", "text"}, {"created", "timestamptz"}, {"updated", "timestamptz"}, {"tags", "text[]"}, {"n", "int8"},
	{"username", "text"}, {"bio", "text"}, {"image", "text"}, {"aid", "int8"}, {"ids", "int8[]"}, {"fa", "int8[]"},
	{"fo", "int8[]"}, {"email", "text"}, {"hash", "text"}, {"b", "bool"},
}

const (
	cT = iota
	cI
	cID
	cSlug
	cTitle
	cDesc
	cBody
	cCreated
	cUpdated
	cTags
	cN
	cUsername
	cBio
	cImage
	cAid
	cIds
	cFa
	cFo
	cEmail
	cHash
	cB
)

// sel builds one branch's SELECT list: every output column, NULL unless given.
func sel(t int, cols map[string]string) string {
	var b strings.Builder
	b.WriteString("SELECT " + strconv.Itoa(t))
	for _, c := range crossCols[1:] {
		b.WriteString(", ")
		if e, ok := cols[c[0]]; ok {
			b.WriteString(e)
		} else {
			b.WriteString("NULL::" + c[1])
		}
	}
	return b.String()
}

// rk is kind k's request arrays.
func rk(k int) string {
	p := func(n int) string { return "$" + strconv.Itoa(5*k+n) }
	return `unnest(` + p(1) + `::int4[], ` + p(2) + `::int8[], ` + p(3) + `::int8[], ` + p(4) + `::int8[], ` + p(5) + `::text[]) r(i, v, lim, off, s)`
}

var crossOIDs = func() []uint32 {
	o := make([]uint32, 0, 5*nKinds)
	for range nKinds {
		o = append(o, 1007, 1016, 1016, 1016, 1009) // int4[], int8[], int8[], int8[], text[]
	}
	return o
}()

var crossStmt = def("cross", func() string {
	byUsername := `(SELECT u.id FROM users u WHERE u.username = r.s)`
	byTag := `(SELECT t.id FROM tags t WHERE t.name = r.s)`
	page := func(k int, ids string) string {
		return `SELECT r.i, r.v, x.id, false AS isfull, ` + strconv.FormatBool(k == kFeed) + ` AS fe FROM ` + rk(k) +
			` CROSS JOIN LATERAL (` + ids + `) x`
	}
	count := func(k int, src string) string {
		return sel(tCount, map[string]string{"i": "r.i", "n": `(SELECT count(*) FROM (` + src + ` LIMIT 1000) s)`}) + ` FROM ` + rk(k)
	}
	return `WITH pa AS MATERIALIZED (
  ` + page(kAll, `SELECT a.id FROM articles a ORDER BY a.id DESC LIMIT r.lim OFFSET r.off`) + `
  UNION ALL ` + page(kTag, `SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = `+byTag+` ORDER BY at.article_id DESC LIMIT r.lim OFFSET r.off`) + `
  UNION ALL ` + page(kAuthor, `SELECT a.id FROM articles a WHERE a.author_id = `+byUsername+` ORDER BY a.id DESC LIMIT r.lim OFFSET r.off`) + `
  UNION ALL ` + page(kFav, `SELECT f.article_id AS id FROM favorites f WHERE f.user_id = `+byUsername+` ORDER BY f.article_id DESC LIMIT r.lim OFFSET r.off`) + `
  UNION ALL ` + page(kFeed, `SELECT x.id FROM follows fo CROSS JOIN LATERAL (
       SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT r.lim + r.off) x
     WHERE fo.follower_id = r.v ORDER BY x.id DESC LIMIT r.lim OFFSET r.off`) + `
  UNION ALL SELECT r.i, r.v, a.id, true, false FROM ` + rk(kArticle) + ` JOIN articles a ON a.slug = r.s),
e AS MATERIALIZED (SELECT a.id, a.author_id, a.slug, a.title, a.description,
    CASE WHEN a.id = ANY(ARRAY(SELECT id FROM pa WHERE isfull)) THEN a.body END AS body, a.created_at, a.updated_at,
    ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) n FROM article_tags at WHERE at.article_id = a.id ORDER BY n) AS tags,
    (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fc, u.username, u.bio, u.image
  FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = ANY(ARRAY(SELECT DISTINCT id FROM pa))),
q AS MATERIALIZED (SELECT pa.i, pa.v, pa.fe, array_agg(pa.id ORDER BY pa.id DESC) AS ids, array_agg(DISTINCT e.author_id) AS au
  FROM pa JOIN e ON e.id = pa.id GROUP BY pa.i, pa.v, pa.fe),
ca AS MATERIALIZED (SELECT a.id, a.slug FROM articles a WHERE a.slug = ANY(ARRAY(SELECT DISTINCT r.s FROM ` + rk(kComments) + `))),
cc AS MATERIALIZED (SELECT ca.id AS aid, c.* FROM ca CROSS JOIN LATERAL (
    SELECT c.id, c.created_at, c.updated_at, c.body, c.author_id FROM comments c
     WHERE c.article_id = ca.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c),
cau AS MATERIALIZED (SELECT aid, array_agg(DISTINCT author_id) AS au FROM cc GROUP BY aid)
` + sel(tArt, map[string]string{"id": "e.id", "slug": "e.slug", "title": "e.title", "description": "e.description",
		"body": "e.body", "created": "e.created_at", "updated": "e.updated_at", "tags": "e.tags", "n": "e.fc",
		"username": "e.username", "bio": "e.bio", "image": "e.image", "aid": "e.author_id"}) + ` FROM e
UNION ALL ` + sel(tPage, map[string]string{"i": "q.i", "ids": "q.ids",
		"fa": `CASE WHEN q.v <> 0 THEN ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = q.v AND f.article_id = ANY(q.ids)) END`,
		"fo": `CASE WHEN q.v <> 0 AND NOT q.fe THEN ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = q.v AND fo.followee_id = ANY(q.au)) END`}) + ` FROM q
UNION ALL ` + sel(tCount, map[string]string{"i": "r.i", "n": `(SELECT count(*) FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s)`}) + ` FROM ` + rk(kAll) + `
UNION ALL ` + count(kTag, `SELECT 1 FROM article_tags at WHERE at.tag_id = `+byTag) + `
UNION ALL ` + count(kAuthor, `SELECT 1 FROM articles a WHERE a.author_id = `+byUsername) + `
UNION ALL ` + count(kFav, `SELECT 1 FROM favorites f WHERE f.user_id = `+byUsername) + `
UNION ALL ` + count(kFeed, `SELECT 1 FROM articles a WHERE a.author_id = ANY(ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v))`) + `
UNION ALL ` + sel(tComment, map[string]string{"id": "cc.aid", "n": "cc.id", "created": "cc.created_at", "updated": "cc.updated_at",
		"body": "cc.body", "username": "u.username", "bio": "u.bio", "image": "u.image", "aid": "cc.author_id"}) + `
  FROM cc JOIN users u ON u.id = cc.author_id
UNION ALL ` + sel(tComments, map[string]string{"i": "r.i", "id": "ca.id",
		"fo": `CASE WHEN r.v <> 0 THEN ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = ANY(cau.au)) END`}) + `
  FROM ` + rk(kComments) + ` JOIN ca ON ca.slug = r.s LEFT JOIN cau ON cau.aid = ca.id
UNION ALL ` + sel(tProfile, map[string]string{"i": "r.i", "username": "u.username", "bio": "u.bio", "image": "u.image",
		"b": `(r.v <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = u.id))`}) + `
  FROM ` + rk(kProfile) + ` JOIN users u ON u.username = r.s
UNION ALL ` + sel(tUser, map[string]string{"i": "r.i", "username": "u.username", "email": "u.email", "bio": "u.bio", "image": "u.image"}) + `
  FROM ` + rk(kUser) + ` JOIN users u ON u.id = r.v
UNION ALL ` + sel(tLogin, map[string]string{"i": "r.i", "username": "u.username", "email": "u.email", "bio": "u.bio", "image": "u.image",
		"n": "u.id", "hash": "u.password_hash"}) + `
  FROM ` + rk(kLogin) + ` JOIN users u ON u.email = r.s
UNION ALL ` + sel(tTags, map[string]string{"tags": `(SELECT array_agg(t.name ORDER BY t.name) FROM tags t)`}) + `
  WHERE cardinality($` + strconv.Itoa(5*kTags+1) + `::int4[]) > 0`
}())

type crossComment struct {
	created int64
	id      int64
	author  int64
	cols    [][]byte // id, created_at, updated_at, body, username, bio, image
}

// readCross runs batch (any mix of kinds) as the one cross statement and builds every response.
func (c *dbConn) readCross(batch []*job) error {
	var a [nKinds][5][]byte
	for k := range a {
		for x := range a[k] {
			a[k][x] = append(a[k][x], '{')
		}
	}
	for i, j := range batch {
		j.reset()
		p := &a[j.kind]
		if len(p[0]) > 1 {
			for x := range p {
				p[x] = append(p[x], ',')
			}
		}
		p[0] = strconv.AppendInt(p[0], int64(i), 10)
		p[1] = strconv.AppendInt(p[1], j.v, 10)
		p[2] = strconv.AppendInt(p[2], j.lim, 10)
		p[3] = strconv.AppendInt(p[3], j.off, 10)
		p[4] = appendArrayString(p[4], j.s)
	}
	args := make([][]byte, 0, 5*nKinds)
	for k := range a {
		for x := range a[k] {
			args = append(args, append(a[k][x], '}'))
		}
	}

	arts := map[int64][][]byte{}
	comments := map[int64][]crossComment{}
	var pages, threads [][][]byte
	err := c.exec([]call{{crossStmt, args}}, func(_ int, v [][]byte) {
		t := binary.BigEndian.Uint32(v[cT])
		if t == tArt || t == tComment || t == tPage || t == tComments {
			r := make([][]byte, len(v))
			for x := range v {
				r[x] = bytes.Clone(v[x])
			}
			switch t {
			case tArt:
				arts[i64(r[cID])] = r
			case tComment:
				aid := i64(r[cID])
				comments[aid] = append(comments[aid], crossComment{i64(r[cCreated]), i64(r[cN]), i64(r[cAid]),
					[][]byte{r[cN], r[cCreated], r[cUpdated], r[cBody], r[cUsername], r[cBio], r[cImage]}})
			case tPage:
				pages = append(pages, r)
			case tComments:
				threads = append(threads, r)
			}
			return
		}
		var j *job
		if t != tTags {
			j = batch[binary.BigEndian.Uint32(v[cI])]
		}
		switch t {
		case tCount:
			j.n = i64(v[cN])
		case tProfile:
			j.out = append(appendProfile(j.out, v[cUsername:cImage+1], v[cB][0] == 1), '}')
			j.rows++
		case tUser:
			j.out = appendUser(j.out, [][]byte{v[cUsername], v[cEmail], v[cBio], v[cImage]})
			j.rows++
		case tLogin:
			j.out = appendUser(j.out, [][]byte{v[cUsername], v[cEmail], v[cBio], v[cImage]})
			j.n, j.hash = i64(v[cN]), string(v[cHash])
			j.rows++
		case tTags:
			for _, j := range batch {
				if j.kind == kTags {
					j.out = append(appendTextArray(j.out, v[cTags]), '}')
					j.rows++
				}
			}
		}
	})
	if err != nil {
		return err
	}

	no, yes := []byte{0}, []byte{1}
	flag := func(ids []int64, id int64) []byte {
		if slices.Contains(ids, id) {
			return yes
		}
		return no
	}
	for _, r := range pages {
		j := batch[binary.BigEndian.Uint32(r[cI])]
		fa, fo := int8Array(r[cFa]), int8Array(r[cFo])
		for _, id := range int8Array(r[cIds]) {
			e := arts[id]
			fol := yes
			if j.kind != kFeed {
				fol = flag(fo, i64(e[cAid]))
			}
			cols := [][]byte{e[cSlug], e[cTitle], e[cDesc], e[cCreated], e[cUpdated], e[cTags], e[cN],
				flag(fa, id), e[cUsername], e[cBio], e[cImage], fol}
			if j.kind == kArticle {
				cols = slices.Insert(cols, 3, e[cBody])
				j.out = append(appendArticle(j.out, cols, true), '}')
			} else {
				if j.rows > 0 {
					j.out = append(j.out, ',')
				}
				j.out = appendArticle(j.out, cols, false)
			}
			j.rows++
		}
	}
	for _, cs := range comments {
		slices.SortFunc(cs, func(x, y crossComment) int {
			if x.created != y.created {
				return -compareInt(x.created, y.created)
			}
			return -compareInt(x.id, y.id)
		})
	}
	for _, r := range threads {
		j := batch[binary.BigEndian.Uint32(r[cI])]
		j.n = 1 // the article exists
		fo := int8Array(r[cFo])
		for _, cm := range comments[i64(r[cID])] {
			if j.rows > 0 {
				j.out = append(j.out, ',')
			}
			j.out = appendComment(j.out, cm.cols, slices.Contains(fo, cm.author))
			j.rows++
		}
	}
	return nil
}

func compareInt(x, y int64) int {
	switch {
	case x < y:
		return -1
	case x > y:
		return 1
	}
	return 0
}

// int8Array decodes a binary one-dimensional int8[] without NULLs (nil or empty: none).
func int8Array(c []byte) []int64 {
	if len(c) < 20 || binary.BigEndian.Uint32(c) != 1 {
		return nil
	}
	n, p := int(binary.BigEndian.Uint32(c[12:])), 20
	out := make([]int64, n)
	for i := range n {
		out[i] = i64(c[p+4 : p+12])
		p += 12
	}
	return out
}

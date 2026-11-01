package main

import (
	"multicorelab/http/conduit"
	"multicorelab/http/jsonw"
)

// slotOf returns the index of key k among keys. With sharing, an identical key
// seen before in this flush gives its index; without, every request gets its
// own entry.
func slotOf[K comparable](m map[K]int, keys *[]K, k K, share bool) int {
	if share {
		if i, ok := m[k]; ok {
			statShared()
			return i
		}
	}
	i := len(*keys)
	*keys = append(*keys, k)
	if share {
		m[k] = i
	}
	return i
}

// readPhase serves every read of one flush in one pipelined round trip. The
// results live only until the responses are encoded.
func (w *worker) readPhase(items []*opState) {
	groups := &w.groups
	for i := range groups {
		groups[i] = groups[i][:0]
	}
	for _, s := range items {
		groups[s.c.Endpoint] = append(groups[s.c.Endpoint], s)
	}
	// A flush that lists articles needs the tag dictionary; if it also lists tags, the tag list's statement reads it.
	w.wantDict = len(groups[conduit.ListArticles])+len(groups[conduit.Feed])+len(groups[conduit.GetArticle]) > 0
	sb := &w.sbs[0]
	sb.items = sb.items[:0]
	fins := w.fins[:0]
	defer func() { // the statements' closures hold this flush's rows: drop them
		clear(fins)
		w.fins = fins[:0]
		for i := range w.sbs {
			clear(w.sbs[i].items)
			w.sbs[i].items = w.sbs[i].items[:0]
		}
	}()
	add := func(f func()) {
		if f != nil {
			fins = append(fins, f)
		}
	}
	for e, g := range groups {
		if len(g) == 0 {
			continue
		}
		switch e := conduit.Endpoint(e); e {
		case conduit.Tags:
			add(w.qTags(sb, g))
		case conduit.GetUser:
			add(w.qUsers(sb, g))
		case conduit.Login:
			add(w.qLogin(sb, g))
		case conduit.GetProfile:
			add(w.qProfiles(sb, g))
		case conduit.ListComments:
			add(w.qComments(sb, g))
		}
	}
	if ops := append(append(w.favOps[:0], groups[conduit.Favorite]...), groups[conduit.Unfavorite]...); len(ops) > 0 {
		w.favOps = ops
		add(w.qFavSettle(sb, ops))
	}
	g := groups
	s2 := w.qDecomposed(sb, g[conduit.ListArticles], g[conduit.Feed], g[conduit.GetArticle])
	// One snapshot for the whole flush: the counts, flags and rows of its responses all come from the same
	// committed state. The transaction opens with the first round and closes with the last.
	opened := len(sb.items) > 0
	if opened {
		sb.begin()
		if len(s2.ops) == 0 {
			sb.exec("COMMIT")
		}
	}
	if err := w.run1(sb); err != nil {
		w.rollback()
		failAll(items, 500, "internal error")
		return
	}
	for _, f := range fins {
		f()
	}
	if len(s2.ops) > 0 {
		sb2 := &w.sbs[1]
		sb2.items = sb2.items[:0]
		fin := s2.run(sb2)
		if !opened {
			sb2.begin()
		}
		sb2.exec("COMMIT")
		if err := w.run1(sb2); err != nil {
			w.rollback()
			failAll(s2.ops, 500, "internal error")
			return
		}
		fin()
	}
}

// conduitEndpoints sizes the groups.
const conduitEndpoints = int(conduit.Tags) + 1

func (w *worker) qTags(sb *stmtBatch, ops []*opState) func() {
	n := 1
	if !w.share {
		n = len(ops)
	}
	// Each execution's result is encoded once, straight from the wire bytes, as the JSON array's elements.
	results := make([][]byte, n)
	for i := 0; i < n; i++ {
		fill := i == 0 && w.wantDict // the first execution's rows also fill the flush's tag dictionary
		sb.query(sqlTagDict, nil, func(rows *pgRows) error {
			if fill {
				w.dict.reset()
			}
			buf := make([]byte, 0, 4096)
			for rows.Next() {
				if len(buf) > 0 {
					buf = append(buf, ',')
				}
				buf = jsonw.Bytes(buf, rows.RawValues()[1])
				if fill {
					w.dict.add(rows.i64(0), rows.str(1))
				}
			}
			results[i] = buf
			w.dict.ok = w.dict.ok || (fill && rows.err == nil)
			return rows.err
		})
	}
	return func() {
		for i, s := range ops {
			names := results[0]
			if !w.share {
				names = results[i]
			}
			op := s.op
			op.Resp = append(op.Resp, `{"tags":[`...)
			op.Resp = append(op.Resp, names...)
			op.Resp = append(op.Resp, `]}`...)
			s.done()
		}
	}
}

const sqlUsersByID = `SELECT k.ord, u.id, u.username, u.email, u.bio, u.image
  FROM unnest($1::bigint[]) WITH ORDINALITY AS k(id, ord) JOIN users u ON u.id = k.id`

func (w *worker) qUsers(sb *stmtBatch, ops []*opState) func() {
	m := map[int64]int{}
	var ids []int64
	for _, s := range ops {
		s.slot = slotOf(m, &ids, s.c.Viewer, w.share)
	}
	res := make([]userRow, len(ids))
	ok := make([]bool, len(ids))
	sb.query(sqlUsersByID, []any{ids}, func(rows *pgRows) error {
		for rows.Next() {
			ord := rows.i64(0) - 1
			res[ord], ok[ord] = userRow{id: rows.i64(1), username: rows.str(2), email: rows.str(3), bio: rows.nstr(4), image: rows.nstr(5)}, true
			if rows.err != nil {
				return rows.err
			}
		}
		return nil
	})
	return func() {
		for _, s := range ops {
			if !ok[s.slot] {
				conduit.Fail(s.op, 401, "user not found")
			} else {
				s.user = res[s.slot]
				w.db.respondUser(s, 200, false)
			}
			s.done()
		}
	}
}

const sqlLoginLookup = `SELECT k.ord, u.id, u.username, u.email, u.bio, u.image, u.password_hash
  FROM unnest($1::text[]) WITH ORDINALITY AS k(email, ord) JOIN users u ON u.email = k.email`

func (w *worker) qLogin(sb *stmtBatch, ops []*opState) func() {
	m := map[string]int{}
	var emails []string
	for _, s := range ops {
		s.slot = slotOf(m, &emails, string(s.c.Email.V), w.share)
	}
	res := make([]userRow, len(emails))
	hashes := make([]string, len(emails))
	ok := make([]bool, len(emails))
	sb.query(sqlLoginLookup, []any{emails}, func(rows *pgRows) error {
		rows.ar = nil // the user waits for bcrypt, past the end of this flush: heap strings
		for rows.Next() {
			ord := rows.i64(0) - 1
			res[ord], ok[ord] = userRow{id: rows.i64(1), username: rows.str(2), email: rows.str(3), bio: rows.nstr(4), image: rows.nstr(5)}, true
			hashes[ord] = rows.str(6)
			if rows.err != nil {
				return rows.err
			}
		}
		return nil
	})
	return func() {
		for _, s := range ops {
			if !ok[s.slot] {
				conduit.Fail(s.op, 401, "invalid email or password")
				s.done()
				continue
			}
			s.user = res[s.slot]
			s.hash = append(s.hash[:0], hashes[s.slot]...)
			w.db.bc.submit(s)
		}
	}
}

// The profile row depends only on the username; whether the viewer follows depends on the viewer. Rows are
// shared per username and flags are probed per distinct (viewer, username).
const sqlProfiles = `SELECT k.ord, u.id, u.username, u.bio, u.image
  FROM unnest($1::text[]) WITH ORDINALITY AS k(name, ord) JOIN users u ON u.username = k.name`

const sqlProfileFlags = `SELECT ord FROM (
  SELECT k.ord, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = k.viewer AND fo.followee_id = u.id) AS fol
    FROM unnest($1::bigint[], $2::text[]) WITH ORDINALITY AS k(viewer, name, ord) JOIN users u ON u.username = k.name
   OFFSET 0) s WHERE fol`

type profFlagKey struct {
	viewer int64
	name   string
}

func (w *worker) qProfiles(sb *stmtBatch, ops []*opState) func() {
	m := map[string]int{}
	var names []string
	fm := map[profFlagKey]int{}
	var fkeys []profFlagKey
	for _, s := range ops {
		s.slot = slotOf(m, &names, string(s.c.Username), w.share)
		if s.c.Viewer != 0 {
			s.slot2 = slotOf(fm, &fkeys, profFlagKey{s.c.Viewer, string(s.c.Username)}, w.share)
		}
	}
	res := make([]userRow, len(names))
	ok := make([]bool, len(names))
	sb.query(sqlProfiles, []any{names}, func(rows *pgRows) error {
		for rows.Next() {
			ord := rows.i64(0) - 1
			res[ord], ok[ord] = userRow{id: rows.i64(1), username: rows.str(2), bio: rows.nstr(3), image: rows.nstr(4)}, true
			if rows.err != nil {
				return rows.err
			}
		}
		return nil
	})
	fol := make([]bool, len(fkeys))
	if len(fkeys) > 0 {
		vs, ns := make([]int64, len(fkeys)), make([]string, len(fkeys))
		for i, k := range fkeys {
			vs[i], ns[i] = k.viewer, k.name
		}
		sb.query(sqlProfileFlags, []any{vs, ns}, func(rows *pgRows) error {
			for rows.Next() {
				fol[rows.i64(0)-1] = true
			}
			return rows.err
		})
	}
	return func() {
		for _, s := range ops {
			op := s.op
			if !ok[s.slot] {
				conduit.Fail(op, 404, "profile not found")
			} else {
				op.Resp = append(op.Resp, `{"profile":`...)
				op.Resp = appendProfile(op.Resp, &res[s.slot], s.c.Viewer != 0 && fol[s.slot2])
				op.Resp = append(op.Resp, '}')
			}
			s.done()
		}
	}
}

type commFlagKey struct {
	viewer int64
	slug   string
}

// Comments and their authors depend only on the article; "following" depends on the viewer, so it is probed
// per distinct (viewer, article) and returns the ids of the comments whose author the viewer follows.
const sqlComments = `SELECT k.ord, c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
  FROM unnest($1::text[]) WITH ORDINALITY AS k(slug, ord)
  JOIN articles a ON a.slug = k.slug
  LEFT JOIN LATERAL (
        SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id
          FROM comments c WHERE c.article_id = a.id
         ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true
  LEFT JOIN users u ON u.id = c.author_id
 ORDER BY k.ord, c.created_at DESC, c.id DESC`

const sqlCommentFlags = `SELECT k.ord, c.id
  FROM unnest($1::bigint[], $2::text[]) WITH ORDINALITY AS k(viewer, slug, ord)
  JOIN articles a ON a.slug = k.slug
  JOIN LATERAL (
        SELECT c.id, c.author_id FROM comments c WHERE c.article_id = a.id
         ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true
 WHERE EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = k.viewer AND fo.followee_id = c.author_id)`

func (w *worker) qComments(sb *stmtBatch, ops []*opState) func() {
	m := map[string]int{}
	var slugs []string
	fm := map[commFlagKey]int{}
	var fkeys []commFlagKey
	for _, s := range ops {
		s.slot = slotOf(m, &slugs, string(s.c.Slug), w.share)
		if s.c.Viewer != 0 {
			s.slot2 = slotOf(fm, &fkeys, commFlagKey{s.c.Viewer, string(s.c.Slug)}, w.share)
		}
	}
	w.comms = w.comms[:0]
	span := make([]commSpan, len(slugs))
	sb.query(sqlComments, []any{slugs}, func(rows *pgRows) error { return readComments(rows, &w.comms, span) })
	fol := make([]map[int64]bool, len(fkeys))
	if len(fkeys) > 0 {
		vs, ss := make([]int64, len(fkeys)), make([]string, len(fkeys))
		for i, k := range fkeys {
			vs[i], ss[i] = k.viewer, k.slug
		}
		sb.query(sqlCommentFlags, []any{vs, ss}, func(rows *pgRows) error {
			for rows.Next() {
				ord := rows.i64(0) - 1
				if fol[ord] == nil {
					fol[ord] = map[int64]bool{}
				}
				fol[ord][rows.i64(1)] = true
			}
			return rows.err
		})
	}
	return func() {
		for _, s := range ops {
			op := s.op
			if !span[s.slot].ok {
				conduit.Fail(op, 404, "article not found")
			} else {
				op.Resp = append(op.Resp, `{"comments":[`...)
				var f map[int64]bool
				if s.c.Viewer != 0 {
					f = fol[s.slot2]
				}
				sp := span[s.slot]
				for i := sp.lo; i < sp.hi; i++ {
					if i > sp.lo {
						op.Resp = append(op.Resp, ',')
					}
					m := &w.comms[i]
					op.Resp = appendComment(op.Resp, m, f[m.id])
				}
				op.Resp = append(op.Resp, `]}`...)
			}
			s.done()
		}
	}
}

// commSpan is where one slug's comments sit in the flush's flat comment slice; ok says the article exists.
type commSpan struct {
	lo, hi int
	ok     bool
}

// readComments reads the rows of sqlComments, ordered by slug and then newest first, into the flat slice.
func readComments(rows *pgRows, comms *[]commRow, span []commSpan) error {
	for rows.Next() {
		ord := rows.i64(0) - 1
		sp := &span[ord]
		if !sp.ok {
			sp.ok, sp.lo, sp.hi = true, len(*comms), len(*comms)
		}
		id, has := rows.ni64(1)
		if !has {
			continue
		}
		*comms = append(*comms, commRow{id: id, body: rows.str(2), created: rows.micros(3), updated: rows.micros(4),
			username: rows.str(5), bio: rows.nstr(6), image: rows.nstr(7)})
		sp.hi = len(*comms)
		if rows.err != nil {
			return rows.err
		}
	}
	return nil
}

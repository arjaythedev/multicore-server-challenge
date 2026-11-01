package main

// The tag names of articles come from a dictionary of all tags read in the flush, ranked in the database's own
// order (ORDER BY name under its collation), so each article's tags sorted by rank are in the order SQL's
// array_agg(name ORDER BY name) gave, on any collation. The dictionary lives for one flush (rule 5).
const sqlTagDict = `SELECT id, name FROM tags ORDER BY name`

type tagDict struct {
	ok    bool // read in this flush
	names []string
	rank  map[int64]int32
}

func (d *tagDict) reset() {
	d.ok = false
	d.names = d.names[:0]
	if d.rank == nil {
		d.rank = map[int64]int32{}
	}
	clear(d.rank)
}

func (d *tagDict) add(id int64, name string) {
	d.rank[id] = int32(len(d.names))
	d.names = append(d.names, name)
}

// readDict reads sqlTagDict's rows into the flush's dictionary.
func (w *worker) readDict(rows *pgRows) error {
	w.dict.reset()
	for rows.Next() {
		w.dict.add(rows.i64(0), rows.str(1))
	}
	w.dict.ok = rows.err == nil
	return rows.err
}

// tagPair is one article_tags row: the article's slot in the flush's table and the tag id.
type tagPair struct {
	slot int32
	tag  int64
}

// assembleTags sets tab.tags from the pairs and the dictionary. A tag missing from the dictionary (created after
// it was read) triggers one re-read. It reports false when that read fails.
func (w *worker) assembleTags(tab *artTab, pairs []tagPair) bool {
	if len(pairs) == 0 {
		return true
	}
	for _, p := range pairs {
		if _, ok := w.dict.rank[p.tag]; !ok {
			sb := &stmtBatch{}
			sb.query(sqlTagDict, nil, w.readDict)
			if err := w.run1(sb); err != nil {
				w.rollback()
				return false
			}
			break
		}
	}
	n := len(tab.ids)
	cnt := fit(w.tcnt, n+1) // cnt[slot+1] counts, then becomes the start of the slot's segment
	w.tcnt = cnt
	ranks := fit(w.trank, len(pairs))
	w.trank = ranks
	for _, p := range pairs {
		if _, ok := w.dict.rank[p.tag]; ok {
			cnt[p.slot+1]++
		}
	}
	for i := 1; i <= n; i++ {
		cnt[i] += cnt[i-1]
	}
	// Fill each segment from its start: cnt[slot] doubles as the cursor, and ends at the next segment's start.
	for _, p := range pairs {
		if r, ok := w.dict.rank[p.tag]; ok {
			ranks[cnt[p.slot]] = r
			cnt[p.slot]++
		}
	}
	lo := int32(0)
	for slot := 0; slot < n; slot++ {
		hi := cnt[slot]
		if hi > lo {
			seg := ranks[lo:hi]
			for i := 1; i < len(seg); i++ {
				for j := i; j > 0 && seg[j] < seg[j-1]; j-- {
					seg[j], seg[j-1] = seg[j-1], seg[j]
				}
			}
			names := w.ar.strings(len(seg))
			for i, r := range seg {
				names[i] = w.dict.names[r]
			}
			tab.tags[slot] = names
		}
		lo = hi
	}
	return true
}

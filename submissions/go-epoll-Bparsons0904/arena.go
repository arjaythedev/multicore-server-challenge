package main

import (
	"unsafe"

	"multicorelab/http/jsonw"
)

// arena holds the text of one flush's decoded rows. Rows read from Postgres live in the connection's read buffer
// only until the next row, so each text value is copied once, here, instead of into a string of its own. Strings
// handed out point into the arena and are valid until reset, which a worker calls at the start of every flush:
// the responses of a flush are encoded before it ends, so nothing derived from the database outlives it (rule 5).
// A nil *arena hands out ordinary heap strings, for the rows that outlive the flush (a login waiting for bcrypt).
type arena struct {
	chunks [][]byte
	ci     int // chunk being filled
	strs   [][]string
	si     int
	sused  int
	arts   [][]artRow
	ai     int
	aused  int
}

const (
	arenaChunk  = 16 << 10
	arenaKeep   = 1 << 20 // chunks larger than this are dropped on reset
	strsChunk   = 1024
	arenaMaxStr = 4 << 10
)

func (a *arena) reset() {
	a.poison()
	for i, c := range a.chunks {
		if cap(c) > arenaKeep {
			a.chunks[i] = nil
		} else {
			a.chunks[i] = c[:0]
		}
	}
	a.ci = 0
	a.si, a.sused = 0, 0
	a.ai, a.aused = 0, 0
}

// str copies b and returns it as a string.
func (a *arena) str(b []byte) string {
	if len(b) == 0 {
		return ""
	}
	if a == nil {
		return string(b)
	}
	for {
		if a.ci == len(a.chunks) {
			a.chunks = append(a.chunks, make([]byte, 0, max(arenaChunk, len(b))))
		}
		c := a.chunks[a.ci]
		if cap(c)-len(c) >= len(b) {
			start := len(c)
			c = append(c, b...)
			a.chunks[a.ci] = c
			return unsafe.String(&c[start], len(b))
		}
		if c == nil {
			a.chunks[a.ci] = make([]byte, 0, max(arenaChunk, len(b)))
			continue
		}
		a.ci++
	}
}

// strings returns a zeroed slice of n strings, with capacity n.
func (a *arena) strings(n int) []string {
	if n == 0 {
		return nil
	}
	if a == nil || n > strsChunk {
		return make([]string, n)
	}
	if a.si == len(a.strs) {
		a.strs = append(a.strs, make([]string, strsChunk))
	}
	if strsChunk-a.sused < n {
		a.si++
		a.sused = 0
		return a.strings(n)
	}
	s := a.strs[a.si][a.sused : a.sused+n : a.sused+n]
	a.sused += n
	clear(s)
	return s
}

const artsChunk = 128

// newArt returns a zeroed artRow that lives until reset.
func (a *arena) newArt() *artRow {
	if a == nil {
		return new(artRow)
	}
	if a.ai == len(a.arts) {
		a.arts = append(a.arts, make([]artRow, artsChunk))
	}
	if a.aused == artsChunk {
		a.ai++
		a.aused = 0
		return a.newArt()
	}
	p := &a.arts[a.ai][a.aused]
	a.aused++
	*p = artRow{}
	return p
}

// artTab numbers the distinct articles of one flush and holds what each response needs of them in dense arrays, so
// encoding a page costs array reads instead of one map lookup per kind of value. Worker-owned and reset per flush.
type artTab struct {
	slot map[int64]int32
	ids  []int64
	head []*artRow
	tags [][]string
	favs []int64
	seg  []artSeg // the viewer-independent JSON of each article, built on first use
	buf  []byte   // where the segments live
}

// artSeg locates an article's JSON before and after the favorited flag in artTab.buf.
type artSeg struct {
	lo, mid, hi int
	built       bool
}

func (t *artTab) reset() {
	if t.slot == nil {
		t.slot = map[int64]int32{}
	}
	clear(t.slot)
	t.ids = t.ids[:0]
}

func (t *artTab) add(id int64) int32 {
	if s, ok := t.slot[id]; ok {
		return s
	}
	s := int32(len(t.ids))
	t.slot[id] = s
	t.ids = append(t.ids, id)
	return s
}

// size readies the value arrays for the ids added so far.
func (t *artTab) size() {
	n := len(t.ids)
	t.head, t.tags, t.favs, t.seg = fit(t.head, n), fit(t.tags, n), fit(t.favs, n), fit(t.seg, n)
	if cap(t.buf) > 4<<20 {
		t.buf = nil
	}
	t.buf = t.buf[:0]
}

// fit returns s resized to n zeroed elements, reusing its storage when it fits.
func fit[T any](s []T, n int) []T {
	if cap(s) < n {
		return make([]T, n)
	}
	s = s[:n]
	clear(s)
	return s
}

// appendList appends the article in slot ps for a list response, encoding its viewer-independent parts once per
// flush. The text is the same as appendArticleView's; only the encoding work is shared.
func (t *artTab) appendList(dst []byte, ps int32, v artView) []byte {
	sg := &t.seg[ps]
	if !sg.built {
		h := t.head[ps]
		sg.lo = len(t.buf)
		t.buf = appendArtHead(t.buf, h, t.tags[ps], false)
		sg.mid = len(t.buf)
		t.buf = appendArtTail(t.buf, h, t.favs[ps])
		sg.hi, sg.built = len(t.buf), true
	}
	dst = append(dst, t.buf[sg.lo:sg.mid]...)
	dst = jsonw.Bool(dst, v.favorited)
	dst = append(dst, t.buf[sg.mid:sg.hi]...)
	dst = jsonw.Bool(dst, v.following)
	return append(dst, '}', '}')
}

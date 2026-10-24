package main

import (
	"strconv"
	"strings"
)

type readFamily uint8

const (
	familyOther readFamily = iota
	familyTags
	familyGlobal
	familyTag
	familyAuthor
	familyFavorite
	familyArticle
	familyComments
	familyArticleID
	numReadFamilies
)

// The hint affects scheduling only. Authentication and the authoritative route
// and query validation still run independently for every request on its worker.
func readHint(j *reactorJob) readFamily {
	if j.db.postCommit {
		return familyArticleID
	}
	path, raw, _ := strings.Cut(bstr(j.wire.target), "?")
	switch path {
	case "/api/tags":
		return familyTags
	case "/api/articles":
		var q queryArgs
		q.init(raw)
		if q.Peek("tag") != "" {
			return familyTag
		}
		if q.Peek("author") != "" {
			return familyAuthor
		}
		if q.Peek("favorited") != "" {
			return familyFavorite
		}
		return familyGlobal
	case "/api/articles/feed":
		return familyOther
	}
	if rest, ok := strings.CutPrefix(path, "/api/articles/"); ok {
		if strings.HasSuffix(rest, "/comments") {
			return familyComments
		}
		if !strings.Contains(rest, "/") {
			return familyArticle
		}
	}
	return familyOther
}

func (d *dbDispatcher) enqueueRead(j *reactorJob) bool {
	j.queuedAt = monoNow()
	family := readHint(j)
	n := len(d.readers)
	start := int(d.nextRead.Add(1) % uint64(n))
	healthy := false
	for _, w := range d.readers {
		healthy = healthy || w.healthy.Load()
	}
	best, minimum := start, int64(^uint64(0)>>1)
	for offset := range n {
		i := (start + offset) % n
		if healthy && !d.readers[i].healthy.Load() {
			continue
		}
		load := d.readers[i].load.Load()
		if load < minimum {
			best, minimum = i, load
		}
	}
	key := readKey(j, family)
	if d.cfg.readAffinity && family != familyOther {
		now := monoNow()
		preferred := int(key % uint64(n))
		bestScore := int64(-1)
		for offset := range n {
			i := (start + offset) % n
			w := d.readers[i]
			if healthy && !w.healthy.Load() {
				continue
			}
			load, oldest := w.load.Load(), w.oldest.Load()
			if load > minimum+int64(d.cfg.readRouteSlack) || oldest != 0 && now-oldest > 5_000_000 {
				continue
			}
			score := w.keys[key%64].Load()*8 + w.families[family].Load()*2
			if i == preferred {
				score++
			}
			if score > bestScore || score == bestScore && load < d.readers[best].load.Load() {
				best, bestScore = i, score
			}
		}
	}
	w := d.readers[best]
	j.readOwner, j.family, j.readKey, j.readQueued = w, family, key, true
	w.load.Add(1)
	if w.queued.Add(1) == 1 {
		w.oldest.Store(monoNow())
	}
	w.families[family].Add(1)
	w.keys[key%64].Add(1)
	select {
	case w.q <- j:
		return true
	default:
		releaseRead(j)
		return false
	}
}

// Keys are routing hints only: collisions never combine or authenticate requests.
func readKey(j *reactorJob, family readFamily) uint64 {
	h := uint64(14695981039346656037)
	add := func(s string) {
		for i := range len(s) {
			h ^= uint64(s[i])
			h *= 1099511628211
		}
		h ^= 255
		h *= 1099511628211
	}
	add(strconv.Itoa(int(family)))
	if j.db.postCommit {
		return h ^ uint64(j.db.articleID)
	}
	path, raw, _ := strings.Cut(bstr(j.wire.target), "?")
	switch family {
	case familyGlobal, familyTag, familyAuthor, familyFavorite:
		var q queryArgs
		q.init(raw)
		for _, k := range []string{"limit", "offset", "tag", "author", "favorited"} {
			add(q.Peek(k))
		}
	default:
		add(path)
	}
	return h
}

func readTaken(j *reactorJob) {
	if !j.readQueued || j.readOwner == nil {
		return
	}
	w := j.readOwner
	w.families[j.family].Add(-1)
	w.keys[j.readKey%64].Add(-1)
	if w.queued.Add(-1) == 0 {
		w.oldest.Store(0)
	}
	j.readQueued = false
}

func releaseRead(j *reactorJob) {
	if w := j.readOwner; w != nil {
		readTaken(j)
		w.load.Add(-1)
		j.readOwner = nil
	}
}

// prepareOperations groups only reads from the same statement family. The
// original order of writes is never changed. Each op owns a contiguous range
// in the flight, so ordinals cannot leak into another request's response.
func (w *worker) prepareOperations(f *flight) {
	f.ops = f.ops[:0]
	if !w.write && !f.single && w.d.cfg.sharedReads {
		f.ordered = f.ordered[:0]
		for id := stmtID(0); id < firstWriteStmt; id++ {
			for _, j := range f.jobs {
				if j.db.stmt == id {
					f.ordered = append(f.ordered, j)
				}
			}
		}
		f.jobs, f.ordered = f.ordered, f.jobs
		clear(f.ordered)
	}
	for start := 0; start < len(f.jobs); {
		id := f.jobs[start].db.stmt
		end := start + 1
		if !w.write && !f.single && w.d.cfg.sharedReads && (id == stTags || id < firstWriteStmt && w.sharedSD[id] != nil) {
			for end < len(f.jobs) && f.jobs[end].db.stmt == id {
				end++
			}
		}
		share := end-start > 1 && usefulSharing(f.jobs[start:end])
		if !share {
			end = start + 1
		}
		i := len(f.ops)
		if i == cap(f.ops) {
			f.ops = append(f.ops, readOperation{})
		} else {
			f.ops = f.ops[:i+1]
		}
		op := &f.ops[i]
		*op = readOperation{start: start, count: end - start, stmt: id, shared: share}
		start = end
	}
	if w.write {
		// Favorite toggles return the article by the input slug, which is
		// already known before execution. Queue those reads after all writes
		// in this flight but before its Sync, so they share the commit boundary
		// and get a fresh READ COMMITTED statement snapshot.
		for i, j := range f.jobs {
			if j.db.stmt != stFavorite && j.db.stmt != stUnfavorite {
				continue
			}
			f.ops = append(f.ops, readOperation{start: i, count: 1, stmt: stArticleBySlug, articleReply: true})
		}
	}
}

package main

import (
	"encoding/binary"
	"slices"
	"strings"
	"testing"

	"multicorelab/http/conduit"
)

func be64(v int64) []byte { return binary.BigEndian.AppendUint64(nil, uint64(v)) }

func TestFavoriteStatementsLeaveTheCountOut(t *testing.T) {
	for name, q := range map[string]string{"favorite": sqlFavorite, "unfavorite": sqlUnfavorite} {
		if strings.Contains(q, "count(") {
			t.Errorf("%s still counts favorites inside the write transaction:\n%s", name, q)
		}
		if !strings.Contains(q, "0::bigint") {
			t.Errorf("%s must return a zero count column", name)
		}
	}
}

func TestFavArticleIDsAreDistinctAndSorted(t *testing.T) {
	var ops []*opState
	for _, id := range []int64{9, 3, 9, 5, 3} {
		s := &opState{}
		s.art.id = id
		ops = append(ops, s)
	}
	if got, want := favArticleIDs(ops), []int64{3, 5, 9}; !slices.Equal(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestReadFavCounts(t *testing.T) {
	src := &replay{rows: [][][]byte{{be64(3), be64(14000)}, {be64(9), be64(1)}}}
	counts := map[int64]int64{}
	if err := readFavCounts(counts)(&pgRows{src: src}); err != nil {
		t.Fatal(err)
	}
	if counts[3] != 14000 || counts[9] != 1 || counts[5] != 0 || len(counts) != 2 {
		t.Fatalf("counts = %v", counts)
	}
}

func favOp(e conduit.Endpoint, viewer int64, slug string) *opState {
	return &opState{c: &conduit.Call{Endpoint: e, Viewer: viewer, Slug: []byte(slug)}}
}

func TestMarkRepeatedFavs(t *testing.T) {
	postA := favOp(conduit.Favorite, 1, "a")
	delA := favOp(conduit.Unfavorite, 1, "a")
	otherViewer := favOp(conduit.Favorite, 2, "a")
	otherArticle := favOp(conduit.Favorite, 1, "b")
	comment := favOp(conduit.CreateComment, 1, "a")
	markRepeatedFavs([]*opState{postA, otherViewer, delA, otherArticle, comment})
	for name, c := range map[string]struct {
		s    *opState
		want bool
	}{"post": {postA, true}, "delete": {delA, true}, "other viewer": {otherViewer, false},
		"other article": {otherArticle, false}, "comment": {comment, false}} {
		if c.s.inTxCount != c.want {
			t.Errorf("%s: inTxCount = %v, want %v", name, c.s.inTxCount, c.want)
		}
	}
	lone := favOp(conduit.Favorite, 1, "a")
	markRepeatedFavs([]*opState{lone, favOp(conduit.CreateComment, 1, "a")})
	if lone.inTxCount {
		t.Error("a single favorite must use the post-commit count")
	}
}

func TestMarkFavsWhenTheFlushRewritesAnArticle(t *testing.T) {
	for _, e := range []conduit.Endpoint{conduit.UpdateArticle, conduit.DeleteArticle} {
		post := favOp(conduit.Favorite, 1, "a-1")
		del := favOp(conduit.Unfavorite, 1, "e-1") // the renamed article: a different slug, so no repeated key
		lone := favOp(conduit.Favorite, 2, "b")
		other := favOp(conduit.CreateComment, 1, "a-1")
		markRepeatedFavs([]*opState{post, favOp(e, 1, "a-1"), del, lone, other})
		if !post.inTxCount || !del.inTxCount || !lone.inTxCount {
			t.Errorf("%v: every favorite of the flush must count inside the transaction", e)
		}
		if other.inTxCount {
			t.Errorf("%v: only favorites and unfavorites are marked", e)
		}
	}
	solo := favOp(conduit.Favorite, 1, "a")
	markRepeatedFavs([]*opState{solo, favOp(conduit.CreateArticle, 1, "x")})
	if solo.inTxCount {
		t.Error("a create does not rewrite an existing article")
	}
}

func TestReadSnapshotBegin(t *testing.T) {
	var sb stmtBatch
	sb.query("SELECT 1", nil, nil)
	sb.query("SELECT 2", nil, nil)
	sb.begin()
	sb.exec("COMMIT")
	var got []string
	for _, it := range sb.items {
		got = append(got, it.sql)
	}
	want := []string{sqlBeginRead, "SELECT 1", "SELECT 2", "COMMIT"}
	if !slices.Equal(got, want) {
		t.Fatalf("got %q, want %q", got, want)
	}
	if !strings.Contains(sqlBeginRead, "REPEATABLE READ READ ONLY") {
		t.Fatal("the read snapshot must be repeatable read and read only")
	}
}

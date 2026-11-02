package server

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
)

func compareAPIJSON(t *testing.T, got []byte, value any) {
	t.Helper()
	want, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	var a, b any
	gotDecoder, wantDecoder := json.NewDecoder(bytes.NewReader(got)), json.NewDecoder(bytes.NewReader(want))
	gotDecoder.UseNumber()
	wantDecoder.UseNumber()
	if !json.Valid(got) {
		t.Fatalf("invalid JSON %q", got)
	}
	if err := gotDecoder.Decode(&a); err != nil {
		t.Fatalf("invalid JSON %q: %v", got, err)
	}
	if err := wantDecoder.Decode(&b); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(a, b) {
		t.Fatalf("JSON values differ:\ngot  %s\nwant %s", got, want)
	}
}

func TestAPIJSON(t *testing.T) {
	texts := []string{"", "plain ASCII", "λ 🐱", "\"\\/\b\f\n\r\t\x00\x1f<>&\u2028\u2029", "\xff\xc0\xed\xa0\x80", strings.Repeat("large\"λ\n", 50000)}
	for _, text := range texts {
		p := profileJSON{Username: text, Bio: &text, Image: &text, Following: true}
		for _, tags := range [][]string{nil, {}, {text, "other"}} {
			a := articleJSON{Slug: text, Title: text, Description: text, Body: &text, TagList: tags,
				CreatedAt: timestamp(text), UpdatedAt: timestamp(text), FavoritesCount: math.MaxInt64, Favorited: true, Author: p}
			c := commentJSON{ID: math.MinInt64, Body: text, CreatedAt: timestamp(text), UpdatedAt: timestamp(text), Author: p}
			values := []any{
				articleListJSON{[]articleJSON{a, a}, 1000}, articleListJSON{nil, 0}, articleListJSON{[]articleJSON{}, 0},
				struct {
					Article articleJSON `json:"article"`
				}{a},
				struct {
					Comments []commentJSON `json:"comments"`
				}{[]commentJSON{c, c}},
				struct {
					Comments []commentJSON `json:"comments"`
				}{},
				struct {
					Comment commentJSON `json:"comment"`
				}{c},
				struct {
					Profile profileJSON `json:"profile"`
				}{p},
				struct {
					Profile profileJSON `json:"profile"`
				}{},
				struct {
					User userJSON `json:"user"`
				}{userJSON{text, text, text, &text, nil}},
				struct {
					Tags []string `json:"tags"`
				}{tags},
			}
			for _, value := range values {
				body, ok := appendAPIJSON(nil, value)
				if !ok {
					t.Fatalf("unhandled %T", value)
				}
				compareAPIJSON(t, body, value)
			}
			fragments := encodeArticleFragments(&a)
			for _, full := range []bool{false, true} {
				for _, favored := range []bool{false, true} {
					for _, following := range []bool{false, true} {
						copy := a
						if !full {
							copy.Body = nil
						}
						copy.Favorited, copy.Author.Following = favored, following
						shared := sharedArticleValue{fragments, full, favored, following}
						compareAPIJSON(t, shared.appendJSON(nil), copy)
						body, _ := appendSharedAPIJSON(nil, sharedArticleResponse{shared})
						compareAPIJSON(t, body, struct {
							Article articleJSON `json:"article"`
						}{copy})
						body, _ = appendSharedAPIJSON(nil, sharedArticleListResponse{[]sharedArticleValue{shared}, 1000})
						compareAPIJSON(t, body, articleListJSON{[]articleJSON{copy}, 1000})
					}
				}
			}
		}
	}
}

func TestAPIJSONResponse(t *testing.T) {
	old := responseEncoding
	defer func() { responseEncoding = old }()
	responseEncoding = "direct"
	// Exercise buffer growth, reuse, and discard as well as generic failures.
	for _, length := range []int{40000, 2, 400000, 0, 3} {
		value := struct {
			Profile profileJSON `json:"profile"`
		}{profileJSON{Username: strings.Repeat("λ\"", length)}}
		w := httptest.NewRecorder()
		writeJSON(w, http.StatusCreated, value)
		if w.Code != 201 || w.Header().Get("Content-Type") != "application/json" {
			t.Fatal("response headers")
		}
		compareAPIJSON(t, w.Body.Bytes(), value)
	}
	TestJSONResponse(t)
}

func FuzzArticleJSON(f *testing.F) {
	for _, s := range []string{"", "hello", "λ\"<>&\x00", "\xff\xed\xa0\x80"} {
		f.Add(s, false, true)
	}
	f.Fuzz(func(t *testing.T, text string, favored, following bool) {
		a := articleJSON{Slug: text, Title: text, Description: text, Body: &text, TagList: []string{text},
			Favorited: favored, Author: profileJSON{Username: text, Bio: &text, Following: following}}
		compareAPIJSON(t, appendArticle(nil, &a), a)
		shared := sharedArticleValue{encodeArticleFragments(&a), true, favored, following}
		compareAPIJSON(t, shared.appendJSON(nil), a)
	})
}

func BenchmarkArticleEncoding(b *testing.B) {
	for _, copies := range []int{1, 4, 16} {
		for _, mode := range []string{"standard", "direct", "shared"} {
			b.Run(fmt.Sprintf("%s/responses%d", mode, copies), func(b *testing.B) {
				old := responseEncoding
				responseEncoding = mode
				defer func() { responseEncoding = old }()
				w := discardResponse{make(http.Header)}
				articles := make([]articleJSON, 10)
				for i := range articles {
					articles[i] = articleJSON{Slug: "an-article-123", Title: "A title λ", Description: "A description with \"quotes\"",
						TagList: []string{"go", "postgres"}, CreatedAt: "2025-01-01T00:00:00.000Z", UpdatedAt: "2025-01-01T00:00:00.000Z",
						Author: profileJSON{Username: "author"}}
				}
				b.ReportAllocs()
				for b.Loop() {
					var shared []sharedArticleValue
					if mode == "shared" {
						shared = make([]sharedArticleValue, len(articles))
						for i := range articles {
							shared[i] = sharedArticleValue{fragments: encodeArticleFragments(&articles[i])}
						}
					}
					for range copies {
						if mode == "shared" {
							writeSharedJSON(w, 200, sharedArticleListResponse{shared, 1000})
						} else {
							writeJSON(w, 200, articleListJSON{articles, 1000})
						}
					}
				}
				b.ReportMetric(float64(b.Elapsed().Nanoseconds())/float64(b.N*copies), "ns/response")
			})
		}
	}
}

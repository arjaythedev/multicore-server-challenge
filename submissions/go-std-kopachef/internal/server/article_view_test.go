package server

import (
	"fmt"
	"reflect"
	"testing"
)

func TestArticleViews(t *testing.T) {
	for _, text := range []string{"", "quoted\" λ\n<>&", "\xff\xc0\x00"} {
		metadata := articleJSON{Slug: text, Title: text, Description: text, Body: &text,
			TagList: []string{text}, Author: profileJSON{Username: text, Bio: &text, Following: true}, FavoritesCount: 7, Favorited: true}
		before := metadata
		for _, full := range []bool{false, true} {
			for _, favored := range []bool{false, true} {
				for _, following := range []bool{false, true} {
					view := articleView{&metadata, articleFlags{favored, following}, full}
					want := metadata
					want.Favorited, want.Author.Following = favored, following
					if !full {
						want.Body = nil
					}
					response := articleViewResponse{view}
					body, ok := appendAPIJSON(nil, response)
					if !ok {
						t.Fatal("view not handled")
					}
					compareAPIJSON(t, body, struct {
						Article articleJSON `json:"article"`
					}{want})
					compareAPIJSON(t, body, response)
					list := articleViewList{[]articleView{view, view}, 1000}
					body, _ = appendAPIJSON(nil, list)
					compareAPIJSON(t, body, articleListJSON{[]articleJSON{want, want}, 1000})
					compareAPIJSON(t, body, list)
				}
			}
		}
		if !reflect.DeepEqual(metadata, before) {
			t.Fatal("encoding mutated shared metadata")
		}
	}
	for _, views := range [][]articleView{nil, {}} {
		value := articleViewList{articles: views}
		body, _ := appendAPIJSON(nil, value)
		compareAPIJSON(t, body, value)
	}
}

var viewBenchmarkBytes int

func BenchmarkArticleOverlays(b *testing.B) {
	for _, size := range []int{1, 10, 100} {
		metadata := make([]articleJSON, size)
		for i := range metadata {
			metadata[i] = articleJSON{Slug: "slug", Title: "title λ", Description: "description", TagList: []string{"go"},
				Author: profileJSON{Username: "author"}, CreatedAt: "2025-01-01T00:00:00.000Z", UpdatedAt: "2025-01-01T00:00:00.000Z"}
		}
		for _, views := range []bool{false, true} {
			b.Run(fmt.Sprintf("articles%d/views%t", size, views), func(b *testing.B) {
				buffer := make([]byte, 0, 65536)
				b.ReportAllocs()
				for b.Loop() {
					if views {
						items := make([]articleView, size)
						for i := range items {
							items[i] = articleView{metadata: &metadata[i], flags: articleFlags{true, true}}
						}
						buffer, _ = appendAPIJSON(buffer[:0], articleViewList{items, 1000})
					} else {
						items := make([]articleJSON, size)
						for i := range items {
							items[i] = metadata[i]
							items[i].Favorited, items[i].Author.Following = true, true
							items[i].Body = nil
						}
						buffer, _ = appendAPIJSON(buffer[:0], articleListJSON{items, 1000})
					}
					viewBenchmarkBytes = len(buffer)
				}
			})
		}
	}
}

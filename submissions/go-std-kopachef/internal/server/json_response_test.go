package server

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type failingJSON struct{}

func (failingJSON) MarshalJSON() ([]byte, error) { return nil, errors.New("test encoding failure") }

func TestJSONResponse(t *testing.T) {
	// A long response followed by short responses also catches stale buffer data.
	for _, value := range []any{strings.Repeat("λ\"\n<", 10000), nil, []string{}, "short"} {
		w := httptest.NewRecorder()
		writeJSON(w, http.StatusCreated, value)
		want, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		if w.Code != http.StatusCreated || w.Header().Get("Content-Type") != "application/json" ||
			strings.TrimSpace(w.Body.String()) != string(want) {
			t.Fatalf("invalid JSON response: status=%d, bytes=%d", w.Code, w.Body.Len())
		}
	}
	w := httptest.NewRecorder()
	writeJSON(w, http.StatusOK, struct {
		Prefix string      `json:"prefix"`
		Bad    failingJSON `json:"bad"`
	}{Prefix: "must not leak a partial response"})
	if w.Code != http.StatusInternalServerError || w.Body.String() != `{"errors":{"body":["internal error"]}}` {
		t.Fatalf("encoding failure response: %d %s", w.Code, w.Body.String())
	}
}

func TestTimestampJSON(t *testing.T) {
	for _, test := range []struct {
		value time.Time
		want  string
	}{
		{time.Date(2025, 4, 1, 12, 0, 0, 123999999, time.FixedZone("offset", 2*60*60)), `"2025-04-01T10:00:00.123Z"`},
		{time.Time{}, `"0001-01-01T00:00:00.000Z"`},
		{time.Unix(-1, 999999999), `"1969-12-31T23:59:59.999Z"`},
	} {
		got, err := json.Marshal(ts(test.value))
		if err != nil || string(got) != test.want {
			t.Fatalf("timestamp = %s, want %s, error %v", got, test.want, err)
		}
	}
}

type discardResponse struct{ header http.Header }

func (w discardResponse) Header() http.Header       { return w.header }
func (discardResponse) WriteHeader(int)             {}
func (discardResponse) Write(p []byte) (int, error) { return len(p), nil }

func BenchmarkJSONResponse(b *testing.B) {
	articles := make([]articleJSON, 10)
	for i := range articles {
		articles[i] = articleJSON{
			Slug: "an-article-123", Title: "A title λ", Description: "A description with \"quotes\"",
			TagList: []string{"go", "postgres"}, CreatedAt: ts(time.Unix(1700000000, 123456000)),
			UpdatedAt: ts(time.Unix(1700000000, 123456000)),
			Author:    profileJSON{Username: "author"},
		}
	}
	value := struct {
		Articles []articleJSON `json:"articles"`
		Count    int           `json:"articlesCount"`
	}{articles, 1000}
	w := discardResponse{make(http.Header)}
	b.Run("marshal", func(b *testing.B) {
		b.ReportAllocs()
		for b.Loop() {
			body, err := json.Marshal(value)
			if err != nil {
				b.Fatal(err)
			}
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write(body)
		}
	})
	b.Run("pooled-encoder", func(b *testing.B) {
		b.ReportAllocs()
		for b.Loop() {
			writeJSON(w, http.StatusOK, value)
		}
	})
}

// Include formatting at row materialization, then encode one or four responses
// using that batch's immutable metadata. Both timestamp representations pay
// their complete formatting cost inside the measured loop.
func BenchmarkJSONMaterialize(b *testing.B) {
	created := time.Unix(1700000000, 123456000)
	for _, copies := range []int{1, 4} {
		b.Run(fmt.Sprintf("responses%d", copies), func(b *testing.B) {
			w := discardResponse{make(http.Header)}
			b.ReportAllocs()
			for b.Loop() {
				articles := make([]articleJSON, 10)
				for i := range articles {
					articles[i] = articleJSON{Slug: "an-article-123", Title: "A title λ",
						Description: "A description with \"quotes\"", TagList: []string{"go", "postgres"},
						CreatedAt: ts(created), UpdatedAt: ts(created), Author: profileJSON{Username: "author"}}
				}
				value := articleListJSON{Articles: articles, ArticlesCount: 1000}
				for range copies {
					writeJSON(w, http.StatusOK, value)
				}
			}
			b.ReportMetric(float64(b.Elapsed().Nanoseconds())/float64(b.N*copies), "ns/response")
		})
	}
}

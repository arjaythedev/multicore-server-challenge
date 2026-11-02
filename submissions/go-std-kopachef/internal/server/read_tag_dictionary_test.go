package server

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"slices"
	"testing"

	"github.com/jackc/pgx/v5"
)

// Exercise pgx's actual array scan plans across growth, empty rows and a
// large-to-small transition. Earlier rows must retain their owned values.
func TestArticleTagIDOwnership(t *testing.T) {
	f := newReadFixture(t, 0)
	for _, format := range []int16{pgx.BinaryFormatCode, pgx.TextFormatCode} {
		t.Run(fmt.Sprint(format), func(t *testing.T) {
			var got articleTagIDs
			var want []int64
			for round, n := range []int{0, 1, 2048, 3, 0, 4096, 2} {
				input := make([]int64, n)
				for i := range input {
					input[i] = int64(round*100000 - i*17)
				}
				rows, err := f.pool.Query(context.Background(), `SELECT $1::bigint[]`, pgx.QueryResultFormats{format}, input)
				if err != nil {
					t.Fatal(err)
				}
				if !rows.Next() || rows.FieldDescriptions()[0].Format != format {
					rows.Close()
					t.Fatal("missing array or wrong format", rows.Err())
				}
				if err := rows.Scan(&got); err != nil {
					rows.Close()
					t.Fatal(err)
				}
				rows.Close()
				want = append(want, input...)
				if len(got.values) != len(want) || !slices.Equal(got.values[got.start:], input) {
					t.Fatalf("array %d changed its values or extent", round)
				}
				if !slices.Equal(got.values, want) {
					t.Fatalf("array %d overwrote an earlier row", round)
				}
			}
			var rejected articleTagIDs
			err := f.pool.QueryRow(context.Background(), `SELECT NULL::bigint[]`, pgx.QueryResultFormats{format}).Scan(&rejected)
			if err == nil {
				t.Fatal("NULL metadata tag IDs were accepted")
			}
		})
	}
}

func TestArticleTagRanksScan(t *testing.T) {
	f := newReadFixture(t, 0)
	for _, format := range []int16{pgx.BinaryFormatCode, pgx.TextFormatCode} {
		t.Run(fmt.Sprint(format), func(t *testing.T) {
			scanner := articleTagRanks{byID: map[int64]int{50: 2, -7: 0, 1 << 40: 1}}
			values, ranks := []int64{50, -7, 1 << 40}, []int{2, 0, 1}
			for _, n := range []int{0, 1, 4096, 3, 0, 2} {
				input, want := make([]int64, n), make([]int, n)
				for i := range input {
					input[i], want[i] = values[i%3], ranks[i%3]
				}
				if err := f.pool.QueryRow(context.Background(), `SELECT $1::bigint[]`, pgx.QueryResultFormats{format}, input).Scan(&scanner); err != nil {
					t.Fatal(err)
				}
				if !slices.Equal(scanner.values, want) {
					t.Fatalf("rank scan changed after resizing to %d", n)
				}
			}
			for _, query := range []string{`SELECT NULL::bigint[]`, `SELECT ARRAY[NULL]::bigint[]`, `SELECT ARRAY[999]::bigint[]`} {
				if err := f.pool.QueryRow(context.Background(), query, pgx.QueryResultFormats{format}).Scan(&scanner); err == nil {
					t.Fatal("invalid metadata tags were accepted", query)
				}
			}
		})
	}
}

// Dictionary order is independent of row order, and results from an earlier
// batch remain owned after the next batch sees newly created Unicode tags.
func TestDictionaryArticlesOrderAndFreshness(t *testing.T) {
	f := newReadFixture(t, 0)
	ctx := context.Background()
	var emptyID int64
	if err := f.pool.QueryRow(ctx, `SELECT id FROM articles WHERE slug=$1`, f.cases[0].slug+"_empty").Scan(&emptyID); err != nil {
		t.Fatal(err)
	}
	ids := []int64{f.articleID, emptyID}
	const columns = "is_flags,id,slug,title,description,body,created_at,updated_at,tag_ids,favorites_count,username,bio,image,viewer,favorited,following,names"
	var retained *articleJSON
	var retainedTags []string
	check := func() {
		for _, format := range []int16{pgx.BinaryFormatCode, pgx.TextFormatCode} {
			for _, order := range []string{"FIRST", "LAST"} {
				query := "WITH r(" + columns + ") AS MATERIALIZED (" + sharedArticleDictionarySQL + ") SELECT * FROM r ORDER BY is_flags NULLS " + order
				rows, err := f.pool.Query(ctx, query, pgx.QueryResultFormats{format}, ids, ids,
					[]int64{f.readerID, f.readerID}, ids)
				if err != nil {
					t.Fatal(err)
				}
				articles, flags := make(map[int64]*articleJSON), make(map[articleViewer]articleFlags)
				_, err = decodeDictionaryArticles(rows, articles, flags, len(ids))
				rows.Close()
				if err != nil {
					t.Fatalf("format %d dictionary %s: %v", format, order, err)
				}
				for i, id := range ids {
					article := articles[id]
					if article == nil {
						t.Fatal("missing fixture article", id)
					}
					slug := f.cases[0].slug
					if i == 1 {
						slug += "_empty"
					}
					body, err := json.Marshal(articleViewResponse{articleView{article, flags[articleViewer{f.readerID, id}], true}})
					if err != nil {
						t.Fatal(err)
					}
					compareRead(t, 200, body, runReadCase(&app{pool: f.pool}, readCase{kind: readArticle, viewer: f.readerID, slug: slug}))
				}
				if retained == nil {
					retained = articles[f.articleID]
					retainedTags = append([]string(nil), retained.TagList...)
				}
			}
		}
	}
	check()
	names := []string{f.cases[0].slug + "_Å", f.cases[0].slug + "_a\"λ", f.cases[0].slug + "_Z"}
	f.tags = append(f.tags, names...)
	if _, err := f.pool.Exec(ctx, `INSERT INTO tags(name) SELECT unnest($1::text[])`, names); err != nil {
		t.Fatal(err)
	}
	if _, err := f.pool.Exec(ctx, `INSERT INTO article_tags(article_id,tag_id) SELECT $1,id FROM tags WHERE name=ANY($2::text[])`, f.articleID, names); err != nil {
		t.Fatal(err)
	}
	check()
	if !reflect.DeepEqual(retained.TagList, retainedTags) {
		t.Fatal("a later dictionary changed the earlier response")
	}
}

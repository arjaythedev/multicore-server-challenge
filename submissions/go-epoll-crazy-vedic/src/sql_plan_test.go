package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

func median(sorted []float64) float64 {
	if len(sorted)%2 == 1 {
		return sorted[len(sorted)/2]
	}
	return (sorted[len(sorted)/2-1] + sorted[len(sorted)/2]) / 2
}

// TestCaptureSQLPlans is an opt-in local experiment. It only reads a disposable
// seeded database and writes PostgreSQL's JSON EXPLAIN output to PLAN_OUT.
func TestCaptureSQLPlans(t *testing.T) {
	if os.Getenv("CAPTURE_SQL_PLANS") != "1" {
		t.Skip("set CAPTURE_SQL_PLANS=1 to capture query plans")
	}
	if os.Getenv("TEST_DATABASE_URL") == "" || os.Getenv("PLAN_OUT") == "" {
		t.Fatal("TEST_DATABASE_URL and PLAN_OUT are required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Minute)
	defer cancel()
	cfg, err := postgresConfig(os.Getenv("TEST_DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	c, err := pgconn.ConnectConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close(ctx)
	queryOne := func(sql string) string {
		t.Helper()
		results, err := c.Exec(ctx, sql).ReadAll()
		if err != nil || len(results) == 0 || len(results[0].Rows) == 0 {
			t.Fatalf("query setup failed: %s: %v", sql, err)
		}
		return string(results[0].Rows[0][0])
	}
	quote := func(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }
	tag := quote(queryOne("SELECT name FROM tags ORDER BY name LIMIT 1"))
	author := quote(queryOne("SELECT u.username FROM articles a JOIN users u ON u.id=a.author_id GROUP BY u.username ORDER BY count(*) DESC LIMIT 1"))
	favorited := quote(queryOne("SELECT u.username FROM favorites f JOIN users u ON u.id=f.user_id GROUP BY u.username ORDER BY count(*) DESC LIMIT 1"))
	followerTop := queryOne("SELECT follower_id FROM follows GROUP BY follower_id ORDER BY count(*) DESC LIMIT 1")
	followerMedian := queryOne(`SELECT u.id FROM users u LEFT JOIN follows f ON f.follower_id=u.id
WHERE u.id<=4000 GROUP BY u.id ORDER BY abs(count(f.followee_id)-12),u.id LIMIT 1`)
	slug := quote(queryOne("SELECT slug FROM articles ORDER BY id DESC LIMIT 1"))
	params := map[string][]string{
		"list_global":      {"1,10,0", "1,10,40"},
		"global_count":     {""},
		"global_page_in":   {"1,10,0", "1,10,40"},
		"global_page_join": {"1,10,0", "1,10,40"},
		"global_full_join": {"1,10,0", "1,10,40"},
		"list_tag":         {"1,10,0," + tag, "1,10,40," + tag},
		"list_author":      {"1,5,0," + author, "1,5,40," + author},
		"list_favorited":   {"1,5,0," + favorited, "1,5,40," + favorited},
		"feed":             {followerTop + ",10,0", followerMedian + ",10,0", followerMedian + ",10,40"},
		"article":          {"1," + slug},
		"comments":         {"1," + slug},
	}
	queries := map[string]string{
		"list_global":    stmts[stListAll].sql,
		"global_count":   countAll,
		"global_page_in": articleListSelect + ` WHERE a.id IN (SELECT p.id FROM articles p ORDER BY p.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC`,
		"global_page_join": strings.Replace(articleListSelect,
			"FROM articles a\n  JOIN users u ON u.id = a.author_id",
			"FROM (SELECT p.id FROM articles p ORDER BY p.id DESC LIMIT $2 OFFSET $3) page\n  JOIN articles a ON a.id = page.id\n  JOIN users u ON u.id = a.author_id", 1) + ` ORDER BY page.id DESC`,
		"global_full_join": `WITH total AS (` + countAll + `) SELECT total.count,page.* FROM total LEFT JOIN LATERAL (` + strings.Replace(articleListSelect,
			"FROM articles a\n  JOIN users u ON u.id = a.author_id",
			"FROM (SELECT p.id FROM articles p ORDER BY p.id DESC LIMIT $2 OFFSET $3) page\n  JOIN articles a ON a.id = page.id\n  JOIN users u ON u.id = a.author_id", 1) + ` ORDER BY page.id DESC) page ON true ORDER BY page.id DESC`,
		"list_tag":       stmts[stListTag].sql,
		"list_author":    stmts[stListAuthor].sql,
		"list_favorited": stmts[stListFavorite].sql,
		"feed":           stmts[stListFeed].sql,
		"article":        stmts[stArticleBySlug].sql,
		"comments":       stmts[stComments].sql,
	}
	plans := map[string]json.RawMessage{}
	timings := map[string]any{}
	repeats := 200
	if value := os.Getenv("PLAN_REPEATS"); value != "" {
		n, err := strconv.Atoi(value)
		if err != nil || n < 200 || n > 10000 {
			t.Fatalf("PLAN_REPEATS must be between 200 and 10000")
		}
		repeats = n
	}
	explainExecute := func(params string) string {
		stmt := "EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON, TIMING OFF, SUMMARY ON) EXECUTE plan_probe"
		if params != "" {
			stmt += "(" + params + ")"
		}
		return stmt
	}
	for name, sql := range queries {
		if _, err := c.Exec(ctx, "PREPARE plan_probe AS "+sql).ReadAll(); err != nil {
			t.Fatalf("prepare %s failed: %v", name, err)
		}
		samples := params[name]
		for i := 0; i < 8; i++ { // let plan_cache_mode=auto reach its normal decision
			stmt := explainExecute(samples[i%len(samples)])
			results, err := c.Exec(ctx, stmt).ReadAll()
			if err != nil || len(results) == 0 || len(results[0].Rows) == 0 {
				t.Fatalf("explain %s failed: %v", name, err)
			}
		}
		for i, params := range samples {
			stmt := explainExecute(params)
			type timing struct {
				Planning  float64 `json:"Planning Time"`
				Execution float64 `json:"Execution Time"`
			}
			planning := make([]float64, 0, repeats)
			execution := make([]float64, 0, repeats)
			for run := 0; run < repeats; run++ {
				results, err := c.Exec(ctx, stmt).ReadAll()
				if err != nil || len(results) == 0 || len(results[0].Rows) == 0 {
					t.Fatalf("explain %s sample %d run %d failed: %v", name, i, run, err)
				}
				var captured []timing
				if err := json.Unmarshal(results[0].Rows[0][0], &captured); err != nil || len(captured) == 0 {
					t.Fatalf("decode explain %s sample %d run %d: %v", name, i, run, err)
				}
				planning = append(planning, captured[0].Planning)
				execution = append(execution, captured[0].Execution)
				if run == 0 {
					plans[fmt.Sprintf("%s_sample_%d", name, i)] = json.RawMessage(append([]byte(nil), results[0].Rows[0][0]...))
				}
			}
			sort.Float64s(planning)
			sort.Float64s(execution)
			timings[fmt.Sprintf("%s_sample_%d", name, i)] = map[string]any{
				"runs": repeats, "median_planning_ms": median(planning), "median_execution_ms": median(execution),
			}
		}
		if _, err := c.Exec(ctx, "DEALLOCATE plan_probe").ReadAll(); err != nil {
			t.Fatal(err)
		}
	}
	out := map[string]any{
		"plan_cache_mode": envOr("PG_PLAN_MODE", "force_generic_plan"),
		"metadata_batch":  envOr("SQL_METADATA_BATCH", "0"),
		"recent_feed":     envOr("FEED_RECENT_SCAN", "0"),
		"favorite_mode":   envOr("PG_FAVORITE_MODE", "combined"),
		"timing_repeats":  repeats,
		"timings":         timings,
		"plans":           plans,
	}
	b, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(os.Getenv("PLAN_OUT"), b, 0o600); err != nil {
		t.Fatal(err)
	}
}

package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

func databaseForTest(t *testing.T) *pgconn.PgConn {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("set TEST_DATABASE_URL to a disposable seeded database")
	}
	cfg, err := postgresConfig(url)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	c, err := pgconn.ConnectConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close(context.Background()) })
	return c
}

func execTestSQL(t *testing.T, c *pgconn.PgConn, sql string) []*pgconn.Result {
	t.Helper()
	r, err := c.Exec(context.Background(), sql).ReadAll()
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func readJob(id stmtID, viewer, limit, offset int64, filter string) *reactorJob {
	j := &reactorJob{}
	j.db.stmt, j.db.viewer = id, viewer
	switch id {
	case stTags:
		j.db.route = rTags
	case stArticleBySlug, stComments:
		j.db.route = rArticle
		if id == stComments {
			j.db.route = rComments
		}
		j.db.addInt(viewer)
		j.db.addText(filter)
	default:
		j.db.route = rList
		j.db.addInt(viewer)
		j.db.addInt(limit)
		j.db.addInt(offset)
		if id != stListAll {
			j.db.addText(filter)
		}
	}
	return j
}

func TestSharedReadsMatchIndividualStatements(t *testing.T) {
	c := databaseForTest(t)
	ctx := context.Background()
	fixtures := execTestSQL(t, c, `SELECT a.id,a.slug,a.author_id,(SELECT username FROM users WHERE id=1),
 (SELECT name FROM tags ORDER BY name LIMIT 1) FROM articles a ORDER BY a.id DESC LIMIT 1`)[0].Rows[0]
	articleID, slug, authorID, username, tag := string(fixtures[0]), string(fixtures[1]), string(fixtures[2]), string(fixtures[3]), string(fixtures[4])
	execTestSQL(t, c, `INSERT INTO favorites(user_id,article_id) VALUES(1,`+articleID+`) ON CONFLICT DO NOTHING;
 DELETE FROM favorites WHERE user_id=2 AND article_id=`+articleID+`;
 INSERT INTO follows(follower_id,followee_id) VALUES(1,`+authorID+`) ON CONFLICT DO NOTHING;
 DELETE FROM follows WHERE follower_id=2 AND followee_id=`+authorID+`;`)
	for _, id := range []stmtID{stListAll, stListTag, stListAuthor, stListFavorite, stArticleBySlug, stComments, stTags} {
		t.Run(fmt.Sprint(id), func(t *testing.T) {
			sd, err := c.Prepare(ctx, fmt.Sprintf("individual%d", id), stmts[id].sql, nil)
			if err != nil {
				t.Fatal(err)
			}
			shared := sd
			if id != stTags {
				shared, err = c.Prepare(ctx, fmt.Sprintf("coalesced%d", id), sharedReads[id], nil)
				if err != nil {
					t.Fatal(err)
				}
			}
			filter := ""
			switch id {
			case stListTag:
				filter = tag
			case stListAuthor, stListFavorite:
				filter = username
			case stArticleBySlug, stComments:
				filter = slug
			}
			var jobs []*reactorJob
			for i := 0; i < 8; i++ {
				f, offset := filter, int64(0)
				if i == 6 {
					if id == stListAll {
						offset = 100000000
					} else {
						f = "__missing_zenithvedic__"
					}
				}
				if i == 7 && id <= stListFavorite {
					offset = 5
				}
				jobs = append(jobs, readJob(id, int64(i%3), 10, offset, f))
			}
			w := &worker{}
			expected := make([][]byte, len(jobs))
			for i, j := range jobs {
				rr := c.ExecPrepared(ctx, sd.Name, j.db.params[:j.db.nparams], paramBinary, resultBinary)
				if _, err := w.finish(j, rr); err != nil {
					t.Fatal(err)
				}
				expected[i] = append([]byte(nil), j.response.body...)
			}
			var params [][]byte
			if id != stTags {
				for p, oid := range sd.ParamOIDs {
					params = append(params, encodeArray(nil, jobs, p, oid))
				}
			}
			rr := c.ExecPrepared(ctx, shared.Name, params, paramBinary, resultBinary)
			if err := w.finishShared(jobs, rr); err != nil {
				t.Fatal(err)
			}
			for i, j := range jobs {
				if !bytes.Equal(expected[i], j.response.body) {
					t.Fatalf("recipient %d differs:\nwant %s\ngot  %s", i, expected[i], j.response.body)
				}
			}
		})
	}
}

func TestTagBatchReadsAgainAfterMutation(t *testing.T) {
	c := databaseForTest(t)
	sd, err := c.Prepare(context.Background(), "tags", stmts[stTags].sql, nil)
	if err != nil {
		t.Fatal(err)
	}
	jobs := []*reactorJob{readJob(stTags, 0, 0, 0, ""), readJob(stTags, 0, 0, 0, "")}
	w := &worker{}
	query := func() {
		t.Helper()
		if err := w.finishShared(jobs, c.ExecPrepared(context.Background(), sd.Name, nil, nil, resultBinary)); err != nil {
			t.Fatal(err)
		}
	}
	query()
	name := fmt.Sprintf("zenith_tag_%d", time.Now().UnixNano())
	execTestSQL(t, c, "INSERT INTO tags(name) VALUES ('"+name+"')")
	query()
	for _, j := range jobs {
		if !bytes.Contains(j.response.body, []byte(name)) {
			t.Fatal("batch reused an earlier result")
		}
	}
}

func TestSharingThresholdAndBinaryArrays(t *testing.T) {
	jobs := []*reactorJob{readJob(stListTag, 1, 10, 0, "één"), readJob(stListTag, 2, 10, 0, "één")}
	if !usefulSharing(jobs) {
		t.Fatal("viewers prevented shared metadata")
	}
	jobs[1] = readJob(stListTag, 2, 10, 1, "één")
	if usefulSharing(jobs) {
		t.Fatal("distinct pages forced materialization")
	}
	encoded := encodeArray(nil, jobs, 3, 25)
	if !bytes.Contains(encoded, []byte("één")) || len(encoded) != 20+2*(4+len("één")) {
		t.Fatal("array lost UTF-8 or length")
	}
}

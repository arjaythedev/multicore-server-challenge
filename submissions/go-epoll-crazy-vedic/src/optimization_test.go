package main

import (
	"bytes"
	"context"
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestBorrowedWireRebasedBeforeInputReuse(t *testing.T) {
	for _, frame := range []string{
		"POST /api/users/login HTTP/1.1\r\nHost: test\r\nAuthorization: Token abc\r\nContent-Length: 3\r\n\r\nxyz",
		"POST /api/users/login HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nxyz\r\n0\r\n\r\n",
	} {
		src := []byte(frame)
		var parsed wireRequest
		if parseWire(src, &parsed) != len(src) {
			t.Fatal("fixture not framed")
		}
		copyFrame := append([]byte(nil), src...)
		j := &reactorJob{frame: copyFrame, wire: rebaseWire(parsed, src, copyFrame)}
		clear(src)
		if !parseJob(j) || string(j.req.body) != "xyz" || string(j.wire.target) != "/api/users/login" {
			t.Fatal("borrowed input escaped its lifetime")
		}
	}
}

func TestHTTPDateAndLocalTLS(t *testing.T) {
	date := string(appendHTTPDate(nil))
	if _, err := time.Parse(time.RFC1123, date); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PG_LOCAL_TLS", "auto")
	t.Setenv("PGSSLMODE", "")
	t.Setenv("PGSERVICE", "")
	t.Setenv("PGSERVICEFILE", "")
	for _, tc := range []struct {
		dsn string
		tls bool
	}{
		{"postgres://u:p@127.0.0.1/db", false},
		{"postgres://u:p@127.0.0.1/db?sslmode=require", true},
		{"postgres://u:p@192.0.2.1/db?sslmode=require", true},
	} {
		c, err := postgresConfig(tc.dsn)
		if err != nil {
			t.Fatal(err)
		}
		if (c.TLSConfig != nil) != tc.tls {
			t.Fatalf("TLS selection for %s", tc.dsn)
		}
	}
}

func TestMetadataAndHybridFeedMatchReference(t *testing.T) {
	t.Setenv("SQL_METADATA_BATCH", "1")
	t.Setenv("FEED_RECENT_SCAN", "1")
	c := databaseForTest(t)
	fixtures := execTestSQL(t, c, `SELECT (SELECT name FROM tags ORDER BY name LIMIT 1),(SELECT username FROM users WHERE id=1)`)[0].Rows[0]
	cases := []struct {
		id                  stmtID
		page, count, filter string
	}{
		{stListAll, listAll, countAll, ""}, {stListTag, listByTag, countByTag, string(fixtures[0])},
		{stListAuthor, listByAuthor, countByAuthor, string(fixtures[1])}, {stListFavorite, listByFavorite, countByFavorite, string(fixtures[1])},
		{stListFeed, listFeed, countFeed, ""},
	}
	for _, tc := range cases {
		count := tc.count
		if tc.id != stListAll && tc.id != stListFeed {
			count = strings.ReplaceAll(count, "$1", "$4")
		}
		reference := `WITH total AS (` + count + `) SELECT total.count,page.* FROM total LEFT JOIN LATERAL (` + tc.page + `) page ON true ORDER BY page.id DESC`
		old, err := c.Prepare(context.Background(), fmt.Sprintf("ref_%d", tc.id), reference, nil)
		if err != nil {
			t.Fatal(err)
		}
		newer, err := c.Prepare(context.Background(), fmt.Sprintf("opt_%d", tc.id), optimizedListStatement(tc.page, count, tc.id == stListFeed), nil)
		if err != nil {
			t.Fatal(err)
		}
		for _, viewer := range []int64{1, 2, 999999999} {
			for _, offset := range []int64{0, 5, 100000000} {
				j := readJob(stListAll, viewer, 10, offset, "")
				j.db.stmt = tc.id
				if tc.id != stListAll && tc.id != stListFeed {
					j.db.addText(tc.filter)
				}
				w := &worker{}
				_, err := w.finish(j, c.ExecPrepared(context.Background(), old.Name, j.db.params[:j.db.nparams], paramBinary, resultBinary))
				if err != nil {
					t.Fatal(err)
				}
				expected := append([]byte(nil), j.response.body...)
				j.db.out = j.db.out[:0]
				_, err = w.finish(j, c.ExecPrepared(context.Background(), newer.Name, j.db.params[:j.db.nparams], paramBinary, resultBinary))
				if err != nil {
					t.Fatal(err)
				}
				if !bytes.Equal(expected, j.response.body) {
					t.Fatalf("statement %d viewer %d offset %d differs", tc.id, viewer, offset)
				}
			}
		}
	}
}

func TestDeferredFlushRetainsIndependentCommitBoundaries(t *testing.T) {
	c := databaseForTest(t)
	d, owner := dispatcherForTest(t)
	w := d.workers[len(d.workers)-1]
	slug := string(execTestSQL(t, c, "SELECT slug FROM articles ORDER BY id DESC LIMIT 1")[0].Rows[0][0])
	w.deferFlush = true
	a, b := commentJob(owner, slug, "deferred bad", 999999999), commentJob(owner, slug, "deferred good", 1)
	w.send([]*reactorJob{a}, true)
	w.send([]*reactorJob{b}, false)
	if w.buffered != 2 || len(owner.completed) != 0 {
		t.Fatal("flight flushed or answered early")
	}
	w.flushPipeline()
	w.receive()
	w.receive()
	if a.response.status != 500 || b.response.status != 201 {
		t.Fatal("a failed transaction damaged a later boundary")
	}
}

func TestReleasedSlotDropsBorrowedWireFields(t *testing.T) {
	r := &eventLoop{outstanding: 1}
	j := &reactorJob{largeID: -1, wire: wireRequest{body: make([]byte, 1024), target: []byte("/api/tags")}}
	r.releaseJob(j)
	if j.wire.body != nil || j.wire.target != nil || r.outstanding != 0 {
		t.Fatal("idle slot retained borrowed input")
	}
}

package server

import (
	"fmt"
	"net/http/httptest"
	"testing"
)

func TestPageBeforeEnrichment(t *testing.T) {
	f := newReadFixture(t, 0)
	a := &app{pool: f.pool}
	var author string
	if err := f.pool.QueryRow(t.Context(), `SELECT username FROM users WHERE id = $1`, f.authorID).Scan(&author); err != nil {
		t.Fatal(err)
	}
	for _, viewer := range []int64{0, f.readerID} {
		for _, limit := range []int64{1, 10} {
			for _, offset := range []int64{0, 1, 40, 100000} {
				for _, byAuthor := range []bool{false, true} {
					t.Run(fmt.Sprintf("viewer%d/limit%d/offset%d/author%v", viewer, limit, offset, byAuthor), func(t *testing.T) {
						old := articleListSelect
						current, count := listAll, countAll
						var filter any
						if byAuthor {
							old += ` WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4)`
							current, count, filter = listByAuthor, countByAuthor, author
						}
						old += ` ORDER BY a.id DESC LIMIT $2 OFFSET $3`
						request := httptest.NewRequest("GET", "/", nil)
						want, got := httptest.NewRecorder(), httptest.NewRecorder()
						a.writeList(want, request, old, count, viewer, limit, offset, filter)
						a.writeList(got, request, current, count, viewer, limit, offset, filter)
						if want.Code != 200 {
							t.Fatalf("reference query failed: %s", want.Body.String())
						}
						compareRead(t, got.Code, got.Body.Bytes(), want)
					})
				}
			}
		}
	}
}

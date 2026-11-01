# http: event-loop server and Conduit front

What the database side needs to know. The server (`multicorelab/http`) runs the
sockets and HTTP. The front (`http/conduit`) routes each request, checks its
token, and validates the query and body, then answers at once (401, 404, 422)
or defers the request with a decoded `Call`. The database side gets the
deferred requests in batches, fills in each response and calls `Done`.

## Wiring

```go
var front *conduit.Front
srv, err := http.New(http.Config{
	Addr:     "0.0.0.0:3000",
	Loops:    2,                  // default min(2, GOMAXPROCS)
	Handback: http.HandbackQueue, // default; HandbackDirect = completer writes
	Wait:     http.WaitEpoll,     // or WaitNetpoll: idle loops hold no thread
	Handler:  func(q *http.Request, r *http.Response) { front.Handle(q, r) },
	Batcher:  db, // your type with SubmitBatch(ops []*http.Op)
})
front = conduit.New(srv.Ops(), []byte(os.Getenv("JWT_SECRET")))
go srv.Serve() // returns after srv.Close(), once requests in flight finish
```

## What SubmitBatch receives

`SubmitBatch(ops []*http.Op)` runs on a loop goroutine, once per loop turn,
with every request that loop deferred in that turn. Each loop calls it
independently.

- It must not block: queue the Ops (or the batch) to your goroutines and return.
- The slice is valid only during the call. Copy the pointers out; the Ops
  themselves stay valid until you call `Done` on them.
- `op.ID()` is below `srv.Ops()`: keep per-Op state in a slice indexed by it.

## When every Op is in flight

Each loop has a fixed number of Ops (`OpsPerLoop`, 1024). A request that
needs one when none is free waits: its connection is not read until an Op
frees, and then the request is parsed and run through the front again,
connections oldest first. Requests the front answers at once (401, 404, 422)
keep flowing meanwhile, on every connection that isn't waiting.

Handlers of your own: `req.Defer()` returns nil when no Op is free. Return at
once without answering; the handler is called again for the same request.

## The Call, by endpoint

`front.Call(op)` returns the request, validated and decoded. `Viewer` is the
token's user id, 0 when anonymous. Every byte slice is decoded (no escapes left).

| Endpoint | Fields set |
|---|---|
| Register | NewUsername, Email, Password (all Valid, non-empty) |
| Login | Email, Password (Valid, non-empty; password not length-checked) |
| GetUser | Viewer, Token (echo it back; don't sign a new one) |
| UpdateUser | Viewer, Token; any of Email, Password, NewUsername, Bio, Image (Valid = present; Bio and Image may be "") |
| GetProfile, Follow, Unfollow | Username; Viewer (optional for GetProfile) |
| ListArticles | Limit, Offset, Filter (NoFilter, ByTag, ByAuthor, ByFavorited), FilterValue |
| Feed | Viewer, Limit, Offset |
| CreateArticle | Title, Description, Body (Valid, non-empty), TagList (order sent, duplicates kept) |
| GetArticle, DeleteArticle, Favorite, Unfavorite, ListComments | Slug |
| UpdateArticle | Slug; any of Title, Description, Body (non-empty when Valid) |
| CreateComment | Slug, Body |
| DeleteComment | Slug, CommentID |
| Tags | nothing |

Viewer is set whenever a valid token was sent, and always where one is required.
The front never looks the user up: a valid token for a deleted user still
arrives with that Viewer (quirk #4). Existence, ownership (403), uniqueness (422 "already
taken") and login credentials (401) are yours to check.

## Filling the response

`op.Resp` starts empty with reusable capacity: append to it. `op.Status`
defaults to 200. Content-Type and Content-Length are added for you, and a HEAD
request's body is dropped. Encode with `jsonw`, which appends to a byte slice
and never allocates beyond growing it. Key order and whitespace don't matter.
Timestamps use `jsonw.Time` or `jsonw.PostgresMicro` (`...T12:00:00.000Z`,
truncated like the reference).

Splice shared, pre-encoded parts in with `jsonw.Raw` and append the per-viewer
parts around them. An article is a head, the same for every viewer, then the
viewer's flags. The head may be shared only by the requests of **one batch**,
from that batch's own query results: never keep it, or anything else derived from
the database, across batches (rule 5). Nothing in `conduit` or `jsonw` keeps
database data between requests.

```go
// Built from this batch's rows, at most once per article per batch, and dropped
// when the batch is done ("body" left out for lists).
func articleHead(dst []byte, a *Article, withBody bool) []byte {
	dst = append(dst, `{"slug":`...)
	dst = jsonw.Bytes(dst, a.Slug)
	// ... "title", "description", "body" if withBody, the same way
	dst = append(dst, `,"tagList":[`...)
	for i, t := range a.Tags { // database collation order (quirk #10)
		if i > 0 {
			dst = append(dst, ',')
		}
		dst = jsonw.Bytes(dst, t)
	}
	dst = append(dst, `],"createdAt":`...)
	dst = jsonw.PostgresMicro(dst, a.Created) // and "updatedAt"
	dst = append(dst, `,"author":{"username":`...)
	dst = jsonw.Bytes(dst, a.Author.Username)
	dst = append(dst, `,"bio":`...)
	dst = jsonw.NullString(dst, a.Author.Bio, a.Author.HasBio) // and "image"
	return dst                                                   // author left open
}

// Per request: the batch's head, then the count and this viewer's flags.
func appendArticle(dst []byte, head []byte, a *Article, favorited, following bool) []byte {
	dst = jsonw.Raw(dst, head)
	dst = append(dst, `,"following":`...)
	dst = jsonw.Bool(dst, following)
	dst = append(dst, `},"favorited":`...)
	dst = jsonw.Bool(dst, favorited)
	dst = append(dst, `,"favoritesCount":`...)
	dst = jsonw.Int(dst, a.FavoritesCount)
	return append(dst, '}')
}

op.Resp = append(op.Resp, `{"article":`...)
op.Resp = append(appendArticle(op.Resp, a, fav, fol), '}')
op.Done()
```

`jsonw` escapes quotes, backslashes and control characters, and turns each byte
of invalid UTF-8 into U+FFFD, so its output is always valid JSON.

## Status codes and errors

| Status | When (yours to send) |
|---|---|
| 200 | reads, Login, UpdateUser, UpdateArticle, Favorite/Unfavorite, Follow/Unfollow |
| 201 | Register, CreateArticle, CreateComment |
| 204 | DeleteArticle, DeleteComment (leave `op.Resp` empty) |
| 401 | Login with wrong credentials; GetUser/UpdateUser for a user that no longer exists |
| 403 | update or delete by someone other than the author |
| 404 | unknown article, profile or comment |
| 422 | username or email already taken |

`conduit.Fail(op, status, msg)` sets the status and replaces the body with
`{"errors":{"body":[msg]}}`; then call `op.Done()`. The differ normalizes error
text, so any message works.

## Tokens for Register and Login

`front.Sign(dst, userID)` appends a fresh HS256 token (claims `sub` as a decimal
string, `exp` in 30 days) and allocates nothing: after `{"user":{"token":"`,
`op.Resp = front.Sign(op.Resp, id)`. GetUser and UpdateUser echo `Call.Token`
instead (quirk #14).

## Completing a batch

A worker that finishes a round trip completes all its Ops with one call:
`http.DoneBatch(ops)`. It is `Done` on each Op, in order (orphans are closed,
HandbackDirect writes as usual), but each loop gets its Ops in one hand-off
and is woken at most once. Ops of different loops may be mixed, and the slice
is yours again when it returns. Encode every response of the batch first, then
call it: calling `Done` after each encoded response can wake a sleeping loop
once per Op instead of once per batch.

## Lifetimes

- Between `Defer` and `Done` the Op is yours. The `Call` and every slice in it
  (and anything from `op.Keep` or `op.Alloc`) are valid until `Done`, then reused.
  Copy what must outlive the request.
- `Done` (or `DoneBatch`) may be called from any goroutine, in any order, exactly once per Op.
  After `Done`, don't touch the Op, its `Resp` (append to it; never swap in a
  slice you still use) or its `Call`.
- Every Op must eventually get `Done`, or its connection stalls and the loop
  runs out of Ops. Answer DB errors with `conduit.Fail(op, 500, "internal error")`.
- An Op still out 5 s after `Close` is orphaned: `Done` just closes its connection.

package server

import (
	"context"
	"net/http"
	"net/url"
	"path"
	"strings"
)

var compactAPIReads = envOr("HTTP_API_READS", "0") == "1"

type compactReadPlan struct {
	kind       readKind
	arg, query string
}

// Only canonical routes backed by the existing read queue qualify. Everything
// else retains ServeMux's redirects, method handling and handler behavior.
func (a *app) planCompactRead(uri string) (compactReadPlan, bool) {
	var p compactReadPlan
	if a.reads == nil {
		return p, false
	}
	name, query, _ := strings.Cut(uri, "?")
	if path.Clean(name) != name {
		return p, false
	}
	p.query = query
	switch name {
	case "/api/tags":
		p.kind = readTags
	case "/api/user":
		if !userReadBatching {
			return p, false
		}
		p.kind = readUser
	case "/api/articles":
		p.kind = readGlobal
	case "/api/articles/feed":
		p.kind = readFeed
	default:
		if arg, ok := strings.CutPrefix(name, "/api/articles/"); ok {
			slug, rest, hasSlash := strings.Cut(arg, "/")
			if slug == "" {
				return p, false
			}
			if !hasSlash {
				p.kind, p.arg = readArticle, slug
			} else if rest == "comments" {
				p.kind, p.arg = readComments, slug
			} else {
				return p, false
			}
		} else if arg, ok := strings.CutPrefix(name, "/api/profiles/"); ok && profileReadBatching && arg != "" && !strings.Contains(arg, "/") {
			p.kind, p.arg = readProfile, arg
		} else {
			return p, false
		}
	}
	return p, true
}

func (a *app) serveCompactRead(ctx context.Context, w http.ResponseWriter, p compactReadPlan, authorization string) {
	var viewer int64
	var token string
	if p.kind != readTags {
		var present bool
		viewer, token, present = a.authHeader(authorization)
		if viewer == 0 && (present || p.kind == readFeed || p.kind == readUser) {
			writeError(w, http.StatusUnauthorized, "unauthorized")
			return
		}
	}
	call := &queuedRead{ctx: ctx, kind: p.kind, viewer: viewer, done: make(chan struct{})}
	switch p.kind {
	case readUser:
		call.filter = token
	case readProfile:
		call.filter = p.arg
	case readArticle, readComments:
		call.slug = p.arg
	}
	if p.kind >= readGlobal {
		// URL.Query ignores ParseQuery errors while retaining valid entries.
		// Preserve that behavior and the existing duplicate/filter semantics.
		query, _ := url.ParseQuery(p.query)
		var ok bool
		call.limit, call.offset, ok = limitOffset(query)
		if !ok {
			writeError(w, http.StatusUnprocessableEntity, "limit must be 1-100 and offset >= 0")
			return
		}
		if p.kind != readFeed {
			switch {
			case query.Get("tag") != "":
				call.kind, call.filter = readTag, query.Get("tag")
			case query.Get("author") != "":
				call.kind, call.filter = readAuthor, query.Get("author")
			case query.Get("favorited") != "":
				call.kind, call.filter = readFavorite, query.Get("favorited")
			}
		}
	}
	a.serveReadCallContext(w, ctx, call)
}

func (s *compactSession) respondRead(ctx context.Context, a *app, plan compactReadPlan, authorization string, closeConnection bool) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	w := &s.writer
	w.reset(&http.Request{Method: http.MethodGet, Close: closeConnection})
	a.serveCompactRead(ctx, w, plan, authorization)
	if !w.sent {
		_, _ = w.Write(nil)
	}
}

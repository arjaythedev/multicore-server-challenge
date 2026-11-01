package main

import (
	"multicorelab/http/conduit"
	"multicorelab/http/jsonw"
)

type userRow struct {
	id              int64
	username, email string
	bio, image      nstr
}

type artRow struct {
	id, authorID            int64
	slug, title, desc, body string
	created, updated        int64 // microseconds since the Unix epoch
	tags                    []string
	favCount                int64
	favorited, following    bool
	username                string
	bio, image              nstr
}

type commRow struct {
	id               int64
	body             string
	created, updated int64
	username         string
	bio, image       nstr
	following        bool
}

func nullStr(dst []byte, n nstr) []byte {
	if !n.ok {
		return jsonw.Null(dst)
	}
	return jsonw.String(dst, n.s)
}

// appendProfile appends a Profile object.
func appendProfile(dst []byte, u *userRow, following bool) []byte {
	return appendAuthor(dst, u.username, u.bio, u.image, following)
}

func appendAuthor(dst []byte, username string, bio, image nstr, following bool) []byte {
	dst = append(dst, `{"username":`...)
	dst = jsonw.String(dst, username)
	dst = append(dst, `,"bio":`...)
	dst = nullStr(dst, bio)
	dst = append(dst, `,"image":`...)
	dst = nullStr(dst, image)
	dst = append(dst, `,"following":`...)
	dst = jsonw.Bool(dst, following)
	return append(dst, '}')
}

// artView is what differs per response for the same article row: its tags, favorites count and the viewer's flags.
type artView struct {
	tags                 []string
	favCount             int64
	favorited, following bool
}

// appendArticle appends an Article object, with its body for single views.
func appendArticle(dst []byte, a *artRow, withBody bool) []byte {
	return appendArticleView(dst, a, artView{a.tags, a.favCount, a.favorited, a.following}, withBody)
}

// appendArticleView writes an article as artHead, the favorited flag, artTail and the following flag. The two
// parts hold everything that does not depend on the viewer, so a flush can encode them once per article.
func appendArticleView(dst []byte, a *artRow, v artView, withBody bool) []byte {
	dst = appendArtHead(dst, a, v.tags, withBody)
	dst = jsonw.Bool(dst, v.favorited)
	dst = appendArtTail(dst, a, v.favCount)
	dst = jsonw.Bool(dst, v.following)
	return append(dst, '}', '}')
}

// appendArtHead appends the article up to and including `"favorited":`.
func appendArtHead(dst []byte, a *artRow, tags []string, withBody bool) []byte {
	dst = append(dst, `{"slug":`...)
	dst = jsonw.String(dst, a.slug)
	dst = append(dst, `,"title":`...)
	dst = jsonw.String(dst, a.title)
	dst = append(dst, `,"description":`...)
	dst = jsonw.String(dst, a.desc)
	if withBody {
		dst = append(dst, `,"body":`...)
		dst = jsonw.String(dst, a.body)
	}
	dst = append(dst, `,"tagList":[`...)
	for i, t := range tags {
		if i > 0 {
			dst = append(dst, ',')
		}
		dst = jsonw.String(dst, t)
	}
	dst = append(dst, `],"createdAt":`...)
	dst = jsonw.UnixMicro(dst, a.created)
	dst = append(dst, `,"updatedAt":`...)
	dst = jsonw.UnixMicro(dst, a.updated)
	return append(dst, `,"favorited":`...)
}

// appendArtTail appends from `,"favoritesCount":` through `"following":`; the viewer's flag and `}}` close it.
func appendArtTail(dst []byte, a *artRow, favCount int64) []byte {
	dst = append(dst, `,"favoritesCount":`...)
	dst = jsonw.Int(dst, favCount)
	dst = append(dst, `,"author":{"username":`...)
	dst = jsonw.String(dst, a.username)
	dst = append(dst, `,"bio":`...)
	dst = nullStr(dst, a.bio)
	dst = append(dst, `,"image":`...)
	dst = nullStr(dst, a.image)
	return append(dst, `,"following":`...)
}

// appendComment appends a Comment object.
func appendComment(dst []byte, m *commRow, following bool) []byte {
	dst = append(dst, `{"id":`...)
	dst = jsonw.Int(dst, m.id)
	dst = append(dst, `,"createdAt":`...)
	dst = jsonw.UnixMicro(dst, m.created)
	dst = append(dst, `,"updatedAt":`...)
	dst = jsonw.UnixMicro(dst, m.updated)
	dst = append(dst, `,"body":`...)
	dst = jsonw.String(dst, m.body)
	dst = append(dst, `,"author":`...)
	dst = appendAuthor(dst, m.username, m.bio, m.image, following)
	return append(dst, '}')
}

// respondUser fills op with {"user": ...} from s.user. A new token is signed
// for Register and Login; GetUser and UpdateUser echo the presented one.
func (d *DB) respondUser(s *opState, status int, sign bool) {
	op, u := s.op, &s.user
	op.Status = status
	dst := append(op.Resp, `{"user":{"email":`...)
	dst = jsonw.String(dst, u.email)
	dst = append(dst, `,"token":"`...)
	if sign {
		dst = d.front.Sign(dst, u.id)
		dst = append(dst, '"')
	} else {
		dst = dst[:len(dst)-1]
		dst = jsonw.Bytes(dst, s.c.Token)
	}
	dst = append(dst, `,"username":`...)
	dst = jsonw.String(dst, u.username)
	dst = append(dst, `,"bio":`...)
	dst = nullStr(dst, u.bio)
	dst = append(dst, `,"image":`...)
	dst = nullStr(dst, u.image)
	op.Resp = append(dst, `}}`...)
}

var _ = conduit.Register

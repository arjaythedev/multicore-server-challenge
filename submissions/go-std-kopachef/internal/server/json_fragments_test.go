package server

import (
	"net/http"
	"strconv"
)

// Rejected eager-sharing experiment, kept only for differential tests and
// benchmarks. Production encodes each response directly.
type articleFragments struct{ fields, body, author []byte }

// All three immutable slices belong to one allocation owned by this active
// batch's responses. They are never pooled or retained for a later batch.
func encodeArticleFragments(a *articleJSON) *articleFragments {
	capacity := 256 + len(a.Slug) + len(a.Title) + len(a.Description) + len(a.CreatedAt) + len(a.UpdatedAt) + len(a.Author.Username)
	for _, tag := range a.TagList {
		capacity += len(tag) + 3
	}
	if a.Body != nil {
		capacity += len(*a.Body)
	}
	if a.Author.Bio != nil {
		capacity += len(*a.Author.Bio)
	}
	if a.Author.Image != nil {
		capacity += len(*a.Author.Image)
	}
	dst := make([]byte, 0, capacity)
	dst = appendArticleFields(dst, a)
	fieldsEnd := len(dst)
	dst = appendArticleBody(dst, a)
	bodyEnd := len(dst)
	dst = append(dst, `,"author":`...)
	dst = appendProfileFields(dst, a.Author)
	return &articleFragments{fields: dst[:fieldsEnd], body: dst[fieldsEnd:bodyEnd], author: dst[bodyEnd:]}
}

type sharedArticleValue struct {
	fragments                  *articleFragments
	full, favorited, following bool
}

func (a sharedArticleValue) appendJSON(dst []byte) []byte {
	dst = append(dst, a.fragments.fields...)
	dst = strconv.AppendBool(dst, a.favorited)
	if a.full {
		dst = append(dst, a.fragments.body...)
	}
	dst = append(dst, a.fragments.author...)
	dst = strconv.AppendBool(dst, a.following)
	return append(dst, '}', '}')
}

type sharedArticleResponse struct{ article sharedArticleValue }
type sharedArticleListResponse struct {
	articles []sharedArticleValue
	count    int64
}

func appendSharedAPIJSON(dst []byte, value any) ([]byte, bool) {
	switch v := value.(type) {
	case sharedArticleResponse:
		dst = append(dst, `{"article":`...)
		dst = v.article.appendJSON(dst)
	case sharedArticleListResponse:
		dst = append(dst, `{"articles":[`...)
		for i, a := range v.articles {
			if i != 0 {
				dst = append(dst, ',')
			}
			dst = a.appendJSON(dst)
		}
		dst = append(dst, `],"articlesCount":`...)
		dst = strconv.AppendInt(dst, v.count, 10)

	default:
		return dst, false
	}
	return append(dst, '}'), true
}

func writeSharedJSON(w http.ResponseWriter, status int, value any) {
	buffer := apiJSONBuffers.Get().(*[]byte)
	body, ok := appendSharedAPIJSON((*buffer)[:0], value)
	if !ok {
		panic("unsupported shared benchmark value")
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(body)
	if cap(body) <= 256<<10 {
		*buffer = body[:0]
		apiJSONBuffers.Put(buffer)
	}
}

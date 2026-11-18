package server

import (
	"encoding/json/jsontext"
	"strconv"

	"conduit/internal/jsonquote"
)

// Selected once before serving. The standard mode remains available for A/B
// measurements and the generic encoder handles response types outside this API.
var responseEncoding = envOr("JSON_ENCODING", "direct")
var vectorJSONQuoting = envOr("JSON_QUOTING", "standard") == "vector"

// AppendQuote provides JSON escaping and replaces invalid UTF-8 just as the
// compatibility encoder does. Minimal JSON escaping preserves string values;
// the response is application/json, never interpolated into an HTML document.
func appendJSONString(dst []byte, value string) []byte {
	if vectorJSONQuoting {
		return jsonquote.Append(dst, value)
	}
	dst, _ = jsontext.AppendQuote(dst, value)
	return dst
}

func appendNullableString(dst []byte, value *string) []byte {
	if value == nil {
		return append(dst, "null"...)
	}
	return appendJSONString(dst, *value)
}

func appendStringArray(dst []byte, values []string) []byte {
	if values == nil {
		return append(dst, "null"...)
	}
	dst = append(dst, '[')
	for i, value := range values {
		if i != 0 {
			dst = append(dst, ',')
		}
		dst = appendJSONString(dst, value)
	}
	return append(dst, ']')
}

// These two fragments stop immediately before their viewer-specific booleans.
func appendProfileFields(dst []byte, p profileJSON) []byte {
	dst = append(dst, `{"username":`...)
	dst = appendJSONString(dst, p.Username)
	dst = append(dst, `,"bio":`...)
	dst = appendNullableString(dst, p.Bio)
	dst = append(dst, `,"image":`...)
	dst = appendNullableString(dst, p.Image)
	return append(dst, `,"following":`...)
}

func appendProfile(dst []byte, p profileJSON) []byte {
	dst = appendProfileFields(dst, p)
	dst = strconv.AppendBool(dst, p.Following)
	return append(dst, '}')
}

func appendArticleFields(dst []byte, a *articleJSON) []byte {
	dst = append(dst, `{"slug":`...)
	dst = appendJSONString(dst, a.Slug)
	dst = append(dst, `,"title":`...)
	dst = appendJSONString(dst, a.Title)
	dst = append(dst, `,"description":`...)
	dst = appendJSONString(dst, a.Description)
	dst = append(dst, `,"tagList":`...)
	dst = appendStringArray(dst, a.TagList)
	dst = append(dst, `,"createdAt":`...)
	dst = appendJSONString(dst, string(a.CreatedAt))
	dst = append(dst, `,"updatedAt":`...)
	dst = appendJSONString(dst, string(a.UpdatedAt))
	dst = append(dst, `,"favoritesCount":`...)
	dst = strconv.AppendInt(dst, a.FavoritesCount, 10)
	return append(dst, `,"favorited":`...)
}

func appendArticleBody(dst []byte, a *articleJSON) []byte {
	if a.Body != nil {
		dst = append(dst, `,"body":`...)
		dst = appendJSONString(dst, *a.Body)
	}
	return dst
}

func appendArticle(dst []byte, a *articleJSON) []byte {
	dst = appendArticleFields(dst, a)
	dst = strconv.AppendBool(dst, a.Favorited)
	dst = appendArticleBody(dst, a)
	dst = append(dst, `,"author":`...)
	dst = appendProfile(dst, a.Author)
	return append(dst, '}')
}

func appendArticleView(dst []byte, view articleView) []byte {
	dst = appendArticleFields(dst, view.metadata)
	dst = strconv.AppendBool(dst, view.flags.favorited)
	if view.full {
		dst = appendArticleBody(dst, view.metadata)
	}
	dst = append(dst, `,"author":`...)
	dst = appendProfileFields(dst, view.metadata.Author)
	dst = strconv.AppendBool(dst, view.flags.following)
	return append(dst, '}', '}')
}

func appendComment(dst []byte, c *commentJSON) []byte {
	dst = append(dst, `{"id":`...)
	dst = strconv.AppendInt(dst, c.ID, 10)
	dst = append(dst, `,"createdAt":`...)
	dst = appendJSONString(dst, string(c.CreatedAt))
	dst = append(dst, `,"updatedAt":`...)
	dst = appendJSONString(dst, string(c.UpdatedAt))
	dst = append(dst, `,"body":`...)
	dst = appendJSONString(dst, c.Body)
	dst = append(dst, `,"author":`...)
	dst = appendProfile(dst, c.Author)
	return append(dst, '}')
}

// A narrow encoder for fixed API shapes. Unsupported types keep the standard
// encoder's error handling. No interface callbacks or arbitrary JSON are trusted.
func appendAPIJSON(dst []byte, value any) ([]byte, bool) {
	switch v := value.(type) {
	case articleViewResponse:
		dst = append(dst, `{"article":`...)
		dst = appendArticleView(dst, v.article)
	case articleViewList:
		dst = append(dst, `{"articles":`...)
		if v.articles == nil {
			dst = append(dst, "null"...)
		} else {
			dst = append(dst, '[')
			for i, article := range v.articles {
				if i != 0 {
					dst = append(dst, ',')
				}
				dst = appendArticleView(dst, article)
			}
			dst = append(dst, ']')
		}
		dst = append(dst, `,"articlesCount":`...)
		dst = strconv.AppendInt(dst, v.count, 10)
	case articleListJSON:
		return appendArticleList(dst, v.Articles, v.ArticlesCount), true
	case struct {
		Articles      []articleJSON `json:"articles"`
		ArticlesCount int64         `json:"articlesCount"`
	}:
		return appendArticleList(dst, v.Articles, v.ArticlesCount), true
	case struct {
		Article articleJSON `json:"article"`
	}:
		dst = append(dst, `{"article":`...)
		dst = appendArticle(dst, &v.Article)
	case struct {
		Comments []commentJSON `json:"comments"`
	}:
		dst = append(dst, `{"comments":`...)
		if v.Comments == nil {
			dst = append(dst, "null"...)
		} else {
			dst = append(dst, '[')
			for i := range v.Comments {
				if i != 0 {
					dst = append(dst, ',')
				}
				dst = appendComment(dst, &v.Comments[i])
			}
			dst = append(dst, ']')
		}
	case struct {
		Comment commentJSON `json:"comment"`
	}:
		dst = append(dst, `{"comment":`...)
		dst = appendComment(dst, &v.Comment)
	case struct {
		Profile profileJSON `json:"profile"`
	}:
		dst = append(dst, `{"profile":`...)
		dst = appendProfile(dst, v.Profile)
	case struct {
		User userJSON `json:"user"`
	}:
		dst = append(dst, `{"user":{"email":`...)
		dst = appendJSONString(dst, v.User.Email)
		dst = append(dst, `,"token":`...)
		dst = appendJSONString(dst, v.User.Token)
		dst = append(dst, `,"username":`...)
		dst = appendJSONString(dst, v.User.Username)
		dst = append(dst, `,"bio":`...)
		dst = appendNullableString(dst, v.User.Bio)
		dst = append(dst, `,"image":`...)
		dst = appendNullableString(dst, v.User.Image)
		dst = append(dst, '}')
	case struct {
		Tags []string `json:"tags"`
	}:
		dst = append(dst, `{"tags":`...)
		dst = appendStringArray(dst, v.Tags)
	default:
		return dst, false
	}
	return append(dst, '}'), true
}

func appendArticleList(dst []byte, articles []articleJSON, count int64) []byte {
	dst = append(dst, `{"articles":`...)
	if articles == nil {
		dst = append(dst, "null"...)
	} else {
		dst = append(dst, '[')
		for i := range articles {
			if i != 0 {
				dst = append(dst, ',')
			}
			dst = appendArticle(dst, &articles[i])
		}
		dst = append(dst, ']')
	}
	dst = append(dst, `,"articlesCount":`...)
	dst = strconv.AppendInt(dst, count, 10)
	return append(dst, '}')
}

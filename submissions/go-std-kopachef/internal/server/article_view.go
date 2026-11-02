package server

import "encoding/json"

// Metadata belongs to one active read batch and stays immutable until its last
// response is encoded. A view owns only the per-request flags and body choice.
type articleView struct {
	metadata *articleJSON
	flags    articleFlags
	full     bool
}

type articleViewResponse struct{ article articleView }
type articleViewList struct {
	articles []articleView
	count    int64
}

func (v articleView) materialize() articleJSON {
	x := *v.metadata
	x.Favorited, x.Author.Following = v.flags.favorited, v.flags.following
	if !v.full {
		x.Body = nil
	}
	return x
}

// Compatibility encoding deliberately uses encoding/json over the original
// response shapes. The direct encoder reads views without materializing copies.
func (v articleViewResponse) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		Article articleJSON `json:"article"`
	}{v.article.materialize()})
}

func (v articleViewList) MarshalJSON() ([]byte, error) {
	var articles []articleJSON
	if v.articles != nil {
		articles = make([]articleJSON, len(v.articles))
		for i, item := range v.articles {
			articles[i] = item.materialize()
		}
	}
	return json.Marshal(articleListJSON{Articles: articles, ArticlesCount: v.count})
}

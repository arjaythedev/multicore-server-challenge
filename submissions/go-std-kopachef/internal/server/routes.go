package server

import "net/http"

type apiRoutes struct {
	*http.ServeMux
	app *app
}

func (a *app) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/users", a.register)
	mux.HandleFunc("POST /api/users/login", a.login)
	mux.HandleFunc("GET /api/user", a.required(a.currentUser))
	mux.HandleFunc("PUT /api/user", a.required(a.updateUser))

	mux.HandleFunc("GET /api/profiles/{username}", a.optional(a.getProfile))
	mux.HandleFunc("POST /api/profiles/{username}/follow", a.required(a.follow(true)))
	mux.HandleFunc("DELETE /api/profiles/{username}/follow", a.required(a.follow(false)))

	mux.HandleFunc("GET /api/articles", a.optional(a.listArticles))
	mux.HandleFunc("GET /api/articles/feed", a.required(a.feed))
	mux.HandleFunc("POST /api/articles", a.required(a.createArticle))
	mux.HandleFunc("GET /api/articles/{slug}", a.optional(a.getArticle))
	mux.HandleFunc("PUT /api/articles/{slug}", a.required(a.updateArticle))
	mux.HandleFunc("DELETE /api/articles/{slug}", a.required(a.deleteArticle))
	mux.HandleFunc("POST /api/articles/{slug}/favorite", a.required(a.favorite(true)))
	mux.HandleFunc("DELETE /api/articles/{slug}/favorite", a.required(a.favorite(false)))
	mux.HandleFunc("GET /api/articles/{slug}/comments", a.optional(a.listComments))
	mux.HandleFunc("POST /api/articles/{slug}/comments", a.required(a.createComment))
	mux.HandleFunc("DELETE /api/articles/{slug}/comments/{id}", a.required(a.deleteComment))

	mux.HandleFunc("GET /api/tags", a.tags)

	// Anything else (unknown path, or a known path with another method) is a JSON 404.
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeError(w, http.StatusNotFound, "not found")
	})
	return &apiRoutes{ServeMux: mux, app: a}
}

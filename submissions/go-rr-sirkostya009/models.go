package main

import "time"

//go:generate go tool ggen -ignoreunknown $GOFILE

//ggen:generate
type jwtHead struct {
	Alg string `json:"alg"`
}

//ggen:generate
type jwtClaims struct {
	Sub string `json:"sub"`
	Exp *int64 `json:"exp"`
}

//ggen:generate
type registerBody struct {
	User registerFields `json:"user" pipe:"required"`
}

type registerFields struct {
	Username string `json:"username" pipe:"required notempty"`
	Email    string `json:"email"    pipe:"required notempty"`
	Password string `json:"password" pipe:"required notempty maxlen=72"`
}

//ggen:generate
type loginBody struct {
	User loginFields `json:"user" pipe:"required"`
}

type loginFields struct {
	Email    string `json:"email"    pipe:"required notempty"`
	Password string `json:"password" pipe:"required notempty"`
}

//ggen:generate
type updateUserBody struct {
	User updateUserFields `json:"user" pipe:"required"`
}

type updateUserFields struct {
	Email    *string `json:"email"    pipe:"notempty"`
	Username *string `json:"username" pipe:"notempty"`
	Password *string `json:"password" pipe:"notempty maxlen=72"`
	Bio      *string `json:"bio"`
	Image    *string `json:"image"`
}

//ggen:generate
type createArticleBody struct {
	Article createArticleFields `json:"article" pipe:"required"`
}

type createArticleFields struct {
	Title       string   `json:"title"       pipe:"required notempty"`
	Description string   `json:"description" pipe:"required notempty"`
	Body        string   `json:"body"        pipe:"required notempty"`
	TagList     []string `json:"tagList"     pipe:"inner:notempty"`
}

//ggen:generate
type updateArticleBody struct {
	Article updateArticleFields `json:"article" pipe:"required"`
}

type updateArticleFields struct {
	Title       *string `json:"title"       pipe:"notempty"`
	Description *string `json:"description" pipe:"notempty"`
	Body        *string `json:"body"        pipe:"notempty"`
}

//ggen:generate
type createCommentBody struct {
	Comment createCommentFields `json:"comment" pipe:"required"`
}

type createCommentFields struct {
	Body string `json:"body" pipe:"required notempty"`
}

type User struct {
	Email    string  `json:"email"`
	Token    string  `json:"token"`
	Username string  `json:"username"`
	Bio      *string `json:"bio"`
	Image    *string `json:"image"`
}

//ggen:generate
type userEnvelope struct {
	User User `json:"user"`
}

type Profile struct {
	Username  string  `json:"username"`
	Bio       *string `json:"bio"`
	Image     *string `json:"image"`
	Following bool    `json:"following"`
}

//ggen:generate
type profileEnvelope struct {
	Profile Profile `json:"profile"`
}

type ArticleItem struct {
	Slug           string    `json:"slug"`
	Title          string    `json:"title"`
	Description    string    `json:"description"`
	TagList        []string  `json:"tagList"`
	CreatedAt      time.Time `json:"createdAt,format:'2006-01-02T15:04:05.000Z07:00'"`
	UpdatedAt      time.Time `json:"updatedAt,format:'2006-01-02T15:04:05.000Z07:00'"`
	Favorited      bool      `json:"favorited"`
	FavoritesCount int64     `json:"favoritesCount"`
	Author         Profile   `json:"author"`
}

type Article struct {
	ArticleItem
	Body string `json:"body"`
}

//ggen:generate
type articleEnvelope struct {
	Article Article `json:"article"`
}

//ggen:generate
type articleList struct {
	Articles      []ArticleItem `json:"articles"`
	ArticlesCount int64         `json:"articlesCount"`
}

type Comment struct {
	ID        int64     `json:"id"`
	CreatedAt time.Time `json:"createdAt,format:'2006-01-02T15:04:05.000Z07:00'"`
	UpdatedAt time.Time `json:"updatedAt,format:'2006-01-02T15:04:05.000Z07:00'"`
	Body      string    `json:"body"`
	Author    Profile   `json:"author"`
}

//ggen:generate
type commentEnvelope struct {
	Comment Comment `json:"comment"`
}

//ggen:generate
type commentList struct {
	Comments []Comment `json:"comments"`
}

//ggen:generate
type tagList struct {
	Tags []string `json:"tags"`
}

//ggen:generate
type errorBody struct {
	Errors errorList `json:"errors"`
}

type errorList struct {
	Body [1]string `json:"body"`
}

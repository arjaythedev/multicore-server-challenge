namespace Engine

open System

/// The viewer of a request: the token's user id, or 0 when anonymous (SPEC: no user has id 0).
type ViewerId = int64

type Profile =
    { Username: string
      Bio: string option
      Image: string option
      Following: bool }

type User =
    { Id: int64
      Username: string
      Email: string
      Bio: string option
      Image: string option }

type Article =
    { Slug: string
      Title: string
      Description: string
      /// None on list endpoints (they omit the body, as the current RealWorld spec does).
      Body: string option
      TagList: string[]
      CreatedAt: DateTime
      UpdatedAt: DateTime
      Favorited: bool
      FavoritesCount: int64
      Author: Profile }

type ArticlePage = { Articles: Article list; Count: int64 }

type Comment =
    { Id: int64
      CreatedAt: DateTime
      UpdatedAt: DateTime
      Body: string
      Author: Profile }

/// GET /api/articles applies at most one filter: the first of tag, author, favorited.
type ArticleFilter =
    | Everything
    | ByTag of string
    | ByAuthor of string
    | FavoritedBy of string

type Paging = { Limit: int64; Offset: int64 }

/// What a guarded write found: the row and its owner decide the status, never the handler's guess.
type Guarded<'a> =
    | Done of 'a
    | NotFound
    | NotYours

/// A write that may hit a UNIQUE constraint (username, email).
type Unique<'a> =
    | Stored of 'a
    | Taken
    | Missing

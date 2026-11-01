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

/// A user as the author of an article or a comment, before anyone's `following` is known.
type Author =
    { Id: int64
      Username: string
      Bio: string option
      Image: string option }

/// An article as anyone sees it. A read batch builds each card once, and every request in it
/// that shows the article (a list, the article page) shares the same card object.
type Card =
    { Id: int64
      Slug: string
      Title: string
      Description: string
      /// None on list endpoints (they omit the body, as the current RealWorld spec does).
      Body: string option
      TagList: string[]
      CreatedAt: DateTime
      UpdatedAt: DateTime
      FavoritesCount: int64
      Author: Author }

/// An article as one viewer sees it: the shared card and the viewer's two flags.
type Article =
    { Card: Card
      Favorited: bool
      /// Does the viewer follow the card's author?
      Following: bool }

type ArticlePage = { Articles: Article list; Count: int64 }

/// A comment as anyone sees it (shared like a Card).
type CommentCard =
    { Id: int64
      CreatedAt: DateTime
      UpdatedAt: DateTime
      Body: string
      Author: Author }

/// A comment as one viewer sees it.
type Comment =
    { Card: CommentCard
      /// Does the viewer follow the comment's author?
      Following: bool }

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

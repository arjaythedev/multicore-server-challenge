module Engine.Articles

open System
open System.Threading.Tasks
open Npgsql
open Npgsql.FSharp

// ---------------------------------------------------------------- SQL ----------
// The writes and the read after a write. The hot reads are Reads' batches. Every write that
// needs a lookup first does the lookup and the write in one statement (a data-modifying CTE).

/// SPEC's SLUGIFY(x), in SQL, so the slug is byte-identical to the reference by construction.
let private slugify (x: string) =
    $"trim(both '-' from lower(regexp_replace({x}, '[^A-Za-z0-9]+', '-', 'g')))"

let private countFavorites = "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id)"

let private isFavorited =
    "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = @viewer)"

/// ARTICLE_FULL_SELECT's column list (and the author's id), with the two favorite columns
/// replaceable (favorite/unfavorite compute them from the write they just made).
let private columns (favoritesCount: string) (favorited: string) =
    $"a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at
              WHERE at.article_id = a.id ORDER BY 1) AS tag_list,
       {favoritesCount} AS favorites_count,
       {favorited} AS favorited,
       a.author_id, u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = @viewer AND fo.followee_id = a.author_id) AS following"

let private fromArticles = "FROM articles a JOIN users u ON u.id = a.author_id"

let private fullSelect = $"SELECT {columns countFavorites isFavorited} {fromArticles}"

// ------------------------------------------------------------------ reads -------
// The hot reads are batched (Reads); these are their typed doors.

let list (reads: Reads.Gather) (viewer: ViewerId) (filter: ArticleFilter) (paging: Paging) : Task<ArticlePage> =
    reads.Page(viewer, filter, paging)

let feed (reads: Reads.Gather) (viewer: ViewerId) (paging: Paging) : Task<ArticlePage> = reads.Feed(viewer, paging)

let bySlug (reads: Reads.Gather) (viewer: ViewerId) (slug: string) : Task<Article option> = reads.Article(viewer, slug)

// After a write: one full article, one request at a time.

let private article (read: RowReader) : Article =
    { Card =
        { Id = read.int64 "id"
          Slug = read.text "slug"
          Title = read.text "title"
          Description = read.text "description"
          Body = Some(read.text "body")
          TagList = read.stringArray "tag_list"
          CreatedAt = read.dateTime "created_at"
          UpdatedAt = read.dateTime "updated_at"
          FavoritesCount = read.int64 "favorites_count"
          Author =
            { Id = read.int64 "author_id"
              Username = read.text "username"
              Bio = read.textOrNone "bio"
              Image = read.textOrNone "image" } }
      Favorited = read.bool "favorited"
      Following = read.bool "following" }

let private single (props: Sql.SqlProps) (sql: string) (parameters: (string * SqlValue) list) =
    task {
        let! rows = props |> Sql.query sql |> Sql.parameters parameters |> Sql.executeAsync article
        return List.tryHead rows
    }

let private byId (props: Sql.SqlProps) (viewer: ViewerId) (id: int64) =
    single props $"{fullSelect} WHERE a.id = @id" [ "@viewer", Sql.int64 viewer; "@id", Sql.int64 id ]

// ----------------------------------------------------------------- writes -------

let private slugOfTitle = slugify "@title"

// SPEC's reference transaction, as two statements of one group-commit write (Commit: only the
// last statement may return rows). The tags go in first, and the article and its tag links
// follow in one statement: a later statement of the same transaction sees the new tags, and the
// links see the article (one statement, FKs checked at its end). Same rows as SPEC's three
// statements, in the same transaction.
let private insertTagsSql = "INSERT INTO tags (name) SELECT DISTINCT unnest(@tags::text[]) ON CONFLICT (name) DO NOTHING"

let private insertArticleSql =
    $"WITH n AS (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id),
          a AS (INSERT INTO articles (id, slug, author_id, title, description, body)
                SELECT n.id, {slugOfTitle} || '-' || n.id, @viewer, @title, @description, @body FROM n
                RETURNING id),
          l AS (INSERT INTO article_tags (article_id, tag_id)
                SELECT a.id, t.id FROM a, tags t WHERE t.name = ANY(@tags::text[]))
     SELECT id FROM a"

/// SPEC: the article, its tags and its tag links in ONE transaction; the response is read
/// after the commit.
let create
    (ds: NpgsqlDataSource)
    (writes: Commit.Writer)
    (viewer: ViewerId)
    (title: string)
    (description: string)
    (body: string)
    (tags: string[])
    : Task<Article> =
    task {
        let article =
            insertArticleSql,
            [ "@viewer", Sql.int64 viewer
              "@title", Sql.text title
              "@description", Sql.text description
              "@body", Sql.text body
              "@tags", Sql.stringArray tags ]
        let statements =
            if tags.Length > 0 then [ (insertTagsSql, [ "@tags", Sql.stringArray tags ]); article ] else [ article ]
        let! ids = writes.Run(statements, fun read -> read.int64 "id")
        let! created = byId (Sql.fromDataSource ds) viewer (List.head ids)
        return Option.get created
    }

type Edit =
    { Title: string option
      Description: string option
      Body: string option }

// Lookup, ownership check and update in one statement; the outer SELECT reports what it found
// so the caller can tell 404 from 403.
let private updateSql =
    $"WITH t AS (SELECT id, author_id FROM articles WHERE slug = @slug),
          w AS (UPDATE articles a
                   SET title = COALESCE(@title, a.title), description = COALESCE(@description, a.description),
                       body = COALESCE(@body, a.body),
                       slug = CASE WHEN @title::text IS NULL THEN a.slug ELSE {slugOfTitle} || '-' || a.id END,
                       updated_at = now()
                  FROM t WHERE a.id = t.id AND t.author_id = @viewer)
     SELECT id, author_id FROM t"

let private deleteSql =
    "WITH t AS (SELECT id, author_id FROM articles WHERE slug = @slug),
          w AS (DELETE FROM articles a USING t WHERE a.id = t.id AND t.author_id = @viewer)
     SELECT id, author_id FROM t"

let private guarded (writes: Commit.Writer) (sql: string) (viewer: ViewerId) (parameters: (string * SqlValue) list) =
    task {
        let! rows =
            writes.Run([ sql, ("@viewer", Sql.int64 viewer) :: parameters ], fun read -> read.int64 "id", read.int64 "author_id")
        return
            match rows with
            | [] -> NotFound
            | (id, author) :: _ when author = viewer -> Done id
            | _ -> NotYours
    }

let update (ds: NpgsqlDataSource) (writes: Commit.Writer) (viewer: ViewerId) (slug: string) (edit: Edit) : Task<Guarded<Article>> =
    task {
        let! found =
            guarded
                writes
                updateSql
                viewer
                [ "@slug", Sql.text slug
                  "@title", Sql.textOrNone edit.Title
                  "@description", Sql.textOrNone edit.Description
                  "@body", Sql.textOrNone edit.Body ]
        match found with
        | Done id ->
            let! updated = byId (Sql.fromDataSource ds) viewer id
            return
                match updated with
                | Some a -> Done a
                | None -> NotFound
        | NotFound -> return NotFound
        | NotYours -> return NotYours
    }

let delete (writes: Commit.Writer) (viewer: ViewerId) (slug: string) : Task<Guarded<unit>> =
    task {
        let! found = guarded writes deleteSql viewer [ "@slug", Sql.text slug ]
        return
            match found with
            | Done _ -> Done()
            | NotFound -> NotFound
            | NotYours -> NotYours
    }

// Favorite / unfavorite: lookup, write and the full article in one statement. The outer
// query's snapshot predates the CTE's write, so the count adds (or subtracts) the rows the
// write actually changed: exactly what a fresh count after the write would return.
let private favoriteSql (on: bool) =
    let change, count, favorited =
        if on then
            "INSERT INTO favorites (user_id, article_id) SELECT @viewer, id FROM t ON CONFLICT DO NOTHING RETURNING 1",
            $"({countFavorites} + (SELECT count(*) FROM w))",
            "true"
        else
            "DELETE FROM favorites f USING t WHERE f.user_id = @viewer AND f.article_id = t.id RETURNING 1",
            $"({countFavorites} - (SELECT count(*) FROM w))",
            "false"
    $"WITH t AS (SELECT id FROM articles WHERE slug = @slug), w AS ({change})
      SELECT {columns count favorited} {fromArticles} WHERE a.id = (SELECT id FROM t)"

let private favoriteOn = favoriteSql true
let private favoriteOff = favoriteSql false

let setFavorite (writes: Commit.Writer) (viewer: ViewerId) (slug: string) (on: bool) : Task<Article option> =
    task {
        let! rows =
            writes.Run(
                [ (if on then favoriteOn else favoriteOff), [ "@viewer", Sql.int64 viewer; "@slug", Sql.text slug ] ],
                article
            )
        return List.tryHead rows
    }

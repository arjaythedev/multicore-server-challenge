module Engine.Articles

open System
open System.Threading.Tasks
open Npgsql
open Npgsql.FSharp

// ---------------------------------------------------------------- SQL ----------
// SPEC.md's reference SQL, reshaped so every read is ONE round trip: a list is its page and
// its capped count in a single statement, and every write that needs a lookup first does the
// lookup and the write in one statement (a data-modifying CTE).

/// SPEC's SLUGIFY(x), in SQL, so the slug is byte-identical to the reference by construction.
let private slugify (x: string) =
    $"trim(both '-' from lower(regexp_replace({x}, '[^A-Za-z0-9]+', '-', 'g')))"

let private countFavorites = "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id)"

let private isFavorited =
    "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = @viewer)"

/// ARTICLE_LIST_SELECT / ARTICLE_FULL_SELECT's column list, with the two favorite columns
/// replaceable (favorite/unfavorite compute them from the write they just made).
let private columns (withBody: bool) (favoritesCount: string) (favorited: string) =
    let body = if withBody then " a.body," else ""
    $"a.id, a.slug, a.title, a.description,{body} a.created_at, a.updated_at,
       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
              WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
       {favoritesCount} AS favorites_count,
       {favorited} AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = @viewer AND fo.followee_id = a.author_id) AS following"

let private fromArticles = "FROM articles a JOIN users u ON u.id = a.author_id"

let private listSelect = $"SELECT {columns false countFavorites isFavorited} {fromArticles}"
let private fullSelect = $"SELECT {columns true countFavorites isFavorited} {fromArticles}"

/// A page and its capped count in one statement. The count is one row; the page joins it
/// laterally, so an empty page (unknown tag, offset past the end) still returns the count.
let private paged (count: string) (page: string) =
    $"SELECT cnt.n AS total, p.* FROM (SELECT count(*) AS n FROM ({count}) s) cnt
       LEFT JOIN LATERAL ({page}) p ON true
      ORDER BY p.id DESC"

// The global count walks the primary key from the OLDEST end: those pages are all-visible,
// so it is an index-only scan that never touches the heap. count(min(total, 1000)) either way.
let private everythingSql =
    paged
        "SELECT 1 FROM articles a ORDER BY a.id LIMIT 1000"
        $"{listSelect} ORDER BY a.id DESC LIMIT @limit OFFSET @offset"

let private tagSql =
    paged
        "SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = @filter) LIMIT 1000"
        $"{listSelect} WHERE a.id IN (SELECT at.article_id FROM article_tags at
                                       WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = @filter)
                                       ORDER BY at.article_id DESC LIMIT @limit OFFSET @offset)
          ORDER BY a.id DESC"

let private authorSql =
    paged
        "SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = @filter) LIMIT 1000"
        $"{listSelect} WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = @filter)
          ORDER BY a.id DESC LIMIT @limit OFFSET @offset"

let private favoritedSql =
    paged
        "SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = @filter) LIMIT 1000"
        $"{listSelect} WHERE a.id IN (SELECT f.article_id FROM favorites f
                                       WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = @filter)
                                       ORDER BY f.article_id DESC LIMIT @limit OFFSET @offset)
          ORDER BY a.id DESC"

let private feedSql =
    paged
        "SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = @viewer) LIMIT 1000"
        $"{listSelect} WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL
                                         (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id
                                           ORDER BY a2.id DESC LIMIT @depth) x
                                       WHERE fo.follower_id = @viewer ORDER BY x.id DESC LIMIT @limit OFFSET @offset)
          ORDER BY a.id DESC"

// ------------------------------------------------------------- readers ---------

let private article (withBody: bool) (read: RowReader) : Article =
    { Slug = read.text "slug"
      Title = read.text "title"
      Description = read.text "description"
      Body = if withBody then Some(read.text "body") else None
      TagList = read.stringArray "tag_list"
      CreatedAt = read.dateTime "created_at"
      UpdatedAt = read.dateTime "updated_at"
      Favorited = read.bool "favorited"
      FavoritesCount = read.int64 "favorites_count"
      Author =
        { Username = read.text "username"
          Bio = read.textOrNone "bio"
          Image = read.textOrNone "image"
          Following = read.bool "following" } }

let private pageOf (rows: (int64 * Article option) list) : ArticlePage =
    match rows with
    | [] -> { Articles = []; Count = 0L }
    | (total, _) :: _ -> { Articles = rows |> List.choose snd; Count = total }

let private runPage (ds: NpgsqlDataSource) (sql: string) (parameters: (string * SqlValue) list) =
    task {
        let! rows =
            Sql.fromDataSource ds
            |> Sql.query sql
            |> Sql.parameters parameters
            |> Sql.executeAsync (fun read ->
                let total = read.int64 "total"
                match read.int64OrNone "id" with
                | Some _ -> total, Some(article false read)
                | None -> total, None)
        return pageOf rows
    }

// ------------------------------------------------------------------ reads -------

let list (ds: NpgsqlDataSource) (viewer: ViewerId) (filter: ArticleFilter) (paging: Paging) : Task<ArticlePage> =
    let common = [ "@viewer", Sql.int64 viewer; "@limit", Sql.int64 paging.Limit; "@offset", Sql.int64 paging.Offset ]
    match filter with
    | Everything -> runPage ds everythingSql common
    | ByTag tag -> runPage ds tagSql (("@filter", Sql.text tag) :: common)
    | ByAuthor name -> runPage ds authorSql (("@filter", Sql.text name) :: common)
    | FavoritedBy name -> runPage ds favoritedSql (("@filter", Sql.text name) :: common)

/// Each followee contributes at most limit + offset of its newest articles (saturating, so a
/// huge offset cannot overflow the LIMIT).
let feed (ds: NpgsqlDataSource) (viewer: ViewerId) (paging: Paging) : Task<ArticlePage> =
    let depth =
        if paging.Offset > Int64.MaxValue - paging.Limit then Int64.MaxValue else paging.Limit + paging.Offset
    runPage
        ds
        feedSql
        [ "@viewer", Sql.int64 viewer
          "@limit", Sql.int64 paging.Limit
          "@offset", Sql.int64 paging.Offset
          "@depth", Sql.int64 depth ]

let private single (props: Sql.SqlProps) (sql: string) (parameters: (string * SqlValue) list) =
    task {
        let! rows = props |> Sql.query sql |> Sql.parameters parameters |> Sql.executeAsync (article true)
        return List.tryHead rows
    }

let bySlug (ds: NpgsqlDataSource) (viewer: ViewerId) (slug: string) : Task<Article option> =
    single (Sql.fromDataSource ds) $"{fullSelect} WHERE a.slug = @slug" [ "@viewer", Sql.int64 viewer; "@slug", Sql.text slug ]

let private byId (props: Sql.SqlProps) (viewer: ViewerId) (id: int64) =
    single props $"{fullSelect} WHERE a.id = @id" [ "@viewer", Sql.int64 viewer; "@id", Sql.int64 id ]

// ----------------------------------------------------------------- writes -------

let private slugOfTitle = slugify "@title"

let private insertArticleSql =
    $"INSERT INTO articles (id, slug, author_id, title, description, body)
      SELECT n.id, {slugOfTitle} || '-' || n.id, @viewer, @title, @description, @body
        FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
      RETURNING id"

/// SPEC: the article, its tags and its tag links in ONE transaction; the response is read
/// after the commit.
let create
    (ds: NpgsqlDataSource)
    (viewer: ViewerId)
    (title: string)
    (description: string)
    (body: string)
    (tags: string[])
    : Task<Article> =
    task {
        let! id =
            task {
                use! conn = ds.OpenConnectionAsync()
                use! tx = conn.BeginTransactionAsync()
                let db = Sql.existingConnection conn
                let! ids =
                    db
                    |> Sql.query insertArticleSql
                    |> Sql.parameters
                        [ "@viewer", Sql.int64 viewer
                          "@title", Sql.text title
                          "@description", Sql.text description
                          "@body", Sql.text body ]
                    |> Sql.executeAsync (fun read -> read.int64 "id")
                let id = List.head ids
                if tags.Length > 0 then
                    let! _ =
                        db
                        |> Sql.query "INSERT INTO tags (name) SELECT DISTINCT unnest(@tags::text[]) ON CONFLICT (name) DO NOTHING"
                        |> Sql.parameters [ "@tags", Sql.stringArray tags ]
                        |> Sql.executeNonQueryAsync
                    let! _ =
                        db
                        |> Sql.query
                            "INSERT INTO article_tags (article_id, tag_id) SELECT @id, t.id FROM tags t WHERE t.name = ANY(@tags::text[])"
                        |> Sql.parameters [ "@id", Sql.int64 id; "@tags", Sql.stringArray tags ]
                        |> Sql.executeNonQueryAsync
                    ()
                do! tx.CommitAsync()
                return id
            }
        let! created = byId (Sql.fromDataSource ds) viewer id
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

let private guarded (ds: NpgsqlDataSource) (sql: string) (viewer: ViewerId) (parameters: (string * SqlValue) list) =
    task {
        let! rows =
            Sql.fromDataSource ds
            |> Sql.query sql
            |> Sql.parameters (("@viewer", Sql.int64 viewer) :: parameters)
            |> Sql.executeAsync (fun read -> read.int64 "id", read.int64 "author_id")
        return
            match rows with
            | [] -> NotFound
            | (id, author) :: _ when author = viewer -> Done id
            | _ -> NotYours
    }

let update (ds: NpgsqlDataSource) (viewer: ViewerId) (slug: string) (edit: Edit) : Task<Guarded<Article>> =
    task {
        let! found =
            guarded
                ds
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

let delete (ds: NpgsqlDataSource) (viewer: ViewerId) (slug: string) : Task<Guarded<unit>> =
    task {
        let! found = guarded ds deleteSql viewer [ "@slug", Sql.text slug ]
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
      SELECT {columns true count favorited} {fromArticles} WHERE a.id = (SELECT id FROM t)"

let private favoriteOn = favoriteSql true
let private favoriteOff = favoriteSql false

let setFavorite (ds: NpgsqlDataSource) (viewer: ViewerId) (slug: string) (on: bool) : Task<Article option> =
    single
        (Sql.fromDataSource ds)
        (if on then favoriteOn else favoriteOff)
        [ "@viewer", Sql.int64 viewer; "@slug", Sql.text slug ]

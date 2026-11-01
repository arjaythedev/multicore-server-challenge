module Engine.Articles

open System
open System.Threading.Tasks
open Npgsql
open Npgsql.FSharp

// ---------------------------------------------------------------- SQL ----------
// SPEC.md's reference SQL, reshaped: a batch of reads of one kind is ONE statement (a list's
// page and its capped count included), and every write that needs a lookup first does the
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

let private fullSelect = $"SELECT {columns true countFavorites isFavorited} {fromArticles}"

// ------------------------------------------------------- batched reads -------
// Every hot read is a Reads kind: one statement answers the whole batch (see Reads). The
// viewer-independent "card" of an article is built once per distinct article in a MATERIALIZED
// CTE `c`; only the viewer's flags are evaluated per request `q`. Lookups by a batch's keys are
// CROSS JOIN LATERAL (..., LIMIT 1), one index probe per distinct key: the planner cannot see
// how few rows a CTE holds, and with a plain join or IN it hash-joins whole tables to fetch ten
// rows. The LIMIT 1 (the keys are unique, so it changes nothing) stops it from flattening the
// LATERAL subquery back into that same join.

/// The card: everything about an article that does not depend on who is looking.
let private cardColumns (withBody: bool) =
    let body = if withBody then " a.body," else ""
    $"a.id, a.author_id, a.slug, a.title, a.description,{body} a.created_at, a.updated_at,
       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
              WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
       {countFavorites} AS favorites_count,
       u.username, u.bio, u.image"

/// The viewer's flags on card c (false for an empty page's NULL card, which is never read).
let private viewerFlags (viewer: string) =
    $"EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = c.id AND f.user_id = {viewer}) AS favorited,
     EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = {viewer} AND fo.followee_id = c.author_id) AS following"

let private flagsInBatch = viewerFlags "q.viewer"
let private flagsAlone = viewerFlags "@viewer"

/// How a list's count and page fragments name the request: the distinct request `d` inside a
/// batched statement, the parameters in a single one.
type private Refs =
    { Key: string
      Lim: string
      Off: string
      Depth: string }

let private inBatch = { Key = "d.key"; Lim = "d.lim"; Off = "d.off"; Depth = "d.depth" }
let private alone = { Key = "@key"; Lim = "@lim"; Off = "@off"; Depth = "@depth" }

/// A list's filter: its capped count, and its page of ids (newest first).
[<NoEquality; NoComparison>]
type private ListFilter =
    { Count: Refs -> string
      Page: Refs -> string }

/// A batch of list requests (viewer, key, limit, offset, depth). Each distinct key's capped count
/// (`n`) and each distinct page's ids (`p`) are read once, then each page article's card once
/// (`c`). An empty page (unknown key, offset past the end) is one row with the count and a NULL
/// card.
let private batchedListSql (f: ListFilter) =
    $"WITH q AS (SELECT * FROM unnest(@viewers::int8[], @keys::text[], @limits::int8[], @offsets::int8[], @depths::int8[])
                   WITH ORDINALITY AS r(viewer, key, lim, off, depth, k)),
          n AS MATERIALIZED (SELECT d.key, (SELECT count(*) FROM ({f.Count inBatch}) s) AS total
                               FROM (SELECT DISTINCT key FROM q) d),
          p AS MATERIALIZED (SELECT d.key, d.lim, d.off, x.id
                               FROM (SELECT DISTINCT key, lim, off, depth FROM q) d CROSS JOIN LATERAL ({f.Page inBatch}) x),
          c AS MATERIALIZED (SELECT x.* FROM (SELECT DISTINCT id FROM p) d CROSS JOIN LATERAL
                               (SELECT {cardColumns false} {fromArticles} WHERE a.id = d.id LIMIT 1) x)
     SELECT q.k, n.total, c.*, {flagsInBatch}
       FROM q JOIN n ON n.key = q.key
       LEFT JOIN p ON p.key = q.key AND p.lim = q.lim AND p.off = q.off
       LEFT JOIN c ON c.id = p.id
      ORDER BY q.k, c.id DESC"

/// One list request: the count, then the page's ids, then their cards, in one statement.
let private singleListSql (f: ListFilter) =
    $"SELECT n.total, c.*, {flagsAlone}
       FROM (SELECT count(*) AS total FROM ({f.Count alone}) s) n
       LEFT JOIN LATERAL (SELECT x.* FROM ({f.Page alone}) p CROSS JOIN LATERAL
                            (SELECT {cardColumns false} {fromArticles} WHERE a.id = p.id LIMIT 1) x) c ON true
      ORDER BY c.id DESC"

// The global count walks the primary key from the OLDEST end: those pages are all-visible,
// so it is an index-only scan that never touches the heap. count(min(total, 1000)) either way.
let private everything =
    { Count = fun _ -> "SELECT 1 FROM articles a ORDER BY a.id LIMIT 1000"
      Page = fun r -> $"SELECT a.id FROM articles a ORDER BY a.id DESC LIMIT {r.Lim} OFFSET {r.Off}" }

let private byTag =
    { Count =
        fun r ->
            $"SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = {r.Key}) LIMIT 1000"
      Page =
        fun r ->
            $"SELECT at.article_id AS id FROM article_tags at
               WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = {r.Key})
               ORDER BY at.article_id DESC LIMIT {r.Lim} OFFSET {r.Off}" }

let private byAuthor =
    { Count =
        fun r ->
            $"SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = {r.Key}) LIMIT 1000"
      Page =
        fun r ->
            $"SELECT a.id FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = {r.Key})
               ORDER BY a.id DESC LIMIT {r.Lim} OFFSET {r.Off}" }

let private favoritedBy =
    { Count =
        fun r ->
            $"SELECT 1 FROM favorites f WHERE f.user_id = (SELECT u.id FROM users u WHERE u.username = {r.Key}) LIMIT 1000"
      Page =
        fun r ->
            $"SELECT f.article_id AS id FROM favorites f WHERE f.user_id = (SELECT u.id FROM users u WHERE u.username = {r.Key})
               ORDER BY f.article_id DESC LIMIT {r.Lim} OFFSET {r.Off}" }

// The feed's key is the viewer. Each followee contributes at most depth = limit + offset of its
// newest articles.
let private feedFilter =
    { Count =
        fun r ->
            $"SELECT 1 FROM articles a
               WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = ({r.Key})::int8) LIMIT 1000"
      Page =
        fun r ->
            $"SELECT x.id FROM follows fo CROSS JOIN LATERAL
                     (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT {r.Depth}) x
               WHERE fo.follower_id = ({r.Key})::int8 ORDER BY x.id DESC LIMIT {r.Lim} OFFSET {r.Off}" }

let private batchedBySlugSql =
    $"WITH q AS (SELECT * FROM unnest(@slugs::text[], @viewers::int8[]) WITH ORDINALITY AS r(slug, viewer, k)),
          c AS MATERIALIZED (SELECT x.* FROM (SELECT DISTINCT slug FROM q) d CROSS JOIN LATERAL
                               (SELECT {cardColumns true} {fromArticles} WHERE a.slug = d.slug LIMIT 1) x)
     SELECT q.k, c.*, {flagsInBatch} FROM q JOIN c ON c.slug = q.slug"

let private singleBySlugSql =
    $"SELECT c.*, {flagsAlone} FROM (SELECT {cardColumns true} {fromArticles} WHERE a.slug = @slug) c"

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

/// One list request: the viewer, the filter's key ("" for none, the viewer for the feed), paging.
type private ListRequest =
    { Viewer: ViewerId
      Key: string
      Paging: Paging }

let private depthOf (paging: Paging) =
    // Saturating, so a huge offset cannot overflow the feed's LIMIT.
    if paging.Offset > Int64.MaxValue - paging.Limit then Int64.MaxValue else paging.Limit + paging.Offset

let private listKind (f: ListFilter) : Reads.Kind<ListRequest, int64 * Article option, ArticlePage> =
    Reads.Kind(
        batchedListSql f,
        (fun (rs: ListRequest[]) ->
            [ Reads.int64s "@viewers" (rs |> Array.map _.Viewer)
              Reads.texts "@keys" (rs |> Array.map _.Key)
              Reads.int64s "@limits" (rs |> Array.map _.Paging.Limit)
              Reads.int64s "@offsets" (rs |> Array.map _.Paging.Offset)
              Reads.int64s "@depths" (rs |> Array.map (fun r -> depthOf r.Paging)) ]),
        singleListSql f,
        (fun (r: ListRequest) ->
            [ Reads.long "@viewer" r.Viewer
              Reads.text "@key" r.Key
              Reads.long "@lim" r.Paging.Limit
              Reads.long "@off" r.Paging.Offset
              Reads.long "@depth" (depthOf r.Paging) ]),
        (fun read ->
            let total = read.int64 "total"
            match read.int64OrNone "id" with
            | Some _ -> total, Some(article false read)
            | None -> total, None),
        (fun _ rows -> pageOf rows)
    )

let private everythingKind = listKind everything
let private tagKind = listKind byTag
let private authorKind = listKind byAuthor
let private favoritedKind = listKind favoritedBy
let private feedKind = listKind feedFilter

let private bySlugKind: Reads.Kind<string * ViewerId, Article, Article option> =
    Reads.Kind(
        batchedBySlugSql,
        (fun rs -> [ Reads.texts "@slugs" (rs |> Array.map fst); Reads.int64s "@viewers" (rs |> Array.map snd) ]),
        singleBySlugSql,
        (fun (slug, viewer) -> [ Reads.text "@slug" slug; Reads.long "@viewer" viewer ]),
        article true,
        (fun _ rows -> List.tryHead rows)
    )

// ------------------------------------------------------------------ reads -------

let list (reads: Reads.Gather) (viewer: ViewerId) (filter: ArticleFilter) (paging: Paging) : Task<ArticlePage> =
    let ask kind key = reads.Run(kind, { Viewer = viewer; Key = key; Paging = paging })
    match filter with
    | Everything -> ask everythingKind ""
    | ByTag tag -> ask tagKind tag
    | ByAuthor name -> ask authorKind name
    | FavoritedBy name -> ask favoritedKind name

let feed (reads: Reads.Gather) (viewer: ViewerId) (paging: Paging) : Task<ArticlePage> =
    reads.Run(feedKind, { Viewer = viewer; Key = string viewer; Paging = paging })

let bySlug (reads: Reads.Gather) (viewer: ViewerId) (slug: string) : Task<Article option> =
    reads.Run(bySlugKind, (slug, viewer))

// After a write: the multiplexed pool, one request at a time.
let private single (props: Sql.SqlProps) (sql: string) (parameters: (string * SqlValue) list) =
    task {
        let! rows = props |> Sql.query sql |> Sql.parameters parameters |> Sql.executeAsync (article true)
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
      SELECT {columns true count favorited} {fromArticles} WHERE a.id = (SELECT id FROM t)"

let private favoriteOn = favoriteSql true
let private favoriteOff = favoriteSql false

let setFavorite (writes: Commit.Writer) (viewer: ViewerId) (slug: string) (on: bool) : Task<Article option> =
    task {
        let! rows =
            writes.Run(
                [ (if on then favoriteOn else favoriteOff), [ "@viewer", Sql.int64 viewer; "@slug", Sql.text slug ] ],
                article true
            )
        return List.tryHead rows
    }

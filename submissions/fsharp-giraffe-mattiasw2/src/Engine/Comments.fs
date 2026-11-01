module Engine.Comments

open System.Threading.Tasks
open Npgsql
open Npgsql.FSharp

// A batch of (slug, viewer) requests. Each distinct article's newest 100 comments are read once
// (`c`); only the viewer's `following` flag is per request. No row for a request = no such
// article (404); an article without comments is one row with NULL comment columns.
let private batchedListSql =
    "WITH q AS (SELECT * FROM unnest(@slugs::text[], @viewers::int8[]) WITH ORDINALITY AS r(slug, viewer, k)),
          t AS MATERIALIZED (SELECT x.id, d.slug FROM (SELECT DISTINCT slug FROM q) d CROSS JOIN LATERAL
                               (SELECT a.id FROM articles a WHERE a.slug = d.slug LIMIT 1) x),
          c AS MATERIALIZED (
            SELECT t.id AS article_id, x.* FROM t CROSS JOIN LATERAL (
                SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image
                  FROM comments c JOIN users u ON u.id = c.author_id
                 WHERE c.article_id = t.id
                 ORDER BY c.created_at DESC, c.id DESC
                 LIMIT 100) x)
     SELECT q.k, c.id, c.body, c.created_at, c.updated_at, c.username, c.bio, c.image,
            EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = q.viewer AND fo.followee_id = c.author_id) AS following
       FROM q JOIN t ON t.slug = q.slug LEFT JOIN c ON c.article_id = t.id
      ORDER BY q.k, c.created_at DESC, c.id DESC"

// One request: the article lookup and its newest 100 comments.
let private singleListSql =
    "SELECT t.id AS article_id, c.* FROM (SELECT id FROM articles WHERE slug = @slug) t
       LEFT JOIN LATERAL (
            SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
                   EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = @viewer AND fo.followee_id = c.author_id) AS following
              FROM comments c JOIN users u ON u.id = c.author_id
             WHERE c.article_id = t.id
             ORDER BY c.created_at DESC, c.id DESC
             LIMIT 100) c ON true
     ORDER BY c.created_at DESC, c.id DESC"

let private comment (following: bool option) (read: RowReader) : Comment =
    { Id = read.int64 "id"
      CreatedAt = read.dateTime "created_at"
      UpdatedAt = read.dateTime "updated_at"
      Body = read.text "body"
      Author =
        { Username = read.text "username"
          Bio = read.textOrNone "bio"
          Image = read.textOrNone "image"
          Following = following |> Option.defaultWith (fun () -> read.bool "following") } }

let private listKind: Reads.Kind<string * ViewerId, Comment option, Comment list option> =
    Reads.Kind(
        batchedListSql,
        (fun rs -> [ Reads.texts "@slugs" (rs |> Array.map fst); Reads.int64s "@viewers" (rs |> Array.map snd) ]),
        singleListSql,
        (fun (slug, viewer) -> [ Reads.text "@slug" slug; Reads.long "@viewer" viewer ]),
        (fun read ->
            match read.int64OrNone "id" with
            | Some _ -> Some(comment None read)
            | None -> None),
        (fun _ rows ->
            match rows with
            | [] -> None
            | rows -> Some(List.choose id rows))
    )

/// None = no such article.
let list (reads: Reads.Gather) (viewer: ViewerId) (slug: string) : Task<Comment list option> =
    reads.Run(listKind, (slug, viewer))

let private createSql =
    "WITH t AS (SELECT id FROM articles WHERE slug = @slug),
          c AS (INSERT INTO comments (article_id, author_id, body) SELECT t.id, @viewer, @body FROM t
                RETURNING id, body, created_at, updated_at, author_id)
     SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
       FROM c JOIN users u ON u.id = c.author_id"

/// None = no such article. The author is the viewer, who does not follow themselves.
let create (writes: Commit.Writer) (viewer: ViewerId) (slug: string) (body: string) : Task<Comment option> =
    task {
        let! rows =
            writes.Run(
                [ createSql, [ "@viewer", Sql.int64 viewer; "@slug", Sql.text slug; "@body", Sql.text body ] ],
                comment (Some false)
            )
        return List.tryHead rows
    }

let private deleteSql =
    "WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
                 WHERE c.id = @id AND a.slug = @slug),
          w AS (DELETE FROM comments c USING t WHERE c.id = t.id AND t.author_id = @viewer)
     SELECT author_id FROM t"

let delete (writes: Commit.Writer) (viewer: ViewerId) (slug: string) (id: int64) : Task<Guarded<unit>> =
    task {
        let! rows =
            writes.Run(
                [ deleteSql, [ "@viewer", Sql.int64 viewer; "@slug", Sql.text slug; "@id", Sql.int64 id ] ],
                fun read -> read.int64 "author_id"
            )
        return
            match rows with
            | [] -> NotFound
            | author :: _ when author = viewer -> Done()
            | _ -> NotYours
    }

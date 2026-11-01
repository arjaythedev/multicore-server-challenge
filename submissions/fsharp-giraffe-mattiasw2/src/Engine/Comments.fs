module Engine.Comments

open System.Threading.Tasks
open Npgsql
open Npgsql.FSharp

// The article lookup and the newest 100 comments in one statement: no article row = 404, an
// article without comments is one row with NULL comment columns.
let private listSql =
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

/// None = no such article.
let list (ds: NpgsqlDataSource) (viewer: ViewerId) (slug: string) : Task<Comment list option> =
    task {
        let! rows =
            Sql.fromDataSource ds
            |> Sql.query listSql
            |> Sql.parameters [ "@viewer", Sql.int64 viewer; "@slug", Sql.text slug ]
            |> Sql.executeAsync (fun read ->
                match read.int64OrNone "id" with
                | Some _ -> Some(comment None read)
                | None -> None)
        return
            match rows with
            | [] -> None
            | rows -> Some(List.choose id rows)
    }

let private createSql =
    "WITH t AS (SELECT id FROM articles WHERE slug = @slug),
          c AS (INSERT INTO comments (article_id, author_id, body) SELECT t.id, @viewer, @body FROM t
                RETURNING id, body, created_at, updated_at, author_id)
     SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
       FROM c JOIN users u ON u.id = c.author_id"

/// None = no such article. The author is the viewer, who does not follow themselves.
let create (ds: NpgsqlDataSource) (viewer: ViewerId) (slug: string) (body: string) : Task<Comment option> =
    task {
        let! rows =
            Sql.fromDataSource ds
            |> Sql.query createSql
            |> Sql.parameters [ "@viewer", Sql.int64 viewer; "@slug", Sql.text slug; "@body", Sql.text body ]
            |> Sql.executeAsync (comment (Some false))
        return List.tryHead rows
    }

let private deleteSql =
    "WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
                 WHERE c.id = @id AND a.slug = @slug),
          w AS (DELETE FROM comments c USING t WHERE c.id = t.id AND t.author_id = @viewer)
     SELECT author_id FROM t"

let delete (ds: NpgsqlDataSource) (viewer: ViewerId) (slug: string) (id: int64) : Task<Guarded<unit>> =
    task {
        let! rows =
            Sql.fromDataSource ds
            |> Sql.query deleteSql
            |> Sql.parameters [ "@viewer", Sql.int64 viewer; "@slug", Sql.text slug; "@id", Sql.int64 id ]
            |> Sql.executeAsync (fun read -> read.int64 "author_id")
        return
            match rows with
            | [] -> NotFound
            | author :: _ when author = viewer -> Done()
            | _ -> NotYours
    }

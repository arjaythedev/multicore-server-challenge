module Engine.Comments

open System.Threading.Tasks
open Npgsql
open Npgsql.FSharp

/// None = no such article. Batched (Reads).
let list (reads: Reads.Gather) (viewer: ViewerId) (slug: string) : Task<Comment list option> =
    reads.Comments(viewer, slug)

let private createSql =
    "WITH t AS (SELECT id FROM articles WHERE slug = @slug),
          c AS (INSERT INTO comments (article_id, author_id, body) SELECT t.id, @viewer, @body FROM t
                RETURNING id, body, created_at, updated_at, author_id)
     SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image
       FROM c JOIN users u ON u.id = c.author_id"

let private comment (read: RowReader) : Comment =
    { Card =
        { Id = read.int64 "id"
          CreatedAt = read.dateTime "created_at"
          UpdatedAt = read.dateTime "updated_at"
          Body = read.text "body"
          Author =
            { Id = read.int64 "author_id"
              Username = read.text "username"
              Bio = read.textOrNone "bio"
              Image = read.textOrNone "image" } }
      Following = false }

/// None = no such article. The author is the viewer, who does not follow themselves.
let create (writes: Commit.Writer) (viewer: ViewerId) (slug: string) (body: string) : Task<Comment option> =
    task {
        let! rows =
            writes.Run(
                [ createSql, [ "@viewer", Sql.int64 viewer; "@slug", Sql.text slug; "@body", Sql.text body ] ],
                comment
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

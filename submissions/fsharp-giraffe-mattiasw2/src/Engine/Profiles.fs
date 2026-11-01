module Engine.Profiles

open System.Threading.Tasks
open Npgsql
open Npgsql.FSharp

let get (ds: NpgsqlDataSource) (viewer: ViewerId) (username: string) : Task<Profile option> =
    task {
        let! rows =
            Sql.fromDataSource ds
            |> Sql.query
                "SELECT u.username, u.bio, u.image,
                        EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = @viewer AND fo.followee_id = u.id) AS following
                   FROM users u WHERE u.username = @username"
            |> Sql.parameters [ "@viewer", Sql.int64 viewer; "@username", Sql.text username ]
            |> Sql.executeAsync (fun read ->
                { Username = read.text "username"
                  Bio = read.textOrNone "bio"
                  Image = read.textOrNone "image"
                  Following = read.bool "following" })
        return List.tryHead rows
    }

// Follow and unfollow: the lookup and the write are ONE statement (a data-modifying CTE runs
// whether or not the outer query reads it), so a toggle is one round trip. No row = 404.
let private followSql =
    "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = @username),
          w AS (INSERT INTO follows (follower_id, followee_id) SELECT @viewer, u.id FROM u ON CONFLICT DO NOTHING)
     SELECT username, bio, image FROM u"

let private unfollowSql =
    "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = @username),
          w AS (DELETE FROM follows fo USING u WHERE fo.follower_id = @viewer AND fo.followee_id = u.id)
     SELECT username, bio, image FROM u"

let setFollowing (ds: NpgsqlDataSource) (viewer: ViewerId) (username: string) (following: bool) : Task<Profile option> =
    task {
        let! rows =
            Sql.fromDataSource ds
            |> Sql.query (if following then followSql else unfollowSql)
            |> Sql.parameters [ "@viewer", Sql.int64 viewer; "@username", Sql.text username ]
            |> Sql.executeAsync (fun read ->
                { Username = read.text "username"
                  Bio = read.textOrNone "bio"
                  Image = read.textOrNone "image"
                  Following = following })
        return List.tryHead rows
    }

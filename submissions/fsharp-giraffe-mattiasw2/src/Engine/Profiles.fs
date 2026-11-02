module Engine.Profiles

open System.Threading.Tasks
open Npgsql
open Npgsql.FSharp

/// Batched (Reads).
let get (reads: Reads.Gather) (viewer: ViewerId) (username: string) : Task<Profile option> =
    reads.Profile(viewer, username)

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

let setFollowing (writes: Commit.Writer) (viewer: ViewerId) (username: string) (following: bool) : Task<Profile option> =
    task {
        let! rows =
            writes.Run(
                [ (if following then followSql else unfollowSql),
                  [ "@viewer", Sql.int64 viewer; "@username", Sql.text username ] ],
                fun read ->
                    { Username = read.text "username"
                      Bio = read.textOrNone "bio"
                      Image = read.textOrNone "image"
                      Following = following }
            )
        return List.tryHead rows
    }

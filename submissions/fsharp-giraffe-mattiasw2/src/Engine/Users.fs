module Engine.Users

open System.Threading.Tasks
open Npgsql
open Npgsql.FSharp

let private user (read: RowReader) : User =
    { Id = read.int64 "id"
      Username = read.text "username"
      Email = read.text "email"
      Bio = read.textOrNone "bio"
      Image = read.textOrNone "image" }

/// Is either name already held by ANOTHER user (`exceptId` 0 = by anyone)? Asked before bcrypt
/// runs, so a refused sign-up or rename never pays for a hash. Only a pre-check: two racing
/// requests can both pass it, and the UNIQUE constraint still decides (Taken).
let taken (ds: NpgsqlDataSource) (exceptId: int64) (username: string option) (email: string option) : Task<bool> =
    match username, email with
    | None, None -> Task.FromResult false
    | _ ->
        task {
            let! rows =
                Sql.fromDataSource ds
                |> Sql.query
                    "SELECT EXISTS (SELECT 1 FROM users WHERE (username = @username OR email = @email) AND id <> @id) AS taken"
                |> Sql.parameters
                    [ "@id", Sql.int64 exceptId
                      "@username", Sql.textOrNone username
                      "@email", Sql.textOrNone email ]
                |> Sql.executeAsync (fun read -> read.bool "taken")
            return List.exists id rows
        }

let register (writes: Commit.Writer) (username: string) (email: string) (passwordHash: string) : Task<Unique<User>> =
    task {
        try
            let! rows =
                writes.Run(
                    [ "INSERT INTO users (username, email, password_hash) VALUES (@username, @email, @hash)
                       RETURNING id, username, email, bio, image",
                      [ "@username", Sql.text username; "@email", Sql.text email; "@hash", Sql.text passwordHash ] ],
                    user
                )
            return
                match rows with
                | u :: _ -> Stored u
                | [] -> Missing
        with e when Db.isUniqueViolation e ->
            return Taken
    }

/// The user and the stored bcrypt hash, for login.
let byEmail (ds: NpgsqlDataSource) (email: string) : Task<(User * string) option> =
    task {
        let! rows =
            Sql.fromDataSource ds
            |> Sql.query "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = @email"
            |> Sql.parameters [ "@email", Sql.text email ]
            |> Sql.executeAsync (fun read -> user read, read.text "password_hash")
        return List.tryHead rows
    }

let byId (ds: NpgsqlDataSource) (id: int64) : Task<User option> =
    task {
        let! rows =
            Sql.fromDataSource ds
            |> Sql.query "SELECT id, username, email, bio, image FROM users WHERE id = @id"
            |> Sql.parameters [ "@id", Sql.int64 id ]
            |> Sql.executeAsync user
        return List.tryHead rows
    }

type Changes =
    { Email: string option
      Username: string option
      PasswordHash: string option
      Bio: string option
      Image: string option }

/// Absent or null fields stay as they are (COALESCE). Missing = the token's user is gone.
let update (writes: Commit.Writer) (id: int64) (c: Changes) : Task<Unique<User>> =
    task {
        try
            let! rows =
                writes.Run(
                    [ "UPDATE users SET email = COALESCE(@email, email), username = COALESCE(@username, username),
                                        password_hash = COALESCE(@hash, password_hash), bio = COALESCE(@bio, bio),
                                        image = COALESCE(@image, image)
                        WHERE id = @id
                       RETURNING id, username, email, bio, image",
                      [ "@id", Sql.int64 id
                        "@email", Sql.textOrNone c.Email
                        "@username", Sql.textOrNone c.Username
                        "@hash", Sql.textOrNone c.PasswordHash
                        "@bio", Sql.textOrNone c.Bio
                        "@image", Sql.textOrNone c.Image ] ],
                    user
                )
            return
                match rows with
                | u :: _ -> Stored u
                | [] -> Missing
        with e when Db.isUniqueViolation e ->
            return Taken
    }

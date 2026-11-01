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

let register (ds: NpgsqlDataSource) (username: string) (email: string) (passwordHash: string) : Task<Unique<User>> =
    task {
        try
            let! rows =
                Sql.fromDataSource ds
                |> Sql.query
                    "INSERT INTO users (username, email, password_hash) VALUES (@username, @email, @hash)
                     RETURNING id, username, email, bio, image"
                |> Sql.parameters [ "@username", Sql.text username; "@email", Sql.text email; "@hash", Sql.text passwordHash ]
                |> Sql.executeAsync user
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
let update (ds: NpgsqlDataSource) (id: int64) (c: Changes) : Task<Unique<User>> =
    task {
        try
            let! rows =
                Sql.fromDataSource ds
                |> Sql.query
                    "UPDATE users SET email = COALESCE(@email, email), username = COALESCE(@username, username),
                                      password_hash = COALESCE(@hash, password_hash), bio = COALESCE(@bio, bio),
                                      image = COALESCE(@image, image)
                      WHERE id = @id
                     RETURNING id, username, email, bio, image"
                |> Sql.parameters
                    [ "@id", Sql.int64 id
                      "@email", Sql.textOrNone c.Email
                      "@username", Sql.textOrNone c.Username
                      "@hash", Sql.textOrNone c.PasswordHash
                      "@bio", Sql.textOrNone c.Bio
                      "@image", Sql.textOrNone c.Image ]
                |> Sql.executeAsync user
            return
                match rows with
                | u :: _ -> Stored u
                | [] -> Missing
        with e when Db.isUniqueViolation e ->
            return Taken
    }

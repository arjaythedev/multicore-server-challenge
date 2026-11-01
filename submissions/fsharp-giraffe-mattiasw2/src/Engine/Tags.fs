module Engine.Tags

open System.Threading.Tasks
open Npgsql
open Npgsql.FSharp

let all (ds: NpgsqlDataSource) : Task<string list> =
    Sql.fromDataSource ds
    |> Sql.query "SELECT name FROM tags ORDER BY name"
    |> Sql.executeAsync (fun read -> read.text "name")

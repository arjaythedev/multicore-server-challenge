module Engine.Tags

open System.Threading.Tasks

/// Every tag request of a batch shares the one statement's rows.
let private allKind =
    Reads.shared "SELECT name FROM tags ORDER BY name" (fun read -> read.text "name") id

let all (reads: Reads.Gather) : Task<string list> = reads.Run(allKind, ())

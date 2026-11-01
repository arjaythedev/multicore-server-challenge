module Engine.Tags

open System.Threading.Tasks

/// Batched (Reads): every tag request of a batch shares one statement's rows.
let all (reads: Reads.Gather) : Task<string list> = reads.Tags()

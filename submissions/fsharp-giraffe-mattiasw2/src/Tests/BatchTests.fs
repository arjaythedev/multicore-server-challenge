/// The read-batching property: a request's answer never depends on the other requests in its
/// batch. FsCheck builds random batches from real keys of the dev seed, with many duplicates,
/// unknown keys, anonymous viewers and huge offsets, and every request's answer in the batch
/// must equal its answer alone, as a client sees it (Wire's bytes). That covers the planning
/// (distinct keys, positions), card sharing, the body rule, the flag sets and the two phases.
/// The SQL itself is checked by the conformance suite.
///
/// Needs BATCH_TEST_DATABASE_URL: a database copied from the dev seed (check.sh phase 4). Only
/// reads it.
module Tests.BatchTests

open System
open System.Text
open Npgsql
open Xunit
open FsCheck
open FsCheck.FSharp
open Engine
open Engine.Reads
open global.Web

let private dataSource =
    lazy
        (match Environment.GetEnvironmentVariable "BATCH_TEST_DATABASE_URL" with
         | null
         | "" -> failwith "BATCH_TEST_DATABASE_URL is not set (check.sh phase 4 provides it)"
         | url -> NpgsqlDataSource.Create(Db.connectionString url 2 false))

/// What a client sees: the answer as Wire encodes it.
let private seen (a: Answer) : string =
    let text (b: Wire.Body) = Encoding.UTF8.GetString b.Span
    match a with
    | TagNames names -> text (Wire.tags names)
    | Listed page -> text (Wire.articles page)
    | Found(Some article) -> text (Wire.article article)
    | Thread(Some comments) -> text (Wire.comments comments)
    | Person(Some profile) -> text (Wire.profile profile)
    | Found None
    | Thread None
    | Person None -> "404"

let private run (reads: Read[]) : Answer[] =
    use conn = dataSource.Value.OpenConnection()
    (answer conn reads).GetAwaiter().GetResult()

let private column (sql: string) (read: Data.Common.DbDataReader -> 'a) : 'a list =
    use conn = dataSource.Value.OpenConnection()
    use cmd = new NpgsqlCommand(sql, conn)
    use r = cmd.ExecuteReader()
    [ while r.Read() do
          read r ]

/// Real keys, chosen so that flags are set: viewers who favorite the pool's articles and follow
/// their authors, and threads with comments.
type private Pools =
    { Slugs: string list
      Usernames: string list
      Tags: string list
      Viewers: int64 list }

let private pools =
    lazy
        (let slugs =
            column
                "(SELECT a.slug FROM articles a JOIN comments c ON c.article_id = a.id GROUP BY a.slug ORDER BY count(*) DESC LIMIT 12)
                 UNION (SELECT a.slug FROM articles a JOIN favorites f ON f.article_id = a.id GROUP BY a.slug ORDER BY count(*) DESC LIMIT 12)
                 UNION (SELECT slug FROM articles ORDER BY id DESC LIMIT 6)"
                (fun r -> r.GetString 0)
         let inPool = "(SELECT id FROM articles WHERE slug = ANY(@slugs))"
         let viewers (sql: string) =
             use conn = dataSource.Value.OpenConnection()
             use cmd = new NpgsqlCommand(sql, conn)
             cmd.Parameters.AddWithValue("slugs", List.toArray slugs) |> ignore
             use r = cmd.ExecuteReader()
             [ while r.Read() do
                   r.GetInt64 0 ]
         let favoriters = viewers $"SELECT DISTINCT user_id FROM favorites WHERE article_id IN {inPool} LIMIT 8"
         let followers =
             viewers
                 $"SELECT DISTINCT fo.follower_id FROM follows fo JOIN articles a ON a.author_id = fo.followee_id
                    WHERE a.id IN {inPool} LIMIT 8"
         let commenterFollowers =
             viewers
                 $"SELECT DISTINCT fo.follower_id FROM follows fo JOIN comments c ON c.author_id = fo.followee_id
                    WHERE c.article_id IN {inPool} LIMIT 6"
         { Slugs = "no-such-slug" :: slugs
           Usernames =
             "no-such-user"
             :: column "SELECT DISTINCT u.username FROM users u JOIN articles a ON a.author_id = u.id LIMIT 10" (fun r -> r.GetString 0)
             @ column "SELECT DISTINCT u.username FROM users u JOIN favorites f ON f.user_id = u.id LIMIT 6" (fun r -> r.GetString 0)
           Tags = "no-such-tag" :: column "SELECT name FROM tags ORDER BY id LIMIT 8" (fun r -> r.GetString 0)
           Viewers = 0L :: favoriters @ followers @ commenterFollowers })

/// Mostly one of the first few (hot) keys, so batch-mates collide often, as on a real feed.
let private skewed (items: 'a list) : Gen<'a> =
    Gen.frequency [ 3, Gen.elements (List.truncate 3 items); 1, Gen.elements items ]

let private reads (p: Pools) : Gen<Read> =
    let paging =
        gen {
            let! limit = Gen.elements [ 1L; 5L; 10L; 10L; 20L; 100L ]
            let! offset = Gen.elements [ 0L; 0L; 0L; 10L; 20L; 40L; 995L; Int64.MaxValue - 3L ]
            return { Limit = limit; Offset = offset }
        }
    let viewer = skewed (List.tail p.Viewers @ [ 0L ])
    let signedIn = skewed (List.tail p.Viewers)
    let filter =
        Gen.oneof
            [ Gen.constant Everything
              skewed p.Tags |> Gen.map ByTag
              skewed p.Usernames |> Gen.map ByAuthor
              skewed p.Usernames |> Gen.map FavoritedBy ]
    Gen.frequency
        [ 2, Gen.constant ReadTags
          4, Gen.map3 (fun v f pg -> ReadPage(v, f, pg)) viewer filter paging
          2, Gen.map2 (fun v pg -> ReadFeed(v, pg)) signedIn paging
          4, Gen.map2 (fun v s -> ReadArticle(v, s)) viewer (skewed (List.tail p.Slugs @ [ List.head p.Slugs ]))
          4, Gen.map2 (fun v s -> ReadComments(v, s)) viewer (skewed (List.tail p.Slugs @ [ List.head p.Slugs ]))
          2, Gen.map2 (fun v u -> ReadProfile(v, u)) viewer (skewed p.Usernames) ]

let private batches (p: Pools) : Arbitrary<Read list> =
    let gen =
        Gen.sized (fun size ->
            gen {
                let! n = Gen.choose (1, max 2 (min 40 size))
                return! Gen.listOfLength n (reads p)
            })
    // Shrink by dropping requests: a failure comes back as the smallest batch that still fails.
    let shrink (batch: Read list) =
        seq {
            for i in 0 .. batch.Length - 1 do
                if batch.Length > 1 then
                    yield List.removeAt i batch
        }
    Arb.fromGenShrink (gen, shrink)

[<Fact>]
let ``a request's answer does not depend on its batch-mates`` () =
    let property (batch: Read list) =
        let batch = Array.ofList batch
        let together = run batch |> Array.map seen
        let alone = batch |> Array.map (fun r -> seen (Array.exactlyOne (run [| r |])))
        together = alone
    Check.One(Config.QuickThrowOnFailure.WithMaxTest(500), Prop.forAll (batches pools.Value) property)

[<Fact>]
let ``the pools reach every flag and every miss`` () =
    // Otherwise the property could pass on batches where nothing is ever favorited or followed.
    let p = pools.Value
    let batch =
        [| for v in p.Viewers do
               for s in p.Slugs do
                   ReadArticle(v, s)
                   ReadComments(v, s)
               for u in p.Usernames do
                   ReadProfile(v, u)
               ReadPage(v, Everything, { Limit = 20L; Offset = 0L }) |]
    let answers = run batch
    let articles =
        answers
        |> Array.collect (function
            | Found(Some a) -> [| a |]
            | Listed page -> Array.ofList page.Articles
            | _ -> [||])
    let comments =
        answers
        |> Array.collect (function
            | Thread(Some cs) -> Array.ofList cs
            | _ -> [||])
    let profiles =
        answers
        |> Array.choose (function
            | Person(Some p) -> Some p
            | _ -> None)
    Assert.Contains(articles, fun a -> a.Favorited)
    Assert.Contains(articles, fun a -> a.Following)
    Assert.Contains(comments, fun c -> c.Following)
    Assert.Contains(profiles, fun p -> p.Following)
    Assert.Contains(answers, fun a -> a = Found None)
    Assert.Contains(answers, fun a -> a = Thread None)
    Assert.Contains(answers, fun a -> a = Person None)

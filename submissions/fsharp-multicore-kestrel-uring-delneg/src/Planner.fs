/// The batch planner (on by default; PLANNER=0 turns it off), after #47 (rust-epoll-WorriedArrow, the leader): every waiting GET of an article,
/// its comments, a profile or an article list (global, tag, author, favorited, feed) goes into ONE batch, answered
/// in two pipelined round trips on one read connection:
///
/// - phase A: one statement per kind present, over arrays of DISTINCT keys (one page per (limit, offset), one count
///   per tag / author / viewer, one row per slug or username), rows tagged with the key's ordinal k;
/// - phase B: the union of every article phase A returned, across all endpoints, is enriched once (tag ids,
///   favorite count, author; the tag names come from one read of all tags, after #47's tag ids + names split), and
///   the viewer flags are one primary-key scan per viewer (`= ANY`).
///
/// Each distinct article's JSON is written once per batch with both flags false; every response is assembled from
/// those pieces and its own flags. Only requests already waiting share a batch, and nothing outlives it (rule 5).
module Planner

open System
open System.Buffers
open System.Buffers.Binary
open System.Buffers.Text
open System.Collections.Generic
open System.Text.Encodings.Web
open System.Text.Json
open Pg
open Ctx

let enabled = Environment.GetEnvironmentVariable "PLANNER" <> "0"
/// artx returns tag ids and phase B reads every tag's name once (PLANNER_TAGIDS=0: names per article in artx)
let private tagIds = Environment.GetEnvironmentVariable "PLANNER_TAGIDS" <> "0"

// ---------- SQL ----------

/// article row after k: id, author_id, slug, title, description, created_at, updated_at
[<Literal>]
let private Cols = "a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at"

/// a count row: k <= 0, the count in column 1, padding to the article row's columns
[<Literal>]
let private Pad = "NULL::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz"

let private T = Oid.TextArray
let private I = Oid.Int8Array

let mutable SArt: Stmt = null
let mutable SCmt: Stmt = null
let mutable SProf: Stmt = null
let mutable SGlobal: Stmt = null
let mutable STag: Stmt = null
let mutable SAuthor: Stmt = null
let mutable SFav: Stmt = null
let mutable SFeed: Stmt = null
let mutable SArtx: Stmt = null
let mutable SFlags: Stmt = null
let mutable STagAll: Stmt = null

/// an article looked up by id, never folded into a join the generic plan could turn into a scan
let private byId (id: string) = "CROSS JOIN LATERAL (SELECT a.* FROM articles a WHERE a.id = " + id + " OFFSET 0) a"

let define (feedProof: bool) (feedProofN: int) =
    SArt <-
        Stmt.Define(
            "SELECT r.k, " + Cols + ", a.body FROM unnest($1::text[]) WITH ORDINALITY r(slug, k) JOIN articles a ON a.slug = r.slug",
            T
        )
    SCmt <-
        Stmt.Define(
            "SELECT r.k, a.id, c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image "
            + "FROM unnest($1::text[]) WITH ORDINALITY r(slug, k) JOIN articles a ON a.slug = r.slug "
            + "LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c "
            + "WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true "
            + "LEFT JOIN users u ON u.id = c.author_id ORDER BY r.k, c.created_at DESC, c.id DESC",
            T
        )
    SProf <-
        Stmt.Define(
            "SELECT r.k, u.id, u.username, u.bio, u.image FROM unnest($1::text[]) WITH ORDINALITY r(username, k) "
            + "JOIN users u ON u.username = r.username",
            T
        )
    SGlobal <-
        Stmt.Define(
            "SELECT 0::int8, (SELECT count(*) FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s), " + Pad
            + " UNION ALL SELECT r.k, " + Cols + " FROM unnest($1::int8[], $2::int8[]) WITH ORDINALITY r(lim, off, k) "
            + "CROSS JOIN LATERAL (SELECT * FROM articles a ORDER BY a.id DESC LIMIT r.lim OFFSET r.off) a",
            I, I
        )
    let listStmt (keyJoin: string) (count: string) (pageJoin: string) (page: string) =
        Stmt.Define(
            "SELECT -r.k, " + count + ", " + Pad + " FROM unnest($1::text[]) WITH ORDINALITY r(key, k) " + keyJoin
            + " UNION ALL SELECT r.k, " + Cols + " FROM unnest($2::text[], $3::int8[], $4::int8[]) WITH ORDINALITY r(key, lim, off, k) "
            + pageJoin + " " + page,
            T, T, I, I
        )
    STag <-
        listStmt
            "LEFT JOIN tags t ON t.name = r.key"
            "(SELECT count(*) FROM (SELECT 1 FROM article_tags c WHERE c.tag_id = t.id LIMIT 1000) s)"
            "JOIN tags t ON t.name = r.key"
            ("CROSS JOIN LATERAL (SELECT at.article_id FROM article_tags at WHERE at.tag_id = t.id ORDER BY at.article_id DESC LIMIT r.lim OFFSET r.off) p "
             + byId "p.article_id")
    SAuthor <-
        listStmt
            "LEFT JOIN users u ON u.username = r.key"
            "(SELECT count(*) FROM (SELECT 1 FROM articles c WHERE c.author_id = u.id LIMIT 1000) s)"
            "JOIN users u ON u.username = r.key"
            "CROSS JOIN LATERAL (SELECT * FROM articles a WHERE a.author_id = u.id ORDER BY a.id DESC LIMIT r.lim OFFSET r.off) a"
    SFav <-
        listStmt
            "LEFT JOIN users u ON u.username = r.key"
            "(SELECT count(*) FROM (SELECT 1 FROM favorites c WHERE c.user_id = u.id LIMIT 1000) s)"
            "JOIN users u ON u.username = r.key"
            ("CROSS JOIN LATERAL (SELECT f.article_id FROM favorites f WHERE f.user_id = u.id ORDER BY f.article_id DESC LIMIT r.lim OFFSET r.off) p "
             + byId "p.article_id")
    // feeds: each distinct viewer's followees once (count, proof and pages); the batch's most shared followees are
    // probed once for a 1000th article (#100's count proof); a page reads the newest (limit + offset) of each followee
    SFeed <-
        Stmt.Define(
            "WITH q AS MATERIALIZED (SELECT r.k, r.v, ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v) AS fl "
            + "FROM unnest($1::int8[]) WITH ORDINALITY r(v, k)), "
            + "h AS MATERIALIZED (SELECT "
            + (if feedProof then
                   "ARRAY(SELECT t.a FROM (SELECT f.a FROM q, unnest(q.fl) AS f(a) GROUP BY f.a "
                   + "HAVING count(*) >= 2 ORDER BY count(*) DESC LIMIT " + string feedProofN + ") t "
                   + "WHERE EXISTS (SELECT 1 FROM articles a3 WHERE a3.author_id = t.a OFFSET 999 LIMIT 1))"
               else "'{}'::int8[]")
            + " AS ha) "
            + "SELECT -q.k, CASE WHEN q.fl && (SELECT ha FROM h) THEN 1000::int8 "
            + "WHEN EXISTS (SELECT 1 FROM articles a3 WHERE a3.author_id = ANY (q.fl) ORDER BY a3.author_id, a3.id DESC OFFSET 999 LIMIT 1) THEN 1000::int8 "
            + "ELSE (SELECT count(*) FROM articles a3 WHERE a3.author_id = ANY (q.fl)) END, " + Pad + " FROM q "
            + "UNION ALL SELECT p.k, " + Cols + " FROM unnest($2::int8[], $3::int8[], $4::int8[]) WITH ORDINALITY p(v, lim, off, k) "
            + "JOIN q ON q.v = p.v CROSS JOIN LATERAL (SELECT * FROM (SELECT y.id FROM unnest(q.fl) AS f(a) "
            + "CROSS JOIN LATERAL (SELECT a3.id FROM articles a3 WHERE a3.author_id = f.a ORDER BY a3.id DESC LIMIT (p.lim + p.off)) y "
            + "ORDER BY y.id DESC LIMIT p.lim OFFSET p.off) x0 LIMIT 100) x "
            + byId "x.id",
            I, I, I, I
        )
    SArtx <-
        Stmt.Define(
            "SELECT r.id, "
            + (if tagIds then "ARRAY(SELECT at.tag_id FROM article_tags at WHERE at.article_id = r.id), "
               else "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = r.id"
                    + (if Json.appSortsTags then "" else " ORDER BY 1") + "), ")
            + "(SELECT count(*) FROM favorites f WHERE f.article_id = r.id), u.username, u.bio, u.image "
            + "FROM unnest($1::int8[], $2::int8[]) r(id, author) JOIN users u ON u.id = r.author",
            I, I
        )
    // every tag's name in name order, read after artx (a later snapshot: tags are never deleted); the batch maps
    // its articles' tag ids to names and ranks, so tagList comes out in Postgres's name order
    STagAll <- Stmt.Define("SELECT t.id::int8, t.name FROM tags t ORDER BY t.name")
    SFlags <-
        Stmt.Define(
            "WITH p AS (SELECT x.v, array_agg(x.a) AS aa FROM unnest($1::int8[], $2::int8[]) x(v, a) GROUP BY x.v), "
            + "q AS (SELECT x.v, array_agg(x.u) AS uu FROM unnest($3::int8[], $4::int8[]) x(v, u) GROUP BY x.v) "
            + "SELECT 0::int8, p.v, f.article_id FROM p CROSS JOIN LATERAL "
            + "(SELECT f.article_id FROM favorites f WHERE f.user_id = p.v AND f.article_id = ANY (p.aa)) f "
            + "UNION ALL SELECT 1::int8, q.v, fo.followee_id FROM q CROSS JOIN LATERAL "
            + "(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = q.v AND fo.followee_id = ANY (q.uu)) fo",
            I, I, I, I
        )

// ---------- distinct keys ----------

[<Literal>]
let private UseKey = 1
[<Literal>]
let private UseViewer = 2
[<Literal>]
let private UseLO = 4

/// The distinct keys of one statement in one batch (open addressing over the requests' own bytes); a key's index
/// + 1 is its k in SQL.
[<Sealed>]
type internal Keys(mode: int) =
    let reps = List<Ctx>()
    let mutable slots = Array.create 64 -1
    let mutable hashes = Array.zeroCreate<int> 64

    static member Hash(mode: int, c: Ctx) =
        let mutable h = HashCode()
        if mode &&& UseKey <> 0 then h.AddBytes c.Key
        if mode &&& UseViewer <> 0 then h.Add c.Viewer
        if mode &&& UseLO <> 0 then
            h.Add c.Limit
            h.Add c.Offset
        h.ToHashCode()

    static member Same(mode: int, a: Ctx, b: Ctx) =
        (mode &&& UseKey = 0 || a.Key.SequenceEqual b.Key)
        && (mode &&& UseViewer = 0 || a.Viewer = b.Viewer)
        && (mode &&& UseLO = 0 || (a.Limit = b.Limit && a.Offset = b.Offset))

    member _.Count = reps.Count
    member _.Rep(i: int) = reps.[i]

    member _.Clear() =
        if reps.Count > 0 then
            Array.Fill(slots, -1)
            reps.Clear()

    member this.Idx(c: Ctx) =
        if (reps.Count + 1) * 2 > slots.Length then
            let size = slots.Length * 2
            slots <- Array.create size -1
            hashes <- Array.zeroCreate size
            for i in 0 .. reps.Count - 1 do
                let h = Keys.Hash(mode, reps.[i])
                let mutable s = h &&& (size - 1)
                while slots.[s] >= 0 do s <- (s + 1) &&& (size - 1)
                slots.[s] <- i
                hashes.[s] <- h
        let h = Keys.Hash(mode, c)
        let mask = slots.Length - 1
        let mutable s = h &&& mask
        let mutable found = -1
        while found < 0 && slots.[s] >= 0 do
            if hashes.[s] = h && Keys.Same(mode, reps.[slots.[s]], c) then found <- slots.[s]
            else s <- (s + 1) &&& mask
        if found >= 0 then found
        else
            slots.[s] <- reps.Count
            hashes.[s] <- h
            reps.Add c
            reps.Count - 1

// ---------- batch state ----------

[<Struct>]
type internal Art =
    { mutable Id: int64
      mutable Author: int64
      mutable Slug: int
      mutable SlugL: int
      mutable Title: int
      mutable TitleL: int
      mutable Desc: int
      mutable DescL: int
      mutable Body: int
      mutable BodyL: int // -1 = not read (list rows)
      mutable Created: int64
      mutable Updated: int64
      mutable Tags: int
      mutable TagsL: int // -1 = no phase B row (then the article is missing)
      mutable Fc: int64
      mutable User: int
      mutable UserL: int
      mutable Bio: int
      mutable BioL: int // -1 = NULL
      mutable Img: int
      mutable ImgL: int
      // the JSON pieces (in jbuf), -1 = not written yet: list form and full form (with body)
      mutable LStart: int
      mutable LFav: int
      mutable LFol: int
      mutable LEnd: int
      mutable FStart: int
      mutable FFav: int
      mutable FFol: int
      mutable FEnd: int }

[<Struct>]
type internal Cmt = { Author: int64; Start: int; Fol: int; End: int }

[<Struct>]
type internal Prof =
    { Id: int64
      mutable User: int
      mutable UserL: int
      mutable Bio: int
      mutable BioL: int
      mutable Img: int
      mutable ImgL: int }

// statements of phase A, in result order when present
[<Literal>]
let private QArt = 0
[<Literal>]
let private QCmt = 1
[<Literal>]
let private QProf = 2
[<Literal>]
let private QGlobal = 3
[<Literal>]
let private QTag = 4
[<Literal>]
let private QAuthor = 5
[<Literal>]
let private QFav = 6
[<Literal>]
let private QFeed = 7
[<Literal>]
let private NQ = 8

let private open1 = "{\"article\":"B
let private close1 = "}"B
let private openN = "{\"articles\":["B
let private closeN = "],\"articlesCount\":"B
let private openC = "{\"comments\":["B
let private closeC = "]}"B
let private comma = ","B
let private tru = "true"B
let private fals = "false"B

let inline private put (o: IBufferWriter<byte>) (src: ReadOnlySpan<byte>) =
    let s = o.GetSpan src.Length
    src.CopyTo s
    o.Advance src.Length

/// One planner batch: requests of every planned kind, answered by phase A and phase B on one read connection.
[<Sealed; AllowNullLiteral>]
type MegaQuery(cap: int, release: MegaQuery -> unit) =
    inherit PgQuery()
    let items = Array.zeroCreate<Ctx> cap
    let finished = Array.zeroCreate<Ctx> cap
    let key = Array.zeroCreate<int> cap // the request's key index in its statement (article, comments, profile, count)
    let page = Array.zeroCreate<int> cap // list requests: the global page number
    let kArt = Keys(UseKey)
    let kCmt = Keys(UseKey)
    let kProf = Keys(UseKey)
    let kGlobal = Keys(UseLO)
    let kCount = [| Keys(UseKey); Keys(UseKey); Keys(UseKey) |] // tag, author, favorited
    let kPage = [| Keys(UseKey ||| UseLO); Keys(UseKey ||| UseLO); Keys(UseKey ||| UseLO) |]
    let kFeedCount = Keys(UseViewer)
    let kFeedPage = Keys(UseViewer ||| UseLO)
    let resultOf = Array.zeroCreate<int> NQ // result index -> statement
    let pageBase = Array.zeroCreate<int> NQ // global page number of a statement's page 1
    let countBase = Array.zeroCreate<int> NQ // index into counts of a statement's count 1
    let mutable nResults = 0
    let mutable phase = 0
    let abuf = ArrayBufferWriter<byte>(64 * 1024) // phase A/B text, copied from the receive buffer
    let jbuf = ArrayBufferWriter<byte>(64 * 1024) // JSON pieces
    let jw = new Utf8JsonWriter(jbuf, JsonWriterOptions(Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping, SkipValidation = true))
    let arts = List<Art>()
    let artIdx = Dictionary<int64, int>()
    let artOf = List<int>() // article statement: k - 1 -> art index or -1
    let pairs = List<struct (int * int64)>() // (global page, article id)
    let mutable pageStart = Array.zeroCreate<int> 256
    let mutable pageLen = Array.zeroCreate<int> 256
    let pageIds = List<int>() // art indexes, pages newest first
    let counts = List<int64>()
    let cmts = List<Cmt>()
    let mutable cmtStart = Array.zeroCreate<int> 256 // comments statement: k - 1 -> first comment, -1 = no article
    let mutable cmtLen = Array.zeroCreate<int> 256
    let profs = List<Prof>()
    let profOf = List<int>() // profile statement: k - 1 -> prof index or -1
    let askFav = HashSet<struct (int64 * int64)>()
    let askFol = HashSet<struct (int64 * int64)>()
    let favs = HashSet<struct (int64 * int64)>()
    let fols = HashSet<struct (int64 * int64)>()
    let favV = List<int64>()
    let favA = List<int64>()
    let folV = List<int64>()
    let folU = List<int64>()
    let tagRank = Dictionary<int64, int>() // tag id -> rank in name order
    let tagOff = List<int>() // by rank: the name in abuf
    let tagLen = List<int>()
    let mutable ranks = Array.zeroCreate<int> 64
    let mutable ok = true

    let copy (r: PgRow) (i: int) (off: byref<int>) (len: byref<int>) =
        if r.IsNull i then
            off <- 0
            len <- -1
        else
            let b = r.Bytes i
            off <- abuf.WrittenCount
            len <- b.Length
            let s = abuf.GetSpan b.Length
            b.CopyTo s
            abuf.Advance b.Length

    let aspan (off: int) (len: int) = abuf.WrittenSpan.Slice(off, len)

    /// a phase-A article row (columns from 1: id, author, slug, title, description, created, updated [, body])
    let artRow (r: PgRow) (withBody: bool) =
        let id = r.Int8 1
        let mutable ai = 0
        if artIdx.TryGetValue(id, &ai) then
            if withBody && arts.[ai].BodyL < 0 then
                let mutable a = arts.[ai]
                copy r 8 &a.Body &a.BodyL
                arts.[ai] <- a
            ai
        else
            let mutable a = Unchecked.defaultof<Art>
            a <- { a with Id = id; Author = r.Int8 2; Created = r.Micros 6; Updated = r.Micros 7; BodyL = -1; TagsL = -1; LStart = -1; FStart = -1 }
            copy r 3 &a.Slug &a.SlugL
            copy r 4 &a.Title &a.TitleL
            copy r 5 &a.Desc &a.DescL
            if withBody then copy r 8 &a.Body &a.BodyL
            ai <- arts.Count
            arts.Add a
            artIdx.[id] <- ai
            ai

    let ensure (arr: byref<int[]>) (n: int) =
        if arr.Length < n then arr <- Array.zeroCreate (max n (arr.Length * 2))

    /// tagList: the article's tag ids (an int4[] in binary) mapped to name ranks, sorted, written as names
    let writeTagIds (a: Art) =
        jw.WritePropertyName Json.N.tagList
        jw.WriteStartArray()
        if a.TagsL >= 20 then
            let b = aspan a.Tags a.TagsL
            if BinaryPrimitives.ReadInt32BigEndian b = 1 then
                let count = BinaryPrimitives.ReadInt32BigEndian(b.Slice 12)
                if ranks.Length < count then ranks <- Array.zeroCreate (max 64 count)
                let mutable pos = 20
                let mutable n = 0
                for _ in 0 .. count - 1 do
                    let len = BinaryPrimitives.ReadInt32BigEndian(b.Slice pos)
                    pos <- pos + 4
                    if len > 0 then
                        let id =
                            if len = 4 then int64 (BinaryPrimitives.ReadInt32BigEndian(b.Slice pos))
                            else BinaryPrimitives.ReadInt64BigEndian(b.Slice pos)
                        pos <- pos + len
                        let mutable rk = 0
                        if tagRank.TryGetValue(id, &rk) then
                            let mutable j = n
                            while j > 0 && ranks.[j - 1] > rk do
                                ranks.[j] <- ranks.[j - 1]
                                j <- j - 1
                            ranks.[j] <- rk
                            n <- n + 1
                for j in 0 .. n - 1 do
                    jw.WriteStringValue(aspan tagOff.[ranks.[j]] tagLen.[ranks.[j]])
        jw.WriteEndArray()

    let fragment (ai: int) (full: bool) =
        let a = arts.[ai]
        jw.Reset()
        let start = jbuf.WrittenCount
        jw.WriteStartObject()
        jw.WriteString(Json.N.slug, aspan a.Slug a.SlugL)
        jw.WriteString(Json.N.title, aspan a.Title a.TitleL)
        jw.WriteString(Json.N.description, aspan a.Desc a.DescL)
        if full then jw.WriteString(Json.N.body, aspan a.Body (max 0 a.BodyL))
        Json.time jw Json.N.createdAt a.Created
        Json.time jw Json.N.updatedAt a.Updated
        if tagIds then writeTagIds a else Json.tagListBytes jw (aspan a.Tags (max 0 a.TagsL))
        jw.WriteNumber(Json.N.favoritesCount, a.Fc)
        jw.WriteBoolean(Json.N.favorited, false)
        jw.Flush()
        let fav = jbuf.WrittenCount - 5
        jw.WritePropertyName Json.N.author
        jw.WriteStartObject()
        jw.WriteString(Json.N.username, aspan a.User a.UserL)
        if a.BioL < 0 then jw.WriteNull Json.N.bio else jw.WriteString(Json.N.bio, aspan a.Bio a.BioL)
        if a.ImgL < 0 then jw.WriteNull Json.N.image else jw.WriteString(Json.N.image, aspan a.Img a.ImgL)
        jw.WriteBoolean(Json.N.following, false)
        jw.Flush()
        let fol = jbuf.WrittenCount - 5
        jw.WriteEndObject()
        jw.WriteEndObject()
        jw.Flush()
        let e = jbuf.WrittenCount
        let mutable x = arts.[ai]
        if full then x <- { x with FStart = start; FFav = fav; FFol = fol; FEnd = e }
        else x <- { x with LStart = start; LFav = fav; LFol = fol; LEnd = e }
        arts.[ai] <- x

    /// writes article ai with the viewer's flags; false if its phase-B row is missing
    let writeArt (o: IBufferWriter<byte>) (ai: int) (full: bool) (v: int64) (feed: bool) =
        if arts.[ai].TagsL < 0 then false
        else
            if (if full then arts.[ai].FStart else arts.[ai].LStart) < 0 then fragment ai full
            let a = arts.[ai]
            let s, fv, fo, e = if full then a.FStart, a.FFav, a.FFol, a.FEnd else a.LStart, a.LFav, a.LFol, a.LEnd
            let src = jbuf.WrittenSpan
            put o (src.Slice(s, fv - s))
            put o (ReadOnlySpan(if v <> 0L && favs.Contains(struct (v, a.Id)) then tru else fals))
            put o (src.Slice(fv + 5, fo - fv - 5))
            put o (ReadOnlySpan(if feed || (v <> 0L && fols.Contains(struct (v, a.Author))) then tru else fals))
            put o (src.Slice(fo + 5, e - fo - 5))
            true

    let askArt (v: int64) (ai: int) (feed: bool) =
        if v <> 0L then
            let a = arts.[ai]
            if askFav.Add(struct (v, a.Id)) then
                favV.Add v
                favA.Add a.Id
            if not feed && askFol.Add(struct (v, a.Author)) then
                folV.Add v
                folU.Add a.Author

    let askUser (v: int64) (u: int64) =
        if v <> 0L && askFol.Add(struct (v, u)) then
            folV.Add v
            folU.Add u

    member val N = 0 with get, set
    member val Conn: PgConn = null with get, set
    member _.Items = items

    /// phase A keys; call after Items/N are set
    member b.Plan() =
        kArt.Clear()
        kCmt.Clear()
        kProf.Clear()
        kGlobal.Clear()
        for t in kCount do t.Clear()
        for t in kPage do t.Clear()
        kFeedCount.Clear()
        kFeedPage.Clear()
        for i in 0 .. b.N - 1 do
            let c = items.[i]
            match c.Route with
            | Route.Article -> key.[i] <- kArt.Idx c
            | Route.Comments -> key.[i] <- kCmt.Idx c
            | Route.Profile -> key.[i] <- kProf.Idx c
            | Route.ListAll -> page.[i] <- kGlobal.Idx c
            | Route.ListTag ->
                key.[i] <- kCount.[0].Idx c
                page.[i] <- kPage.[0].Idx c
            | Route.ListAuthor ->
                key.[i] <- kCount.[1].Idx c
                page.[i] <- kPage.[1].Idx c
            | Route.ListFavorited ->
                key.[i] <- kCount.[2].Idx c
                page.[i] <- kPage.[2].Idx c
            | _ -> // Route.Feed
                key.[i] <- kFeedCount.Idx c
                page.[i] <- kFeedPage.Idx c
        // global numbering of pages and counts
        let mutable pb = 0
        let mutable cb = 0
        pageBase.[QGlobal] <- pb
        pb <- pb + kGlobal.Count
        countBase.[QGlobal] <- cb
        cb <- cb + 1
        for f in 0 .. 2 do
            pageBase.[QTag + f] <- pb
            pb <- pb + kPage.[f].Count
            countBase.[QTag + f] <- cb
            cb <- cb + kCount.[f].Count
        pageBase.[QFeed] <- pb
        pb <- pb + kFeedPage.Count
        countBase.[QFeed] <- cb
        cb <- cb + kFeedCount.Count
        ensure &pageStart pb
        ensure &pageLen pb
        Array.Clear(pageLen, 0, pb)
        counts.Clear()
        for _ in 1..cb do counts.Add 0L
        ensure &cmtStart kCmt.Count
        ensure &cmtLen kCmt.Count
        for i in 0 .. kCmt.Count - 1 do
            cmtStart.[i] <- -1
            cmtLen.[i] <- 0
        artOf.Clear()
        for _ in 1 .. kArt.Count do artOf.Add -1
        profOf.Clear()
        for _ in 1 .. kProf.Count do profOf.Add -1
        abuf.ResetWrittenCount()
        jbuf.ResetWrittenCount()
        arts.Clear()
        artIdx.Clear()
        pairs.Clear()
        pageIds.Clear()
        cmts.Clear()
        profs.Clear()
        askFav.Clear()
        askFol.Clear()
        favs.Clear()
        fols.Clear()
        favV.Clear()
        favA.Clear()
        folV.Clear()
        folU.Clear()
        tagRank.Clear()
        tagOff.Clear()
        tagLen.Clear()
        ok <- true
        phase <- 0

    member private _.Texts(w: PgWriter, k: Keys) =
        w.BeginArray Oid.Text
        for i in 0 .. k.Count - 1 do w.Text (k.Rep i).Key
        w.EndArray k.Count

    member private _.Longs(w: PgWriter, k: Keys, f: Ctx -> int64) =
        w.BeginArray Oid.Int8
        for i in 0 .. k.Count - 1 do w.Int8(f (k.Rep i))
        w.EndArray k.Count

    member private _.LongList(w: PgWriter, l: List<int64>) =
        w.BeginArray Oid.Int8
        for x in l do w.Int8 x
        w.EndArray l.Count

    override b.Write(w) =
        nResults <- 0
        let add q =
            resultOf.[nResults] <- q
            nResults <- nResults + 1
        if phase = 0 then
            if kArt.Count > 0 then
                w.Bind SArt
                b.Texts(w, kArt)
                w.EndBind()
                add QArt
            if kCmt.Count > 0 then
                w.Bind SCmt
                b.Texts(w, kCmt)
                w.EndBind()
                add QCmt
            if kProf.Count > 0 then
                w.Bind SProf
                b.Texts(w, kProf)
                w.EndBind()
                add QProf
            if kGlobal.Count > 0 then
                w.Bind SGlobal
                b.Longs(w, kGlobal, fun c -> int64 c.Limit)
                b.Longs(w, kGlobal, fun c -> c.Offset)
                w.EndBind()
                add QGlobal
            for f in 0 .. 2 do
                if kPage.[f].Count > 0 then
                    w.Bind(if f = 0 then STag elif f = 1 then SAuthor else SFav)
                    b.Texts(w, kCount.[f])
                    b.Texts(w, kPage.[f])
                    b.Longs(w, kPage.[f], fun c -> int64 c.Limit)
                    b.Longs(w, kPage.[f], fun c -> c.Offset)
                    w.EndBind()
                    add (QTag + f)
            if kFeedPage.Count > 0 then
                w.Bind SFeed
                b.Longs(w, kFeedCount, fun c -> c.Viewer)
                b.Longs(w, kFeedPage, fun c -> c.Viewer)
                b.Longs(w, kFeedPage, fun c -> int64 c.Limit)
                b.Longs(w, kFeedPage, fun c -> c.Offset)
                w.EndBind()
                add QFeed
        else
            if arts.Count > 0 then
                w.Bind SArtx
                w.BeginArray Oid.Int8
                for a in arts do w.Int8 a.Id
                w.EndArray arts.Count
                w.BeginArray Oid.Int8
                for a in arts do w.Int8 a.Author
                w.EndArray arts.Count
                w.EndBind()
                add 0
                if tagIds then
                    w.Bind STagAll
                    w.EndBind()
                    add 2
            if favV.Count + folV.Count > 0 then
                w.Bind SFlags
                b.LongList(w, favV)
                b.LongList(w, favA)
                b.LongList(w, folV)
                b.LongList(w, folU)
                w.EndBind()
                add 1
        w.Sync()

    override b.Row(result, r) =
        if result < nResults && ok then
            try
                let q = resultOf.[result]
                if phase = 0 then
                    let k = r.Int8 0
                    match q with
                    | QArt ->
                        let ai = artRow r true
                        if k >= 1L && int k <= artOf.Count then artOf.[int k - 1] <- ai
                    | QCmt ->
                        let ki = int k - 1
                        if ki >= 0 && ki < kCmt.Count then
                            if cmtStart.[ki] < 0 then cmtStart.[ki] <- cmts.Count
                            if not (r.IsNull 2) then
                                jw.Reset()
                                let start = jbuf.WrittenCount
                                jw.WriteStartObject()
                                jw.WriteNumber(Json.N.id, r.Int8 2)
                                Json.time jw Json.N.createdAt (r.Micros 4)
                                Json.time jw Json.N.updatedAt (r.Micros 5)
                                jw.WriteString(Json.N.body, r.Bytes 3)
                                jw.WritePropertyName Json.N.author
                                jw.WriteStartObject()
                                jw.WriteString(Json.N.username, r.Bytes 7)
                                Json.nullableText jw Json.N.bio r 8
                                Json.nullableText jw Json.N.image r 9
                                jw.WriteBoolean(Json.N.following, false)
                                jw.Flush()
                                let fol = jbuf.WrittenCount - 5
                                jw.WriteEndObject()
                                jw.WriteEndObject()
                                jw.Flush()
                                cmts.Add({ Author = r.Int8 6; Start = start; Fol = fol; End = jbuf.WrittenCount } : Cmt)
                                cmtLen.[ki] <- cmtLen.[ki] + 1
                    | QProf ->
                        let ki = int k - 1
                        if ki >= 0 && ki < profOf.Count then
                            let mutable p: Prof = { Id = r.Int8 1; User = 0; UserL = 0; Bio = 0; BioL = 0; Img = 0; ImgL = 0 }
                            copy r 2 &p.User &p.UserL
                            copy r 3 &p.Bio &p.BioL
                            copy r 4 &p.Img &p.ImgL
                            profOf.[ki] <- profs.Count
                            profs.Add p
                    | _ ->
                        // lists: k <= 0 a count (k = 0: the global count), k > 0 a page row
                        if k <= 0L then
                            let ci = if q = QGlobal then countBase.[q] else countBase.[q] + int (-k) - 1
                            if ci >= 0 && ci < counts.Count then counts.[ci] <- r.Int8 1
                        else
                            let ai = artRow r false
                            pairs.Add(struct (pageBase.[q] + int k - 1, arts.[ai].Id))
                elif q = 0 then
                    let mutable ai = 0
                    if artIdx.TryGetValue(r.Int8 0, &ai) then
                        let mutable a = arts.[ai]
                        copy r 1 &a.Tags &a.TagsL
                        if a.TagsL < 0 then
                            a.Tags <- 0
                            a.TagsL <- 0
                        a.Fc <- r.Int8 2
                        copy r 3 &a.User &a.UserL
                        copy r 4 &a.Bio &a.BioL
                        copy r 5 &a.Img &a.ImgL
                        arts.[ai] <- a
                elif q = 2 then
                    let mutable off = 0
                    let mutable len = 0
                    copy r 1 &off &len
                    tagRank.[r.Int8 0] <- tagOff.Count
                    tagOff.Add off
                    tagLen.Add(max 0 len)
                else
                    let t = r.Int8 0
                    if t = 0L then favs.Add(struct (r.Int8 1, r.Int8 2)) |> ignore
                    else fols.Add(struct (r.Int8 1, r.Int8 2)) |> ignore
            with e ->
                eprintfn "planner row: %O" e
                ok <- false

    /// after phase A: pages in order, phase B keys
    member private b.AfterA() =
        // pages: sort (page, id desc)
        pairs.Sort(fun (struct (p1, i1)) (struct (p2, i2)) -> if p1 <> p2 then compare p1 p2 else compare i2 i1)
        let mutable j = 0
        while j < pairs.Count do
            let struct (p, _) = pairs.[j]
            pageStart.[p] <- pageIds.Count
            let mutable n = 0
            let mutable more = true
            while more do
                let struct (p2, id) = pairs.[j]
                if p2 <> p then more <- false
                else
                    pageIds.Add artIdx.[id]
                    n <- n + 1
                    j <- j + 1
                    if j >= pairs.Count then more <- false
            pageLen.[p] <- n
        for i in 0 .. b.N - 1 do
            let c = items.[i]
            let v = c.Viewer
            match c.Route with
            | Route.Article ->
                let ai = artOf.[key.[i]]
                if ai >= 0 then askArt v ai false
            | Route.Comments ->
                if v <> 0L then
                    let ki = key.[i]
                    if cmtStart.[ki] >= 0 then
                        for x in cmtStart.[ki] .. cmtStart.[ki] + cmtLen.[ki] - 1 do askUser v cmts.[x].Author
            | Route.Profile ->
                let p = profOf.[key.[i]]
                if p >= 0 then askUser v profs.[p].Id
            | r ->
                let g = b.PageOf(i)
                let feed = r = Route.Feed
                for x in pageStart.[g] .. pageStart.[g] + pageLen.[g] - 1 do askArt v pageIds.[x] feed

    member private _.PageOf(i: int) =
        let c = items.[i]
        match c.Route with
        | Route.ListAll -> pageBase.[QGlobal] + page.[i]
        | Route.ListTag -> pageBase.[QTag] + page.[i]
        | Route.ListAuthor -> pageBase.[QAuthor] + page.[i]
        | Route.ListFavorited -> pageBase.[QFav] + page.[i]
        | _ -> pageBase.[QFeed] + page.[i]

    member private _.CountOf(i: int) =
        let c = items.[i]
        match c.Route with
        | Route.ListAll -> counts.[countBase.[QGlobal]]
        | Route.ListTag -> counts.[countBase.[QTag] + key.[i]]
        | Route.ListAuthor -> counts.[countBase.[QAuthor] + key.[i]]
        | Route.ListFavorited -> counts.[countBase.[QFav] + key.[i]]
        | _ -> counts.[countBase.[QFeed] + key.[i]]

    /// the i-th request's response
    member private b.Answer(i: int) =
        let c = items.[i]
        let v = c.Viewer
        let o = c.Out :> IBufferWriter<byte>
        match c.Route with
        | Route.Article ->
            let ai = artOf.[key.[i]]
            if ai < 0 then c.Error(404, "article not found")
            else
                put o (ReadOnlySpan open1)
                if not (writeArt o ai true v false) then failwith "article without phase B row"
                put o (ReadOnlySpan close1)
        | Route.Comments ->
            let ki = key.[i]
            if cmtStart.[ki] < 0 then c.Error(404, "article not found")
            else
                put o (ReadOnlySpan openC)
                let src = jbuf.WrittenSpan
                for x in cmtStart.[ki] .. cmtStart.[ki] + cmtLen.[ki] - 1 do
                    let m = cmts.[x]
                    if x > cmtStart.[ki] then put o (ReadOnlySpan comma)
                    put o (src.Slice(m.Start, m.Fol - m.Start))
                    put o (ReadOnlySpan(if v <> 0L && fols.Contains(struct (v, m.Author)) then tru else fals))
                    put o (src.Slice(m.Fol + 5, m.End - m.Fol - 5))
                put o (ReadOnlySpan closeC)
        | Route.Profile ->
            let pi = profOf.[key.[i]]
            if pi < 0 then c.Error(404, "profile not found")
            else
                let p = profs.[pi]
                let w = c.W
                w.WriteStartObject()
                w.WritePropertyName Json.N.profile
                w.WriteStartObject()
                w.WriteString(Json.N.username, aspan p.User p.UserL)
                if p.BioL < 0 then w.WriteNull Json.N.bio else w.WriteString(Json.N.bio, aspan p.Bio p.BioL)
                if p.ImgL < 0 then w.WriteNull Json.N.image else w.WriteString(Json.N.image, aspan p.Img p.ImgL)
                w.WriteBoolean(Json.N.following, v <> 0L && fols.Contains(struct (v, p.Id)))
                w.WriteEndObject()
                w.WriteEndObject()
        | r ->
            let g = b.PageOf i
            let feed = r = Route.Feed
            put o (ReadOnlySpan openN)
            for x in pageStart.[g] .. pageStart.[g] + pageLen.[g] - 1 do
                if x > pageStart.[g] then put o (ReadOnlySpan comma)
                if not (writeArt o pageIds.[x] false v feed) then failwith "list article without phase B row"
            put o (ReadOnlySpan closeN)
            let s = o.GetSpan 24
            let mutable n = 0
            Utf8Formatter.TryFormat(b.CountOf i, s, &n) |> ignore
            s.[n] <- '}'B
            o.Advance(n + 1)

    member private b.Finish(err: PgError) =
        let n = b.N
        Array.Copy(items, finished, n)
        b.N <- 0
        for i in 0 .. n - 1 do
            let c = finished.[i]
            try
                if isNull err && ok then b.Answer i
                else
                    if not (isNull err) then eprintfn "planner %O: %O" c.Route err
                    c.Error(500, "internal error")
            with e ->
                eprintfn "planner answer %O: %O" c.Route e
                c.Error(500, "internal error")
        Array.Clear(items, 0, n)
        release b // the next batch may go out before these responses are written
        for i in 0 .. n - 1 do
            let c = finished.[i]
            finished.[i] <- null
            try c.Finish() with e -> eprintfn "%O" e

    override b.Done(err) =
        if phase = 0 && isNull err && ok then
            (try b.AfterA() with e -> eprintfn "planner: %O" e; ok <- false)
            if ok && (arts.Count > 0 || favV.Count + folV.Count > 0) then
                phase <- 1
                b.Conn.Submit b |> ignore // a broken connection calls Done with an error
            else b.Finish null
        else b.Finish err

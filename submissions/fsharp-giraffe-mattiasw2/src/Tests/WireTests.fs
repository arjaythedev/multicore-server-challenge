module Tests.WireTests

open System
open System.Text
open System.Text.Json
open Xunit
open Engine
open global.Web

let private parse (json: string) = JsonDocument.Parse(json).RootElement
let private isError (r: Result<'a, string>) = match r with Error _ -> true | Ok _ -> false
let private text (body: Wire.Body) = Encoding.UTF8.GetString(body.Span)

let private query (pairs: (string * string) list) (name: string) =
    pairs |> List.tryFind (fun (k, _) -> k = name) |> Option.map snd

// ------------------------------------------------------------------ paging ------

[<Fact>]
let ``paging defaults to limit 20 offset 0`` () =
    Assert.Equal(Ok { Limit = 20L; Offset = 0L }, Wire.paging (query []))

[<Fact>]
let ``leading zeros are fine`` () =
    Assert.Equal(Ok { Limit = 5L; Offset = 5L }, Wire.paging (query [ "limit", "05"; "offset", "005" ]))

[<Theory>]
[<InlineData("limit", "0")>]
[<InlineData("limit", "101")>]
[<InlineData("limit", "-1")>]
[<InlineData("limit", "abc")>]
[<InlineData("limit", "")>]
[<InlineData("limit", "1.5")>]
[<InlineData("limit", "+5")>]
[<InlineData("limit", " 5")>]
[<InlineData("offset", "-1")>]
[<InlineData("offset", "abc")>]
[<InlineData("offset", "")>]
[<InlineData("offset", "99999999999999999999")>]
let ``out-of-range or non-integer paging is a 422`` (name: string, value: string) =
    Assert.True(isError (Wire.paging (query [ name, value ])))

[<Fact>]
let ``a large in-range offset is accepted`` () =
    Assert.Equal(Ok { Limit = 20L; Offset = 100000000L }, Wire.paging (query [ "offset", "100000000" ]))

// ------------------------------------------------------------------ filter ------

[<Fact>]
let ``tag beats author beats favorited`` () =
    Assert.Equal(ByTag "t", Wire.filter (query [ "favorited", "f"; "author", "a"; "tag", "t" ]))
    Assert.Equal(ByAuthor "a", Wire.filter (query [ "favorited", "f"; "author", "a" ]))
    Assert.Equal(FavoritedBy "f", Wire.filter (query [ "favorited", "f" ]))
    Assert.Equal(Everything, Wire.filter (query []))

[<Fact>]
let ``an empty filter value counts as not given`` () =
    Assert.Equal(ByAuthor "a", Wire.filter (query [ "tag", ""; "author", "a" ]))

// ------------------------------------------------------------------ bodies ------

[<Fact>]
let ``registration needs all three non-empty strings inside "user"`` () =
    Assert.Equal(
        Ok({ Username = "u"; Email = "e"; Password = "p" }: Wire.Registration),
        Wire.registration (parse """{"extra":1,"user":{"username":"u","email":"e","password":"p","admin":true}}""")
    )

[<Theory>]
[<InlineData("""{"user":{"username":"u","email":"e"}}""")>]
[<InlineData("""{"user":{"username":"","email":"e","password":"p"}}""")>]
[<InlineData("""{"user":{"username":"u","email":null,"password":"p"}}""")>]
[<InlineData("""{"user":{"username":123,"email":"e","password":"p"}}""")>]
[<InlineData("""{"username":"u","email":"e","password":"p"}""")>]
[<InlineData("""{"user":"u"}""")>]
[<InlineData("""{"User":{"username":"u","email":"e","password":"p"}}""")>]
[<InlineData("""[1]""")>]
let ``a bad registration is refused`` (json: string) =
    Assert.True(isError (Wire.registration (parse json)))

[<Fact>]
let ``a password over 72 bytes is refused, not truncated`` () =
    let json = $"""{{"user":{{"username":"u","email":"e","password":"{String('p', 73)}"}}}}"""
    Assert.True(isError (Wire.registration (parse json)))

[<Fact>]
let ``a user edit keeps absent and null fields unchanged`` () =
    match Wire.userEdit (parse """{"user":{"bio":null,"email":null}}""") with
    | Ok e -> Assert.Equal(({ Email = None; Username = None; Password = None; Bio = None; Image = None }: Wire.UserEdit), e)
    | Error m -> failwith m

[<Fact>]
let ``an empty bio is a value, an empty email is a 422`` () =
    Assert.Equal(Some "", (Wire.userEdit (parse """{"user":{"bio":""}}""") |> Result.map (fun e -> e.Bio) |> Result.defaultValue None))
    Assert.True(isError (Wire.userEdit (parse """{"user":{"email":""}}""")))
    Assert.True(isError (Wire.userEdit (parse """{"user":{"bio":5}}""")))

[<Theory>]
[<InlineData("""{"article":{"description":"d","body":"b"}}""")>]
[<InlineData("""{"article":{"title":"t","description":"","body":"b"}}""")>]
[<InlineData("""{"article":{"title":"t","description":"d","body":null}}""")>]
[<InlineData("""{"article":{"title":7,"description":"d","body":"b"}}""")>]
[<InlineData("""{"article":{"title":"t","description":"d","body":"b","tagList":"x"}}""")>]
[<InlineData("""{"article":{"title":"t","description":"d","body":"b","tagList":["ok",""]}}""")>]
[<InlineData("""{"article":{"title":"t","description":"d","body":"b","tagList":[1]}}""")>]
[<InlineData("""{"article":{"title":"t","description":"d","body":"b","tagList":[null]}}""")>]
[<InlineData("""{"title":"t","description":"d","body":"b"}""")>]
let ``a bad new article is refused`` (json: string) =
    Assert.True(isError (Wire.newArticle (parse json)))

[<Theory>]
[<InlineData("""{"article":{"title":"t","description":"d","body":"b"}}""")>]
[<InlineData("""{"article":{"title":"t","description":"d","body":"b","tagList":null}}""")>]
[<InlineData("""{"article":{"title":"t","description":"d","body":"b","tagList":[]}}""")>]
let ``no tags is an empty tag list`` (json: string) =
    match Wire.newArticle (parse json) with
    | Ok a -> Assert.Empty a.Tags
    | Error m -> failwith m

[<Fact>]
let ``a comment id must be a positive integer`` () =
    Assert.Equal(ValueSome 12L, Wire.commentId "12")
    Assert.Equal(ValueNone, Wire.commentId "abc")
    Assert.Equal(ValueNone, Wire.commentId "-1")

// ---------------------------------------------------------------- encoding ------

[<Fact>]
let ``timestamps are UTC with exactly three digits, truncated`` () =
    let d = DateTime(2025, 4, 1, 12, 0, 0, DateTimeKind.Utc).AddTicks(9_999_999L)
    Assert.Equal("2025-04-01T12:00:00.999Z", Wire.timestamp d)

[<Fact>]
let ``a profile's null bio and image are JSON null`` () =
    let p = { Username = "u"; Bio = None; Image = None; Following = false }
    Assert.Equal("""{"profile":{"username":"u","bio":null,"image":null,"following":false}}""", text (Wire.profile p))

[<Fact>]
let ``a list article has no body; a single article does`` () =
    // One shared card WITH a body (an article page in the same batch needed it): the list
    // still shows none.
    let card: Card =
        { Id = 1L; Slug = "s"; Title = "t"; Description = "d"; Body = Some "x"; TagList = [| "a"; "b" |]
          CreatedAt = DateTime(2025, 1, 1, 0, 0, 0, DateTimeKind.Utc); UpdatedAt = DateTime(2025, 1, 1, 0, 0, 0, DateTimeKind.Utc)
          FavoritesCount = 3L
          Author = { Id = 7L; Username = "u"; Bio = Some "b"; Image = None } }
    let a = { Card = card; Favorited = true; Following = true }
    let listed = text (Wire.articles { Articles = [ a ]; Count = 1000L })
    Assert.DoesNotContain("\"body\"", listed)
    Assert.Contains("\"articlesCount\":1000", listed)
    Assert.Contains("\"body\":\"x\"", text (Wire.article a))

[<Fact>]
let ``errors have the RealWorld shape`` () =
    Assert.Equal("""{"errors":{"body":["nope"]}}""", text (Wire.error "nope"))

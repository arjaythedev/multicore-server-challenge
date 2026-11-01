/// Our lockstep bcrypt against the reference, BCrypt.Net-Next: bit for bit, on random
/// passwords (ASCII, multibyte, up to bcrypt's 72 bytes), random salts and random batch sizes.
module Tests.BcryptTests

open System
open System.Text
open Xunit
open FsCheck
open FsCheck.FSharp
open Engine

[<Fact>]
let ``the initial state is pi's digits, as published`` () =
    let s = Bcrypt.initialState
    Assert.Equal(1042, s.Length)
    Assert.Equal(0x243F6A88u, s[0]) // P[0]
    Assert.Equal(0x8979FB1Bu, s[17]) // P[17]
    Assert.Equal(0xD1310BA6u, s[18]) // S0[0]
    Assert.Equal(0x4B7A70E9u, s[18 + 256]) // S1[0]
    Assert.Equal(0xE93D5A68u, s[18 + 512]) // S2[0]
    Assert.Equal(0x3A39CE37u, s[18 + 768]) // S3[0]
    Assert.Equal(0x3AC372E6u, s[1041]) // S3[255]

/// Characters of 1 to 4 UTF-8 bytes, so a password's bytes cross the 72-byte edge in every way.
let private passwordChar =
    Gen.frequency
        [ 6, Gen.choose (0x20, 0x7E) |> Gen.map (fun c -> string (char c))
          2, Gen.choose (0xA0, 0x7FF) |> Gen.map (fun c -> string (char c))
          1, Gen.choose (0x4E00, 0x9FFF) |> Gen.map (fun c -> string (char c))
          1, Gen.choose (0x1F600, 0x1F64F) |> Gen.map Char.ConvertFromUtf32 ]

/// Up to bcrypt's limit: the server refuses longer ones (Passwords.fits).
let private password =
    gen {
        let! n = Gen.choose (0, 40)
        let! chars = Gen.listOfLength n passwordChar
        let mutable s = ""
        for c in chars do
            if Encoding.UTF8.GetByteCount(s + c) <= 72 then s <- s + c
        return s
    }

let private salt = Gen.arrayOfLength 16 (Gen.choose (0, 255) |> Gen.map byte)

let private batch =
    gen {
        let! n = Gen.choose (1, 6)
        return! Gen.listOfLength n (Gen.zip password salt)
    }

[<Fact>]
let ``lockstep bcrypt equals BCrypt.Net-Next, bit for bit`` () =
    let property (inputs: (string * byte[]) list) =
        let inputs = Array.ofList inputs
        let ours =
            Bcrypt.raw 4 [| for p, s in inputs -> Bcrypt.key p, s |]
            |> Array.mapi (fun i h -> Bcrypt.format "$2a$" 4 (snd inputs[i]) h)
        let reference =
            inputs |> Array.map (fun (p, s) -> BCrypt.Net.BCrypt.HashPassword(p, "$2a$04$" + Bcrypt.encode s))
        ours = reference
    Check.One(Config.QuickThrowOnFailure.WithMaxTest(300), Prop.forAll (Arb.fromGen batch) property)

[<Fact>]
let ``the empty password, and 71 and 72 bytes (ASCII and multibyte)`` () =
    let s = Array.init 16 byte
    for p in [ ""; String('x', 72); String.replicate 36 "é"; String('x', 71) ] do
        let ours = Bcrypt.format "$2a$" 4 s (Array.exactlyOne (Bcrypt.raw 4 [| Bcrypt.key p, s |]))
        Assert.Equal(BCrypt.Net.BCrypt.HashPassword(p, "$2a$04$" + Bcrypt.encode s), ours)

[<Fact>]
let ``cost 10 both ways: our hash verifies in BCrypt.Net, theirs in ours`` () =
    let salt = Array.init 16 (fun i -> byte (i * 17))
    let ours = Bcrypt.format "$2a$" 10 salt (Array.exactlyOne (Bcrypt.raw 10 [| Bcrypt.key "password123", salt |]))
    Assert.True(BCrypt.Net.BCrypt.Verify("password123", ours))
    for revision in [ 'a'; 'b' ] do
        let theirs = BCrypt.Net.BCrypt.HashPassword("pässwörd", BCrypt.Net.BCrypt.GenerateSalt(10, revision))
        match Bcrypt.parse theirs with
        | Some stored -> Assert.Equal<byte[]>(stored.Hash, Array.exactlyOne (Bcrypt.raw stored.Cost [| Bcrypt.key "pässwörd", stored.Salt |]))
        | None -> failwith $"could not parse {theirs}"

[<Fact>]
let ``the server's own verify, and anything malformed is false`` () =
    let stored = BCrypt.Net.BCrypt.HashPassword("password123", 10)
    Assert.True((Passwords.verify "password123" stored).Result)
    Assert.False((Passwords.verify "password124" stored).Result)
    Assert.True((Passwords.verify "password123" ((Passwords.hash "password123").Result)).Result)
    for junk in [ ""; "nope"; "$2a$10$tooshort"; "$2x$10$" + String('a', 53); "$2a$99$" + String('a', 53); stored.Replace('$', '!') ] do
        Assert.False((Passwords.verify "password123" junk).Result)

/// bcrypt ($2a$/$2b$/$2y$), computing several hashes in lockstep.
///
/// One bcrypt is ~1 M Blowfish encryptions, each step feeding the next: a chain of dependent
/// S-box lookups, so a single hash leaves the CPU waiting on memory latency. Hashes of different
/// logins are independent, so this module steps several of them ("lanes") together: chain step
/// k of every lane, then step k + 1. Neighbouring steps then have no data dependency, and the
/// CPU's out-of-order engine overlaps them. The output is bcrypt's, bit for bit
/// (Tests/BcryptTests.fs checks it against BCrypt.Net-Next on random passwords and salts).
module Engine.Bcrypt

#nowarn "9" // NativePtr: the Blowfish state is pinned, and the rounds index it without bounds checks

open System
open System.Numerics
open System.Text
open Microsoft.FSharp.NativeInterop

// ------------------------------------------------------------------ constants ---------

/// One lane's Blowfish state: P (18 words), then the four S-boxes (4 × 256 words).
[<Literal>]
let private StateWords = 1042

/// Blowfish's initial state is the hexadecimal digits of pi's fractional part (P starts
/// 0x243F6A88). Computed here with Machin's formula, pi = 16 atan(1/5) - 4 atan(1/239), on
/// big integers, instead of pasting 1042 constants; the unit test checks words of it against
/// the published tables.
let initialState: uint32[] =
    let bits = StateWords * 32 + 64 // 64 guard bits absorb the truncation of ~7000 terms
    let scale = BigInteger.One <<< bits
    let arctanInverse (x: int) =
        let x2 = BigInteger(x * x)
        let mutable power = scale / BigInteger x
        let mutable sum = power
        let mutable k = 1
        while not power.IsZero do
            power <- power / x2
            let term = power / BigInteger(2 * k + 1)
            sum <- if k % 2 = 1 then sum - term else sum + term
            k <- k + 1
        sum
    let pi = BigInteger 16 * arctanInverse 5 - BigInteger 4 * arctanInverse 239
    let fraction = pi - BigInteger 3 * scale
    let word = BigInteger UInt32.MaxValue
    Array.init StateWords (fun i -> uint32 ((fraction >>> (bits - 32 * (i + 1))) &&& word))

/// "OrpheanBeholderScryDoubt", the text bcrypt encrypts 64 times.
let private magic =
    let b = Encoding.ASCII.GetBytes "OrpheanBeholderScryDoubt"
    Array.init 6 (fun i -> (uint32 b[4 * i] <<< 24) ||| (uint32 b[4 * i + 1] <<< 16) ||| (uint32 b[4 * i + 2] <<< 8) ||| uint32 b[4 * i + 3])

// ------------------------------------------------------------------ Blowfish ----------

// Each S-box is addressed as its own pointer (a constant offset from the state) and indexed by
// a byte: the JIT then knows the index is not negative and folds the offset into the load
// (`[p + 4*idx + 1096]`), where an int sum `offset + idx` costs an add and a sign extension.
let inline private f (s: nativeptr<uint32>) (x: uint32) =
    ((NativePtr.get s (int (byte (x >>> 24))) + NativePtr.get (NativePtr.add s 256) (int (byte (x >>> 16))))
     ^^^ NativePtr.get (NativePtr.add s 512) (int (byte (x >>> 8))))
    + NativePtr.get (NativePtr.add s 768) (int (byte x))

/// One Blowfish block with the lane state at `p`.
let inline private encipher (p: nativeptr<uint32>) (xl: byref<uint32>) (xr: byref<uint32>) =
    let s = NativePtr.add p 18
    let mutable l = xl ^^^ NativePtr.get p 0
    let mutable r = xr
    let mutable i = 1
    while i < 17 do
        r <- r ^^^ f s l ^^^ NativePtr.get p i
        l <- l ^^^ f s r ^^^ NativePtr.get p (i + 1)
        i <- i + 2
    xl <- r ^^^ NativePtr.get p 17
    xr <- l

/// Two Blowfish blocks, of two lanes, with their rounds interleaved: two independent chains of
/// S-box lookups in flight at once, all in registers.
let inline private encipher2
    (p0: nativeptr<uint32>)
    (p1: nativeptr<uint32>)
    (l0: byref<uint32>)
    (r0: byref<uint32>)
    (l1: byref<uint32>)
    (r1: byref<uint32>)
    =
    let s0 = NativePtr.add p0 18
    let s1 = NativePtr.add p1 18
    let mutable a = l0 ^^^ NativePtr.get p0 0
    let mutable b = r0
    let mutable c = l1 ^^^ NativePtr.get p1 0
    let mutable d = r1
    let mutable i = 1
    while i < 17 do
        b <- b ^^^ f s0 a ^^^ NativePtr.get p0 i
        d <- d ^^^ f s1 c ^^^ NativePtr.get p1 i
        a <- a ^^^ f s0 b ^^^ NativePtr.get p0 (i + 1)
        c <- c ^^^ f s1 d ^^^ NativePtr.get p1 (i + 1)
        i <- i + 2
    l0 <- b ^^^ NativePtr.get p0 17
    r0 <- a
    l1 <- d ^^^ NativePtr.get p1 17
    r1 <- c

/// One Feistel half-round of the lane at `p`: `y ^^^ F(x) ^^^ P[i]`. The S-boxes start 18 words
/// into the state, so only the lane's one pointer stays live.
let inline private half (p: nativeptr<uint32>) (i: int) (x: uint32) (y: uint32) =
    y ^^^ f (NativePtr.add p 18) x ^^^ NativePtr.get p i

/// Four Blowfish blocks, of four lanes, with their rounds interleaved. The 16 rounds are written
/// out: each P word is then a constant offset, and no round counter competes for the registers
/// that the eight chain words and four lane pointers already fill.
let inline private encipher4
    (p0: nativeptr<uint32>)
    (p1: nativeptr<uint32>)
    (p2: nativeptr<uint32>)
    (p3: nativeptr<uint32>)
    (x: nativeptr<uint32>)
    =
    let mutable a0 = NativePtr.get x 0 ^^^ NativePtr.get p0 0
    let mutable b0 = NativePtr.get x 1
    let mutable a1 = NativePtr.get x 2 ^^^ NativePtr.get p1 0
    let mutable b1 = NativePtr.get x 3
    let mutable a2 = NativePtr.get x 4 ^^^ NativePtr.get p2 0
    let mutable b2 = NativePtr.get x 5
    let mutable a3 = NativePtr.get x 6 ^^^ NativePtr.get p3 0
    let mutable b3 = NativePtr.get x 7
    b0 <- half p0 1 a0 b0
    b1 <- half p1 1 a1 b1
    b2 <- half p2 1 a2 b2
    b3 <- half p3 1 a3 b3
    a0 <- half p0 2 b0 a0
    a1 <- half p1 2 b1 a1
    a2 <- half p2 2 b2 a2
    a3 <- half p3 2 b3 a3
    b0 <- half p0 3 a0 b0
    b1 <- half p1 3 a1 b1
    b2 <- half p2 3 a2 b2
    b3 <- half p3 3 a3 b3
    a0 <- half p0 4 b0 a0
    a1 <- half p1 4 b1 a1
    a2 <- half p2 4 b2 a2
    a3 <- half p3 4 b3 a3
    b0 <- half p0 5 a0 b0
    b1 <- half p1 5 a1 b1
    b2 <- half p2 5 a2 b2
    b3 <- half p3 5 a3 b3
    a0 <- half p0 6 b0 a0
    a1 <- half p1 6 b1 a1
    a2 <- half p2 6 b2 a2
    a3 <- half p3 6 b3 a3
    b0 <- half p0 7 a0 b0
    b1 <- half p1 7 a1 b1
    b2 <- half p2 7 a2 b2
    b3 <- half p3 7 a3 b3
    a0 <- half p0 8 b0 a0
    a1 <- half p1 8 b1 a1
    a2 <- half p2 8 b2 a2
    a3 <- half p3 8 b3 a3
    b0 <- half p0 9 a0 b0
    b1 <- half p1 9 a1 b1
    b2 <- half p2 9 a2 b2
    b3 <- half p3 9 a3 b3
    a0 <- half p0 10 b0 a0
    a1 <- half p1 10 b1 a1
    a2 <- half p2 10 b2 a2
    a3 <- half p3 10 b3 a3
    b0 <- half p0 11 a0 b0
    b1 <- half p1 11 a1 b1
    b2 <- half p2 11 a2 b2
    b3 <- half p3 11 a3 b3
    a0 <- half p0 12 b0 a0
    a1 <- half p1 12 b1 a1
    a2 <- half p2 12 b2 a2
    a3 <- half p3 12 b3 a3
    b0 <- half p0 13 a0 b0
    b1 <- half p1 13 a1 b1
    b2 <- half p2 13 a2 b2
    b3 <- half p3 13 a3 b3
    a0 <- half p0 14 b0 a0
    a1 <- half p1 14 b1 a1
    a2 <- half p2 14 b2 a2
    a3 <- half p3 14 b3 a3
    b0 <- half p0 15 a0 b0
    b1 <- half p1 15 a1 b1
    b2 <- half p2 15 a2 b2
    b3 <- half p3 15 a3 b3
    a0 <- half p0 16 b0 a0
    a1 <- half p1 16 b1 a1
    a2 <- half p2 16 b2 a2
    a3 <- half p3 16 b3 a3
    NativePtr.set x 0 (b0 ^^^ NativePtr.get p0 17)
    NativePtr.set x 1 a0
    NativePtr.set x 2 (b1 ^^^ NativePtr.get p1 17)
    NativePtr.set x 3 a1
    NativePtr.set x 4 (b2 ^^^ NativePtr.get p2 17)
    NativePtr.set x 5 a2
    NativePtr.set x 6 (b3 ^^^ NativePtr.get p3 17)
    NativePtr.set x 7 a3

/// `expand` for exactly four lanes; the chains live in `x` (8 words) between blocks.
let private expand4
    (p: nativeptr<uint32>[])
    (k: nativeptr<uint32>[])
    (s: nativeptr<uint32>[])
    (x: nativeptr<uint32>)
    (salted: bool)
    =
    for lane in 0..3 do
        for i in 0..17 do
            NativePtr.set p[lane] i (NativePtr.get p[lane] i ^^^ NativePtr.get k[lane] i)
    for i in 0..7 do
        NativePtr.set x i 0u
    let p0, p1, p2, p3 = p[0], p[1], p[2], p[3]
    let mutable j = 0
    while j < StateWords do
        if salted then
            for lane in 0..3 do
                NativePtr.set x (2 * lane) (NativePtr.get x (2 * lane) ^^^ NativePtr.get s[lane] (j &&& 3))
                NativePtr.set x (2 * lane + 1) (NativePtr.get x (2 * lane + 1) ^^^ NativePtr.get s[lane] ((j + 1) &&& 3))
        encipher4 p0 p1 p2 p3 x
        NativePtr.set p0 j (NativePtr.get x 0)
        NativePtr.set p0 (j + 1) (NativePtr.get x 1)
        NativePtr.set p1 j (NativePtr.get x 2)
        NativePtr.set p1 (j + 1) (NativePtr.get x 3)
        NativePtr.set p2 j (NativePtr.get x 4)
        NativePtr.set p2 (j + 1) (NativePtr.get x 5)
        NativePtr.set p3 j (NativePtr.get x 6)
        NativePtr.set p3 (j + 1) (NativePtr.get x 7)
        j <- j + 2

/// `expand` for exactly two lanes, the pair's chains in registers and their rounds interleaved.
let private expand2 (p0: nativeptr<uint32>) (p1: nativeptr<uint32>) (k0: nativeptr<uint32>) (k1: nativeptr<uint32>) (s0: nativeptr<uint32>) (s1: nativeptr<uint32>) (salted: bool) =
    for i in 0..17 do
        NativePtr.set p0 i (NativePtr.get p0 i ^^^ NativePtr.get k0 i)
        NativePtr.set p1 i (NativePtr.get p1 i ^^^ NativePtr.get k1 i)
    let mutable l0 = 0u
    let mutable r0 = 0u
    let mutable l1 = 0u
    let mutable r1 = 0u
    let mutable j = 0
    if salted then
        while j < StateWords do
            l0 <- l0 ^^^ NativePtr.get s0 (j &&& 3)
            r0 <- r0 ^^^ NativePtr.get s0 ((j + 1) &&& 3)
            l1 <- l1 ^^^ NativePtr.get s1 (j &&& 3)
            r1 <- r1 ^^^ NativePtr.get s1 ((j + 1) &&& 3)
            encipher2 p0 p1 &l0 &r0 &l1 &r1
            NativePtr.set p0 j l0
            NativePtr.set p0 (j + 1) r0
            NativePtr.set p1 j l1
            NativePtr.set p1 (j + 1) r1
            j <- j + 2
    else
        while j < StateWords do
            encipher2 p0 p1 &l0 &r0 &l1 &r1
            NativePtr.set p0 j l0
            NativePtr.set p0 (j + 1) r0
            NativePtr.set p1 j l1
            NativePtr.set p1 (j + 1) r1
            j <- j + 2

/// Blowfish's key schedule, for every lane at once: P ^= the lane's 18 key words, then the
/// whole state is re-encrypted as a chain, each block XORed with the next two words of the
/// lane's salt (bcrypt's EksBlowfish) when `salted`, else with nothing (plain Blowfish).
let private expand
    (state: nativeptr<uint32>)
    (lanes: int)
    (keys: nativeptr<uint32>)
    (salts: nativeptr<uint32>)
    (salted: bool)
    (chain: nativeptr<uint32>)
    =
    for lane in 0 .. lanes - 1 do
        let p = NativePtr.add state (lane * StateWords)
        let k = NativePtr.add keys (lane * 18)
        for i in 0..17 do
            NativePtr.set p i (NativePtr.get p i ^^^ NativePtr.get k i)
        NativePtr.set chain (2 * lane) 0u
        NativePtr.set chain (2 * lane + 1) 0u
    let mutable j = 0
    while j < StateWords do
        // Step j of every lane: independent chains, so the CPU overlaps them.
        for lane in 0 .. lanes - 1 do
            let p = NativePtr.add state (lane * StateWords)
            let mutable xl = NativePtr.get chain (2 * lane)
            let mutable xr = NativePtr.get chain (2 * lane + 1)
            if salted then
                xl <- xl ^^^ NativePtr.get salts (lane * 4 + (j &&& 3))
                xr <- xr ^^^ NativePtr.get salts (lane * 4 + ((j + 1) &&& 3))
            encipher p &xl &xr
            NativePtr.set p j xl
            NativePtr.set p (j + 1) xr
            NativePtr.set chain (2 * lane) xl
            NativePtr.set chain (2 * lane + 1) xr
        j <- j + 2

/// 18 words from `bytes` repeated cyclically (Blowfish's key stream; bytes past 72 never count).
let private streamWords (bytes: byte[]) : uint32[] =
    let mutable at = 0
    Array.init 18 (fun _ ->
        let mutable w = 0u
        for _ in 1..4 do
            w <- (w <<< 8) ||| uint32 bytes[at]
            at <- (at + 1) % bytes.Length
        w)

/// bcrypt's raw 23 bytes for each (key, 16-byte salt), all with the same cost. The key is the
/// password's UTF-8 bytes followed by a NUL (the $2a$/$2b$ convention).
let raw (cost: int) (inputs: (byte[] * byte[])[]) : byte[][] =
    // Three lanes go as four (a copy of the last one, its result dropped): one interleaved quad
    // costs less than a pair and a single.
    let given = inputs.Length
    let inputs = if given % 4 = 3 then Array.append inputs [| inputs[given - 1] |] else inputs
    let lanes = inputs.Length
    let state = Array.zeroCreate<uint32> (lanes * StateWords)
    let keys = Array.zeroCreate<uint32> (lanes * 18)
    let saltKeys = Array.zeroCreate<uint32> (lanes * 18)
    let salts = Array.zeroCreate<uint32> (lanes * 4)
    let chain = Array.zeroCreate<uint32> (lanes * 2)
    let text = Array.zeroCreate<uint32> (lanes * 6)
    for lane in 0 .. lanes - 1 do
        let key, salt = inputs[lane]
        Array.blit initialState 0 state (lane * StateWords) StateWords
        Array.blit (streamWords key) 0 keys (lane * 18) 18
        let saltStream = streamWords salt
        Array.blit saltStream 0 saltKeys (lane * 18) 18
        Array.blit saltStream 0 salts (lane * 4) 4 // the salt's 4 words (16 bytes)
        Array.blit magic 0 text (lane * 6) 6
    use pState = fixed state
    use pKeys = fixed keys
    use pSaltKeys = fixed saltKeys
    use pSalts = fixed salts
    use pChain = fixed chain
    use pText = fixed text
    // Lanes go in fours through expand4, then a pair through expand2 (rounds interleaved), and
    // an odd one out through expand.
    let quads = lanes / 4
    let lane l = NativePtr.add pState (l * StateWords)
    let words (p: nativeptr<uint32>) l n = NativePtr.add p (l * n)
    let x = Array.zeroCreate<uint32> 8
    use pX = fixed x
    let schedule (keys: nativeptr<uint32>) (salted: bool) =
        for q in 0 .. quads - 1 do
            let ls = [| 4 * q .. 4 * q + 3 |]
            expand4 (ls |> Array.map lane) (ls |> Array.map (fun l -> words keys l 18)) (ls |> Array.map (fun l -> words pSalts l 4)) pX salted
        let mutable l = 4 * quads
        if lanes - l >= 2 then
            expand2 (lane l) (lane (l + 1)) (words keys l 18) (words keys (l + 1) 18) (words pSalts l 4) (words pSalts (l + 1) 4) salted
            l <- l + 2
        if l < lanes then
            expand (lane l) 1 (words keys l 18) (words pSalts l 4) salted pChain
    schedule pKeys true
    for _ in 1 .. (1 <<< cost) do
        schedule pKeys false
        schedule pSaltKeys false
    for _ in 1..64 do
        for block in 0..2 do
            for lane in 0 .. lanes - 1 do
                let p = NativePtr.add pState (lane * StateWords)
                let t = NativePtr.add pText (lane * 6 + 2 * block)
                let mutable xl = NativePtr.get t 0
                let mutable xr = NativePtr.get t 1
                encipher p &xl &xr
                NativePtr.set t 0 xl
                NativePtr.set t 1 xr
    Array.init given (fun lane ->
        Array.init 23 (fun i -> byte (text[lane * 6 + i / 4] >>> (24 - 8 * (i % 4)))))

// ------------------------------------------------------------------ the string ---------

let private alphabet = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

let private alphabetIndex =
    let index = Array.create 128 -1
    alphabet |> String.iteri (fun i c -> index[int c] <- i)
    index

/// bcrypt's base64 (its own alphabet, no padding).
let encode (bytes: byte[]) : string =
    let sb = StringBuilder()
    let mutable i = 0
    while i < bytes.Length do
        let c1 = int bytes[i]
        sb.Append(alphabet[c1 >>> 2]) |> ignore
        if i + 1 >= bytes.Length then
            sb.Append(alphabet[(c1 &&& 3) <<< 4]) |> ignore
        else
            let c2 = int bytes[i + 1]
            sb.Append(alphabet[((c1 &&& 3) <<< 4) ||| (c2 >>> 4)]) |> ignore
            if i + 2 >= bytes.Length then
                sb.Append(alphabet[(c2 &&& 15) <<< 2]) |> ignore
            else
                let c3 = int bytes[i + 2]
                sb.Append(alphabet[((c2 &&& 15) <<< 2) ||| (c3 >>> 6)]).Append(alphabet[c3 &&& 63]) |> ignore
        i <- i + 3
    sb.ToString()

/// `count` bytes from bcrypt base64, or None if a character is outside the alphabet.
let decode (text: string) (count: int) : byte[] option =
    let digit (i: int) =
        if i < text.Length && int text[i] < 128 then alphabetIndex[int text[i]] else -1
    let out = Array.zeroCreate<byte> count
    let mutable n = 0
    let mutable i = 0
    let mutable ok = true
    while ok && n < count do
        let d1, d2 = digit i, digit (i + 1)
        if d1 < 0 || d2 < 0 then
            ok <- false
        else
            out[n] <- byte ((d1 <<< 2) ||| ((d2 &&& 0x30) >>> 4))
            n <- n + 1
            if n < count then
                let d3 = digit (i + 2)
                if d3 < 0 then
                    ok <- false
                else
                    out[n] <- byte (((d2 &&& 0x0F) <<< 4) ||| ((d3 &&& 0x3C) >>> 2))
                    n <- n + 1
                    if n < count then
                        let d4 = digit (i + 3)
                        if d4 < 0 then
                            ok <- false
                        else
                            out[n] <- byte (((d3 &&& 0x03) <<< 6) ||| d4)
                            n <- n + 1
            i <- i + 4
    if ok then Some out else None

/// A stored hash this module computes itself: its revision, cost, salt and 23 hash bytes.
type Stored =
    { Revision: string
      Cost: int
      Salt: byte[]
      Hash: byte[] }

/// `$2a$` / `$2b$` / `$2y$`, a two-digit cost from 4 to 31, 22 + 31 characters of base64.
/// Anything else is None (and Passwords hands it to BCrypt.Net-Next).
let parse (stored: string) : Stored option =
    if isNull stored || stored.Length <> 60 || stored[0] <> '$' || stored[1] <> '2' || stored[3] <> '$' || stored[6] <> '$' then
        None
    else
        let revision = stored.Substring(0, 4)
        match revision, Int32.TryParse(stored.AsSpan(4, 2)) with
        | ("$2a$" | "$2b$" | "$2y$"), (true, cost) when cost >= 4 && cost <= 31 ->
            match decode (stored.Substring(7, 22)) 16, decode (stored.Substring(29, 31)) 23 with
            | Some salt, Some hash ->
                Some
                    { Revision = revision
                      Cost = cost
                      Salt = salt
                      Hash = hash }
            | _ -> None
        | _ -> None

/// The key bcrypt hashes: the password's UTF-8 bytes and a NUL.
let key (password: string) : byte[] = Encoding.UTF8.GetBytes(password + "\000")

/// The stored form of a hash.
let format (revision: string) (cost: int) (salt: byte[]) (hash: byte[]) : string =
    $"{revision}{cost:D2}${encode salt}{encode hash}"

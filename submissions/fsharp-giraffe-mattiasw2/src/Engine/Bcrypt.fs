/// bcrypt ($2a$/$2b$/$2y$), computing several hashes in lockstep.
///
/// One bcrypt is ~1 M Blowfish encryptions, each step feeding the next: a chain of dependent
/// S-box lookups, so a single hash leaves the CPU waiting on memory latency. Hashes of different
/// logins are independent, so several of them ("lanes") are stepped together: chain step k of
/// every lane, then step k + 1. Neighbouring steps then have no data dependency, and the CPU's
/// out-of-order engine overlaps them.
///
/// The Blowfish itself is C and assembly (native/cbcrypt.c, native/gen-bcrypt-x86.py), built by
/// native/build.sh into libcbcrypt.so and called here. This module chooses the kernel and the
/// width, and reads and writes the stored form. The output is bcrypt's, bit for bit
/// (Tests/BcryptTests.fs checks every kernel at every width against BCrypt.Net-Next).
module Engine.Bcrypt

#nowarn "9" // NativePtr: the buffers handed to the library live on the stack

open System
open System.Diagnostics
open System.Numerics
open System.Runtime.InteropServices
open System.Text
open Microsoft.FSharp.NativeInterop

// ------------------------------------------------------------------ constants ---------

/// One lane's Blowfish state: P (18 words), then the four S-boxes (4 × 256 words).
[<Literal>]
let private StateWords = 1042

/// Blowfish's initial state is the hexadecimal digits of pi's fractional part (P starts
/// 0x243F6A88). Computed here with Machin's formula, pi = 16 atan(1/5) - 4 atan(1/239), on
/// big integers, instead of pasting 1042 constants; the unit test checks words of it against
/// the published tables. Pinned for good, so the library reads it in place.
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
    let state = GC.AllocateUninitializedArray<uint32>(StateWords, pinned = true)
    for i in 0 .. StateWords - 1 do
        state[i] <- uint32 ((fraction >>> (bits - 32 * (i + 1))) &&& word)
    state

// ------------------------------------------------------------------ the library --------

/// The kernels this CPU can run, as a bit mask (bit k: kernel k).
[<DllImport("cbcrypt", ExactSpelling = true)>]
extern int private cbcrypt_kernels()

/// `lanes` hashes of one cost: 72 key bytes, a key length and 16 salt bytes a lane in, 23 hash
/// bytes a lane out. 0, or -1 for an argument out of range (native/cbcrypt.c).
[<DllImport("cbcrypt", ExactSpelling = true)>]
extern int private cbcrypt_raw(uint32* init, int kernel, int cost, int lanes, byte* keys, int* keyLengths, byte* salts, byte* hashes)

/// `initialState` where it is pinned.
let private initial: nativeptr<uint32> =
    NativePtr.ofNativeInt (Marshal.UnsafeAddrOfPinnedArrayElement(initialState, 0))

/// The most hashes one call steps together.
[<Literal>]
let MaxLanes = 6

/// A kernel is the code of the cost loop: 0 is C, the others assembly that differs in how a
/// round takes its four S-box index bytes apart. Which is fastest depends on the CPU.
let kernelNames = [| "c"; "ah"; "bextr"; "shrx" |]

/// The kernels this CPU can run (the assembly ones need x86-64 with BMI1 and BMI2).
let kernels: int list =
    let mask = cbcrypt_kernels ()
    [ for k in 0 .. kernelNames.Length - 1 do
          if (mask >>> k) &&& 1 = 1 then
              k ]

/// bcrypt's raw 23 bytes for each (key, 16-byte salt), all with the same cost, computed by
/// `kernel`, MaxLanes at a time. The key is the password's UTF-8 bytes followed by a NUL (the
/// $2a$/$2b$ convention); bytes past 72 never count.
let rawWith (kernel: int) (cost: int) (inputs: (byte[] * byte[])[]) : byte[][] =
    let keys = NativePtr.stackalloc<byte> (MaxLanes * 72)
    let lengths = NativePtr.stackalloc<int> MaxLanes
    let salts = NativePtr.stackalloc<byte> (MaxLanes * 16)
    let hashes = NativePtr.stackalloc<byte> (MaxLanes * 23)
    let out = Array.zeroCreate<byte[]> inputs.Length
    let mutable first = 0
    while first < inputs.Length do
        let lanes = min MaxLanes (inputs.Length - first)
        for lane in 0 .. lanes - 1 do
            let key, salt = inputs[first + lane]
            if key.Length = 0 || salt.Length <> 16 then
                invalidArg (nameof inputs) "a key of at least one byte and a salt of 16"
            let length = min key.Length 72
            key.AsSpan(0, length).CopyTo(Span<byte>(NativePtr.toVoidPtr (NativePtr.add keys (lane * 72)), 72))
            NativePtr.set lengths lane length
            salt.AsSpan().CopyTo(Span<byte>(NativePtr.toVoidPtr (NativePtr.add salts (lane * 16)), 16))
        if cbcrypt_raw (initial, kernel, cost, lanes, keys, lengths, salts, hashes) <> 0 then
            invalidOp $"bcrypt: kernel {kernel}, cost {cost}, {lanes} lanes refused"
        for lane in 0 .. lanes - 1 do
            out[first + lane] <- Span<byte>(NativePtr.toVoidPtr (NativePtr.add hashes (lane * 23)), 23).ToArray()
        first <- first + lanes
    out

/// Milliseconds a hash of cost 10 takes `kernel` at `lanes` lanes: the best of three runs at
/// cost 6, a sixteenth of the work (a run is 2-3 ms).
let private time (kernel: int) (lanes: int) : float =
    let inputs = Array.init lanes (fun l -> [| byte (l + 1); 0uy |], Array.create 16 (byte l))
    let mutable best = Double.MaxValue
    for _ in 1..3 do
        let started = Stopwatch.GetTimestamp()
        rawWith kernel 6 inputs |> ignore
        best <- min best (Stopwatch.GetElapsedTime(started).TotalMilliseconds * 16.0 / float lanes)
    best

/// The kernel and the width that hash fastest on this CPU, timed here (~0.2 s): among `wanted`
/// kernels (a name of kernelNames, anything else: all this CPU has) and at exactly `width`
/// lanes (0: 1 to MaxLanes; then the narrowest width within 3% of the best, since a batch is
/// not always full). Returns (kernel, width, ms per cost-10 hash).
let calibrate (wanted: string) (width: int) : int * int * float =
    let candidates =
        match kernels |> List.filter (fun k -> kernelNames[k] = wanted) with
        | [] -> kernels
        | named -> named
    let widths = if width >= 1 then [ min width MaxLanes ] else [ 1..MaxLanes ]
    let timed = [ for w in widths -> w, candidates |> List.map (fun k -> k, time k w) |> List.minBy snd ]
    let fastest = timed |> List.map (fun (_, (_, ms)) -> ms) |> List.min
    let w, (k, ms) = timed |> List.find (fun (_, (_, ms)) -> ms <= fastest * 1.03)
    k, w, ms

/// The kernel `raw` uses: Passwords.start sets it from `calibrate`; before that, the measured best.
let mutable private chosen = -1

let choose (kernel: int) : unit = chosen <- kernel

/// `rawWith` the chosen kernel.
let raw (cost: int) (inputs: (byte[] * byte[])[]) : byte[][] =
    if chosen < 0 then
        let k, _, _ = calibrate "" 0
        chosen <- k
    rawWith chosen cost inputs

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

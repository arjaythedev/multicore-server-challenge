// auth.rs: SHA-256 and HMAC-SHA256 (the JWT's HS256 with the secret's ipad/opad midstates computed once), JWT
// verification and issuing, and bcrypt with several hashes run in lockstep. The Rust's x86 SHA-NI path has no Swift
// counterpart (Swift doesn't reach CPU intrinsics), so SHA-256 is the Rust's portable compression function.
import Glibc

typealias SHA256State = InlineArray<8, UInt32>
typealias Digest32 = InlineArray<32, UInt8>

private let sha256H0: SHA256State = [
    0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
]

private let sha256K: InlineArray<64, UInt32> = [
    0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
    0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
    0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
    0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
    0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
    0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
    0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
    0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
]

@inline(__always) private func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { x >> n | x << (32 - n) }

@inline(__always) private func compressWords(_ state: inout SHA256State, _ words: InlineArray<16, UInt32>) {
    var w = words
    var a = state[0], b = state[1], c = state[2], d = state[3]
    var e = state[4], f = state[5], g = state[6], h = state[7]
    for i in 0..<64 {
        if i >= 16 {
            let w15 = w[(i + 1) & 15]
            let w2 = w[(i + 14) & 15]
            let s0 = rotr(w15, 7) ^ rotr(w15, 18) ^ (w15 >> 3)
            let s1 = rotr(w2, 17) ^ rotr(w2, 19) ^ (w2 >> 10)
            w[i & 15] = w[i & 15] &+ s0 &+ w[(i + 9) & 15] &+ s1
        }
        let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
        let ch = (e & f) ^ (~e & g)
        let temp1 = h &+ s1 &+ ch &+ sha256K[i] &+ w[i & 15]
        let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
        let maj = (a & b) ^ (a & c) ^ (b & c)
        let temp2 = s0 &+ maj
        h = g
        g = f
        f = e
        e = d &+ temp1
        d = c
        c = b
        b = a
        a = temp1 &+ temp2
    }
    state[0] &+= a
    state[1] &+= b
    state[2] &+= c
    state[3] &+= d
    state[4] &+= e
    state[5] &+= f
    state[6] &+= g
    state[7] &+= h
}

/// Compresses the 64-byte block at `offset` of `data`.
@inline(__always) private func compressBlock(_ state: inout SHA256State, _ data: RawSpan, at offset: Int = 0) {
    var w = InlineArray<16, UInt32>(repeating: 0)
    for i in 0..<16 { w[i] = data.load(fromByteOffset: offset + 4 * i, as: UInt32.self, .bigEndian) }
    compressWords(&state, w)
}

private func sha256(from initial: SHA256State, priorBytes: UInt64, _ data: Span<UInt8>) -> SHA256State {
    var state = initial
    let full = data.count / 64
    for i in 0..<full { compressBlock(&state, data.bytes, at: 64 * i) }
    let rem = data.count - 64 * full
    let totalBits = (priorBytes + UInt64(data.count)) * 8
    var tail = InlineArray<64, UInt8>(repeating: 0)
    for i in 0..<rem { tail[i] = data[64 * full + i] }
    tail[rem] = 0x80
    if rem >= 56 {
        compressBlock(&state, tail.span.bytes)
        tail = InlineArray(repeating: 0)
    }
    for i in 0..<8 { tail[56 + i] = UInt8(truncatingIfNeeded: totalBits >> (56 - 8 * UInt64(i))) }
    compressBlock(&state, tail.span.bytes)
    return state
}

@inline(__always) private func stateBytes(_ state: SHA256State) -> Digest32 {
    Digest32 { i in UInt8(truncatingIfNeeded: state[i >> 2] >> (24 - 8 * UInt32(i & 3))) }
}

func sha256Digest(_ data: Span<UInt8>) -> Digest32 {
    stateBytes(sha256(from: sha256H0, priorBytes: 0, data))
}

func hmacSHA256(key: borrowing [UInt8], _ data: Span<UInt8>) -> Digest32 {
    TokenSigner(secret: key).sign(data)
}

private let jwtHeaderStandard: StaticString = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
private let jwtHeaderReordered: StaticString = "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9"
private let jwtHeaderMinimal: StaticString = "eyJhbGciOiJIUzI1NiJ9"

private enum FlatClaims {
    /// Not a flat payload: parse it fully.
    case fallback
    case invalid
    case valid(Int64)
}

@inline(__always) private func skipWhitespace(_ buf: Span<UInt8>, _ from: Int) -> Int {
    var pos = from
    while pos < buf.count {
        switch buf[pos] {
        case 0x20, 0x09, 0x0D, 0x0A: pos += 1
        default: return pos
        }
    }
    return pos
}

/// The fast path for flat payloads with no escapes and no nested values (`scan_flat_claims`).
private func scanFlatClaims(_ buf: Span<UInt8>, now: Double) -> FlatClaims {
    if findByte(buf, 0x5C) != nil { return .fallback }
    var i = skipWhitespace(buf, 0)
    if i >= buf.count || buf[i] != 0x7B { return .invalid }
    i = skipWhitespace(buf, i + 1)
    if i < buf.count && buf[i] == 0x7D { return .invalid }
    var sub: Int64?
    var exp: Double?
    var nbf: Double?
    while true {
        if i >= buf.count || buf[i] != 0x22 { return .fallback }
        i += 1
        let k0 = i
        while i < buf.count && buf[i] != 0x22 {
            if buf[i] < 0x20 { return .invalid }
            i += 1
        }
        if i >= buf.count { return .invalid }
        let key = buf.extracting(k0..<i)
        i = skipWhitespace(buf, i + 1)
        if i >= buf.count || buf[i] != 0x3A { return .invalid }
        i = skipWhitespace(buf, i + 1)
        if i >= buf.count { return .invalid }
        if spanEqual(key, "sub") {
            if buf[i] != 0x22 { return .invalid }
            i += 1
            let v0 = i
            var uid: Int64 = 0
            while i < buf.count && buf[i] != 0x22 {
                let ch = buf[i]
                guard (0x30...0x39).contains(ch) else { return .invalid }
                let (m, o1) = uid.multipliedReportingOverflow(by: 10)
                let (s, o2) = m.addingReportingOverflow(Int64(ch - 0x30))
                if o1 || o2 { return .fallback }
                uid = s
                i += 1
            }
            if i >= buf.count || i == v0 || uid <= 0 { return .invalid }
            i += 1
            sub = uid
        } else if spanEqual(key, "exp") || spanEqual(key, "nbf") || spanEqual(key, "iat") {
            let negative = buf[i] == 0x2D
            if negative { i += 1 }
            let d0 = i
            var value: Int64 = 0
            while i < buf.count && (0x30...0x39).contains(buf[i]) {
                let (m, o1) = value.multipliedReportingOverflow(by: 10)
                let digit = Int64(buf[i] - 0x30)
                let (s, o2) = negative ? m.subtractingReportingOverflow(digit) : m.addingReportingOverflow(digit)
                if o1 || o2 { return .fallback }
                value = s
                i += 1
            }
            if i == d0 { return .invalid }
            if i < buf.count && (buf[i] == 0x2E || buf[i] == 0x65 || buf[i] == 0x45) { return .fallback }
            if spanEqual(key, "exp") {
                exp = Double(value)
            } else if spanEqual(key, "nbf") {
                nbf = Double(value)
            }
        } else {
            return .fallback
        }
        i = skipWhitespace(buf, i)
        if i >= buf.count { return .invalid }
        if buf[i] == 0x2C {
            i = skipWhitespace(buf, i + 1)
            continue
        } else if buf[i] == 0x7D {
            i = skipWhitespace(buf, i + 1)
            if i != buf.count { return .invalid }
            break
        } else {
            return .fallback
        }
    }
    guard let exp, now < exp else { return .invalid }
    if let nbf, now < nbf { return .invalid }
    guard let sub else { return .invalid }
    return .valid(sub)
}

@inline(__always) private func constantTimeEqual32(_ a: Digest32, _ b: Span<UInt8>) -> Bool {
    guard b.count >= 32 else { return false }
    var diff: UInt8 = 0
    for i in 0..<32 { diff |= a[i] ^ b[i] }
    return diff == 0
}

/// HS256 with the secret's ipad/opad midstates precomputed: each signature costs the message's blocks plus one.
struct TokenSigner: Sendable {
    private var ipadState: SHA256State
    private var opadState: SHA256State

    init(secret: borrowing [UInt8]) {
        var block = InlineArray<64, UInt8>(repeating: 0)
        if secret.count > 64 {
            let hashed = sha256Digest(secret.span)
            for i in 0..<32 { block[i] = hashed[i] }
        } else {
            for i in 0..<secret.count { block[i] = secret[i] }
        }
        let ipad = InlineArray<64, UInt8> { 0x36 ^ block[$0] }
        let opad = InlineArray<64, UInt8> { 0x5C ^ block[$0] }
        ipadState = sha256H0
        opadState = sha256H0
        compressBlock(&ipadState, ipad.span.bytes)
        compressBlock(&opadState, opad.span.bytes)
    }

    func sign(_ data: Span<UInt8>) -> Digest32 {
        let inner = sha256(from: ipadState, priorBytes: 64, data)
        let words: InlineArray<16, UInt32> = [
            inner[0], inner[1], inner[2], inner[3], inner[4], inner[5], inner[6], inner[7],
            0x8000_0000, 0, 0, 0, 0, 0, 0, 768,
        ]
        var outer = opadState
        compressWords(&outer, words)
        return stateBytes(outer)
    }

    /// The user id of a valid token (signature, `alg`, `exp`, `nbf`), nil otherwise.
    func verify(_ token: Span<UInt8>) -> Int64? {
        guard let dot1 = findByte(token, 0x2E), let dot2 = findByte(token, 0x2E, from: dot1 + 1) else { return nil }
        let header = token.extracting(0..<dot1)
        let payload64 = token.extracting((dot1 + 1)..<dot2)
        let signature64 = token.extracting((dot2 + 1)..<token.count)
        if findByte(signature64, 0x2E) != nil { return nil }

        var signature = InlineArray<48, UInt8>(repeating: 0)
        var signatureSpan = signature.mutableSpan
        guard b64UrlDecode(signature64, into: &signatureSpan) == 32 else { return nil }
        let expected = sign(token.extracting(0..<dot2))
        guard constantTimeEqual32(expected, signature.span) else { return nil }

        if !spanEqual(header, jwtHeaderStandard) && !spanEqual(header, jwtHeaderReordered) && !spanEqual(header, jwtHeaderMinimal) {
            if header.count > 340 { return nil }
            var headerBytes = InlineArray<256, UInt8>(repeating: 0)
            var headerSpan = headerBytes.mutableSpan
            guard let n = b64UrlDecode(header, into: &headerSpan),
                  let alg = parseJson(headerBytes.span.extracting(0..<n))?.get("alg")?.string,
                  bytesEqual(alg, "HS256") else { return nil }
        }

        let now = unixNowF64()
        if payload64.count <= 680 {
            var payload = InlineArray<512, UInt8>(repeating: 0)
            var payloadSpan = payload.mutableSpan
            guard let n = b64UrlDecode(payload64, into: &payloadSpan) else { return nil }
            return claims(payload.span.extracting(0..<n), now: now)
        }
        guard let payload = b64UrlDecodeArray(payload64) else { return nil }
        return claims(payload.span, now: now)
    }

    private func claims(_ payload: Span<UInt8>, now: Double) -> Int64? {
        switch scanFlatClaims(payload, now: now) {
        case .valid(let uid): return uid
        case .invalid: return nil
        case .fallback: break
        }
        guard let obj = parseJson(payload)?.object, let exp = obj.get("exp")?.number, now < exp else { return nil }
        if let nbf = obj.get("nbf") {
            guard let n = nbf.number, now >= n else { return nil }
        }
        if let iat = obj.get("iat"), iat.number == nil { return nil }
        guard let sub = obj.get("sub")?.string, !sub.isEmpty, sub.allSatisfy({ (0x30...0x39).contains($0) }),
              let uid = Int64(String(decoding: sub, as: UTF8.self)), uid > 0 else { return nil }
        return uid
    }

    /// A token for `userID`, valid 30 days.
    func issue(_ userID: Int64) -> [UInt8] {
        let iat = unixNowSecs()
        var payload = ByteBuffer(capacity: 96)
        payload.append("{\"exp\":")
        appendU64(&payload, UInt64(iat + 30 * 86_400))
        payload.append(",\"iat\":")
        appendU64(&payload, UInt64(iat))
        payload.append(",\"sub\":\"")
        appendU64(&payload, UInt64(userID))
        payload.append("\"}")

        var token = ByteBuffer(capacity: 160)
        token.append("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.")
        b64UrlEncode(payload.span, into: &token)
        let signature = sign(token.span)
        token.append(0x2E)
        b64UrlEncode(signature.span, into: &token)
        return token.take()
    }
}

// ---------- bcrypt ----------

/// One Blowfish state, the P-array and the four S-boxes (BF_S[box][i] at s[256 * box + i]). The Rust pads it to a
/// 64-byte line; Swift has no alignment attribute, so it is 4,168 bytes, packed.
struct BfState: BitwiseCopyable {
    var p: InlineArray<18, UInt32>
    var s: InlineArray<1024, UInt32>

    static let initial = BfState(p: bfInitialP, s: bfInitialS)
}

typealias BcryptDigest = InlineArray<23, UInt8>
typealias BcryptSalt = InlineArray<16, UInt8>

/// F of lane `k`'s state, its S-boxes read in place: passing `st[k].s` as an argument would copy all 4 KB of them
/// on every call (a `borrowing` parameter of a copyable value read through a subscript is still a copy).
@inline(__always) private func feistel<let n: Int>(_ st: borrowing InlineArray<n, BfState>, _ k: Int, _ x: UInt32) -> UInt32 {
    let a = st[k].s[Int(x >> 24)]
    let b = st[k].s[256 + Int(x >> 16 & 0xFF)]
    let c = st[k].s[512 + Int(x >> 8 & 0xFF)]
    let d = st[k].s[768 + Int(x & 0xFF)]
    return ((a &+ b) ^ c) &+ d
}

/// 16-round Blowfish in each of `n` states, interleaved round by round so their S-box loads overlap.
@inline(__always) private func encipherLanes<let n: Int>(_ st: borrowing InlineArray<n, BfState>,
                                                          _ l: inout InlineArray<n, UInt32>, _ r: inout InlineArray<n, UInt32>) {
    for pair in 0..<8 {
        for k in 0..<n {
            l[k] ^= st[k].p[2 * pair]
            r[k] ^= feistel(st, k, l[k])
        }
        for k in 0..<n {
            r[k] ^= st[k].p[2 * pair + 1]
            l[k] ^= feistel(st, k, r[k])
        }
    }
    for k in 0..<n {
        let nl = r[k] ^ st[k].p[17]
        let nr = l[k] ^ st[k].p[16]
        l[k] = nl
        r[k] = nr
    }
}

/// The 32-bit words a key (the password and its NUL) and a salt contribute (`KeyMaterial`).
struct KeyMaterial: BitwiseCopyable {
    var keyP: InlineArray<18, UInt32>
    var salt4: InlineArray<4, UInt32>
    var salt18: InlineArray<18, UInt32>

    init(password: borrowing [UInt8], salt: BcryptSalt) {
        // The key is the password (at most 72 bytes) and its NUL, cycled through 18 words (next_be_word).
        let length = min(password.count, 72) + 1
        keyP = InlineArray(repeating: 0)
        var cursor = 0
        for i in 0..<18 {
            var w: UInt32 = 0
            for _ in 0..<4 {
                if cursor >= length { cursor = 0 }
                w = w << 8 | UInt32(cursor < length - 1 ? password[cursor] : 0)
                cursor += 1
            }
            keyP[i] = w
        }
        salt4 = InlineArray(repeating: 0)
        for i in 0..<4 {
            salt4[i] = UInt32(salt[4 * i]) << 24 | UInt32(salt[4 * i + 1]) << 16 | UInt32(salt[4 * i + 2]) << 8 | UInt32(salt[4 * i + 3])
        }
        salt18 = InlineArray(repeating: 0)
        for i in 0..<18 { salt18[i] = salt4[i & 3] }
    }
}

@inline(__always) private func eksExpand<let n: Int>(_ st: inout InlineArray<n, BfState>, _ mats: borrowing InlineArray<n, KeyMaterial>,
                                                      withSalt: Bool, saltAsKey: Bool) {
    for k in 0..<n {
        for i in 0..<18 { st[k].p[i] ^= saltAsKey ? mats[k].salt18[i] : mats[k].keyP[i] }
    }
    var l = InlineArray<n, UInt32>(repeating: 0)
    var r = InlineArray<n, UInt32>(repeating: 0)
    var sIdx = 0
    for i in 0..<9 {
        if withSalt {
            for k in 0..<n {
                l[k] ^= mats[k].salt4[sIdx & 3]
                r[k] ^= mats[k].salt4[(sIdx + 1) & 3]
            }
            sIdx += 2
        }
        encipherLanes(st, &l, &r)
        for k in 0..<n {
            st[k].p[2 * i] = l[k]
            st[k].p[2 * i + 1] = r[k]
        }
    }
    for pair in 0..<512 {
        if withSalt {
            for k in 0..<n {
                l[k] ^= mats[k].salt4[sIdx & 3]
                r[k] ^= mats[k].salt4[(sIdx + 1) & 3]
            }
            sIdx += 2
        }
        encipherLanes(st, &l, &r)
        for k in 0..<n {
            st[k].s[2 * pair] = l[k]
            st[k].s[2 * pair + 1] = r[k]
        }
    }
}

/// Which family of the generated key-only expansion kernels runs (BcryptKernels.swift), as the Rust's BcryptKernel;
/// calibration picks the faster on this CPU.
enum BcryptKernel: Sendable, CustomStringConvertible {
    /// Bytes extracted with constant shifts: the compiler picks the instructions (BMI1's bextr on AMD).
    case constant
    /// The shifts by 24 and 16 take their count from a register: BMI2's shrx, which keeps its input, so no copy
    /// before each shift (the Rust's shrx kernel, for Intel). Slower without BMI2.
    case shrx

    init?(name: String) {
        switch name {
        case "constant": self = .constant
        case "shrx": self = .shrx
        default: return nil
        }
    }

    var description: String { self == .constant ? "constant" : "shrx" }
}

/// `n` bcrypt digests at one cost, in lockstep (`bcrypt_lanes<N>`). Every lane runs all 2^cost rounds.
func bcryptLanes<let n: Int>(_ mats: borrowing InlineArray<n, KeyMaterial>, cost: Int,
                             kernel: BcryptKernel) -> InlineArray<n, BcryptDigest> {
    var st = InlineArray<n, BfState>(repeating: .initial)
    eksExpand(&st, mats, withSalt: true, saltAsKey: false)
    // The cost loop: the key and then the salt XORed into P, each followed by a key-only expansion, the kernel
    // written out for n lanes (BcryptKernels.swift, the Rust's bc_expand0); one loop, so it is inlined once.
    for half in 0..<(2 << cost) {
        let saltAsKey = half & 1 == 1
        for k in 0..<n {
            for i in 0..<18 { st[k].p[i] ^= saltAsKey ? mats[k].salt18[i] : mats[k].keyP[i] }
        }
        bfExpand0(&st, kernel)
    }
    let magic: InlineArray<6, UInt32> = [0x4f72_7068, 0x6561_6e42, 0x6568_6f6c, 0x6465_7253, 0x6372_7944, 0x6f75_6274]
    var ctext = InlineArray<n, InlineArray<6, UInt32>>(repeating: magic)
    for _ in 0..<64 {
        for blk in 0..<3 {
            var l = InlineArray<n, UInt32> { ctext[$0][2 * blk] }
            var r = InlineArray<n, UInt32> { ctext[$0][2 * blk + 1] }
            encipherLanes(st, &l, &r)
            for k in 0..<n {
                ctext[k][2 * blk] = l[k]
                ctext[k][2 * blk + 1] = r[k]
            }
        }
    }
    return InlineArray<n, BcryptDigest> { k in
        BcryptDigest { i in UInt8(truncatingIfNeeded: ctext[k][i >> 2] >> (24 - 8 * UInt32(i & 3))) }
    }
}

/// The L1 data cache size in KB, from sysfs (32 if unknown).
func detectL1DKB() -> Int {
    guard let file = fopen("/sys/devices/system/cpu/cpu0/cache/index0/size", "r") else { return 32 }
    defer { fclose(file) }
    var buf = InlineArray<32, CChar>(repeating: 0)
    var span = buf.mutableSpan
    let line = span.withUnsafeMutableBufferPointer { fgets($0.baseAddress, 32, file).map { String(cString: $0) } }
    guard var text = line?.trimmingWhitespace() else { return 32 }
    if text.hasSuffix("K") || text.hasSuffix("k") { text.removeLast() } else { return 32 }
    guard let kb = Int(text), (16...512).contains(kb) else { return 32 }
    return kb
}

extension String {
    fileprivate func trimmingWhitespace() -> String {
        String(self.drop { $0.isWhitespace }.reversed().drop { $0.isWhitespace }.reversed())
    }
}

private typealias Probe = (lanes: Int, kernel: BcryptKernel, us10: Int, perHash: Int)

/// `n` lanes with `kernel` at cost 7, the faster of two runs (`probe_nk`), scaled to cost 10.
private func probe<let n: Int>(_: InlineArray<n, KeyMaterial>.Type, _ kernel: BcryptKernel) -> Probe {
    let pw = Array("calibrate-benchmark-pw".utf8)
    let mats = InlineArray<n, KeyMaterial> { k in
        KeyMaterial(password: pw, salt: BcryptSalt(repeating: UInt8(truncatingIfNeeded: k &* 17 &+ 3)))
    }
    var us7 = Int.max
    for _ in 0..<2 {
        let t0 = monotonicNanos()
        let digests = bcryptLanes(mats, cost: 7, kernel: kernel)
        us7 = min(us7, Int((monotonicNanos() - t0) / 1000))
        withExtendedLifetime(digests) {}
    }
    let us10 = max(us7 * 8, 1000)
    return (n, kernel, us10, us10 / n)
}

/// Picks the kernel and the lockstep width (`calibrate_bcrypt_hardware`): times both kernel families at 2, 3, 4 and
/// 6 lanes and keeps the fastest per hash whose states fit the L1. Returns (lanes, kernel, the estimated
/// microseconds of one cost-10 batch, L1D KB).
func calibrateBcryptHardware() -> (lanes: Int, kernel: BcryptKernel, bcryptUs: Int, l1dKB: Int) {
    let l1d = detectL1DKB()
    let warm = InlineArray<1, KeyMaterial>(repeating: KeyMaterial(password: Array("calibrate-warmup".utf8), salt: BcryptSalt(repeating: 0x5A)))
    for kernel in [BcryptKernel.constant, .shrx] { withExtendedLifetime(bcryptLanes(warm, cost: 5, kernel: kernel)) {} }
    var candidates: [Probe] = []
    for kernel in [BcryptKernel.constant, .shrx] {
        candidates += [probe(InlineArray<2, KeyMaterial>.self, kernel), probe(InlineArray<3, KeyMaterial>.self, kernel),
                       probe(InlineArray<4, KeyMaterial>.self, kernel), probe(InlineArray<6, KeyMaterial>.self, kernel)]
    }
    var best = candidates[0]
    for cand in candidates.dropFirst() {
        let stateKB = cand.lanes * MemoryLayout<BfState>.size / 1024
        if stateKB <= l1d && cand.perHash * 103 < best.perHash * 100 { best = cand }
    }
    return (best.lanes, best.kernel, best.us10, l1d)
}

private let bcryptAlphabet: StaticString = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

@inline(__always) private func bcryptValue(_ c: UInt8) -> UInt8? {
    switch c {
    case 0x2E, 0x2F: c - 0x2E
    case 0x41...0x5A: c - 0x41 + 2
    case 0x61...0x7A: c - 0x61 + 28
    case 0x30...0x39: c - 0x30 + 54
    default: nil
    }
}

private func encodeBcrypt64(_ src: Span<UInt8>, into dst: inout [UInt8]) {
    let enc = bcryptAlphabet.utf8Start
    var i = 0
    while i < src.count {
        let b0 = src[i]
        i += 1
        dst.append(enc[Int(b0 >> 2)])
        var v = (b0 & 0x03) << 4
        guard i < src.count else {
            dst.append(enc[Int(v)])
            break
        }
        let b1 = src[i]
        i += 1
        v |= b1 >> 4
        dst.append(enc[Int(v)])
        v = (b1 & 0x0F) << 2
        guard i < src.count else {
            dst.append(enc[Int(v)])
            break
        }
        let b2 = src[i]
        i += 1
        v |= b2 >> 6
        dst.append(enc[Int(v)])
        dst.append(enc[Int(b2 & 0x3F)])
    }
}

/// `count` bytes of bcrypt's base64 (`decode_bcrypt_b64<N>`), generic over the output's size.
private func decodeBcrypt64<let count: Int>(_ src: Span<UInt8>) -> InlineArray<count, UInt8>? {
    var out = InlineArray<count, UInt8>(repeating: 0)
    var o = 0
    var i = 0
    while o < count {
        guard i + 1 < src.count, let c1 = bcryptValue(src[i]), let c2 = bcryptValue(src[i + 1]) else { return nil }
        out[o] = c1 << 2 | (c2 & 0x30) >> 4
        o += 1
        if o >= count { break }
        guard i + 2 < src.count, let c3 = bcryptValue(src[i + 2]) else { return nil }
        out[o] = (c2 & 0x0F) << 4 | (c3 & 0x3C) >> 2
        o += 1
        if o >= count { break }
        guard i + 3 < src.count, let c4 = bcryptValue(src[i + 3]) else { return nil }
        out[o] = (c3 & 0x03) << 6 | c4
        o += 1
        i += 4
    }
    return out
}

struct ParsedBcrypt {
    var cost: Int
    var salt: BcryptSalt
    var digest: BcryptDigest
}

func parseBcrypt(_ encoded: Span<UInt8>) -> ParsedBcrypt? {
    guard encoded.count == 60, encoded[0] == 0x24, encoded[1] == 0x32, encoded[3] == 0x24, encoded[6] == 0x24,
          encoded[2] == 0x61 || encoded[2] == 0x62 || encoded[2] == 0x79,
          (0x30...0x39).contains(encoded[4]), (0x30...0x39).contains(encoded[5]) else { return nil }
    let cost = Int(encoded[4] - 0x30) * 10 + Int(encoded[5] - 0x30)
    guard (4...31).contains(cost),
          let salt = decodeBcrypt64(encoded.extracting(7..<29)) as BcryptSalt?,
          let digest = decodeBcrypt64(encoded.extracting(29..<60)) as BcryptDigest? else { return nil }
    return ParsedBcrypt(cost: cost, salt: salt, digest: digest)
}

func formatBcrypt(cost: Int, salt: BcryptSalt, digest: BcryptDigest) -> [UInt8] {
    var out: [UInt8] = [0x24, 0x32, 0x61, 0x24, 0x30 + UInt8(cost / 10), 0x30 + UInt8(cost % 10), 0x24]
    out.reserveCapacity(60)
    encodeBcrypt64(salt.span, into: &out)
    encodeBcrypt64(digest.span, into: &out)
    return out
}

@inline(__always) func constantTimeDigestEqual(_ a: BcryptDigest, _ b: BcryptDigest) -> Bool {
    var diff: UInt8 = 0
    for i in 0..<23 { diff |= a[i] ^ b[i] }
    return diff == 0
}

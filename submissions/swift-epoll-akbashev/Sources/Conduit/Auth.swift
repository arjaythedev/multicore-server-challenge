// auth.rs: SHA-256 and HMAC-SHA256 (the JWT's HS256 with the secret's ipad/opad midstates computed once), JWT
// verification and issuing, and bcrypt with several hashes run in lockstep. SHA-256 runs on the CPU's SHA extensions
// where it has them, as the Rust's SHA-NI path (the SHAExtensions module), and on the Rust's portable compression
// function otherwise.
import Glibc
#if arch(x86_64)
import SHAExtensions
#endif

/// SHA-256 and HMAC-SHA256.
enum SHA256 {
    typealias State = InlineArray<8, UInt32>
    typealias Digest = InlineArray<32, UInt8>

    static let initialState: State = [
        0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
    ]

    private static let roundConstants: InlineArray<64, UInt32> = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]

    @inline(__always) private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { x >> n | x << (32 - n) }

    @inline(__always) static func compressWords(_ state: inout State, _ words: InlineArray<16, UInt32>) {
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
            let temp1 = h &+ s1 &+ ch &+ roundConstants[i] &+ w[i & 15]
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
    @inline(__always) static func compressBlock(_ state: inout State, _ data: RawSpan, at offset: Int = 0) {
        var w = InlineArray<16, UInt32>(repeating: 0)
        for i in 0..<16 { w[i] = data.load(fromByteOffset: offset + 4 * i, as: UInt32.self, .bigEndian) }
        compressWords(&state, w)
    }

    /// Compresses the `blocks` 64-byte blocks of `data`, on the CPU's SHA extensions if `extensions`.
    @inline(__always) static func compress(_ state: inout State, _ data: RawSpan, blocks: Int, extensions: Bool) {
        #if arch(x86_64)
        if extensions {
            data.withUnsafeBytes { raw in
                withUnsafeMutableBytes(of: &state) { SHAExtensions.compress($0.baseAddress!.assumingMemoryBound(to: UInt32.self), raw.baseAddress!, blocks: blocks) }
            }
            return
        }
        #endif
        for i in 0..<blocks { compressBlock(&state, data, at: 64 * i) }
    }

    static func hash(from initial: State, priorBytes: UInt64, _ data: Span<UInt8>, extensions: Bool = usesExtensions) -> State {
        var state = initial
        let full = data.count / 64
        if full > 0 { compress(&state, data.bytes, blocks: full, extensions: extensions) }
        // The rest, 0x80, zeros and the length in bits: one block, or two when the rest leaves no room for the length.
        let rem = data.count - 64 * full
        let blocks = rem >= 56 ? 2 : 1
        let totalBits = (priorBytes + UInt64(data.count)) * 8
        var tail = InlineArray<128, UInt8>(repeating: 0)
        for i in 0..<rem { tail[i] = data[64 * full + i] }
        tail[rem] = 0x80
        for i in 0..<8 { tail[64 * blocks - 8 + i] = UInt8(truncatingIfNeeded: totalBits >> (56 - 8 * UInt64(i))) }
        compress(&state, tail.span.bytes, blocks: blocks, extensions: extensions)
        return state
    }

    /// Whether SHA-256 runs on the CPU's SHA extensions: the CPU lists them (`sha_ni` in /proc/cpuinfo), and they
    /// hash messages of every padding case as the Swift function does. Checked once.
    static let usesExtensions: Bool = {
        #if arch(x86_64)
        guard Sys.cpuHasFlag("sha_ni") else { return false }
        for n in [0, 1, 55, 56, 63, 64, 65, 119, 120, 127, 128, 300] {
            let message = (0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
            let fast = hash(from: initialState, priorBytes: 0, message.span, extensions: true)
            let portable = hash(from: initialState, priorBytes: 0, message.span, extensions: false)
            for i in 0..<8 where fast[i] != portable[i] { return false }
        }
        return true
        #else
        return false
        #endif
    }()

    @inline(__always) static func stateBytes(_ state: State) -> Digest {
        Digest { i in UInt8(truncatingIfNeeded: state[i >> 2] >> (24 - 8 * UInt32(i & 3))) }
    }

    static func digest(_ data: Span<UInt8>) -> Digest {
        stateBytes(hash(from: initialState, priorBytes: 0, data))
    }

    static func hmac(key: borrowing [UInt8], _ data: Span<UInt8>) -> Digest {
        TokenSigner(secret: key).sign(data)
    }
}

/// HS256 with the secret's ipad/opad midstates precomputed: each signature costs the message's blocks plus one.
struct TokenSigner: Sendable {
    private var ipadState: SHA256.State
    private var opadState: SHA256.State
    /// `SHA256.usesExtensions`, kept here for the requests.
    private let extensions = SHA256.usesExtensions

    init(secret: borrowing [UInt8]) {
        var block = InlineArray<64, UInt8>(repeating: 0)
        if secret.count > 64 {
            let hashed = SHA256.digest(secret.span)
            for i in 0..<32 { block[i] = hashed[i] }
        } else {
            for i in 0..<secret.count { block[i] = secret[i] }
        }
        let ipad = InlineArray<64, UInt8> { 0x36 ^ block[$0] }
        let opad = InlineArray<64, UInt8> { 0x5C ^ block[$0] }
        ipadState = SHA256.initialState
        opadState = SHA256.initialState
        SHA256.compressBlock(&ipadState, ipad.span.bytes)
        SHA256.compressBlock(&opadState, opad.span.bytes)
    }

    func sign(_ data: Span<UInt8>) -> SHA256.Digest {
        let inner = SHA256.hash(from: ipadState, priorBytes: 64, data, extensions: extensions)
        var outer = opadState
        if extensions {
            // The outer block as bytes: the inner digest, 0x80, and the length (64 + 32 bytes, 768 bits).
            var block = InlineArray<64, UInt8>(repeating: 0)
            let digest = SHA256.stateBytes(inner)
            for i in 0..<32 { block[i] = digest[i] }
            block[32] = 0x80
            block[62] = 0x03
            SHA256.compress(&outer, block.span.bytes, blocks: 1, extensions: true)
        } else {
            let words: InlineArray<16, UInt32> = [
                inner[0], inner[1], inner[2], inner[3], inner[4], inner[5], inner[6], inner[7],
                0x8000_0000, 0, 0, 0, 0, 0, 0, 768,
            ]
            SHA256.compressWords(&outer, words)
        }
        return SHA256.stateBytes(outer)
    }

    /// The user id of a valid token (signature, `alg`, `exp`, `nbf`), nil otherwise.
    func verify(_ token: Span<UInt8>) -> Int64? {
        guard let dot1 = Bytes.find(token, 0x2E), let dot2 = Bytes.find(token, 0x2E, from: dot1 + 1) else { return nil }
        let header = token.extracting(0..<dot1)
        let payload64 = token.extracting((dot1 + 1)..<dot2)
        let signature64 = token.extracting((dot2 + 1)..<token.count)
        if Bytes.find(signature64, 0x2E) != nil { return nil }

        var signature = InlineArray<48, UInt8>(repeating: 0)
        var signatureSpan = signature.mutableSpan
        guard Base64.urlDecode(signature64, into: &signatureSpan) == 32 else { return nil }
        let expected = sign(token.extracting(0..<dot2))
        guard Self.constantTimeEqual32(expected, signature.span) else { return nil }

        if !Bytes.equal(header, Self.jwtHeaderStandard) && !Bytes.equal(header, Self.jwtHeaderReordered) && !Bytes.equal(header, Self.jwtHeaderMinimal) {
            if header.count > 340 { return nil }
            var headerBytes = InlineArray<256, UInt8>(repeating: 0)
            var headerSpan = headerBytes.mutableSpan
            guard let n = Base64.urlDecode(header, into: &headerSpan) else { return nil }
            let json = headerBytes.span.extracting(0..<n)
            guard let fields = JSON.scan(json, keys: ["alg"]), let alg = fields[0], alg.kind == .string,
                  JSON.withString(json, alg, { Bytes.equal($0, "HS256") }) else { return nil }
        }

        let now = Sys.unixNowF64()
        if payload64.count <= 680 {
            var payload = InlineArray<512, UInt8>(repeating: 0)
            var payloadSpan = payload.mutableSpan
            guard let n = Base64.urlDecode(payload64, into: &payloadSpan) else { return nil }
            return claims(payload.span.extracting(0..<n), now: now)
        }
        guard let payload = Base64.urlDecodeArray(payload64) else { return nil }
        return claims(payload.span, now: now)
    }

    /// The claims, read in place: `exp` (required) and `nbf` against the clock, `iat` a number if present, and `sub` a
    /// positive integer string, the user id.
    private func claims(_ payload: Span<UInt8>, now: Double) -> Int64? {
        guard let fields = JSON.scan(payload, keys: ["exp", "nbf", "iat", "sub"]), fields.isObject,
              let exp = fields[0], exp.kind == .number,
              let expires = JSON.number(payload, exp), now < expires else { return nil }
        if let nbf = fields[1] {
            guard nbf.kind == .number, let notBefore = JSON.number(payload, nbf), now >= notBefore else { return nil }
        }
        if let iat = fields[2], iat.kind != .number { return nil }
        guard let sub = fields[3], sub.kind == .string else { return nil }
        return JSON.withString(payload, sub, Self.positiveInteger)
    }

    /// A positive decimal integer that fits an Int64, nil otherwise.
    private static func positiveInteger(_ digits: Span<UInt8>) -> Int64? {
        guard digits.count > 0 else { return nil }
        var value: Int64 = 0
        for i in 0..<digits.count {
            let ch = digits[i]
            guard (0x30...0x39).contains(ch) else { return nil }
            let (m, o1) = value.multipliedReportingOverflow(by: 10)
            let (s, o2) = m.addingReportingOverflow(Int64(ch - 0x30))
            if o1 || o2 { return nil }
            value = s
        }
        return value > 0 ? value : nil
    }

    /// A token for `userID`, valid 30 days.
    func issue(_ userID: Int64) -> [UInt8] {
        let iat = Sys.unixNowSecs()
        var payload = ByteBuffer(capacity: 96)
        payload.append("{\"exp\":")
        JSON.writeUInt(&payload, UInt64(iat + 30 * 86_400))
        payload.append(",\"iat\":")
        JSON.writeUInt(&payload, UInt64(iat))
        payload.append(",\"sub\":\"")
        JSON.writeUInt(&payload, UInt64(userID))
        payload.append("\"}")

        var token = ByteBuffer(capacity: 160)
        token.append("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.")
        Base64.urlEncode(payload.span, into: &token)
        let signature = sign(token.span)
        token.append(0x2E)
        Base64.urlEncode(signature.span, into: &token)
        return token.take()
    }
}

extension TokenSigner {
    private static let jwtHeaderStandard: StaticString = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
    private static let jwtHeaderReordered: StaticString = "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9"
    private static let jwtHeaderMinimal: StaticString = "eyJhbGciOiJIUzI1NiJ9"

    @inline(__always) private static func constantTimeEqual32(_ a: SHA256.Digest, _ b: Span<UInt8>) -> Bool {
        guard b.count >= 32 else { return false }
        var diff: UInt8 = 0
        for i in 0..<32 { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}

// ---------- bcrypt ----------

/// bcrypt: OpenBSD's algorithm with several hashes in lockstep, its calibration, and the `$2b$` encoding.
enum Bcrypt {
    /// One Blowfish state, the P-array and the four S-boxes (BF_S[box][i] at s[256 * box + i]). The Rust pads it to a
    /// 64-byte line; Swift has no alignment attribute, so it is 4,168 bytes, packed.
    struct State: BitwiseCopyable {
        var p: InlineArray<18, UInt32>
        var s: InlineArray<1024, UInt32>

        static let initial = State(p: initialP, s: initialS)
    }

    typealias Digest = InlineArray<23, UInt8>
    typealias Salt = InlineArray<16, UInt8>

    /// F of lane `k`'s state, its S-boxes read in place: passing `st[k].s` as an argument would copy all 4 KB of them
    /// on every call (a `borrowing` parameter of a copyable value read through a subscript is still a copy).
    @inline(__always) private static func feistel<let n: Int>(_ st: borrowing InlineArray<n, State>, _ k: Int, _ x: UInt32) -> UInt32 {
        let a = st[k].s[Int(x >> 24)]
        let b = st[k].s[256 + Int(x >> 16 & 0xFF)]
        let c = st[k].s[512 + Int(x >> 8 & 0xFF)]
        let d = st[k].s[768 + Int(x & 0xFF)]
        return ((a &+ b) ^ c) &+ d
    }

    /// 16-round Blowfish in each of `n` states, interleaved round by round so their S-box loads overlap.
    @inline(__always) private static func encipherLanes<let n: Int>(_ st: borrowing InlineArray<n, State>,
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

        init(password: borrowing [UInt8], salt: Salt) {
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

    @inline(__always) private static func eksExpand<let n: Int>(_ st: inout InlineArray<n, State>, _ mats: borrowing InlineArray<n, KeyMaterial>,
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

    /// Which family of the generated key-only expansion kernels runs (BcryptKernels.swift), as the Rust's Kernel;
    /// calibration picks the faster on this CPU.
    enum Kernel: Sendable, CustomStringConvertible {
        /// Bytes extracted with constant shifts: the compiler picks the instructions (BMI1's bextr on AMD, ubfx on arm64).
        case constant
        #if arch(x86_64)
        /// The shifts by 24 and 16 take their count from a register: BMI2's shrx, which keeps its input, so no copy
        /// before each shift (the Rust's shrx kernel, for Intel). Slower without BMI2; x86-64 only, since elsewhere there
        /// is no copy to save (arm64's ubfx extracts a constant field in one instruction).
        case shrx
        #endif

        /// Every family this architecture has.
        static var all: [Kernel] {
            #if arch(x86_64)
            [.constant, .shrx]
            #else
            [.constant]
            #endif
        }

        init?(name: String) {
            guard let kernel = Self.all.first(where: { $0.description == name }) else { return nil }
            self = kernel
        }

        var description: String {
            switch self {
            case .constant: "constant"
            #if arch(x86_64)
            case .shrx: "shrx"
            #endif
            }
        }
    }

    /// `n` bcrypt digests at one cost, in lockstep (`bcrypt_lanes<N>`). Every lane runs all 2^cost rounds.
    static func hashLanes<let n: Int>(_ mats: borrowing InlineArray<n, KeyMaterial>, cost: Int,
                                      kernel: Kernel) -> InlineArray<n, Digest> {
        var st = InlineArray<n, State>(repeating: .initial)
        eksExpand(&st, mats, withSalt: true, saltAsKey: false)
        // The cost loop: the key and then the salt XORed into P, each followed by a key-only expansion, the kernel
        // written out for n lanes (BcryptKernels.swift, the Rust's bc_expand0); one loop, so it is inlined once.
        for half in 0..<(2 << cost) {
            let saltAsKey = half & 1 == 1
            for k in 0..<n {
                for i in 0..<18 { st[k].p[i] ^= saltAsKey ? mats[k].salt18[i] : mats[k].keyP[i] }
            }
            expand0(&st, kernel)
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
        return InlineArray<n, Digest> { k in
            Digest { i in UInt8(truncatingIfNeeded: ctext[k][i >> 2] >> (24 - 8 * UInt32(i & 3))) }
        }
    }

    /// The L1 data cache size in KB, from sysfs (32 if unknown).
    static func detectL1DKB() -> Int {
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

    private typealias Probe = (lanes: Int, kernel: Kernel, us10: Int, perHash: Int)

    /// `n` lanes with `kernel` at cost 7, the faster of two runs (`probe_nk`), scaled to cost 10.
    private static func probe<let n: Int>(_: InlineArray<n, KeyMaterial>.Type, _ kernel: Kernel) -> Probe {
        let pw = Array("calibrate-benchmark-pw".utf8)
        let mats = InlineArray<n, KeyMaterial> { k in
            KeyMaterial(password: pw, salt: Salt(repeating: UInt8(truncatingIfNeeded: k &* 17 &+ 3)))
        }
        var us7 = Int.max
        for _ in 0..<2 {
            let t0 = Sys.monotonicNanos()
            let digests = hashLanes(mats, cost: 7, kernel: kernel)
            us7 = min(us7, Int((Sys.monotonicNanos() - t0) / 1000))
            withExtendedLifetime(digests) {}
        }
        let us10 = max(us7 * 8, 1000)
        return (n, kernel, us10, us10 / n)
    }

    /// Picks the kernel and the lockstep width (`calibrate_bcrypt_hardware`): times every kernel family this architecture
    /// has at 2, 3, 4 and 6 lanes and keeps the fastest per hash whose states fit the L1. Returns (lanes, kernel, the
    /// estimated microseconds of one cost-10 batch, L1D KB).
    static func calibrate() -> (lanes: Int, kernel: Kernel, bcryptUs: Int, l1dKB: Int) {
        let l1d = detectL1DKB()
        let warm = InlineArray<1, KeyMaterial>(repeating: KeyMaterial(password: Array("calibrate-warmup".utf8), salt: Salt(repeating: 0x5A)))
        for kernel in Kernel.all { withExtendedLifetime(hashLanes(warm, cost: 5, kernel: kernel)) {} }
        var candidates: [Probe] = []
        for kernel in Kernel.all {
            candidates += [probe(InlineArray<2, KeyMaterial>.self, kernel), probe(InlineArray<3, KeyMaterial>.self, kernel),
                           probe(InlineArray<4, KeyMaterial>.self, kernel), probe(InlineArray<5, KeyMaterial>.self, kernel),
                           probe(InlineArray<6, KeyMaterial>.self, kernel)]
        }
        if getenv("BCRYPT_REPORT") != nil {
            for c in candidates { Sys.logLine("bcrypt \(c.kernel) x\(c.lanes): \(c.us10) us per batch, \(c.perHash) us per hash") }
        }
        var best = candidates[0]
        for cand in candidates.dropFirst() {
            let stateKB = cand.lanes * MemoryLayout<State>.size / 1024
            if stateKB <= l1d && cand.perHash * 103 < best.perHash * 100 { best = cand }
        }
        return (best.lanes, best.kernel, best.us10, l1d)
    }

    private static let alphabet: StaticString = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

    @inline(__always) private static func alphabetValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x2E, 0x2F: c - 0x2E
        case 0x41...0x5A: c - 0x41 + 2
        case 0x61...0x7A: c - 0x61 + 28
        case 0x30...0x39: c - 0x30 + 54
        default: nil
        }
    }

    private static func encode64(_ src: Span<UInt8>, into dst: inout [UInt8]) {
        let enc = alphabet.utf8Start
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
    private static func decode64<let count: Int>(_ src: Span<UInt8>) -> InlineArray<count, UInt8>? {
        var out = InlineArray<count, UInt8>(repeating: 0)
        var o = 0
        var i = 0
        while o < count {
            guard i + 1 < src.count, let c1 = alphabetValue(src[i]), let c2 = alphabetValue(src[i + 1]) else { return nil }
            out[o] = c1 << 2 | (c2 & 0x30) >> 4
            o += 1
            if o >= count { break }
            guard i + 2 < src.count, let c3 = alphabetValue(src[i + 2]) else { return nil }
            out[o] = (c2 & 0x0F) << 4 | (c3 & 0x3C) >> 2
            o += 1
            if o >= count { break }
            guard i + 3 < src.count, let c4 = alphabetValue(src[i + 3]) else { return nil }
            out[o] = (c3 & 0x03) << 6 | c4
            o += 1
            i += 4
        }
        return out
    }

    struct Parsed {
        let cost: Int
        let salt: Salt
        let digest: Digest
    }

    static func parse(_ encoded: Span<UInt8>) -> Parsed? {
        guard encoded.count == 60, encoded[0] == 0x24, encoded[1] == 0x32, encoded[3] == 0x24, encoded[6] == 0x24,
              encoded[2] == 0x61 || encoded[2] == 0x62 || encoded[2] == 0x79,
              (0x30...0x39).contains(encoded[4]), (0x30...0x39).contains(encoded[5]) else { return nil }
        let cost = Int(encoded[4] - 0x30) * 10 + Int(encoded[5] - 0x30)
        guard (4...31).contains(cost),
              let salt = decode64(encoded.extracting(7..<29)) as Salt?,
              let digest = decode64(encoded.extracting(29..<60)) as Digest? else { return nil }
        return Parsed(cost: cost, salt: salt, digest: digest)
    }

    static func format(cost: Int, salt: Salt, digest: Digest) -> [UInt8] {
        var out: [UInt8] = [0x24, 0x32, 0x61, 0x24, 0x30 + UInt8(cost / 10), 0x30 + UInt8(cost % 10), 0x24]
        out.reserveCapacity(60)
        encode64(salt.span, into: &out)
        encode64(digest.span, into: &out)
        return out
    }

    @inline(__always) static func digestsEqual(_ a: Digest, _ b: Digest) -> Bool {
        var diff: UInt8 = 0
        for i in 0..<23 { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}

extension String {
    fileprivate func trimmingWhitespace() -> String {
        String(self.drop { $0.isWhitespace }.reversed().drop { $0.isWhitespace }.reversed())
    }
}

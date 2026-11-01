// HS256 JWT issue/verify. No verification cache (SPEC.md rule: every request re-verifies).
import Crypto
import Foundation
import HTTPTypes

/// How long an issued token is valid (SPEC.md: exp = iat + 30 days). iat and exp are wall-clock Unix seconds, so they
/// come from Date: ContinuousClock and SuspendingClock are monotonic, with no fixed epoch.
let tokenTTL: Duration = .seconds(30 * 24 * 3600)

/// base64url of {"alg":"HS256","typ":"JWT"}: the header of every token this server issues, and the usual HS256 header.
let issuedHeader = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"

func b64urlEncode(_ bytes: [UInt8]) -> String {
    var s = Data(bytes).base64EncodedString()
    s = s.replacingOccurrences(of: "+", with: "-")
    s = s.replacingOccurrences(of: "/", with: "_")
    while s.hasSuffix("=") { s.removeLast() }
    return s
}

func b64urlDecode(_ s: String) -> [UInt8]? {
    var t = s.replacingOccurrences(of: "-", with: "+")
    t = t.replacingOccurrences(of: "_", with: "/")
    while t.count % 4 != 0 { t.append("=") }
    guard let data = Data(base64Encoded: t) else { return nil }
    return Array(data)
}

/// Unpadded base64url (RFC 4648 §5), strict: any other byte, a dangling 6-bit group or non-zero trailing bits make
/// the input invalid. Returns the number of bytes written, or nil if the input is invalid or does not fit in `out`.
func b64urlDecode(_ input: Span<UInt8>, into out: inout MutableSpan<UInt8>) -> Int? {
    var acc: UInt32 = 0
    var bits = 0
    var n = 0
    for i in input.indices {
        let c = input[i]
        let v: UInt32
        switch c {
        case 0x41...0x5A: v = UInt32(c - 0x41) // A-Z
        case 0x61...0x7A: v = UInt32(c - 0x61 + 26) // a-z
        case 0x30...0x39: v = UInt32(c - 0x30 + 52) // 0-9
        case 0x2D: v = 62 // -
        case 0x5F: v = 63 // _
        default: return nil
        }
        acc = acc << 6 | v
        bits += 6
        if bits >= 8 {
            bits -= 8
            guard n < out.count else { return nil }
            out[n] = UInt8(truncatingIfNeeded: acc >> UInt32(bits))
            n += 1
        }
    }
    guard bits < 6, acc & ((1 << UInt32(bits)) - 1) == 0 else { return nil }
    return n
}

/// HS256 under JWT_SECRET. The HMAC is keyed once; every MAC starts from a copy of it (copy-on-write) instead of
/// re-deriving the key's inner and outer pads.
///
/// `@unchecked`: on Linux swift-crypto's `HMAC` isn't marked Sendable (CryptoKit's, on Darwin, is). Sharing `keyed`
/// is still safe: it is never mutated, a copy's `update` copies the digest context before writing to it
/// (isKnownUniquelyReferenced), and `finalize` works on a copy of the context, so concurrent use only ever reads it.
struct JWTSigner: @unchecked Sendable {
    private let keyed: HMAC<SHA256>

    init(secret: String) {
        keyed = HMAC(key: SymmetricKey(data: Data(secret.utf8)))
    }

    private func mac(_ message: Span<UInt8>) -> HMAC<SHA256>.MAC {
        var hmac = keyed
        message.withUnsafeBytes { hmac.update(data: $0) }
        return hmac.finalize()
    }

    func issue(id: Int64) -> String {
        let now = Int64(Date().timeIntervalSince1970)
        let payload = "{\"sub\":\"\(id)\",\"iat\":\(now),\"exp\":\(now + tokenTTL.components.seconds)}"
        var token = issuedHeader + "." + b64urlEncode(Array(payload.utf8))
        let sig = mac(token.utf8.span)
        token += "." + b64urlEncode(Array(sig))
        return token
    }

    /// Verify an HS256 JWT: signature (constant-time), alg, exp and a positive numeric sub.
    /// Returns the user id, or nil if the token is invalid.
    func verify(_ bytes: Span<UInt8>) -> Int64? {
        var dot1 = -1
        var dot2 = -1
        for i in bytes.indices where bytes[i] == 0x2E { // .
            if dot1 < 0 { dot1 = i } else if dot2 < 0 { dot2 = i } else { return nil }
        }
        guard dot2 >= 0 else { return nil }

        // The signature covers "header.payload" exactly as sent; HS256's 32-byte MAC is 43 base64url characters.
        var sig = InlineArray<32, UInt8>(repeating: 0)
        let sigCount: Int?
        do {
            var out = sig.mutableSpan
            sigCount = b64urlDecode(bytes.extracting((dot2 + 1)..<bytes.count), into: &out)
        }
        guard sigCount == 32 else { return nil }
        let expected = mac(bytes.extracting(0..<dot2))
        guard sig.span.withUnsafeBytes({ expected == $0 }) else { return nil } // constant-time

        if bytesEqual(bytes.extracting(0..<dot1), issuedHeader.utf8.span),
           let verdict = fastClaims(bytes.extracting((dot1 + 1)..<dot2)) {
            switch verdict {
            case .user(let id): return id
            case .reject: return nil
            }
        }
        return fullClaims(bytes.withUnsafeBufferPointer { String(decoding: $0, as: UTF8.self) })
    }

    private enum Verdict { case user(Int64), reject }

    private static let subKey: UInt32 = 0x73_75_62 // "sub"
    private static let iatKey: UInt32 = 0x69_61_74 // "iat"
    private static let expKey: UInt32 = 0x65_78_70 // "exp"

    /// The claims as SPEC.md defines them (and this server issues them): one flat JSON object of the keys sub (a plain
    /// string), iat and exp (plain integers), each at most once, in any order, with no whitespace or escapes. Returns
    /// nil for anything else, which then goes through JSONSerialization, so this never decides a token differently.
    private func fastClaims(_ segment: Span<UInt8>) -> Verdict? {
        var buffer = InlineArray<192, UInt8>(repeating: 0)
        let decoded: Int?
        do {
            var out = buffer.mutableSpan
            decoded = b64urlDecode(segment, into: &out)
        }
        guard let decoded else { return nil }
        return parseClaims(buffer.span.extracting(0..<decoded))
    }

    private func parseClaims(_ json: Span<UInt8>) -> Verdict? {
        let n = json.count
        guard n >= 2, json[0] == 0x7B else { return nil } // {

        var i = 1
        var sub: Range<Int>?
        var iat = false
        var exp: Int64?
        while true {
            guard i < n, json[i] == 0x22 else { return nil } // "key"
            let keyStart = i + 1
            i = keyStart
            while i < n, json[i] != 0x22 { i += 1 }
            guard i + 1 < n, json[i + 1] == 0x3A else { return nil } // :
            // The key's three bytes packed into an integer; 0 for a key of any other length.
            let key: UInt32 = i - keyStart == 3
                ? UInt32(json[keyStart]) << 16 | UInt32(json[keyStart + 1]) << 8 | UInt32(json[keyStart + 2])
                : 0
            i += 2
            guard i < n else { return nil }

            if json[i] == 0x22 { // "string": only sub may be one
                let start = i + 1
                i = start
                while i < n, json[i] != 0x22 {
                    if json[i] == 0x5C || json[i] < 0x20 { return nil }
                    i += 1
                }
                guard i < n, key == Self.subKey, sub == nil else { return nil }
                sub = start..<i
                i += 1
            } else { // integer: only iat or exp may be one
                let negative = json[i] == 0x2D
                if negative { i += 1 }
                let start = i
                var value: Int64 = 0
                while i < n, json[i] >= 0x30, json[i] <= 0x39 {
                    guard i - start < 18 else { return nil }
                    value = value * 10 + Int64(json[i] - 0x30)
                    i += 1
                }
                guard i > start, !(i - start > 1 && json[start] == 0x30) else { return nil } // digits, no leading zero
                switch key {
                case Self.iatKey where !iat: iat = true
                case Self.expKey where exp == nil: exp = negative ? -value : value
                default: return nil // another key, or iat/exp twice
                }
            }

            guard i < n else { return nil }
            if json[i] == 0x2C { i += 1; continue } // ,
            guard json[i] == 0x7D, i == n - 1 else { return nil } // } and nothing after it
            break
        }

        guard let exp, Double(exp) >= Date().timeIntervalSince1970 else { return .reject }
        guard let sub, let id = parseUint(json.extracting(sub)), id > 0 else { return .reject }
        return .user(id)
    }

    /// Any other well-signed token: alg, exp (number or numeric string) and sub, through JSONSerialization.
    private func fullClaims(_ token: String) -> Int64? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard let headerBytes = b64urlDecode(String(parts[0])) else { return nil }
        guard let payloadBytes = b64urlDecode(String(parts[1])) else { return nil }

        let header: Any
        let payload: Any
        do {
            header = try JSONSerialization.jsonObject(with: Data(headerBytes))
            payload = try JSONSerialization.jsonObject(with: Data(payloadBytes))
        } catch {
            return nil
        }
        guard let headerDict = header as? [String: Any], headerDict["alg"] as? String == "HS256" else {
            return nil
        }
        guard let claims = payload as? [String: Any] else { return nil }

        // exp is required and must be in the future; accept number or numeric string.
        let exp: Double?
        switch claims["exp"] {
        case let n as NSNumber: exp = n.doubleValue
        case let s as String: exp = Double(s)
        default: exp = nil
        }
        guard let exp, exp >= Date().timeIntervalSince1970 else { return nil }

        guard let sub = claims["sub"] as? String, let id = parseUint(sub), id > 0 else { return nil }
        return id
    }
}

/// The Authorization header: absent -> anonymous; present but invalid -> 401 (SPEC.md "Authentication"). Checked from
/// the header's bytes in the request as received.
enum Auth {
    /// The viewer of an auth-optional endpoint: no header (or an empty one) is anonymous, viewer 0.
    static func optional(_ header: Span<UInt8>, _ signer: JWTSigner) throws -> Int64 {
        if header.isEmpty { return 0 }
        guard header.count > 6, equals(header.extracting(0..<6), "Token "),
              let id = signer.verify(header.extracting(6..<header.count)) else {
            throw ApiError(.unauthorized, "unauthorized")
        }
        return id
    }

    /// The viewer of an auth-required endpoint.
    static func require(_ header: Span<UInt8>, _ signer: JWTSigner) throws -> Int64 {
        let viewer = try optional(header, signer)
        guard viewer != 0 else { throw ApiError(.unauthorized, "unauthorized") }
        return viewer
    }

    /// The viewer and the token as presented, for the endpoints that echo it back (GET and PUT /api/user).
    static func requireWithToken(_ header: Span<UInt8>, _ signer: JWTSigner) throws -> (Int64, String) {
        let viewer = try require(header, signer)
        return (viewer, header.extracting(6..<header.count).withUnsafeBufferPointer { String(decoding: $0, as: UTF8.self) })
    }
}

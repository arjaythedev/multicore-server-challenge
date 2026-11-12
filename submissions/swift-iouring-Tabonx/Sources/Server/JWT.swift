// HS256 JWT verification. Every token's signature is checked on every request (rule 5).

import CShim

public enum AuthResult {
    case absent
    case invalid
    case user(id: Int64, token: ByteView)
}

/// Verifies tokens with a fixed secret. Owns scratch space for decoded segments, so one instance
/// must only be used by one thread at a time.
public struct JWTVerifier: ~Copyable {
    let hmac: HMACSHA256
    var header: OutBuffer
    var payload: OutBuffer
    var scratch: OutBuffer
    let mac: UnsafeMutablePointer<UInt8>
    let signature: UnsafeMutablePointer<UInt8>

    public init(secret: ByteView) {
        hmac = HMACSHA256(key: secret)
        header = OutBuffer(capacity: 256)
        payload = OutBuffer(capacity: 1024)
        scratch = OutBuffer(capacity: 256)
        mac = .allocate(capacity: 32)
        signature = .allocate(capacity: 64)
    }

    deinit {
        mac.deallocate()
        signature.deallocate()
    }

    /// Checks an `Authorization` header value. `nil` means the header was absent.
    public mutating func verify(authorization: ByteView?, nowMs: Int64) -> AuthResult {
        guard let auth = authorization else { return .absent }
        guard auth.hasPrefix("Token ") else { return .invalid }
        let token = auth.slice(6, auth.count)

        var dot1 = -1
        var dot2 = -1
        for i in 0..<token.count where token[i] == UInt8(ascii: ".") {
            if dot1 < 0 { dot1 = i } else if dot2 < 0 { dot2 = i } else { return .invalid }
        }
        guard dot1 > 0, dot2 > dot1 &+ 1, dot2 < token.count &- 1 else { return .invalid }

        header.truncate(0)
        payload.truncate(0)
        guard base64URLDecode(token.slice(0, dot1), into: &header),
            base64URLDecode(token.slice(dot1 &+ 1, dot2), into: &payload)
        else { return .invalid }

        // The header must be an object whose "alg" is exactly "HS256".
        var algOK = false
        let headerDoc = scanJSONObject(header.view) { m in
            guard keyIs(m, "alg") else { return }
            algOK = false
            if m.kind == .string {
                if m.escaped {
                    scratch.truncate(0)
                    unescapeJSONString(m.value, into: &scratch)
                    algOK = scratch.view.equals("HS256")
                } else {
                    algOK = m.value.equals("HS256")
                }
            }
        }
        guard headerDoc == .object, algOK else { return .invalid }

        // Signature over the raw "header.payload" bytes, compared in constant time.
        let sigSegment = token.slice(dot2 &+ 1, token.count)
        guard sigSegment.count == 43, base64URLDecodeRaw(sigSegment, into: signature) == 32 else {
            return .invalid
        }
        hmac.mac(token.slice(0, dot2), into: mac)
        var diff: UInt8 = 0
        for i in 0..<32 { diff |= mac[i] ^ signature[i] }
        guard diff == 0 else { return .invalid }

        var exp: Double? = nil
        var sub: ByteView? = nil
        var subEscaped = false
        let payloadDoc = scanJSONObject(payload.view) { m in
            if keyIs(m, "exp") {
                exp = m.kind == .number ? parseJSONNumber(m.value) : nil
            } else if keyIs(m, "sub") {
                sub = m.kind == .string ? m.value : nil
                subEscaped = m.escaped
            }
        }
        guard payloadDoc == .object else { return .invalid }
        guard let expValue = exp, expValue * 1000 > Double(nowMs) else { return .invalid }
        guard var subView = sub else { return .invalid }
        if subEscaped {
            scratch.truncate(0)
            unescapeJSONString(subView, into: &scratch)
            subView = scratch.view
        }
        guard let id = parsePositiveInt(subView) else { return .invalid }
        return .user(id: id, token: token)
    }

    /// Appends a fresh HS256 token for user `id`, valid for 30 days.
    public mutating func sign(id: Int64, nowSeconds: Int64, into out: inout OutBuffer) {
        scratch.truncate(0)
        scratch.append("{\"sub\":\"")
        scratch.appendInt(id)
        scratch.append("\",\"iat\":")
        scratch.appendInt(nowSeconds)
        scratch.append(",\"exp\":")
        scratch.appendInt(nowSeconds &+ 2_592_000)
        scratch.append(UInt8(ascii: "}"))
        let start = out.count
        out.append("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.") // {"alg":"HS256","typ":"JWT"}
        appendBase64URL(scratch.view, into: &out)
        hmac.mac(ByteView(base: UnsafePointer(out.base + start), count: out.count &- start), into: mac)
        out.append(UInt8(ascii: "."))
        appendBase64URL(ByteView(base: UnsafePointer(mac), count: 32), into: &out)
    }
}

let base64URLAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

/// Unpadded base64url.
func appendBase64URL(_ v: ByteView, into out: inout OutBuffer) {
    var i = 0
    let n = v.count
    while i &+ 3 <= n {
        let w = UInt32(v[i]) << 16 | UInt32(v[i &+ 1]) << 8 | UInt32(v[i &+ 2])
        out.append(base64URLAlphabet[Int(w >> 18)])
        out.append(base64URLAlphabet[Int(w >> 12 & 63)])
        out.append(base64URLAlphabet[Int(w >> 6 & 63)])
        out.append(base64URLAlphabet[Int(w & 63)])
        i &+= 3
    }
    if n &- i == 1 {
        let w = UInt32(v[i]) << 16
        out.append(base64URLAlphabet[Int(w >> 18)])
        out.append(base64URLAlphabet[Int(w >> 12 & 63)])
    } else if n &- i == 2 {
        let w = UInt32(v[i]) << 16 | UInt32(v[i &+ 1]) << 8
        out.append(base64URLAlphabet[Int(w >> 18)])
        out.append(base64URLAlphabet[Int(w >> 12 & 63)])
        out.append(base64URLAlphabet[Int(w >> 6 & 63)])
    }
}

/// Compares a member's key with `name`, decoding escapes if the key has any.
@inline(__always)
func keyIs(_ m: JSONMember, _ name: StaticString) -> Bool {
    if !m.keyEscaped { return m.key.equals(name) }
    var tmp = OutBuffer(capacity: m.key.count)
    unescapeJSONString(m.key, into: &tmp)
    return tmp.view.equals(name)
}

/// ASCII digits only, no sign, greater than zero, fits in Int64.
public func parsePositiveInt(_ v: ByteView) -> Int64? {
    guard v.count > 0, v.count <= 19 else { return nil }
    var value: Int64 = 0
    for i in 0..<v.count {
        let d = v[i] &- 48
        guard d < 10 else { return nil }
        let (m, o1) = value.multipliedReportingOverflow(by: 10)
        let (s, o2) = m.addingReportingOverflow(Int64(d))
        guard !o1, !o2 else { return nil }
        value = s
    }
    return value > 0 ? value : nil
}

private func base64Value(_ c: UInt8) -> UInt32 {
    switch c {
    case 65...90: return UInt32(c &- 65)
    case 97...122: return UInt32(c &- 71)
    case 48...57: return UInt32(c &+ 4)
    case 45: return 62  // -
    case 95: return 63  // _
    default: return 0xFF
    }
}

/// Unpadded base64url into `out`. Returns false on invalid characters or length.
func base64URLDecode(_ v: ByteView, into out: inout OutBuffer) -> Bool {
    out.reserve(v.count &* 3 / 4 &+ 3)
    let start = out.count
    let n = base64URLDecodeRaw(v, into: out.base + start)
    guard n >= 0 else { return false }
    out.truncate(start &+ n)
    return true
}

/// Decodes into raw memory with room for count*3/4+3 bytes. Returns the length, or -1 on error.
func base64URLDecodeRaw(_ v: ByteView, into out: UnsafeMutablePointer<UInt8>) -> Int {
    let n = v.count
    guard n % 4 != 1 else { return -1 }
    var o = 0
    var i = 0
    while i &+ 4 <= n {
        let a = base64Value(v[i]), b = base64Value(v[i &+ 1]), c = base64Value(v[i &+ 2]), d = base64Value(v[i &+ 3])
        guard (a | b | c | d) & 0xC0 == 0 else { return -1 }
        let x = a << 18 | b << 12 | c << 6 | d
        out[o] = UInt8(truncatingIfNeeded: x >> 16)
        out[o &+ 1] = UInt8(truncatingIfNeeded: x >> 8)
        out[o &+ 2] = UInt8(truncatingIfNeeded: x)
        o &+= 3
        i &+= 4
    }
    let rest = n &- i
    if rest == 2 {
        let a = base64Value(v[i]), b = base64Value(v[i &+ 1])
        guard (a | b) & 0xC0 == 0 else { return -1 }
        out[o] = UInt8(truncatingIfNeeded: (a << 18 | b << 12) >> 16)
        o &+= 1
    } else if rest == 3 {
        let a = base64Value(v[i]), b = base64Value(v[i &+ 1]), c = base64Value(v[i &+ 2])
        guard (a | b | c) & 0xC0 == 0 else { return -1 }
        let x = a << 18 | b << 12 | c << 6
        out[o] = UInt8(truncatingIfNeeded: x >> 16)
        out[o &+ 1] = UInt8(truncatingIfNeeded: x >> 8)
        o &+= 2
    }
    return o
}

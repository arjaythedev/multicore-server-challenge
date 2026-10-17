// HS256 JWT issue/verify. No verification cache (SPEC.md rule: every request re-verifies).
import Crypto
import Foundation
import Hummingbird

let tokenTTLSeconds: Double = 30 * 24 * 3600

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

func issueToken(id: Int64, secret: SymmetricKey) -> String {
    let now = Date().timeIntervalSince1970
    let header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}"
    let payload = "{\"sub\":\"\(id)\",\"iat\":\(Int(now)),\"exp\":\(Int(now + tokenTTLSeconds))}"
    var signed = [UInt8]()
    signed.append(contentsOf: Array(b64urlEncode(Array(header.utf8)).utf8))
    signed.append(0x2E)
    signed.append(contentsOf: Array(b64urlEncode(Array(payload.utf8)).utf8))
    let sig = HMAC<SHA256>.authenticationCode(for: signed, using: secret)
    signed.append(0x2E)
    signed.append(contentsOf: Array(b64urlEncode(Array(sig)).utf8))
    return String(decoding: signed, as: UTF8.self)
}

extension SymmetricKey {
    /// Verify an HS256 JWT: signature (constant-time), alg, exp and a positive numeric sub.
    /// Returns the user id, or nil if the token is invalid.
    func verifyToken(_ token: String) -> Int64? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        guard let headerBytes = b64urlDecode(String(parts[0])) else { return nil }
        guard let payloadBytes = b64urlDecode(String(parts[1])) else { return nil }
        guard let sigBytes = b64urlDecode(String(parts[2])) else { return nil }

        // Signed data is "header.payload" verbatim (Go's jwt also uses the raw segments).
        var signed = [UInt8]()
        signed.append(contentsOf: Array(parts[0].utf8))
        signed.append(0x2E)
        signed.append(contentsOf: Array(parts[1].utf8))
        guard HMAC<SHA256>.isValidAuthenticationCode(sigBytes, authenticating: signed, using: self) else {
            return nil
        }

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

/// The Authorization header: absent -> anonymous; present but invalid -> 401 (SPEC.md "Authentication").
struct Auth {
    var viewer: Int64 = 0
    var token: String = ""

    static func extract(_ request: Request, secret: SymmetricKey) -> Auth {
        guard let header = request.headers[.authorization], !header.isEmpty else {
            return Auth()
        }
        guard header.hasPrefix("Token ") else { return Auth() } // present but invalid
        let token = String(header.dropFirst(6))
        guard let id = secret.verifyToken(token) else { return Auth() }
        return Auth(viewer: id, token: token)
    }

    /// Viewer for an auth-required endpoint: 0 means reject with 401.
    static func require(_ request: Request, secret: SymmetricKey) throws -> Auth {
        let auth = extract(request, secret: secret)
        guard auth.viewer != 0 else { throw ApiError(.unauthorized, "unauthorized") }
        return auth
    }

    /// Viewer for an auth-optional endpoint: a present-but-invalid header is a 401.
    static func optional(_ request: Request, secret: SymmetricKey) throws -> Auth {
        let auth = extract(request, secret: secret)
        let headerPresent = request.headers[.authorization].map { !$0.isEmpty } ?? false
        if headerPresent, auth.viewer == 0 { throw ApiError(.unauthorized, "unauthorized") }
        return auth
    }
}

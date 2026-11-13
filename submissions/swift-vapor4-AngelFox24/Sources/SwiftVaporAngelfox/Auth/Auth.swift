import Foundation
import JWT
import Vapor

/// JWT claims used by RealWorld: `sub` is the user id as a decimal string,
/// `iat` is the issue time and `exp` is 30 days later.
///
/// `iat`/`exp` are modelled as integers because the challenge conformance
/// requires whole Unix seconds, while JWTKit's `IssuedAtClaim`/`ExpirationClaim`
/// encode a `Date` as a fractional JSON number.
struct UserJWTPayload: JWTPayload {
    var sub: SubjectClaim
    var iat: Int64
    var exp: Int64

    func verify(using signer: JWTSigner) throws {
        guard exp > Int64(Date().timeIntervalSince1970) else {
            throw JWTError.claimVerificationFailure(name: "exp", reason: "expired")
        }
    }
}

struct AuthenticatedUser: Sendable {
    let id: Int
    let token: String
}

extension Request {
    /// Auth is optional on some endpoints and required on others.
    ///
    /// - No `Authorization` header on an optional endpoint -> anonymous viewer (id 0).
    /// - A header that is present but malformed or invalid -> always 401.
    func authenticate(required: Bool) async throws -> AuthenticatedUser? {
        guard let header = headers.first(name: .authorization), !header.isEmpty else {
            if required {
                throw APIError(.unauthorized, "unauthorized")
            }
            return nil
        }

        guard header.hasPrefix("Token ") else {
            throw APIError(.unauthorized, "unauthorized")
        }

        let token = String(header.dropFirst("Token ".count))
        do {
            let payload = try jwt.verify(token, as: UserJWTPayload.self)
            guard let id = Int(payload.sub.value), id > 0 else {
                throw APIError(.unauthorized, "unauthorized")
            }
            return AuthenticatedUser(id: id, token: token)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError(.unauthorized, "unauthorized")
        }
    }

    func requireUser() async throws -> AuthenticatedUser {
        guard let user = try await authenticate(required: true) else {
            throw APIError(.unauthorized, "unauthorized")
        }
        return user
    }
}

func issueToken(for userID: Int, on request: Request) async throws -> String {
    let now = Int64(Date().timeIntervalSince1970)
    let payload = UserJWTPayload(
        sub: SubjectClaim(value: String(userID)),
        iat: now,
        exp: now + 30 * 24 * 60 * 60
    )
    return try request.jwt.sign(payload)
}

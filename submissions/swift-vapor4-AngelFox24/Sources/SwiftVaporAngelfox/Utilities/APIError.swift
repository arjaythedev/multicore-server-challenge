import Fluent
import Vapor

/// Every endpoint returns RealWorld's error shape:
/// `{"errors": {"body": ["message"]}}`.
struct APIError: Error {
    let status: HTTPStatus
    let message: String

    init(_ status: HTTPStatus, _ message: String) {
        self.status = status
        self.message = message
    }
}

struct APIErrorBody: Content, Sendable {
    struct Errors: Content, Sendable {
        let body: [String]
    }

    let errors: Errors

    init(_ message: String) {
        self.errors = .init(body: [message])
    }
}

struct APIErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch let error as APIError {
            return try Self.response(status: error.status, message: error.message)
        } catch is DecodingError {
            // Vapor makes DecodingError conform to AbortError with 400; the
            // challenge contract wants 422 for invalid bodies and queries.
            return try Self.response(status: .unprocessableEntity, message: "invalid body")
        } catch let error as any AbortError {
            return try Self.response(status: error.status, message: error.reason)
        } catch {
            request.logger.report(error: error)
            return try Self.response(status: .internalServerError, message: "internal error")
        }
    }

    private static func response(status: HTTPStatus, message: String) throws -> Response {
        let response = Response(status: status)
        try response.content.encode(APIErrorBody(message))
        return response
    }
}

extension Error {
    /// Fluent wraps Postgres unique violations in a `DatabaseError`; both the
    /// registration and update flows turn those into a 422.
    var isConstraintFailure: Bool {
        (self as? any DatabaseError)?.isConstraintFailure ?? false
    }
}

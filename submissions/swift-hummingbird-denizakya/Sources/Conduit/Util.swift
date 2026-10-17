// Shared helpers: JSON writing, RFC 3339 timestamps, query/body parsing, errors.
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdCore
import PostgresNIO

struct ApiError: Error {
    let status: HTTPResponse.Status
    let message: String
    init(_ status: HTTPResponse.Status, _ message: String) {
        self.status = status
        self.message = message
    }
}

// ---------- responses ----------

func jsonResponse(_ status: HTTPResponse.Status, _ body: String) -> Response {
    var headers = HTTPFields()
    headers.append(HTTPField(name: .contentType, value: "application/json"))
    return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(string: body)))
}

func errorResponse(_ status: HTTPResponse.Status, _ message: String) -> Response {
    jsonResponse(status, "{\"errors\":{\"body\":[\(jsonEscape(message))]}}")
}

func internalErrorResponse(_ error: Error) -> Response {
    print("error: \(error)")
    return errorResponse(.internalServerError, "internal error")
}

// Run a handler, mapping ApiError to a JSON response and anything else to a 500.
func handle(_ request: Request, _ handler: () async throws -> Response) async throws -> Response {
    do {
        return try await handler()
    } catch let e as ApiError {
        return errorResponse(e.status, e.message)
    } catch {
        return internalErrorResponse(error)
    }
}

func isUniqueViolation(_ error: Error) -> Bool {
    if let e = error as? PSQLError, e.serverInfo?[.sqlState] == "23505" { return true }
    return false
}

// ---------- JSON writing ----------

let hexDigits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]

func jsonEscape(_ s: String) -> String {
    var out: [UInt8] = []
    out.reserveCapacity(s.utf8.count + 2)
    out.append(0x22) // "
    for b in s.utf8 {
        switch b {
        case 0x22: out.append(contentsOf: Array("\\\"".utf8)) // "
        case 0x5C: out.append(contentsOf: Array("\\\\".utf8)) // backslash
        case 0x08: out.append(contentsOf: Array("\\b".utf8))
        case 0x0C: out.append(contentsOf: Array("\\f".utf8))
        case 0x0A: out.append(contentsOf: Array("\\n".utf8))
        case 0x0D: out.append(contentsOf: Array("\\r".utf8))
        case 0x09: out.append(contentsOf: Array("\\t".utf8))
        case 0x00...0x1F:
            out.append(contentsOf: Array("\\u00".utf8))
            let hex: [UInt8] = Array("0123456789abcdef".utf8)
            out.append(hex[Int((b >> 4) & 0xF)])
            out.append(hex[Int(b & 0xF)])
        default:
            out.append(b)
        }
    }
    out.append(0x22)
    return String(decoding: out, as: UTF8.self)
}

// ---------- timestamps ----------

/// RFC 3339 UTC with exactly 3 fractional digits, truncated (SPEC.md "Formats").
func rfc3339ms(_ date: Date) -> String {
    var ms = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    let days = ms / 86_400_000
    ms -= days * 86_400_000
    let (y, m, d) = civilFromDays(days)
    let hh = ms / 3_600_000
    ms -= hh * 3_600_000
    let mm = ms / 60_000
    ms -= mm * 60_000
    let ss = ms / 1_000
    ms -= ss * 1_000
    var out = ""
    out.reserveCapacity(24)
    appendPadded(&out, y, 4); out.append("-")
    appendPadded(&out, m, 2); out.append("-")
    appendPadded(&out, d, 2); out.append("T")
    appendPadded(&out, hh, 2); out.append(":")
    appendPadded(&out, mm, 2); out.append(":")
    appendPadded(&out, ss, 2); out.append(".")
    appendPadded(&out, ms, 3); out.append("Z")
    return out
}

private func appendPadded(_ out: inout String, _ v: Int64, _ width: Int) {
    var digits = [UInt8](repeating: 0x30, count: width)
    var x = v
    var i = width - 1
    while i >= 0 {
        digits[i] = UInt8(0x30 + x % 10)
        x /= 10
        i -= 1
    }
    out.append(String(decoding: digits, as: UTF8.self))
}

/// Howard Hinnant's civil_from_days: days since 1970-01-01 -> (year, month [1-12], day [1-31]).
func civilFromDays(_ z: Int64) -> (Int64, Int64, Int64) {
    let z = z + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    return (m <= 2 ? y + 1 : y, m, d)
}

// ---------- query parameters ----------

/// First-value-wins query parser over the raw query string (matches Go's URL.Query()[k][0]).
struct QueryParams {
    private var values: [String: String] = [:]

    init(_ query: String?) {
        guard let query, !query.isEmpty else { return }
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let bytes = Array(pair.utf8)
            let eq = bytes.firstIndex(of: 0x3D)
            let keySlice: [UInt8] = eq.map { Array(bytes[0..<$0]) } ?? bytes
            guard let key = percentDecode(keySlice) else { continue }
            let valueSlice: [UInt8] = eq.map { Array(bytes[($0 + 1)...]) } ?? []
            let value = percentDecode(valueSlice) ?? ""
            if values[key] == nil { values[key] = value }
        }
    }

    func get(_ key: String) -> String? { values[key] }
}

func percentDecode(_ bytes: [UInt8]) -> String? {
    var out = [UInt8]()
    out.reserveCapacity(bytes.count)
    var i = 0
    while i < bytes.count {
        let b = bytes[i]
        if b == 0x2B { // +
            out.append(0x20)
            i += 1
        } else if b == 0x25, i + 2 < bytes.count,
                  let hi = hexVal(bytes[i + 1]), let lo = hexVal(bytes[i + 2]) {
            out.append(hi << 4 | lo)
            i += 3
        } else {
            out.append(b)
            i += 1
        }
    }
    return String(decoding: out, as: UTF8.self)
}

private func hexVal(_ b: UInt8) -> UInt8? {
    switch b {
    case 0x30...0x39: return b - 0x30
    case 0x41...0x46: return b - 0x41 + 10
    case 0x61...0x66: return b - 0x61 + 10
    default: return nil
    }
}

/// ASCII digits only (no sign, no spaces), fits in an Int64.
func parseUint(_ s: String) -> Int64? {
    if s.isEmpty { return nil }
    var n: Int64 = 0
    for b in s.utf8 {
        guard b >= 0x30, b <= 0x39 else { return nil }
        let d = Int64(b - 0x30)
        if n > (Int64.max - d) / 10 { return nil }
        n = n * 10 + d
    }
    return n
}

/// limit (default 20, 1-100) and offset (default 0, >= 0); a present-but-invalid value is a 422.
func limitOffset(_ query: QueryParams) throws -> (Int64, Int64) {
    var limit: Int64 = 20
    var offset: Int64 = 0
    if let raw = query.get("limit") {
        guard let n = parseUint(raw), n >= 1, n <= 100 else {
            throw ApiError(.unprocessableContent, "limit must be 1-100")
        }
        limit = n
    }
    if let raw = query.get("offset") {
        guard let n = parseUint(raw) else {
            throw ApiError(.unprocessableContent, "offset must be a non-negative integer")
        }
        offset = n
    }
    return (limit, offset)
}

// ---------- request bodies ----------

/// Parse the body as a JSON object and return the inner object under `key` (case-sensitive keys).
func readWrapper(_ request: Request, _ key: String) async throws -> [String: Any] {
    let buffer = try await request.body.collect(upTo: 1 << 20)
    let data = Data(buffer.readableBytesView)
    let top: Any
    do {
        top = try JSONSerialization.jsonObject(with: data)
    } catch {
        throw ApiError(.unprocessableContent, "invalid body")
    }
    guard let dict = top as? [String: Any], let inner = dict[key] as? [String: Any] else {
        throw ApiError(.unprocessableContent, "invalid body")
    }
    return inner
}

enum BodyError: Error { case invalid }

/// absent or null -> nil; a string -> value; anything else (or empty when nonEmpty) is invalid.
func optString(_ m: [String: Any], _ key: String, nonEmpty: Bool = false) throws -> String? {
    guard let raw = m[key] else { return nil }
    if raw is NSNull { return nil }
    guard let s = raw as? String else { throw BodyError.invalid }
    if nonEmpty, s.isEmpty { throw BodyError.invalid }
    return s
}

/// Must be present and a non-empty string.
func reqString(_ m: [String: Any], _ key: String) throws -> String {
    guard let s = try optString(m, key, nonEmpty: true) else { throw BodyError.invalid }
    return s
}

/// tagList: optional array of non-empty, non-null strings.
func optTagList(_ m: [String: Any]) throws -> [String] {
    guard let raw = m["tagList"], !(raw is NSNull) else { return [] }
    guard let items = raw as? [Any] else { throw BodyError.invalid }
    var tags = [String]()
    tags.reserveCapacity(items.count)
    for item in items {
        if item is NSNull { throw BodyError.invalid }
        guard let s = item as? String, !s.isEmpty else { throw BodyError.invalid }
        tags.append(s)
    }
    return tags
}

// ---------- row decoding helpers ----------

extension PostgresRow {
    /// O(1) positional cell access (PostgresRow itself is only a Sequence).
    func cell(_ i: Int) -> PostgresCell { PostgresRandomAccessRow(self)[i] }
}

extension PostgresCell {
    func text() throws -> String { try decode(String.self) }
    func textOrNull() throws -> String? { try decode(String?.self) }
    func int() throws -> Int64 { try decode(Int64.self) }
    func bool() throws -> Bool { try decode(Bool.self) }
    func date() throws -> Date { try decode(Date.self) }
    func textArray() throws -> [String] { try decode([String].self) ?? [] }
}

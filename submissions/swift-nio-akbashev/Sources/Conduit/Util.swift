// Shared helpers: JSON writing, RFC 3339 timestamps, query/body parsing, errors, column types.
import Foundation
import Logging
import NIOCore
import PostgresNIO

struct ApiError: Error {
    let status: Status
    let message: String
    init(_ status: Status, _ message: String) {
        self.status = status
        self.message = message
    }
}

// ---------- responses ----------

func errorResponse(_ status: Status, _ message: String) -> Response {
    var out = JSONWriter(capacity: 64)
    out.raw("{\"errors\":{\"body\":[")
    out.string(message)
    out.raw("]}}")
    return out.response(status)
}

func emptyResponse(_ status: Status) -> Response {
    JSONWriter(capacity: 0).response(status)
}

/// ApiError as its JSON response, anything else as a 500.
func errorResponse(for error: any Error) -> Response {
    if let e = error as? ApiError { return errorResponse(e.status, e.message) }
    App.logger.error("internal error", metadata: ["error": "\(error)"])
    return errorResponse(.internalServerError, "internal error")
}

/// Runs a handler; whatever it throws becomes its response.
func handle(_ handler: () async throws -> Response) async -> Answer {
    do {
        return .response(try await handler())
    } catch {
        return .response(errorResponse(for: error))
    }
}

func isUniqueViolation(_ error: any Error) -> Bool {
    if let e = error as? PSQLError, e.serverInfo?[.sqlState] == "23505" { return true }
    return false
}

// ---------- JSON writing ----------

/// Writes a JSON body straight into the response's ByteBuffer: no intermediate Strings, and column text goes from the
/// Postgres row's bytes to the response's bytes in one copy. ~Copyable, so the buffer can't be duplicated by accident
/// (a second reference would make the next write copy the whole buffer), and `response` consumes the writer.
struct JSONWriter: ~Copyable {
    /// Bytes kept free in front of the body for the response's head (Response.wire), which takes at most 120.
    static let headroom = 128

    private var buffer: ByteBuffer

    init(capacity: Int) {
        buffer = ByteBufferAllocator().buffer(capacity: Self.headroom + capacity)
        buffer.moveWriterIndex(forwardBy: Self.headroom)
        buffer.moveReaderIndex(forwardBy: Self.headroom)
    }

    consuming func response(_ status: Status) -> Response {
        Response(status: status, buffer: buffer)
    }

    /// The bytes written, for a batch's shared JSON (see `splice`).
    consuming func finish() -> ByteBuffer {
        buffer
    }

    /// Where the next byte goes, as an offset into the bytes written so far.
    var position: Int { buffer.readableBytes }

    /// Copies `range` (offsets as `position` gave them) of JSON written by another writer.
    mutating func splice(_ json: borrowing ByteBuffer, _ range: Range<Int32>) {
        buffer.writeBytes(json.readableBytesSpan.extracting(Int(range.lowerBound)..<Int(range.upperBound)))
    }

    /// JSON punctuation and keys, written verbatim.
    mutating func raw(_ s: StaticString) {
        buffer.writeStaticString(s)
    }

    mutating func string(_ s: String) { escaped(s.utf8.span) }
    mutating func string(_ s: Substring) { escaped(s.utf8.span) }
    mutating func string(_ t: borrowing PGText) { escaped(t.bytes.readableBytesUInt8Span) }

    mutating func stringOrNull(_ t: borrowing PGText?) {
        switch t {
        case .some(let t): string(t)
        case .none: raw("null")
        }
    }

    mutating func bool(_ b: Bool) {
        if b { raw("true") } else { raw("false") }
    }

    mutating func int(_ v: Int64) {
        var digits = InlineArray<20, UInt8>(repeating: 0)
        var x = v.magnitude
        var i = 20
        repeat {
            i -= 1
            digits[i] = 0x30 &+ UInt8(truncatingIfNeeded: x % 10)
            x /= 10
        } while x != 0
        if v < 0 { raw("-") }
        buffer.writeBytes(digits.span.extracting(i..<20).bytes)
    }

    /// `"YYYY-MM-DDTHH:MM:SS.mmmZ"`: RFC 3339 UTC with exactly 3 fractional digits, truncated (SPEC.md "Formats").
    mutating func timestamp(_ t: PGTimestamp) {
        var ms = t.unixMillis
        var days = ms / 86_400_000
        ms -= days * 86_400_000
        if ms < 0 { days -= 1; ms += 86_400_000 }
        let (y, m, d) = civilFromDays(days)
        var out = InlineArray<26, UInt8>(repeating: 0x30)
        out[0] = 0x22; out[5] = 0x2D; out[8] = 0x2D; out[11] = 0x54 // " - - T
        out[14] = 0x3A; out[17] = 0x3A; out[20] = 0x2E; out[24] = 0x5A; out[25] = 0x22 // : : . Z "
        putDigits(&out, y, at: 1, width: 4)
        putDigits(&out, m, at: 6, width: 2)
        putDigits(&out, d, at: 9, width: 2)
        putDigits(&out, ms / 3_600_000, at: 12, width: 2)
        putDigits(&out, ms / 60_000 % 60, at: 15, width: 2)
        putDigits(&out, ms / 1_000 % 60, at: 18, width: 2)
        putDigits(&out, ms % 1_000, at: 21, width: 3)
        buffer.writeBytes(out.span.bytes)
    }

    /// A quoted JSON string. Its exact escaped length is counted first, so the buffer grows at most once and every
    /// byte goes in with a plain store (`OutputRawSpan`) instead of a `ByteBuffer` write call of its own.
    private mutating func escaped(_ bytes: Span<UInt8>) {
        var length = bytes.count + 2
        for i in bytes.indices {
            let b = bytes[i]
            if b >= 0x20, b != 0x22, b != 0x5C { continue }
            switch b {
            case 0x22, 0x5C, 0x08, 0x0C, 0x0A, 0x0D, 0x09: length += 1 // \" \\ \b \f \n \r \t
            default: length += 5 // \u00XX
            }
        }
        let plain = length == bytes.count + 2
        buffer.writeWithOutputRawSpan(minimumWritableBytes: length) { out in
            out.append(0x22)
            if plain {
                for i in bytes.indices { out.append(bytes[i]) }
            } else {
                for i in bytes.indices {
                    let b = bytes[i]
                    if b >= 0x20, b != 0x22, b != 0x5C {
                        out.append(b)
                        continue
                    }
                    out.append(0x5C)
                    switch b {
                    case 0x22, 0x5C: out.append(b)
                    case 0x08: out.append(0x62) // b
                    case 0x0C: out.append(0x66) // f
                    case 0x0A: out.append(0x6E) // n
                    case 0x0D: out.append(0x72) // r
                    case 0x09: out.append(0x74) // t
                    default:
                        out.append(0x75) // u
                        out.append(0x30)
                        out.append(0x30)
                        out.append(hexDigit(b >> 4))
                        out.append(hexDigit(b & 0xF))
                    }
                }
            }
            out.append(0x22)
        }
    }
}

private func hexDigit(_ v: UInt8) -> UInt8 {
    v < 10 ? 0x30 + v : 0x57 + v // 0-9, a-f
}

private func putDigits(_ out: inout InlineArray<26, UInt8>, _ v: Int64, at start: Int, width: Int) {
    var x = v
    var i = start + width - 1
    while i >= start {
        out[i] = 0x30 &+ UInt8(truncatingIfNeeded: x % 10)
        x /= 10
        i -= 1
    }
}

// ---------- timestamps ----------

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

// ---------- rows ----------

/// A text column's bytes, still in the row's buffer (a ByteBuffer slice, not a copy). JSONWriter escapes them into the
/// response directly, so no String is ever built for them.
struct PGText {
    let bytes: ByteBuffer
}

/// A timestamptz as Postgres sends it: microseconds since 2000-01-01 UTC. Kept as an integer so the millisecond
/// truncation is exact; going through Date's Double puts about 1 timestamp in 9,000 a millisecond early.
struct PGTimestamp {
    let micros: Int64

    /// Milliseconds since 1970-01-01, rounded down.
    var unixMillis: Int64 {
        var ms = micros / 1000
        if micros % 1000 < 0 { ms -= 1 }
        return ms + 946_684_800_000
    }
}

enum RowError: Error {
    case missingColumn
    case unexpectedNull(String)
    case typeMismatch(String, PostgresDataType)
}

/// Reads a row's cells in order, straight from their bytes. Our SQL fixes every column's type, so there is no generic
/// PostgresDecodable call per cell, nor the runtime type-metadata lookups that come with one: Time Profiler put the
/// one-pass `row.decode((A, B, ...).self)` at 38% of the list handler.
struct RowCursor {
    private var cells: PostgresRow.Iterator

    init(_ row: PostgresRow) {
        cells = row.makeIterator()
    }

    private mutating func cell() throws -> PostgresCell {
        guard let cell = cells.next() else { throw RowError.missingColumn }
        return cell
    }

    /// The next cell's bytes, or nil for SQL NULL; the cell must be in binary format and of `type`.
    private mutating func binary(_ type: PostgresDataType) throws -> ByteBuffer? {
        let cell = try cell()
        guard cell.dataType == type, cell.format == .binary else { throw RowError.typeMismatch(cell.columnName, cell.dataType) }
        return cell.bytes
    }

    mutating func skip() throws {
        _ = try cell()
    }

    mutating func textOrNull() throws -> PGText? {
        let cell = try cell()
        switch cell.dataType {
        case .text, .varchar, .bpchar, .name: return cell.bytes.map(PGText.init(bytes:))
        default: throw RowError.typeMismatch(cell.columnName, cell.dataType)
        }
    }

    mutating func text() throws -> PGText {
        guard let text = try textOrNull() else { throw RowError.unexpectedNull("text") }
        return text
    }

    mutating func intOrNull() throws -> Int64? {
        guard var bytes = try binary(.int8) else { return nil }
        guard bytes.readableBytes == 8, let value = bytes.readInteger(as: Int64.self) else {
            throw RowError.typeMismatch("bigint", .int8)
        }
        return value
    }

    mutating func int() throws -> Int64 {
        guard let value = try intOrNull() else { throw RowError.unexpectedNull("bigint") }
        return value
    }

    mutating func int4() throws -> Int32 {
        guard var bytes = try binary(.int4) else { throw RowError.unexpectedNull("int") }
        guard bytes.readableBytes == 4, let value = bytes.readInteger(as: Int32.self) else {
            throw RowError.typeMismatch("int", .int4)
        }
        return value
    }

    mutating func bool() throws -> Bool {
        guard let bytes = try binary(.bool) else { throw RowError.unexpectedNull("bool") }
        guard bytes.readableBytes == 1, let value = bytes.getInteger(at: bytes.readerIndex, as: UInt8.self) else {
            throw RowError.typeMismatch("bool", .bool)
        }
        return value != 0
    }

    mutating func timestampOrNull() throws -> PGTimestamp? {
        let cell = try cell()
        guard cell.dataType == .timestamptz || cell.dataType == .timestamp, cell.format == .binary else {
            throw RowError.typeMismatch(cell.columnName, cell.dataType)
        }
        guard var bytes = cell.bytes else { return nil }
        guard bytes.readableBytes == 8, let micros = bytes.readInteger(as: Int64.self) else {
            throw RowError.typeMismatch(cell.columnName, cell.dataType)
        }
        return PGTimestamp(micros: micros)
    }

    mutating func timestamp() throws -> PGTimestamp {
        guard let value = try timestampOrNull() else { throw RowError.unexpectedNull("timestamptz") }
        return value
    }

    /// A one-dimensional text[] in Postgres's binary array format: a header (dimensions, has-nulls flag, element type,
    /// then each dimension's length and lower bound), then each element's length and bytes. Elements stay slices.
    mutating func textArray() throws -> [PGText] {
        guard var bytes = try binary(.textArray) else { throw RowError.unexpectedNull("text[]") }
        let count = try Self.arrayHeader(&bytes, "text[]", .textArray)
        var elements = [PGText]()
        elements.reserveCapacity(count)
        for _ in 0..<count {
            guard let length = bytes.readInteger(as: Int32.self), length >= 0,
                  let element = bytes.readSlice(length: Int(length)) else { throw RowError.typeMismatch("text[]", .textArray) }
            elements.append(PGText(bytes: element))
        }
        return elements
    }

    /// A one-dimensional int4[] in the same format, without NULL elements.
    mutating func int4Array() throws -> [Int32] {
        guard var bytes = try binary(.int4Array) else { throw RowError.unexpectedNull("int4[]") }
        let count = try Self.arrayHeader(&bytes, "int4[]", .int4Array)
        var elements = [Int32]()
        elements.reserveCapacity(count)
        for _ in 0..<count {
            guard bytes.readInteger(as: Int32.self) == 4, let element = bytes.readInteger(as: Int32.self) else {
                throw RowError.typeMismatch("int4[]", .int4Array)
            }
            elements.append(element)
        }
        return elements
    }

    /// Reads a binary array's header; returns its element count (0 for an empty array).
    private static func arrayHeader(_ bytes: inout ByteBuffer, _ name: String, _ type: PostgresDataType) throws -> Int {
        guard let dimensions = bytes.readInteger(as: Int32.self), bytes.readInteger(as: Int32.self) != nil,
              bytes.readInteger(as: UInt32.self) != nil else { throw RowError.typeMismatch(name, type) }
        if dimensions == 0 { return 0 }
        guard dimensions == 1, let count = bytes.readInteger(as: Int32.self), count >= 0,
              bytes.readInteger(as: Int32.self) != nil else { throw RowError.typeMismatch(name, type) }
        return Int(count)
    }
}

// ---------- query parameters ----------

/// First-value-wins query parser over the raw query string (matches Go's URL.Query()[k][0]).
/// Each lookup scans the query's bytes in place, a slice of the request's; only the value it returns becomes a String.
struct QueryParams {
    private let query: ByteBuffer

    init(_ query: ByteBuffer) {
        self.query = query
    }

    func get(_ key: String) -> String? {
        let bytes = query.readableBytesUInt8Span
        var start = 0
        while start < bytes.count {
            var end = start
            while end < bytes.count, bytes[end] != 0x26 { end += 1 } // &
            if end > start {
                let pair = bytes.extracting(start..<end)
                var eq = 0
                while eq < pair.count, pair[eq] != 0x3D { eq += 1 } // =
                let rawKey = pair.extracting(0..<eq)
                if needsDecoding(rawKey) ? percentDecode(rawKey) == key : bytesEqual(rawKey, key.utf8.span) {
                    return eq < pair.count ? percentDecode(pair.extracting((eq + 1)..<pair.count)) : ""
                }
            }
            start = end + 1
        }
        return nil
    }
}

private func needsDecoding(_ bytes: Span<UInt8>) -> Bool {
    for i in bytes.indices where bytes[i] == 0x25 || bytes[i] == 0x2B { return true } // % +
    return false
}

func percentDecode(_ bytes: Span<UInt8>) -> String {
    if !needsDecoding(bytes), let utf8 = try? UTF8Span(validating: bytes) {
        return String(copying: utf8)
    }
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

/// A path segment, percent-decoded ('+' stays itself in a path); nil if an escape is malformed or the bytes are not
/// UTF-8.
func percentDecodePath(_ bytes: Span<UInt8>) -> String? {
    var escaped = false
    for i in bytes.indices where bytes[i] == 0x25 { escaped = true; break } // %
    if !escaped {
        guard let utf8 = try? UTF8Span(validating: bytes) else { return nil }
        return String(copying: utf8)
    }
    var out = [UInt8]()
    out.reserveCapacity(bytes.count)
    var i = 0
    while i < bytes.count {
        if bytes[i] == 0x25 {
            guard i + 2 < bytes.count, let hi = hexVal(bytes[i + 1]), let lo = hexVal(bytes[i + 2]) else { return nil }
            out.append(hi << 4 | lo)
            i += 3
        } else {
            out.append(bytes[i])
            i += 1
        }
    }
    return String(validating: out, as: UTF8.self)
}

private func hexVal(_ b: UInt8) -> UInt8? {
    switch b {
    case 0x30...0x39: return b - 0x30
    case 0x41...0x46: return b - 0x41 + 10
    case 0x61...0x66: return b - 0x61 + 10
    default: return nil
    }
}

func bytesEqual(_ a: Span<UInt8>, _ b: Span<UInt8>) -> Bool {
    guard a.count == b.count else { return false }
    for i in a.indices where a[i] != b[i] { return false }
    return true
}

/// ASCII digits only (no sign, no spaces), fits in an Int64.
func parseUint(_ bytes: Span<UInt8>) -> Int64? {
    if bytes.isEmpty { return nil }
    var n: Int64 = 0
    for i in bytes.indices {
        let b = bytes[i]
        guard b >= 0x30, b <= 0x39 else { return nil }
        let d = Int64(b - 0x30)
        if n > (Int64.max - d) / 10 { return nil }
        n = n * 10 + d
    }
    return n
}

func parseUint(_ s: String) -> Int64? {
    parseUint(s.utf8.span)
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
func readWrapper(_ body: ByteBuffer, _ key: String) throws -> [String: Any] {
    let data = Data(body.readableBytesView)
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

/// absent or null -> nil; a string -> value; anything else (or empty when nonEmpty) is invalid. So is a string with
/// NUL in it: Postgres text can't hold one, and as a parameter it would fail the whole group or batch it went in.
func optString(_ m: [String: Any], _ key: String, nonEmpty: Bool = false) throws -> String? {
    guard let raw = m[key] else { return nil }
    if raw is NSNull { return nil }
    guard let s = raw as? String, !s.utf8.contains(0) else { throw BodyError.invalid }
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
        guard let s = item as? String, !s.isEmpty, !s.utf8.contains(0) else { throw BodyError.invalid }
        tags.append(s)
    }
    return tags
}

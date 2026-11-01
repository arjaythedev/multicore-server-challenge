// codec.rs: byte search, the JSON writer (strings, integers, RFC 3339 timestamps), base64 and base64url, and the JSON
// parser for request bodies and JWT claims. Readers take a `Span`; the parser is a ~Escapable view over one.
import Glibc

/// The first `needle` in `hay[from..<end]` (memchr: glibc's vectorized search, where the Rust uses SSE2).
@inline(__always) func findByte(_ hay: Span<UInt8>, _ needle: UInt8, from: Int = 0, end: Int? = nil) -> Int? {
    let end = end ?? hay.count
    guard from < end else { return nil }
    return hay.withUnsafeBufferPointer { buf -> Int? in
        guard let hit = memchr(buf.baseAddress! + from, Int32(needle), end - from) else { return nil }
        return UnsafeRawPointer(buf.baseAddress!).distance(to: UnsafeRawPointer(hit))
    }
}

/// The index of the first "\r\n" at or after `from`.
@inline(__always) func findCRLF(_ hay: Span<UInt8>, from: Int = 0) -> Int? {
    guard hay.count >= 2 else { return nil }
    let last = hay.count - 1
    var pos = from
    while pos < last {
        guard let idx = findByte(hay, 0x0D, from: pos, end: last) else { return nil }
        if hay[idx + 1] == 0x0A { return idx }
        pos = idx + 1
    }
    return nil
}

func fillRandom(_ dst: UnsafeMutableRawBufferPointer) -> Bool {
    var done = 0
    while done < dst.count {
        let n = sys_getrandom(dst.baseAddress! + done, dst.count - done, 0)
        if n < 0 {
            if errno == Sys.EINTR { continue }
            return false
        }
        done += n
    }
    return true
}

// ---------- JSON output ----------

private let maskLo: UInt64 = 0x0101_0101_0101_0101
private let maskHi: UInt64 = 0x8080_8080_8080_8080

/// Whether any of 8 bytes is a control character, a quote or a backslash (SWAR).
@inline(__always) private func hasSpecial8(_ word: UInt64) -> Bool {
    let q = word ^ (maskLo &* 0x22)
    let bs = word ^ (maskLo &* 0x5C)
    let ctrl = (word &- maskLo &* 0x20) | ((q &- maskLo) & ~q) | ((bs &- maskLo) & ~bs)
    return (ctrl & ~word & maskHi) != 0
}

/// Whether 16 bytes need no escaping (the Rust's SSE2 `chunk16_clean`, as portable SIMD).
@inline(__always) private func chunk16Clean(_ raw: UnsafeRawBufferPointer, _ at: Int) -> Bool {
    let v = raw.loadUnaligned(fromByteOffset: at, as: SIMD16<UInt8>.self)
    let special = (v .== SIMD16(repeating: 0x22)) .| (v .== SIMD16(repeating: 0x5C)) .| (v .< SIMD16(repeating: 0x20))
    return !any(special)
}

private let hexDigits: StaticString = "0123456789abcdef"

/// `src` as a JSON string, quotes included.
func writeStr(_ dst: inout ByteBuffer, _ src: Span<UInt8>) {
    src.withUnsafeBytes { raw in
        let n = raw.count
        dst.append(0x22)
        var pos = 0
        while pos + 16 <= n, chunk16Clean(raw, pos) { pos += 16 }
        while pos + 8 <= n, !hasSpecial8(UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: pos, as: UInt64.self))) {
            pos += 8
        }
        while pos < n {
            let c = raw[pos]
            if c < 0x20 || c == 0x22 || c == 0x5C { break }
            pos += 1
        }
        if pos == n {
            dst.append(raw)
            dst.append(0x22)
            return
        }
        dst.append(UnsafeRawBufferPointer(rebasing: raw[0..<pos]))
        var anchor = pos
        var idx = pos
        while idx < n {
            if idx + 16 <= n, chunk16Clean(raw, idx) {
                idx += 16
                continue
            }
            let c = raw[idx]
            let escape: StaticString
            switch c {
            case 0x22: escape = "\\\""
            case 0x5C: escape = "\\\\"
            case 0x0A: escape = "\\n"
            case 0x0D: escape = "\\r"
            case 0x09: escape = "\\t"
            case 0x00...0x1F: escape = ""
            default:
                idx += 1
                continue
            }
            dst.append(UnsafeRawBufferPointer(rebasing: raw[anchor..<idx]))
            if escape.utf8CodeUnitCount == 0 {
                dst.append("\\u00")
                dst.append(hexDigits.utf8Start[Int(c >> 4)])
                dst.append(hexDigits.utf8Start[Int(c & 0x0F)])
            } else {
                dst.append(escape)
            }
            anchor = idx + 1
            idx += 1
        }
        dst.append(UnsafeRawBufferPointer(rebasing: raw[anchor..<n]))
        dst.append(0x22)
    }
}

@inline(__always) func writeStr(_ dst: inout ByteBuffer, _ src: borrowing [UInt8]) {
    writeStr(&dst, src.span)
}

@inline(__always) func writeStr(_ dst: inout ByteBuffer, _ literal: StaticString) {
    writeStr(&dst, Span(_unsafeElements: UnsafeBufferPointer(start: literal.utf8Start, count: literal.utf8CodeUnitCount)))
}

@inline(__always) func writeNullableStr(_ dst: inout ByteBuffer, _ value: Span<UInt8>?) {
    if let value { writeStr(&dst, value) } else { dst.append("null") }
}

@inline(__always) func writeNullableStr(_ dst: inout ByteBuffer, _ value: [UInt8]?) {
    if let value { writeStr(&dst, value.span) } else { dst.append("null") }
}

private let decDigits: StaticString = """
    00010203040506070809101112131415161718192021222324252627282930313233343536373839\
    40414243444546474849505152535455565758596061626364656667686970717273747576777879\
    8081828384858687888990919293949596979899
    """

/// The decimal digits of `n` (Rust's `format_u64_into`, two digits per step).
@inline(__always) func appendU64(_ dst: inout ByteBuffer, _ value: UInt64) {
    var digits = InlineArray<20, UInt8>(repeating: 0)
    var pos = 20
    var n = value
    let lut = decDigits.utf8Start
    while n >= 100 {
        let rem = Int((n % 100) * 2)
        n /= 100
        pos -= 2
        digits[pos] = lut[rem]
        digits[pos + 1] = lut[rem + 1]
    }
    if n < 10 {
        pos -= 1
        digits[pos] = 0x30 + UInt8(n)
    } else {
        let rem = Int(n * 2)
        pos -= 2
        digits[pos] = lut[rem]
        digits[pos + 1] = lut[rem + 1]
    }
    dst.append(digits.span.extracting(pos..<20))
}

@inline(__always) func writeI64(_ dst: inout ByteBuffer, _ value: Int64) {
    if value < 0 { dst.append(0x2D) }
    appendU64(&dst, value.magnitude)
}

@inline(__always) func writeBool(_ dst: inout ByteBuffer, _ value: Bool) {
    dst.append(value ? "true" : "false")
}

@inline(__always) private func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
    let q = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
}

@inline(__always) private func floorMod(_ a: Int64, _ b: Int64) -> Int64 {
    let r = a % b
    return r < 0 ? r + b : r
}

private func ymdFromUnixDays(_ days: Int64) -> (year: Int64, month: UInt32, day: UInt32) {
    let z = days + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = UInt64(z - era * 146_097)
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
    let y = Int64(yoe) + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = UInt32(doy - (153 * mp + 2) / 5 + 1)
    let m = UInt32(mp < 10 ? mp + 3 : mp - 9)
    return (m <= 2 ? y + 1 : y, m, d)
}

/// A Postgres binary timestamptz (microseconds since 2000-01-01 UTC) as a quoted RFC 3339 string with milliseconds.
func writeTimestamp(_ dst: inout ByteBuffer, _ pgMicros: Int64) {
    let totalUs = pgMicros + 946_684_800_000_000
    let totalMs = floorDiv(totalUs, 1000)
    let totalSec = floorDiv(totalMs, 1000)
    let millis = UInt32(floorMod(totalMs, 1000))
    let days = floorDiv(totalSec, 86_400)
    let daySec = UInt32(floorMod(totalSec, 86_400))
    let (year, month, day) = ymdFromUnixDays(days)
    let y = UInt32(truncatingIfNeeded: year)
    let hh = daySec / 3600, mm = (daySec / 60) % 60, ss = daySec % 60
    @inline(__always) func digit(_ v: UInt32) -> UInt8 { 0x30 + UInt8(v % 10) }
    let out: InlineArray<26, UInt8> = [
        0x22, digit(y / 1000), digit(y / 100), digit(y / 10), digit(y), 0x2D,
        digit(month / 10), digit(month), 0x2D, digit(day / 10), digit(day), 0x54,
        digit(hh / 10), digit(hh), 0x3A, digit(mm / 10), digit(mm), 0x3A, digit(ss / 10), digit(ss), 0x2E,
        digit(millis / 100), digit(millis / 10), digit(millis), 0x5A, 0x22,
    ]
    dst.append(out.span)
}

// ---------- base64 ----------

private let b64StdAlphabet: StaticString = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
private let b64UrlAlphabet: StaticString = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

/// A base64url character's value, 0xFF if it isn't one.
@inline(__always) private func b64UrlValue(_ c: UInt8) -> UInt8 {
    switch c {
    case 0x41...0x5A: c - 0x41
    case 0x61...0x7A: c - 0x61 + 26
    case 0x30...0x39: c - 0x30 + 52
    case 0x2D: 62
    case 0x5F: 63
    default: 0xFF
    }
}

@inline(__always) private func b64StdValue(_ c: UInt8) -> UInt8 {
    switch c {
    case 0x41...0x5A: c - 0x41
    case 0x61...0x7A: c - 0x61 + 26
    case 0x30...0x39: c - 0x30 + 52
    case 0x2B: 62
    case 0x2F: 63
    default: 0xFF
    }
}

/// base64url without padding, appended.
func b64UrlEncode(_ src: Span<UInt8>, into out: inout ByteBuffer) {
    let enc = b64UrlAlphabet.utf8Start
    var i = 0
    while i + 3 <= src.count {
        let n = UInt32(src[i]) << 16 | UInt32(src[i + 1]) << 8 | UInt32(src[i + 2])
        out.append(enc[Int(n >> 18 & 0x3F)])
        out.append(enc[Int(n >> 12 & 0x3F)])
        out.append(enc[Int(n >> 6 & 0x3F)])
        out.append(enc[Int(n & 0x3F)])
        i += 3
    }
    let rem = src.count - i
    if rem == 1 {
        let n = UInt32(src[i]) << 16
        out.append(enc[Int(n >> 18 & 0x3F)])
        out.append(enc[Int(n >> 12 & 0x3F)])
    } else if rem == 2 {
        let n = UInt32(src[i]) << 16 | UInt32(src[i + 1]) << 8
        out.append(enc[Int(n >> 18 & 0x3F)])
        out.append(enc[Int(n >> 12 & 0x3F)])
        out.append(enc[Int(n >> 6 & 0x3F)])
    }
}

/// Decodes unpadded base64url into `dst`; the byte count, or nil if `src` isn't base64url or `dst` is too small.
func b64UrlDecode(_ src: Span<UInt8>, into dst: inout MutableSpan<UInt8>) -> Int? {
    if src.count % 4 == 1 { return nil }
    let needed = (src.count / 4) * 3 + (src.count % 4 == 2 ? 1 : src.count % 4 == 3 ? 2 : 0)
    if dst.count < needed { return nil }
    var si = 0
    var di = 0
    while si + 4 <= src.count {
        let a = b64UrlValue(src[si]), b = b64UrlValue(src[si + 1]), c = b64UrlValue(src[si + 2]), d = b64UrlValue(src[si + 3])
        if (a | b | c | d) & 0x80 != 0 { return nil }
        let n = UInt32(a) << 18 | UInt32(b) << 12 | UInt32(c) << 6 | UInt32(d)
        dst[di] = UInt8(truncatingIfNeeded: n >> 16)
        dst[di + 1] = UInt8(truncatingIfNeeded: n >> 8)
        dst[di + 2] = UInt8(truncatingIfNeeded: n)
        si += 4
        di += 3
    }
    let rem = src.count - si
    if rem == 2 {
        let a = b64UrlValue(src[si]), b = b64UrlValue(src[si + 1])
        if (a | b) & 0x80 != 0 || b & 0x0F != 0 { return nil }
        dst[di] = a << 2 | b >> 4
        di += 1
    } else if rem == 3 {
        let a = b64UrlValue(src[si]), b = b64UrlValue(src[si + 1]), c = b64UrlValue(src[si + 2])
        if (a | b | c) & 0x80 != 0 || c & 0x03 != 0 { return nil }
        let n = UInt32(a) << 18 | UInt32(b) << 12 | UInt32(c) << 6
        dst[di] = UInt8(truncatingIfNeeded: n >> 16)
        dst[di + 1] = UInt8(truncatingIfNeeded: n >> 8)
        di += 2
    }
    return di
}

func b64UrlDecodeArray(_ src: Span<UInt8>) -> [UInt8]? {
    var out = [UInt8](repeating: 0, count: (src.count * 3) / 4 + 3)
    var dst = out.mutableSpan
    guard let n = b64UrlDecode(src, into: &dst) else { return nil }
    out.removeLast(out.count - n)
    return out
}

/// Padded standard base64 (SCRAM).
func b64StdEncode(_ src: borrowing [UInt8]) -> [UInt8] {
    let enc = b64StdAlphabet.utf8Start
    var out: [UInt8] = []
    out.reserveCapacity((src.count + 2) / 3 * 4)
    var i = 0
    while i + 3 <= src.count {
        let n = UInt32(src[i]) << 16 | UInt32(src[i + 1]) << 8 | UInt32(src[i + 2])
        out.append(enc[Int(n >> 18 & 0x3F)])
        out.append(enc[Int(n >> 12 & 0x3F)])
        out.append(enc[Int(n >> 6 & 0x3F)])
        out.append(enc[Int(n & 0x3F)])
        i += 3
    }
    let rem = src.count - i
    if rem == 1 {
        let n = UInt32(src[i]) << 16
        out.append(enc[Int(n >> 18 & 0x3F)])
        out.append(enc[Int(n >> 12 & 0x3F)])
        out.append(0x3D)
        out.append(0x3D)
    } else if rem == 2 {
        let n = UInt32(src[i]) << 16 | UInt32(src[i + 1]) << 8
        out.append(enc[Int(n >> 18 & 0x3F)])
        out.append(enc[Int(n >> 12 & 0x3F)])
        out.append(enc[Int(n >> 6 & 0x3F)])
        out.append(0x3D)
    }
    return out
}

func b64StdDecode(_ bytes: Span<UInt8>) -> [UInt8]? {
    if bytes.count == 0 { return [] }
    if bytes.count % 4 != 0 { return nil }
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count / 4 * 3)
    var i = 0
    while i < bytes.count {
        let a = b64StdValue(bytes[i]), b = b64StdValue(bytes[i + 1])
        if (a | b) & 0x80 != 0 { return nil }
        let cRaw = bytes[i + 2], dRaw = bytes[i + 3]
        if cRaw == 0x3D {
            if dRaw != 0x3D || i + 4 != bytes.count || b & 0x0F != 0 { return nil }
            out.append(a << 2 | b >> 4)
            break
        }
        let c = b64StdValue(cRaw)
        if c & 0x80 != 0 { return nil }
        if dRaw == 0x3D {
            if i + 4 != bytes.count || c & 0x03 != 0 { return nil }
            let n = UInt32(a) << 18 | UInt32(b) << 12 | UInt32(c) << 6
            out.append(UInt8(truncatingIfNeeded: n >> 16))
            out.append(UInt8(truncatingIfNeeded: n >> 8))
            break
        }
        let d = b64StdValue(dRaw)
        if d & 0x80 != 0 { return nil }
        let n = UInt32(a) << 18 | UInt32(b) << 12 | UInt32(c) << 6 | UInt32(d)
        out.append(UInt8(truncatingIfNeeded: n >> 16))
        out.append(UInt8(truncatingIfNeeded: n >> 8))
        out.append(UInt8(truncatingIfNeeded: n))
        i += 4
    }
    return out
}

// ---------- JSON input ----------

/// Whether `bytes` is valid UTF-8 (Rust's `str::from_utf8`), by the standard library's validator.
@inline(__always) func isValidUTF8(_ bytes: Span<UInt8>) -> Bool {
    (try? UTF8Span(validating: bytes)) != nil
}

/// memcmp of `n` bytes, where a pointer may be nil only if `n` is 0.
@inline(__always) func compareBytes(_ a: UnsafeRawPointer?, _ b: UnsafeRawPointer?, _ n: Int) -> Int32 {
    n == 0 ? 0 : memcmp(a!, b!, n)
}

@inline(__always) func bytesEqual(_ a: borrowing [UInt8], _ b: StaticString) -> Bool {
    a.count == b.utf8CodeUnitCount && a.withUnsafeBytes { compareBytes($0.baseAddress, b.utf8Start, a.count) == 0 }
}

@inline(__always) func spanEqual(_ a: Span<UInt8>, _ b: StaticString) -> Bool {
    a.count == b.utf8CodeUnitCount && a.withUnsafeBytes { compareBytes($0.baseAddress, b.utf8Start, a.count) == 0 }
}

/// A parsed JSON value. Strings are their UTF-8 bytes (validated), compared byte for byte as the Rust's are.
enum JsonVal: Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string([UInt8])
    case array([JsonVal])
    case object(JsonMap)

    var string: [UInt8]? {
        if case .string(let s) = self { s } else { nil }
    }

    var number: Double? {
        if case .number(let n) = self { n } else { nil }
    }

    var object: JsonMap? {
        if case .object(let m) = self { m } else { nil }
    }

    func get(_ key: StaticString) -> JsonVal? { object?.get(key) }
}

struct JsonMap: Sendable {
    struct Entry: Sendable {
        var key: [UInt8]
        var value: JsonVal
    }

    private(set) var entries: [Entry] = []

    func get(_ key: StaticString) -> JsonVal? {
        entries.last { bytesEqual($0.key, key) }?.value
    }

    mutating func remove(_ key: StaticString) -> JsonVal? {
        guard let pos = entries.lastIndex(where: { bytesEqual($0.key, key) }) else { return nil }
        let value = entries.remove(at: pos).value
        entries.removeAll { bytesEqual($0.key, key) }
        return value
    }

    var values: [JsonVal] { entries.map(\.value) }

    mutating func insert(_ key: [UInt8], _ value: JsonVal) {
        if let i = entries.firstIndex(where: { $0.key == key }) {
            entries[i].value = value
        } else {
            entries.append(Entry(key: key, value: value))
        }
    }
}

func parseJson(_ src: Span<UInt8>) -> JsonVal? {
    var p = JsonParser(src)
    guard let value = p.parseValue(depth: 0) else { return nil }
    p.skipWhitespace()
    return p.pos == src.count ? value : nil
}

/// A recursive-descent parser over a borrowed body: it can't outlive the bytes it reads.
struct JsonParser: ~Escapable {
    let src: Span<UInt8>
    var pos = 0

    @_lifetime(copy src)
    init(_ src: Span<UInt8>) {
        self.src = src
    }

    @inline(__always) mutating func skipWhitespace() {
        while pos < src.count {
            switch src[pos] {
            case 0x20, 0x09, 0x0D, 0x0A: pos += 1
            default: return
            }
        }
    }

    @inline(__always) private func at(_ offset: Int = 0) -> UInt8? {
        pos + offset < src.count ? src[pos + offset] : nil
    }

    private func matches(_ literal: StaticString) -> Bool {
        let n = literal.utf8CodeUnitCount
        guard pos + n <= src.count else { return false }
        return spanEqual(src.extracting(pos..<(pos + n)), literal)
    }

    mutating func parseValue(depth: Int) -> JsonVal? {
        if depth > 64 { return nil }
        skipWhitespace()
        guard let b = at() else { return nil }
        switch b {
        case 0x22: return parseString().map(JsonVal.string)
        case 0x7B: return parseObject(depth: depth + 1).map(JsonVal.object)
        case 0x5B: return parseArray(depth: depth + 1).map(JsonVal.array)
        case 0x74:
            guard matches("true") else { return nil }
            pos += 4
            return .bool(true)
        case 0x66:
            guard matches("false") else { return nil }
            pos += 5
            return .bool(false)
        case 0x6E:
            guard matches("null") else { return nil }
            pos += 4
            return .null
        case 0x2D, 0x30...0x39: return parseNumber().map(JsonVal.number)
        default: return nil
        }
    }

    mutating func parseString() -> [UInt8]? {
        pos += 1
        let start = pos
        while pos < src.count {
            let c = src[pos]
            if c == 0x22 {
                let segment = src.extracting(start..<pos)
                guard isValidUTF8(segment) else { return nil }
                pos += 1
                return segment.withUnsafeBufferPointer { Array($0) }
            }
            if c == 0x5C { return parseStringEscaped(start) }
            if c < 0x20 { return nil }
            pos += 1
        }
        return nil
    }

    private mutating func parseStringEscaped(_ start: Int) -> [UInt8]? {
        let head = src.extracting(start..<pos)
        guard isValidUTF8(head) else { return nil }
        var out = head.withUnsafeBufferPointer { Array($0) }
        while pos < src.count {
            let c = src[pos]
            if c == 0x22 {
                pos += 1
                return out
            }
            if c < 0x20 { return nil }
            if c != 0x5C {
                let segStart = pos
                pos += 1
                while pos < src.count {
                    let b = src[pos]
                    if b == 0x22 || b == 0x5C || b < 0x20 { break }
                    pos += 1
                }
                let segment = src.extracting(segStart..<pos)
                guard isValidUTF8(segment) else { return nil }
                segment.withUnsafeBufferPointer { out.append(contentsOf: $0) }
                continue
            }
            pos += 1
            guard let esc = at() else { return nil }
            pos += 1
            switch esc {
            case 0x22: out.append(0x22)
            case 0x5C: out.append(0x5C)
            case 0x2F: out.append(0x2F)
            case 0x62: out.append(0x08)
            case 0x66: out.append(0x0C)
            case 0x6E: out.append(0x0A)
            case 0x72: out.append(0x0D)
            case 0x74: out.append(0x09)
            case 0x75:
                guard let u1 = readHex4() else { return nil }
                let code: UInt32
                if (0xD800...0xDBFF).contains(u1) {
                    guard matches("\\u") else { return nil }
                    pos += 2
                    guard let u2 = readHex4(), (0xDC00...0xDFFF).contains(u2) else { return nil }
                    code = 0x10000 + (UInt32(u1 - 0xD800) << 10) + UInt32(u2 - 0xDC00)
                } else if (0xDC00...0xDFFF).contains(u1) {
                    return nil
                } else {
                    code = UInt32(u1)
                }
                guard let scalar = Unicode.Scalar(code) else { return nil }
                out.append(contentsOf: UTF8.encode(scalar)!)
            default:
                return nil
            }
        }
        return nil
    }

    private mutating func readHex4() -> UInt16? {
        guard pos + 4 <= src.count else { return nil }
        var value: UInt16 = 0
        for i in 0..<4 {
            let b = src[pos + i]
            let d: UInt8
            switch b {
            case 0x30...0x39: d = b - 0x30
            case 0x61...0x66: d = b - 0x61 + 10
            case 0x41...0x46: d = b - 0x41 + 10
            default: return nil
            }
            value = value << 4 | UInt16(d)
        }
        pos += 4
        return value
    }

    private mutating func skipDigits() {
        while let b = at(), (0x30...0x39).contains(b) { pos += 1 }
    }

    mutating func parseNumber() -> Double? {
        let start = pos
        if at() == 0x2D { pos += 1 }
        guard let first = at() else { return nil }
        if first == 0x30 {
            pos += 1
            if let b = at(), (0x30...0x39).contains(b) { return nil }
        } else if (0x30...0x39).contains(first) {
            skipDigits()
        } else {
            return nil
        }
        if at() == 0x2E {
            pos += 1
            let fracStart = pos
            skipDigits()
            if pos == fracStart { return nil }
        }
        if let e = at(), e == 0x65 || e == 0x45 {
            pos += 1
            if let s = at(), s == 0x2B || s == 0x2D { pos += 1 }
            let expStart = pos
            skipDigits()
            if pos == expStart { return nil }
        }
        let text = src.extracting(start..<pos).withUnsafeBufferPointer { String(decoding: $0, as: UTF8.self) }
        guard let v = Double(text), v.isFinite else { return nil }
        return v
    }

    mutating func parseArray(depth: Int) -> [JsonVal]? {
        pos += 1
        skipWhitespace()
        var arr: [JsonVal] = []
        if at() == 0x5D {
            pos += 1
            return arr
        }
        while true {
            guard let v = parseValue(depth: depth) else { return nil }
            arr.append(v)
            skipWhitespace()
            switch at() {
            case 0x2C: pos += 1
            case 0x5D:
                pos += 1
                return arr
            default: return nil
            }
        }
    }

    mutating func parseObject(depth: Int) -> JsonMap? {
        pos += 1
        skipWhitespace()
        var map = JsonMap()
        if at() == 0x7D {
            pos += 1
            return map
        }
        while true {
            skipWhitespace()
            guard at() == 0x22, let key = parseString() else { return nil }
            skipWhitespace()
            guard at() == 0x3A else { return nil }
            pos += 1
            guard let value = parseValue(depth: depth) else { return nil }
            map.insert(key, value)
            skipWhitespace()
            switch at() {
            case 0x2C: pos += 1
            case 0x7D:
                pos += 1
                return map
            default: return nil
            }
        }
    }
}

// HTTP/1.1 messages, without a framework: a request's head is parsed in place from the bytes NIO read, and a response
// leaves the JSON writer as one buffer, its head written into room kept free in front of the body.
import NIOCore

/// The longest request head accepted (431 beyond it), and the largest body (413).
let maxHead = 64 * 1024
let maxBody = 1 << 20

enum Method: Sendable {
    case get, post, put, delete, head, other
}

enum Status: Sendable {
    case ok, created, noContent
    case badRequest, unauthorized, forbidden, notFound, contentTooLarge, unprocessableContent, headerFieldsTooLarge
    case internalServerError, notImplemented, serviceUnavailable

    var line: StaticString {
        switch self {
        case .ok: "HTTP/1.1 200 OK\r\n"
        case .created: "HTTP/1.1 201 Created\r\n"
        case .noContent: "HTTP/1.1 204 No Content\r\n"
        case .badRequest: "HTTP/1.1 400 Bad Request\r\n"
        case .unauthorized: "HTTP/1.1 401 Unauthorized\r\n"
        case .forbidden: "HTTP/1.1 403 Forbidden\r\n"
        case .notFound: "HTTP/1.1 404 Not Found\r\n"
        case .contentTooLarge: "HTTP/1.1 413 Content Too Large\r\n"
        case .unprocessableContent: "HTTP/1.1 422 Unprocessable Content\r\n"
        case .headerFieldsTooLarge: "HTTP/1.1 431 Request Header Fields Too Large\r\n"
        case .internalServerError: "HTTP/1.1 500 Internal Server Error\r\n"
        case .notImplemented: "HTTP/1.1 501 Not Implemented\r\n"
        case .serviceUnavailable: "HTTP/1.1 503 Service Unavailable\r\n"
        }
    }
}

// ---------- requests ----------

/// A parsed request head. Ranges are offsets into the bytes it was parsed from.
struct RequestHead {
    var method: Method
    var target: Range<Int>
    /// Bytes up to and including the blank line that ends the head.
    var length = 0
    var contentLength = 0
    var chunked = false
    var authorization = 0..<0
    var keepAlive: Bool
    var expectContinue = false
}

enum HeadParse {
    case incomplete
    case invalid(Status)
    case complete(RequestHead)
}

/// Parses the request line and headers at the start of `bytes`. Lines may end in CRLF or a bare LF (RFC 9112 §2.2).
/// Only the headers this server acts on are looked at; the rest are skipped.
func parseHead(_ bytes: Span<UInt8>) -> HeadParse {
    let incomplete: HeadParse = bytes.count > maxHead ? .invalid(.headerFieldsTooLarge) : .incomplete
    guard let requestLine = nextLine(bytes, from: 0) else { return incomplete }

    // method SP request-target SP HTTP-version
    var sp1 = 0
    while sp1 < requestLine.end, bytes[sp1] != 0x20 { sp1 += 1 }
    var sp2 = sp1 + 1
    while sp2 < requestLine.end, bytes[sp2] != 0x20 { sp2 += 1 }
    guard sp1 > 0, sp2 < requestLine.end, sp2 > sp1 + 1 else { return .invalid(.badRequest) }
    let version = bytes.extracting((sp2 + 1)..<requestLine.end)
    let keepAlive: Bool
    if equals(version, "HTTP/1.1") { keepAlive = true }
    else if equals(version, "HTTP/1.0") { keepAlive = false }
    else { return .invalid(.badRequest) }
    var head = RequestHead(method: method(bytes.extracting(0..<sp1)), target: (sp1 + 1)..<sp2, keepAlive: keepAlive)

    var contentLength: Int?
    var pos = requestLine.next
    while true {
        guard let line = nextLine(bytes, from: pos) else { return incomplete }
        if line.end == pos { // the blank line
            guard line.next <= maxHead else { return .invalid(.headerFieldsTooLarge) }
            head.length = line.next
            break
        }
        guard bytes[pos] != 0x20, bytes[pos] != 0x09 else { return .invalid(.badRequest) } // obsolete line folding
        var colon = pos
        while colon < line.end, bytes[colon] != 0x3A { colon += 1 }
        guard colon < line.end, colon > pos, bytes[colon - 1] != 0x20, bytes[colon - 1] != 0x09 else {
            return .invalid(.badRequest)
        }
        var start = colon + 1
        var end = line.end
        while start < end, bytes[start] == 0x20 || bytes[start] == 0x09 { start += 1 }
        while end > start, bytes[end - 1] == 0x20 || bytes[end - 1] == 0x09 { end -= 1 }
        let name = bytes.extracting(pos..<colon)
        let value = bytes.extracting(start..<end)
        switch name.count {
        case 13 where equalsIgnoringCase(name, "authorization"):
            head.authorization = start..<end
        case 14 where equalsIgnoringCase(name, "content-length"):
            guard let n = parseUint(value), n <= Int64(Int32.max), contentLength == nil || contentLength == Int(n) else {
                return .invalid(.badRequest)
            }
            contentLength = Int(n)
        case 17 where equalsIgnoringCase(name, "transfer-encoding"):
            guard equalsIgnoringCase(value, "chunked") else { return .invalid(.notImplemented) }
            head.chunked = true
        case 10 where equalsIgnoringCase(name, "connection"):
            forEachToken(value) { token in
                if equalsIgnoringCase(token, "close") { head.keepAlive = false }
                else if equalsIgnoringCase(token, "keep-alive") { head.keepAlive = true }
            }
        case 6 where equalsIgnoringCase(name, "expect"):
            head.expectContinue = equalsIgnoringCase(value, "100-continue")
        default:
            break
        }
        pos = line.next
    }
    // Both framings at once is how requests get smuggled past a proxy (RFC 9112 §6.1): refuse it.
    if head.chunked, contentLength != nil { return .invalid(.badRequest) }
    head.contentLength = contentLength ?? 0
    return .complete(head)
}

/// The line starting at `from`: where its text ends (before CR LF or LF) and where the next line starts.
private func nextLine(_ bytes: Span<UInt8>, from: Int) -> (end: Int, next: Int)? {
    var i = from
    while i < bytes.count {
        if bytes[i] == 0x0A { return (i > from && bytes[i - 1] == 0x0D ? i - 1 : i, i + 1) }
        i += 1
    }
    return nil
}

private func method(_ bytes: Span<UInt8>) -> Method {
    switch bytes.count {
    case 3: equals(bytes, "GET") ? .get : equals(bytes, "PUT") ? .put : .other
    case 4: equals(bytes, "POST") ? .post : equals(bytes, "HEAD") ? .head : .other
    case 6: equals(bytes, "DELETE") ? .delete : .other
    default: .other
    }
}

/// Calls `body` with each element of a comma-separated header value, trimmed.
private func forEachToken(_ value: Span<UInt8>, _ body: (Span<UInt8>) -> Void) {
    var start = 0
    while start <= value.count {
        var end = start
        while end < value.count, value[end] != 0x2C { end += 1 } // ,
        var s = start
        var e = end
        while s < e, value[s] == 0x20 || value[s] == 0x09 { s += 1 }
        while e > s, value[e - 1] == 0x20 || value[e - 1] == 0x09 { e -= 1 }
        body(value.extracting(s..<e))
        start = end + 1
    }
}

func equals(_ bytes: Span<UInt8>, _ literal: StaticString) -> Bool {
    guard bytes.count == literal.utf8CodeUnitCount else { return false }
    let expected = literal.utf8Start
    for i in bytes.indices where bytes[i] != expected[i] { return false }
    return true
}

/// ASCII case-insensitive; `literal` is lowercase.
func equalsIgnoringCase(_ bytes: Span<UInt8>, _ literal: StaticString) -> Bool {
    guard bytes.count == literal.utf8CodeUnitCount else { return false }
    let expected = literal.utf8Start
    for i in bytes.indices {
        let b = bytes[i]
        guard (b >= 0x41 && b <= 0x5A ? b | 0x20 : b) == expected[i] else { return false }
    }
    return true
}

enum ChunkedParse {
    case incomplete
    case invalid(Status)
    /// The body's pieces (ranges of the bytes parsed) and how many bytes the chunked body took, trailers included.
    case complete(pieces: [Range<Int>], size: Int, length: Int)
}

/// A chunked body (RFC 9112 §7.1) starting at `from`. Chunk extensions and trailer fields are skipped.
func parseChunked(_ bytes: Span<UInt8>, from: Int) -> ChunkedParse {
    var pieces: [Range<Int>] = []
    var size = 0
    var pos = from
    while true {
        guard let line = nextLine(bytes, from: pos) else { return bytes.count - from > maxBody + maxHead ? .invalid(.contentTooLarge) : .incomplete }
        var sizeEnd = pos
        while sizeEnd < line.end, bytes[sizeEnd] != 0x3B, bytes[sizeEnd] != 0x20, bytes[sizeEnd] != 0x09 { sizeEnd += 1 } // ; or BWS
        guard sizeEnd > pos, sizeEnd - pos <= 8 else { return .invalid(.badRequest) }
        var chunk = 0
        for i in pos..<sizeEnd {
            let b = bytes[i]
            let digit: Int
            switch b {
            case 0x30...0x39: digit = Int(b - 0x30)
            case 0x41...0x46: digit = Int(b - 0x41 + 10)
            case 0x61...0x66: digit = Int(b - 0x61 + 10)
            default: return .invalid(.badRequest)
            }
            chunk = chunk << 4 | digit
        }
        pos = line.next
        if chunk == 0 {
            while true { // trailer fields, up to a blank line
                guard let trailer = nextLine(bytes, from: pos) else { return .incomplete }
                let blank = trailer.end == pos
                pos = trailer.next
                if blank { return .complete(pieces: pieces, size: size, length: pos - from) }
            }
        }
        size += chunk
        guard size <= maxBody else { return .invalid(.contentTooLarge) }
        guard bytes.count >= pos + chunk + 1 else { return .incomplete }
        pieces.append(pos..<(pos + chunk))
        pos += chunk
        guard let end = nextLine(bytes, from: pos) else { return .incomplete }
        guard end.end == pos else { return .invalid(.badRequest) } // the chunk's data must end with its line break
        pos = end.next
    }
}

// ---------- responses ----------

/// A response's status and body. The body is a JSONWriter's buffer, with JSONWriter.headroom free bytes in front of it.
struct Response: Sendable {
    let status: Status
    var buffer: ByteBuffer

    /// The bytes to send: the head written into the room in front of the body, so status line, headers and body leave
    /// in one buffer with no copy. `bodyless` (a HEAD request) sends the head alone. A 204 has no Content-Length.
    consuming func wire(keepAlive: Bool, bodyless: Bool) -> ByteBuffer {
        let contentHeaders: StaticString = "Content-Type: application/json\r\nContent-Length: "
        let close: StaticString = "Connection: close\r\n"
        let bodyLength = buffer.readableBytes
        var digits = 1
        var n = bodyLength
        while n >= 10 { digits += 1; n /= 10 }
        let hasBody = status != .noContent
        let headLength = status.line.utf8CodeUnitCount
            + (hasBody ? contentHeaders.utf8CodeUnitCount + digits + 2 : 0)
            + (keepAlive ? 0 : close.utf8CodeUnitCount)
            + 2
        let bodyStart = buffer.readerIndex
        let start = bodyStart - headLength
        precondition(start >= 0, "response head does not fit in the JSON writer's headroom")

        var at = start
        at += buffer.setStaticString(status.line, at: at)
        if hasBody {
            at += buffer.setStaticString(contentHeaders, at: at)
            var text = InlineArray<20, UInt8>(repeating: 0)
            var value = bodyLength
            var i = 20
            repeat {
                i -= 1
                text[i] = UInt8(truncatingIfNeeded: 0x30 + value % 10)
                value /= 10
            } while value != 0
            at += buffer.setBytes(text.span.extracting(i..<20).bytes, at: at)
            at += buffer.setStaticString("\r\n", at: at)
        }
        if !keepAlive { at += buffer.setStaticString(close, at: at) }
        at += buffer.setStaticString("\r\n", at: at)
        buffer.moveReaderIndex(to: start)
        if bodyless { buffer.moveWriterIndex(to: bodyStart) }
        return buffer
    }
}

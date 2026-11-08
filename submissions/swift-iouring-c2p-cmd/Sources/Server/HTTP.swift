import CShim

// HTTP/1.1 framing: request parsing in place and response headers written in front of the body.

public enum ParseResult {
    /// Need more bytes.
    case incomplete
    /// Unparseable or unsupported (e.g. chunked bodies): answer 400 and close.
    case invalid
    /// A full request occupying the first `length` bytes.
    case request(Request, length: Int)
}

/// Upper bound for request line plus headers. Larger requests are rejected.
public let maxHeaderBytes = 16 * 1024
/// Upper bound for a body. SPEC.md leaves anything over 16 KB out of scope.
public let maxBodyBytes = 1024 * 1024

/// Parses one request from the start of `v`.
public func parseRequest(_ v: ByteView) -> ParseResult {
    let n = v.count
    guard n > 0, let p = v.base else { return .incomplete }

    // Find the end of the header block.
    let limit = min(n, maxHeaderBytes)
    let headerEnd = sv_header_end(p, limit)
    if headerEnd < 0 { return n >= maxHeaderBytes ? .invalid : .incomplete }

    // Request line: METHOD SP target SP HTTP/1.x CRLF
    var lineEnd = 0
    while lineEnd < headerEnd && p[lineEnd] != 0x0D { lineEnd &+= 1 }
    var sp1 = 0
    while sp1 < lineEnd && p[sp1] != 0x20 { sp1 &+= 1 }
    guard sp1 > 0, sp1 < lineEnd else { return .invalid }
    var sp2 = sp1 &+ 1
    while sp2 < lineEnd && p[sp2] != 0x20 { sp2 &+= 1 }
    guard sp2 < lineEnd, lineEnd &- sp2 == 9 else { return .invalid }
    let version = v.slice(sp2 &+ 1, lineEnd)
    guard version.hasPrefix("HTTP/1.") else { return .invalid }
    let http10 = version[7] == UInt8(ascii: "0")

    let methodView = v.slice(0, sp1)
    let method: Method
    if methodView.equals("GET") {
        method = .get
    } else if methodView.equals("POST") {
        method = .post
    } else if methodView.equals("PUT") {
        method = .put
    } else if methodView.equals("DELETE") {
        method = .delete
    } else {
        method = .other
    }
    var pathEnd = sp1 &+ 1
    while pathEnd < sp2 && p[pathEnd] != UInt8(ascii: "?") { pathEnd &+= 1 }
    let path = v.slice(sp1 &+ 1, pathEnd)
    let query = pathEnd < sp2 ? v.slice(pathEnd &+ 1, sp2) : ByteView.empty

    var authorization: ByteView? = nil
    var contentLength = 0
    var keepAlive = !http10
    var lineStart = lineEnd &+ 2
    while lineStart < headerEnd &- 2 {
        var e = lineStart
        while p[e] != 0x0D { e &+= 1 }
        var colon = lineStart
        while colon < e && p[colon] != UInt8(ascii: ":") { colon &+= 1 }
        guard colon < e else { return .invalid }
        let name = v.slice(lineStart, colon)
        var vs = colon &+ 1
        while vs < e && (p[vs] == 0x20 || p[vs] == 0x09) { vs &+= 1 }
        var ve = e
        while ve > vs && (p[ve &- 1] == 0x20 || p[ve &- 1] == 0x09) { ve &-= 1 }
        let value = v.slice(vs, ve)
        switch name.count {
        case 13 where equalsIgnoringCase(name, "authorization"):
            authorization = value
        case 14 where equalsIgnoringCase(name, "content-length"):
            guard value.count > 0, value.count <= 9 else { return .invalid }
            var len = 0
            for k in 0..<value.count {
                let d = value[k] &- 48
                guard d < 10 else { return .invalid }
                len = len &* 10 &+ Int(d)
            }
            contentLength = len
        case 10 where equalsIgnoringCase(name, "connection"):
            if equalsIgnoringCase(value, "close") { keepAlive = false }
            else if equalsIgnoringCase(value, "keep-alive") { keepAlive = true }
        case 17 where equalsIgnoringCase(name, "transfer-encoding"):
            return .invalid
        default:
            break
        }
        lineStart = e &+ 2
    }

    guard contentLength <= maxBodyBytes else { return .invalid }
    let total = headerEnd &+ contentLength
    if n < total { return .incomplete }
    let body = contentLength > 0 ? v.slice(headerEnd, total) : ByteView.empty
    return .request(
        Request(method: method, path: path, query: query, authorization: authorization, body: body, keepAlive: keepAlive),
        length: total)
}

@inline(__always)
func equalsIgnoringCase(_ v: ByteView, _ s: StaticString) -> Bool {
    guard v.count == s.utf8CodeUnitCount else { return false }
    let q = s.utf8Start
    for i in 0..<v.count where v[i] | 0x20 != q[i] | 0x20 { return false }
    return true
}

/// Status line, Content-Type and Content-Length for each status we send.
func statusLine(_ status: Int) -> StaticString {
    switch status {
    case 200: return "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
    case 201: return "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: "
    case 401: return "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: "
    case 403: return "HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nContent-Length: "
    case 404: return "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: "
    case 422: return "HTTP/1.1 422 Unprocessable Entity\r\nContent-Type: application/json\r\nContent-Length: "
    default: return "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: "
    }
}

/// Appends a full response.
func appendHTTPResponse(status: Int, body: ByteView, close: Bool, into out: inout OutBuffer) {
    if status == 204 {
        out.append(close ? "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n" : "HTTP/1.1 204 No Content\r\n\r\n")
        return
    }
    let line = statusLine(status)
    out.reserve(line.utf8CodeUnitCount &+ 64 &+ body.count)
    out.append(line)
    out.appendInt(Int64(body.count))
    out.append(close ? "\r\nConnection: close\r\n\r\n" : "\r\n\r\n")
    out.append(body)
}

/// A complete response for unparseable requests.
public func appendBadRequest(into out: inout OutBuffer) {
    out.append("HTTP/1.1 422 Unprocessable Entity\r\nContent-Type: application/json\r\nContent-Length: 37\r\nConnection: close\r\n\r\n{\"errors\":{\"body\":[\"invalid request\"]}}")
}

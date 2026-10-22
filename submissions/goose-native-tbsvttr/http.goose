// HTTP/1.1 requests read straight from the receive buffer, and responses built whole in one buffer: status line,
// headers and a JSON body whose length is written into the header at the end.

import json;
import std;

// Generic byte quoting reused from our twelve-dollar-server-challenge PR #143.
extern fn json_append_string(text: const u8[:], out: u8[>..]&);

let M_GET = 1;
let M_POST = 2;
let M_PUT = 3;
let M_DELETE = 4;
let M_OTHER = 5;

let HEADER_MAX = 16384;
let BODY_MAX = 1048576;

// One request: views into the buffer it was read from.
struct Request {
    method: i64 = 0,
    path: const u8[:] = "",
    query: const u8[:] = "",
    auth: const u8[:] = "",
    has_auth: bool = false,
    body: const u8[:] = "",
    close: bool = false,
    size: i64 = 0,              // header and body bytes
}

let NEED_MORE = 0;
let PARSED = 1;                 // otherwise the status to refuse the request with, and the connection closes

fn lower(c: u8) -> u8 { if c >= 'A' && c <= 'Z' { c + 32 } else { c } }

// Whether s equals the lower-case name, ignoring ASCII case.
fn is_name(s: const u8[:], name: const u8[:]) -> bool {
    if s.len != name.len { return false; }
    for c, i in s { if lower(c) != name[i] { return false; } }
    return true;
}

fn has_token(s: const u8[:], token: const u8[:]) -> bool {
    var at = 0;
    while at + token.len <= s.len {
        if is_name(s[at..at + token.len], token) { return true; }
        at += 1;
    }
    return false;
}

fn trim_ows(s: const u8[:]) -> const u8[:] {
    var a = 0;
    var b = s.len;
    while a < b && (s[a] == ' ' || s[a] == '\t') { a += 1; }
    while b > a && (s[b - 1] == ' ' || s[b - 1] == '\t') { b -= 1; }
    return s[a..b];
}

// ASCII digits only (no sign, no space) that fit an i64.
fn parse_uint(s: const u8[:]) -> i64, bool {
    if s.len == 0 { return 0, false; }
    var v = 0;
    for c in s {
        if c < '0' || c > '9' { return 0, false; }
        let d = (c - '0') as i64;
        if v > (0x7fffffffffffffff - d) / 10 { return 0, false; }
        v = v * 10 + d;
    }
    return v, true;
}

fn parse_request(buf: const u8[:]) -> Request, i64 {
    var r = Request { path: buf[0..0], query: buf[0..0], auth: buf[0..0], body: buf[0..0], .. };
    let end = find(buf, "\r\n\r\n");
    if end < 0 { return r, if buf.len > HEADER_MAX { 431 } else { NEED_MORE }; }
    if end > HEADER_MAX { return r, 431; }
    let head = buf[..end + 2];

    var eol = find(head, "\r\n");
    let line = head[..eol];
    let sp1 = find(line, " ");
    if sp1 <= 0 { return r, 400; }
    let rest = line[sp1 + 1..];
    let sp2 = find(rest, " ");
    if sp2 <= 0 { return r, 400; }
    let method = line[..sp1];
    let target = rest[..sp2];
    let version = rest[sp2 + 1..];
    r.method = if method == "GET" { M_GET } else if method == "POST" { M_POST } else if method == "PUT" { M_PUT }
               else if method == "DELETE" { M_DELETE } else { M_OTHER };
    let q = find(target, "?");
    if q >= 0 { r.path = target[..q]; r.query = target[q + 1..]; } else { r.path = target; }
    var keep_alive = false;
    if version == "HTTP/1.0" { r.close = true; } else if version != "HTTP/1.1" { return r, 400; }

    var length = 0;
    var has_length = false;
    var at = eol + 2;
    while at < head.len {
        let next = find(head[at..], "\r\n");
        let h = head[at..at + next];
        at += next + 2;
        let colon = find(h, ":");
        if colon <= 0 { return r, 400; }
        let name = h[..colon];
        let value = trim_ows(h[colon + 1..]);
        if is_name(name, "content-length") {
            let n, ok = parse_uint(value);
            if !ok || (has_length && n != length) { return r, 400; }
            length = n;
            has_length = true;
        } else if is_name(name, "authorization") {
            if !r.has_auth { r.auth = value; r.has_auth = true; }
        } else if is_name(name, "connection") {
            if has_token(value, "close") { r.close = true; }
            if has_token(value, "keep-alive") { keep_alive = true; }
        } else if is_name(name, "transfer-encoding") {
            return r, 400;
        }
    }
    if keep_alive && version == "HTTP/1.0" { r.close = false; }
    if length > BODY_MAX { return r, 413; }
    let total = end + 4 + length;
    if buf.len < total { return r, NEED_MORE; }
    r.body = buf[end + 4..total];
    r.size = total;
    return r, PARSED;
}

// ---------- text ----------

fn hex(c: u8) -> i64 {
    if c >= '0' && c <= '9' { return c - '0'; }
    if c >= 'a' && c <= 'f' { return c - 'a' + 10; }
    if c >= 'A' && c <= 'F' { return c - 'A' + 10; }
    return -1;
}

// %XX escapes (and '+' as a space when plus is set) decoded onto out; false on a malformed escape.
fn pct_decode(out: u8[>..]&, s: const u8[:], plus: bool) -> bool {
    var i = 0;
    while i < s.len {
        let c = s[i];
        if c == '%' {
            if i + 2 >= s.len { return false; }
            let hi = hex(s[i + 1]);
            let lo = hex(s[i + 2]);
            if hi < 0 || lo < 0 { return false; }
            out.push((hi << 4 | lo) as! u8);
            i += 3;
        } else {
            out.push(if plus && c == '+' { ' ' } else { c });
            i += 1;
        }
    }
    return true;
}

// Well-formed UTF-8 without NUL: what Postgres stores in a text column.
fn valid_text(s: const u8[:]) -> bool {
    var i = 0;
    while i < s.len {
        let c = s[i];
        if c < 0x80 {
            if c == 0 { return false; }
            i += 1;
            continue;
        }
        var n = 0;
        var min: i64 = 0;
        var v: i64 = 0;
        if c >= 0xc2 && c <= 0xdf { n = 1; v = c & 0x1f; min = 0x80; }
        else if c >= 0xe0 && c <= 0xef { n = 2; v = c & 0x0f; min = 0x800; }
        else if c >= 0xf0 && c <= 0xf4 { n = 3; v = c & 0x07; min = 0x10000; }
        else { return false; }
        if i + n >= s.len { return false; }
        for k in 1..n + 1 {
            let d = s[i + k];
            if d & 0xc0 != 0x80 { return false; }
            v = v << 6 | (d & 0x3f);
        }
        if v < min || v > 0x10ffff || (v >= 0xd800 && v <= 0xdfff) { return false; }
        i += n + 1;
    }
    return true;
}

// The first `key` parameter of a query string, decoded onto out, the way Go's url.Values.Get reads it.
fn query_get(q: const u8[:], key: const u8[:], out: u8[>..]&) -> bool {
    var at = 0;
    while at <= q.len {
        var end = at;
        while end < q.len && q[end] != '&' { end += 1; }
        let pair = q[at..end];
        at = end + 1;
        if pair.len == 0 || find(pair, ";") >= 0 { continue; }
        let eq = find(pair, "=");
        let k = if eq < 0 { pair } else { pair[..eq] };
        let v = if eq < 0 { pair[pair.len..] } else { pair[eq + 1..] };
        var dk: u8[>..] = [];
        if !pct_decode(dk, k, true) || dk != key { continue; }
        let mark = out.len;
        if !pct_decode(out, v, true) { out.resize(mark); continue; }
        return true;
    }
    return false;
}

// ---------- responses ----------

fn reason(status: i64) -> const u8[:] {
    match status {
        200 => "200 OK",
        201 => "201 Created",
        204 => "204 No Content",
        400 => "400 Bad Request",
        401 => "401 Unauthorized",
        403 => "403 Forbidden",
        404 => "404 Not Found",
        413 => "413 Content Too Large",
        422 => "422 Unprocessable Entity",
        431 => "431 Request Header Fields Too Large",
        503 => "503 Service Unavailable",
        _ => "500 Internal Server Error",
    }
}

// Starts a JSON response; the body follows, then end_response with what this returns.
fn begin_response(out: u8[>..]&, status: i64, close: bool) -> i64 {
    format(out, "HTTP/1.1 ", reason(status), "\r\nContent-Type: application/json\r\n");
    if close { out.append("Connection: close\r\n"); }
    if status == 503 { out.append("Retry-After: 1\r\n"); }
    out.append("Content-Length:           \r\n\r\n");
    return out.len;
}

// Writes the body's length right-aligned into the spaces left for it.
fn end_response(out: u8[>..]&, body_at: i64) {
    var n = out.len - body_at;
    var at = body_at - 5;
    loop {
        out[at] = ('0' + n % 10) as! u8;
        n /= 10;
        at -= 1;
        if n == 0 { break; }
    }
}

fn no_content(out: u8[>..]&, close: bool) {
    out.append("HTTP/1.1 204 No Content\r\n");
    if close { out.append("Connection: close\r\n"); }
    out.append("\r\n");
}

fn error_response(out: u8[>..]&, status: i64, message: const u8[:], close: bool) {
    let at = begin_response(out, status, close);
    out.append("{\"errors\":{\"body\":[");
    json_append_string(message, out);
    out.append("]}}");
    end_response(out, at);
}

// ---------- JSON fields ----------

fn key(out: u8[>..]&, name: const u8[:]) { out.push('"'); out.append(name); out.append("\":"); }

fn put_nullable(out: u8[>..]&, s: const u8[:], present: bool) {
    if present { json_append_string(s, out); } else { out.append("null"); }
}

fn put_bool(out: u8[>..]&, b: bool) { out.append(if b { "true" } else { "false" }); }

fn two(out: u8[>..]&, n: i64) { out.push(('0' + n / 10) as! u8); out.push(('0' + n % 10) as! u8); }

// A timestamptz (microseconds since 2000-01-01 UTC) as RFC 3339 with milliseconds, truncated.
fn put_time(out: u8[>..]&, us: i64) {
    let ms = div_euclid(us, 1000) + 946684800000;
    let secs = div_euclid(ms, 1000);
    let milli = ms - secs * 1000;
    let days = div_euclid(secs, 86400);
    let sod = secs - days * 86400;
    let z = days + 719468;                          // civil_from_days (Howard Hinnant)
    let era = div_euclid(z, 146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + (if m <= 2 { 1 } else { 0 });
    out.push('"');
    two(out, y / 100); two(out, y % 100); out.push('-'); two(out, m); out.push('-'); two(out, d);
    out.push('T'); two(out, sod / 3600); out.push(':'); two(out, sod / 60 % 60); out.push(':'); two(out, sod % 60);
    out.push('.');
    out.push(('0' + milli / 100) as! u8); two(out, milli % 100);
    out.append("Z\"");
}

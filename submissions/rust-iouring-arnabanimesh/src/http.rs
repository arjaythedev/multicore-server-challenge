//! HTTP/1.1 request parsing (httparse) and response-head helpers.

use std::borrow::Cow;

pub const MAX_HEADERS: usize = 64;
pub const MAX_HEAD: usize = 32 * 1024;
pub const MAX_BODY: usize = 1024 * 1024;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Method {
    Get,
    Post,
    Put,
    Delete,
    Other,
}

pub struct Req<'a> {
    pub method: Method,
    /// Path without the query string (still percent-encoded).
    pub path: &'a [u8],
    pub query: &'a [u8],
    pub auth: Option<&'a [u8]>,
    body: &'a [u8],
    chunked: Option<Vec<u8>>,
    pub keep_alive: bool,
    /// Bytes of the input buffer used by this request (head + body).
    pub consumed: usize,
}

impl<'a> Req<'a> {
    pub fn body(&self) -> &[u8] {
        match &self.chunked {
            Some(v) => v.as_slice(),
            None => self.body,
        }
    }
}

pub enum Parsed<'a> {
    Incomplete,
    Bad(u16),
    Complete(Req<'a>),
}

pub fn parse(buf: &[u8]) -> Parsed<'_> {
    let mut headers = [httparse::EMPTY_HEADER; MAX_HEADERS];
    let mut req = httparse::Request::new(&mut headers);
    let head_len = match req.parse(buf) {
        Ok(httparse::Status::Complete(n)) => n,
        Ok(httparse::Status::Partial) => {
            if buf.len() > MAX_HEAD {
                return Parsed::Bad(400);
            }
            return Parsed::Incomplete;
        }
        Err(_) => return Parsed::Bad(400),
    };

    let method = match req.method {
        Some("GET") => Method::Get,
        Some("POST") => Method::Post,
        Some("PUT") => Method::Put,
        Some("DELETE") => Method::Delete,
        _ => Method::Other,
    };
    let full_path: &[u8] = match req.path {
        Some(p) => p.as_bytes(),
        None => return Parsed::Bad(400),
    };
    let (path, query) = match memchr::memchr(b'?', full_path) {
        Some(i) => (&full_path[..i], &full_path[i + 1..]),
        None => (full_path, &full_path[full_path.len()..]),
    };

    let mut content_length: Option<usize> = None;
    let mut chunked = false;
    let mut auth: Option<&[u8]> = None;
    let mut conn_close = false;
    let mut conn_keep = false;
    for h in req.headers.iter() {
        let n = h.name.as_bytes();
        if n.len() == 13 && eq_ic(n, b"authorization") {
            auth = Some(h.value);
        } else if n.len() == 14 && eq_ic(n, b"content-length") {
            match parse_usize(h.value) {
                Some(v) => content_length = Some(v),
                None => return Parsed::Bad(400),
            }
        } else if n.len() == 17 && eq_ic(n, b"transfer-encoding") {
            if contains_ic(h.value, b"chunked") {
                chunked = true;
            }
        } else if n.len() == 10 && eq_ic(n, b"connection") {
            if contains_ic(h.value, b"close") {
                conn_close = true;
            }
            if contains_ic(h.value, b"keep-alive") {
                conn_keep = true;
            }
        }
    }

    let version = req.version.unwrap_or(1);
    let keep_alive = if conn_close {
        false
    } else if version == 0 {
        conn_keep
    } else {
        true
    };

    if chunked {
        return match decode_chunked(&buf[head_len..]) {
            Ok(Some((body, used))) => Parsed::Complete(Req {
                method,
                path,
                query,
                auth,
                body: &[],
                chunked: Some(body),
                keep_alive,
                consumed: head_len + used,
            }),
            Ok(None) => {
                if buf.len() > MAX_HEAD + MAX_BODY {
                    Parsed::Bad(413)
                } else {
                    Parsed::Incomplete
                }
            }
            Err(_) => Parsed::Bad(400),
        };
    }

    let cl = content_length.unwrap_or(0);
    if cl > MAX_BODY {
        return Parsed::Bad(413);
    }
    if buf.len() < head_len + cl {
        return Parsed::Incomplete;
    }
    Parsed::Complete(Req {
        method,
        path,
        query,
        auth,
        body: &buf[head_len..head_len + cl],
        chunked: None,
        keep_alive,
        consumed: head_len + cl,
    })
}

fn eq_ic(a: &[u8], lower: &[u8]) -> bool {
    a.len() == lower.len() && a.iter().zip(lower.iter()).all(|(x, y)| x.to_ascii_lowercase() == *y)
}

fn contains_ic(hay: &[u8], needle_lower: &[u8]) -> bool {
    if needle_lower.is_empty() || hay.len() < needle_lower.len() {
        return false;
    }
    hay.windows(needle_lower.len()).any(|w| eq_ic(w, needle_lower))
}

fn parse_usize(v: &[u8]) -> Option<usize> {
    if v.is_empty() || v.len() > 12 {
        return None;
    }
    let mut n: usize = 0;
    for &b in v {
        if !b.is_ascii_digit() {
            return None;
        }
        n = n * 10 + (b - b'0') as usize;
    }
    Some(n)
}

/// Signed decimal integer like Go's `strconv.Atoi`: optional sign, digits only.
pub fn parse_int(v: &[u8]) -> Option<i64> {
    let (neg, digits) = match v.first() {
        Some(&b'-') => (true, &v[1..]),
        Some(&b'+') => (false, &v[1..]),
        _ => (false, v),
    };
    if digits.is_empty() || digits.len() > 18 {
        return None;
    }
    let mut n: i64 = 0;
    for &b in digits {
        if !b.is_ascii_digit() {
            return None;
        }
        n = n * 10 + (b - b'0') as i64;
    }
    Some(if neg { -n } else { n })
}

fn find_crlf(d: &[u8]) -> Option<usize> {
    d.windows(2).position(|w| w == b"\r\n")
}

fn parse_hex(v: &[u8]) -> Option<usize> {
    let mut s = v;
    while let Some(&last) = s.last() {
        if last == b' ' || last == b'\t' {
            s = &s[..s.len() - 1];
        } else {
            break;
        }
    }
    if s.is_empty() || s.len() > 8 {
        return None;
    }
    let mut n: usize = 0;
    for &b in s {
        let d = hex_val(b)?;
        n = n * 16 + d as usize;
    }
    Some(n)
}

/// Rare path: `Transfer-Encoding: chunked` request bodies.
/// Ok(Some((body, bytes_used))) when complete, Ok(None) when more data is needed.
fn decode_chunked(data: &[u8]) -> Result<Option<(Vec<u8>, usize)>, ()> {
    let mut out: Vec<u8> = Vec::new();
    let mut pos = 0usize;
    loop {
        let line_end = match find_crlf(&data[pos..]) {
            Some(i) => pos + i,
            None => return Ok(None),
        };
        let line = &data[pos..line_end];
        let size_part = match memchr::memchr(b';', line) {
            Some(i) => &line[..i],
            None => line,
        };
        let size = parse_hex(size_part).ok_or(())?;
        pos = line_end + 2;
        if size == 0 {
            // trailers, terminated by an empty line
            loop {
                let e = match find_crlf(&data[pos..]) {
                    Some(i) => pos + i,
                    None => return Ok(None),
                };
                let empty = e == pos;
                pos = e + 2;
                if empty {
                    return Ok(Some((out, pos)));
                }
            }
        }
        if out.len() + size > MAX_BODY {
            return Err(());
        }
        if data.len() < pos + size + 2 {
            return Ok(None);
        }
        out.extend_from_slice(&data[pos..pos + size]);
        pos += size;
        if &data[pos..pos + 2] != b"\r\n" {
            return Err(());
        }
        pos += 2;
    }
}

fn hex_val(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

/// Percent-decoding. Borrowed when nothing needs decoding. `plus_is_space` is for query strings.
pub fn pct_decode(s: &[u8], plus_is_space: bool) -> Cow<'_, [u8]> {
    let needs = s.iter().any(|&b| b == b'%' || (plus_is_space && b == b'+'));
    if !needs {
        return Cow::Borrowed(s);
    }
    let mut out: Vec<u8> = Vec::with_capacity(s.len());
    let mut i = 0usize;
    while i < s.len() {
        let b = s[i];
        if b == b'%' && i + 2 < s.len() {
            if let (Some(h), Some(l)) = (hex_val(s[i + 1]), hex_val(s[i + 2])) {
                out.push(h * 16 + l);
                i += 3;
                continue;
            }
        }
        if plus_is_space && b == b'+' {
            out.push(b' ');
        } else {
            out.push(b);
        }
        i += 1;
    }
    Cow::Owned(out)
}

/// First occurrence of `key` in a raw query string; the value is returned still percent-encoded.
pub fn query_get<'a>(q: &'a [u8], key: &[u8]) -> Option<&'a [u8]> {
    for part in q.split(|&b| b == b'&') {
        let (k, v) = match memchr::memchr(b'=', part) {
            Some(i) => (&part[..i], &part[i + 1..]),
            None => (part, &part[part.len()..]),
        };
        if k == key {
            return Some(v);
        }
    }
    None
}

// ---------------------------------------------------------------------------- responses

pub fn status_line(code: u16) -> &'static [u8] {
    match code {
        200 => &b"HTTP/1.1 200 OK\r\n"[..],
        201 => &b"HTTP/1.1 201 Created\r\n"[..],
        204 => &b"HTTP/1.1 204 No Content\r\n"[..],
        400 => &b"HTTP/1.1 400 Bad Request\r\n"[..],
        401 => &b"HTTP/1.1 401 Unauthorized\r\n"[..],
        403 => &b"HTTP/1.1 403 Forbidden\r\n"[..],
        404 => &b"HTTP/1.1 404 Not Found\r\n"[..],
        405 => &b"HTTP/1.1 405 Method Not Allowed\r\n"[..],
        413 => &b"HTTP/1.1 413 Payload Too Large\r\n"[..],
        422 => &b"HTTP/1.1 422 Unprocessable Entity\r\n"[..],
        503 => &b"HTTP/1.1 503 Service Unavailable\r\n"[..],
        _ => &b"HTTP/1.1 500 Internal Server Error\r\n"[..],
    }
}

fn put(dst: &mut [u8], n: usize, src: &[u8]) -> usize {
    dst[n..n + src.len()].copy_from_slice(src);
    n + src.len()
}

fn put_usize(dst: &mut [u8], n: usize, mut v: usize) -> usize {
    if v == 0 {
        dst[n] = b'0';
        return n + 1;
    }
    let mut tmp = [0u8; 20];
    let mut i = 20usize;
    while v > 0 {
        i -= 1;
        tmp[i] = b'0' + (v % 10) as u8;
        v /= 10;
    }
    put(dst, n, &tmp[i..])
}

/// Writes the response head into `dst` (must be at least 160 bytes) and returns its length.
pub fn write_head(dst: &mut [u8], code: u16, body_len: usize, close: bool) -> usize {
    let mut n = put(dst, 0, status_line(code));
    if code != 204 {
        n = put(dst, n, b"Content-Type: application/json\r\n");
        n = put(dst, n, b"Content-Length: ");
        n = put_usize(dst, n, body_len);
        n = put(dst, n, b"\r\n");
    }
    if close {
        n = put(dst, n, b"Connection: close\r\n");
    }
    put(dst, n, b"\r\n")
}

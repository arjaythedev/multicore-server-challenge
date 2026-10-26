pub const MAX_HEAD: usize = 16 * 1024;
pub const MAX_BODY: usize = 1024 * 1024;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Method {
    Get,
    Post,
    Put,
    Delete,
    Other,
}

pub struct Request<'a> {
    pub method: Method,
    pub path: &'a [u8],
    pub query: &'a [u8],
    pub auth: Option<&'a [u8]>,
    pub body: &'a [u8],
    pub close: bool,
}

pub enum Parsed<'a> {
    Done(Request<'a>, usize),
    Partial,
    Bad,
}

fn find_head_end(buf: &[u8]) -> Option<usize> {
    buf.windows(4).position(|w| w == b"\r\n\r\n")
}

fn trim(mut s: &[u8]) -> &[u8] {
    while let [b' ' | b'\t', rest @ ..] = s {
        s = rest;
    }
    while let [rest @ .., b' ' | b'\t'] = s {
        s = rest;
    }
    s
}

pub fn parse(buf: &[u8]) -> Parsed<'_> {
    let Some(head_end) = find_head_end(buf) else {
        return if buf.len() > MAX_HEAD {
            Parsed::Bad
        } else {
            Parsed::Partial
        };
    };
    let head = &buf[..head_end];
    let mut lines = head.split(|&c| c == b'\n');
    let request_line = lines.next().unwrap_or(b"");
    let request_line = request_line.strip_suffix(b"\r").unwrap_or(request_line);
    let mut parts = request_line.split(|&c| c == b' ');
    let method = match parts.next() {
        Some(b"GET") => Method::Get,
        Some(b"POST") => Method::Post,
        Some(b"PUT") => Method::Put,
        Some(b"DELETE") => Method::Delete,
        Some(_) => Method::Other,
        None => return Parsed::Bad,
    };
    let Some(target) = parts.next() else {
        return Parsed::Bad;
    };
    let version = parts.next().unwrap_or(b"");
    let mut close = version == b"HTTP/1.0";
    let (path, query) = match target.iter().position(|&c| c == b'?') {
        Some(q) => (&target[..q], &target[q + 1..]),
        None => (target, &b""[..]),
    };
    let mut auth = None;
    let mut content_length = 0usize;
    for line in lines {
        let line = line.strip_suffix(b"\r").unwrap_or(line);
        let Some(colon) = line.iter().position(|&c| c == b':') else {
            continue;
        };
        let name = &line[..colon];
        let value = trim(&line[colon + 1..]);
        if name.eq_ignore_ascii_case(b"authorization") {
            auth = Some(value);
        } else if name.eq_ignore_ascii_case(b"content-length") {
            match std::str::from_utf8(value).ok().and_then(|v| v.parse().ok()) {
                Some(n) => content_length = n,
                None => return Parsed::Bad,
            }
        } else if name.eq_ignore_ascii_case(b"connection") {
            if value.eq_ignore_ascii_case(b"close") {
                close = true;
            } else if value.eq_ignore_ascii_case(b"keep-alive") {
                close = false;
            }
        } else if name.eq_ignore_ascii_case(b"transfer-encoding") {
            return Parsed::Bad;
        }
    }
    if content_length > MAX_BODY {
        return Parsed::Bad;
    }
    let total = head_end + 4 + content_length;
    if buf.len() < total {
        return Parsed::Partial;
    }
    Parsed::Done(
        Request {
            method,
            path,
            query,
            auth,
            body: &buf[head_end + 4..total],
            close,
        },
        total,
    )
}

fn hex(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}

pub fn pct_decode_into(s: &[u8], plus: bool, out: &mut Vec<u8>) {
    let mut i = 0;
    while i < s.len() {
        let c = s[i];
        if c == b'%'
            && i + 2 < s.len()
            && let (Some(h), Some(l)) = (hex(s[i + 1]), hex(s[i + 2]))
        {
            out.push(h << 4 | l);
            i += 3;
            continue;
        }
        out.push(if plus && c == b'+' { b' ' } else { c });
        i += 1;
    }
}

pub fn pct_decode(s: &[u8], plus: bool) -> Vec<u8> {
    if !s.iter().any(|&c| c == b'%' || (plus && c == b'+')) {
        return s.to_vec();
    }
    let mut out = Vec::with_capacity(s.len());
    pct_decode_into(s, plus, &mut out);
    out
}

pub fn status_line(status: u16) -> &'static [u8] {
    match status {
        200 => b"HTTP/1.1 200 OK\r\n",
        201 => b"HTTP/1.1 201 Created\r\n",
        204 => b"HTTP/1.1 204 No Content\r\n",
        400 => b"HTTP/1.1 400 Bad Request\r\n",
        401 => b"HTTP/1.1 401 Unauthorized\r\n",
        403 => b"HTTP/1.1 403 Forbidden\r\n",
        404 => b"HTTP/1.1 404 Not Found\r\n",
        422 => b"HTTP/1.1 422 Unprocessable Entity\r\n",
        503 => b"HTTP/1.1 503 Service Unavailable\r\n",
        _ => b"HTTP/1.1 500 Internal Server Error\r\n",
    }
}

pub fn head(out: &mut Vec<u8>, status: u16, len: usize, close: bool) {
    out.extend_from_slice(status_line(status));
    if status != 204 {
        out.extend_from_slice(b"Content-Type: application/json\r\nContent-Length: ");
        crate::json::int(out, len as i64);
        out.extend_from_slice(b"\r\n");
    }
    if close {
        out.extend_from_slice(b"Connection: close\r\n");
    }
    out.extend_from_slice(b"\r\n");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_request() {
        let raw = b"POST /api/users?x=1 HTTP/1.1\r\nHost: a\r\nAuthorization: Token abc\r\n\
                    Content-Length: 2\r\n\r\n{}GET";
        let Parsed::Done(req, used) = parse(raw) else {
            panic!("not parsed");
        };
        assert!(req.method == Method::Post);
        assert_eq!(req.path, b"/api/users");
        assert_eq!(req.query, b"x=1");
        assert_eq!(req.auth, Some(&b"Token abc"[..]));
        assert_eq!(req.body, b"{}");
        assert_eq!(used, raw.len() - 3);
    }

    #[test]
    fn decodes() {
        assert_eq!(pct_decode(b"a%2Bb+c%2", true), b"a+b c%2");
        assert_eq!(pct_decode(b"%205", false), b" 5");
    }
}

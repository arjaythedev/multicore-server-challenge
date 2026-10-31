//! Fast zero-copy HTTP/1.1 request parser.

#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum HttpMethod {
    Get,
    Post,
    Put,
    Delete,
}

pub struct ParsedRequest<'a> {
    pub method: HttpMethod,
    pub path: &'a str,
    pub query: Option<&'a str>,
    pub token: Option<&'a str>,
    pub body: &'a [u8],
    pub keep_alive: bool,
    pub consumed_len: usize,
}

pub enum ParseResult<'a> {
    Complete(ParsedRequest<'a>),
    Incomplete,
    BadRequest,
}

pub fn parse_http_request(buf: &[u8]) -> ParseResult<'_> {
    // Find header boundary \r\n\r\n
    let header_end = match buf.windows(4).position(|w| w == b"\r\n\r\n") {
        Some(pos) => pos,
        None => return ParseResult::Incomplete,
    };

    let header_bytes = &buf[..header_end];
    let mut lines = header_bytes.split(|&b| b == b'\n');

    let req_line = match lines.next() {
        Some(l) => {
            if l.ends_with(b"\r") {
                &l[..l.len() - 1]
            } else {
                l
            }
        }
        None => return ParseResult::BadRequest,
    };

    let mut parts = req_line.split(|&b| b == b' ');
    let method_bytes = match parts.next() {
        Some(m) => m,
        None => return ParseResult::BadRequest,
    };
    let uri_bytes = match parts.next() {
        Some(u) => u,
        None => return ParseResult::BadRequest,
    };

    let method = match method_bytes {
        b"GET" => HttpMethod::Get,
        b"POST" => HttpMethod::Post,
        b"PUT" => HttpMethod::Put,
        b"DELETE" => HttpMethod::Delete,
        _ => return ParseResult::BadRequest,
    };

    let uri_str = match std::str::from_utf8(uri_bytes) {
        Ok(s) => s,
        Err(_) => return ParseResult::BadRequest,
    };

    let (path, query) = match uri_str.split_once('?') {
        Some((p, q)) => (p, Some(q)),
        None => (uri_str, None),
    };

    let mut content_length: usize = 0;
    let mut token: Option<&str> = None;
    let mut keep_alive = true; // HTTP/1.1 defaults to keep-alive

    for line_raw in lines {
        let line = if line_raw.ends_with(b"\r") {
            &line_raw[..line_raw.len() - 1]
        } else {
            line_raw
        };
        if line.is_empty() {
            continue;
        }

        if let Some(pos) = line.iter().position(|&b| b == b':') {
            let key = &line[..pos];
            let val = line[pos + 1..].trim_ascii();

            if key.eq_ignore_ascii_case(b"authorization") {
                if let Ok(v_str) = std::str::from_utf8(val) {
                    if let Some(t) = v_str.strip_prefix("Token ") {
                        token = Some(t.trim());
                    }
                }
            } else if key.eq_ignore_ascii_case(b"content-length") {
                if let Ok(v_str) = std::str::from_utf8(val) {
                    if let Ok(len) = v_str.parse::<usize>() {
                        content_length = len;
                    }
                }
            } else if key.eq_ignore_ascii_case(b"connection") {
                if val.eq_ignore_ascii_case(b"close") {
                    keep_alive = false;
                }
            }
        }
    }

    let body_start = header_end + 4;
    let body_end = body_start + content_length;

    if buf.len() < body_end {
        return ParseResult::Incomplete;
    }

    let body = &buf[body_start..body_end];

    ParseResult::Complete(ParsedRequest {
        method,
        path,
        query,
        token,
        body,
        keep_alive,
        consumed_len: body_end,
    })
}

//! Zero-copy streaming HTTP/1.1 parser.
//! Supports keep-alive, pipelining, Content-Length bodies, and partial reads across buffers.

#[derive(Debug, PartialEq, Eq)]
pub enum HttpMethod {
    Get,
    Post,
    Put,
    Delete,
    Other,
}

#[derive(Debug, PartialEq, Eq)]
pub struct HttpRequest<'a> {
    pub method: HttpMethod,
    pub path: &'a str,
    pub auth_token: Option<&'a str>,
    pub keepalive: bool,
    pub body: &'a [u8],
    pub bytes_consumed: usize,
}

#[derive(Debug, PartialEq, Eq)]
pub enum ParseResult<'a> {
    Complete(HttpRequest<'a>),
    Incomplete,
    Error,
}

pub fn parse_http_request(buf: &[u8]) -> ParseResult<'_> {
    // 1. Locate end of HTTP headers (\r\n\r\n)
    let header_end = match find_header_end(buf) {
        Some(idx) => idx,
        None => return ParseResult::Incomplete,
    };

    let header_bytes = &buf[..header_end];
    let header_str = match std::str::from_utf8(header_bytes) {
        Ok(s) => s,
        Err(_) => return ParseResult::Error,
    };

    let mut lines = header_str.split("\r\n");
    let req_line = match lines.next() {
        Some(l) if !l.is_empty() => l,
        _ => return ParseResult::Error,
    };

    // Parse request line: METHOD PATH HTTP/1.1
    let mut parts = req_line.split_ascii_whitespace();
    let method_str = match parts.next() {
        Some(m) => m,
        None => return ParseResult::Error,
    };
    let path = match parts.next() {
        Some(p) => p,
        None => return ParseResult::Error,
    };

    let method = match method_str {
        "GET" => HttpMethod::Get,
        "POST" => HttpMethod::Post,
        "PUT" => HttpMethod::Put,
        "DELETE" => HttpMethod::Delete,
        _ => HttpMethod::Other,
    };

    let mut content_length: usize = 0;
    let mut auth_token: Option<&str> = None;
    let mut keepalive: bool = true;

    // Parse headers
    for line in lines {
        if line.is_empty() {
            break;
        }

        if let Some(colon_idx) = line.find(':') {
            let name = &line[..colon_idx].trim();
            let value = &line[colon_idx + 1..].trim();

            if name.eq_ignore_ascii_case("content-length") {
                if let Ok(len) = value.parse::<usize>() {
                    content_length = len;
                }
            } else if name.eq_ignore_ascii_case("authorization") {
                // SPEC line 31: Header Authorization: Token <jwt> (RealWorld's scheme, not Bearer).
                // Missing scheme or non-Token scheme (e.g. Bearer) must reject with 401.
                if let Some((scheme, token_part)) = value.split_once(|c: char| c == ' ' || c == '\t') {
                    if scheme.trim().eq_ignore_ascii_case("token") {
                        auth_token = Some(token_part.trim());
                    } else {
                        // Invalid scheme (e.g. "Bearer") -> sentinel "" so token.is_some() is true, jwt_verify fails -> 401
                        auth_token = Some("");
                    }
                } else {
                    // Bare token without scheme -> sentinel "" so token.is_some() is true, jwt_verify fails -> 401
                    auth_token = Some("");
                }
            } else if name.eq_ignore_ascii_case("connection") {
                if value.eq_ignore_ascii_case("close") {
                    keepalive = false;
                }
            }
        }
    }

    // Body check
    let body_start = header_end + 4; // Skip \r\n\r\n
    let total_needed = body_start + content_length;

    if buf.len() < total_needed {
        return ParseResult::Incomplete;
    }

    let body = &buf[body_start..total_needed];

    ParseResult::Complete(HttpRequest {
        method,
        path,
        auth_token,
        keepalive,
        body,
        bytes_consumed: total_needed,
    })
}

#[inline(always)]
fn find_header_end(buf: &[u8]) -> Option<usize> {
    if buf.len() < 4 {
        return None;
    }
    // Search for \r\n\r\n
    for i in 0..buf.len() - 3 {
        if buf[i] == b'\r' && buf[i + 1] == b'\n' && buf[i + 2] == b'\r' && buf[i + 3] == b'\n' {
            return Some(i);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_simple_get() {
        let req = b"GET /api/tags HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\n\r\n";
        match parse_http_request(req) {
            ParseResult::Complete(r) => {
                assert_eq!(r.method, HttpMethod::Get);
                assert_eq!(r.path, "/api/tags");
                assert!(r.keepalive);
                assert_eq!(r.auth_token, None);
                assert_eq!(r.body.len(), 0);
                assert_eq!(r.bytes_consumed, req.len());
            }
            _ => panic!("failed to parse simple get"),
        }
    }

    #[test]
    fn test_parse_post_with_body_and_jwt() {
        let req = b"POST /api/users/login HTTP/1.1\r\nAuthorization: Token my-secret-jwt\r\nContent-Length: 11\r\n\r\n{\"user\":{}}";
        match parse_http_request(req) {
            ParseResult::Complete(r) => {
                assert_eq!(r.method, HttpMethod::Post);
                assert_eq!(r.path, "/api/users/login");
                assert_eq!(r.auth_token, Some("my-secret-jwt"));
                assert_eq!(r.body, b"{\"user\":{}}");
                assert_eq!(r.bytes_consumed, req.len());
            }
            _ => panic!("failed to parse post with body"),
        }
    }

    #[test]
    fn test_authorization_scheme_enforcement() {
        let valid = b"GET /api/user HTTP/1.1\r\nAuthorization: Token valid-jwt\r\n\r\n";
        if let ParseResult::Complete(r) = parse_http_request(valid) {
            assert_eq!(r.auth_token, Some("valid-jwt"));
        } else {
            panic!("valid token failed to parse");
        }

        let bearer = b"GET /api/user HTTP/1.1\r\nAuthorization: Bearer some-jwt\r\n\r\n";
        if let ParseResult::Complete(r) = parse_http_request(bearer) {
            assert_eq!(r.auth_token, Some(""), "Bearer scheme must yield empty token for 401");
        } else {
            panic!("bearer token failed to parse");
        }

        let bare = b"GET /api/user HTTP/1.1\r\nAuthorization: bare-jwt-without-scheme\r\n\r\n";
        if let ParseResult::Complete(r) = parse_http_request(bare) {
            assert_eq!(r.auth_token, Some(""), "Bare scheme must yield empty token for 401");
        } else {
            panic!("bare token failed to parse");
        }
    }

    #[test]
    fn test_parse_pipelined_requests() {
        let mut stream = Vec::new();
        stream.extend_from_slice(b"GET /api/tags HTTP/1.1\r\n\r\n");
        stream.extend_from_slice(b"GET /api/user HTTP/1.1\r\n\r\n");

        match parse_http_request(&stream) {
            ParseResult::Complete(r1) => {
                assert_eq!(r1.path, "/api/tags");
                let remaining = &stream[r1.bytes_consumed..];
                match parse_http_request(remaining) {
                    ParseResult::Complete(r2) => {
                        assert_eq!(r2.path, "/api/user");
                    }
                    _ => panic!("failed to parse second pipelined request"),
                }
            }
            _ => panic!("failed to parse first pipelined request"),
        }
    }

    #[test]
    fn test_parse_incomplete() {
        let partial = b"POST /api/articles HTTP/1.1\r\nContent-Length: 50\r\n\r\nshort";
        assert_eq!(parse_http_request(partial), ParseResult::Incomplete);
    }
}

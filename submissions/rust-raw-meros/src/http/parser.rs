//! Request parser: one pass over a buffer that may hold part of a request, one request, or several.
//!
//! Flow: locate the end of the header block ([`scan`]), parse the request line and the headers we care about,
//! then check that the body (if any) has fully arrived. A request that arrives in one read is parsed once; a
//! request that trickles in re-scans the buffer after each read (at most 16 KiB of head, so this stays cheap).
//!
//! Headers we do not need (Host, User-Agent, Accept, Accept-Encoding, Expect, ...) are skipped after a syntax
//! check of the line. Bare `\n` line endings are not accepted as line ends.

use super::header::{self, ConnectionToken, Length};
use super::request::{Method, Parse, Request};
use super::scan::find_header_end;
use super::status::Status;

/// Largest request head (request line + headers + blank line) accepted. Larger gets 431.
pub const MAX_HEAD_BYTES: usize = 16 * 1024;
/// Largest request body accepted. Larger gets 413 (decided from `Content-Length`, before the body arrives).
pub const MAX_BODY_BYTES: usize = 1024 * 1024;

const CRLF: &[u8] = b"\r\n";
const HTTP_11: &[u8] = b"HTTP/1.1";
const HTTP_10: &[u8] = b"HTTP/1.0";

// Header names by length. Lengths are distinct, so a length match picks the only candidate.
const AUTHORIZATION: &[u8] = b"authorization";
const CONNECTION: &[u8] = b"connection";
const CONTENT_LENGTH: &[u8] = b"content-length";
const CONTENT_TYPE: &[u8] = b"content-type";
const TRANSFER_ENCODING: &[u8] = b"transfer-encoding";

/// Look at the bytes received so far and say whether they hold a complete request.
pub fn parse_request(buf: &[u8]) -> Parse<'_> {
    let Some(head_end) = find_header_end(buf) else {
        return if buf.len() > MAX_HEAD_BYTES {
            Parse::Bad(Status::RequestHeaderFieldsTooLarge)
        } else {
            Parse::Incomplete
        };
    };
    if head_end > MAX_HEAD_BYTES {
        return Parse::Bad(Status::RequestHeaderFieldsTooLarge);
    }
    let head = match parse_head(&buf[..head_end]) {
        Ok(head) => head,
        Err(status) => return Parse::Bad(status),
    };
    if head.content_length > MAX_BODY_BYTES {
        return Parse::Bad(Status::PayloadTooLarge);
    }
    let consumed = head_end + head.content_length;
    if buf.len() < consumed {
        return Parse::Incomplete;
    }
    Parse::Request(Request {
        method: head.method,
        path: head.path,
        query: head.query,
        authorization: head.authorization,
        has_content_type_json: head.json,
        body: &buf[head_end..consumed],
        keep_alive: head.keep_alive,
        consumed,
    })
}

/// Everything learned from the head, before the body is looked at.
struct Head<'a> {
    method: Method,
    path: &'a [u8],
    query: &'a [u8],
    authorization: Option<&'a [u8]>,
    json: bool,
    keep_alive: bool,
    content_length: usize,
}

/// Parse a complete head (ending in the blank line). Errors are the status to answer with.
fn parse_head(head: &[u8]) -> Result<Head<'_>, Status> {
    // Drop the blank line's CRLF; what remains is `line CRLF line CRLF ...`.
    let mut rest = &head[..head.len() - CRLF.len()];

    let (request_line, after) = next_line(rest)?;
    rest = after;
    let line = parse_request_line(request_line)?;

    let mut out = Head {
        method: line.method,
        path: line.path,
        query: line.query,
        authorization: None,
        json: false,
        keep_alive: line.http11,
        content_length: 0,
    };
    let mut seen_length = false;
    while !rest.is_empty() {
        let (header_line, after) = next_line(rest)?;
        rest = after;
        let (name, value) = split_header(header_line)?;
        apply_header(&mut out, &mut seen_length, name, value)?;
    }
    Ok(out)
}

/// Split off the first CRLF-terminated line. A `\r` that is not followed by `\n` is malformed.
fn next_line(buf: &[u8]) -> Result<(&[u8], &[u8]), Status> {
    let cr = buf
        .iter()
        .position(|&b| b == b'\r')
        .ok_or(Status::BadRequest)?;
    if buf.get(cr + 1) != Some(&b'\n') {
        return Err(Status::BadRequest);
    }
    Ok((&buf[..cr], &buf[cr + CRLF.len()..]))
}

struct RequestLine<'a> {
    method: Method,
    path: &'a [u8],
    query: &'a [u8],
    http11: bool,
}

/// `METHOD SP target SP HTTP/1.x`. Only origin-form targets (`/path?query`) are accepted.
fn parse_request_line(line: &[u8]) -> Result<RequestLine<'_>, Status> {
    let mut parts = line.splitn(3, |&b| b == b' ');
    let (Some(method), Some(target), Some(version)) = (parts.next(), parts.next(), parts.next())
    else {
        return Err(Status::BadRequest);
    };
    if method.is_empty() || !method.iter().all(|&b| header::is_token_byte(b)) {
        return Err(Status::BadRequest);
    }
    let http11 = match version {
        HTTP_11 => true,
        HTTP_10 => false,
        _ => return Err(Status::BadRequest),
    };
    if target.first() != Some(&b'/') || target.iter().any(|&b| b <= b' ' || b == 0x7f) {
        return Err(Status::BadRequest);
    }
    let (path, query) = match target.iter().position(|&b| b == b'?') {
        Some(q) => (&target[..q], &target[q + 1..]),
        None => (target, &target[target.len()..]),
    };
    Ok(RequestLine {
        method: Method::from_bytes(method),
        path,
        query,
        http11,
    })
}

/// `name: value` with the value trimmed. The name must be a non-empty token (this also rejects folded lines).
fn split_header(line: &[u8]) -> Result<(&[u8], &[u8]), Status> {
    let colon = line
        .iter()
        .position(|&b| b == b':')
        .ok_or(Status::BadRequest)?;
    let name = &line[..colon];
    if name.is_empty() || !name.iter().all(|&b| header::is_token_byte(b)) {
        return Err(Status::BadRequest);
    }
    Ok((name, header::trim_ows(&line[colon + 1..])))
}

/// Record the headers that change how the request is served; ignore the rest.
fn apply_header<'a>(
    out: &mut Head<'a>,
    seen_length: &mut bool,
    name: &[u8],
    value: &'a [u8],
) -> Result<(), Status> {
    let is = |wanted: &[u8]| name.eq_ignore_ascii_case(wanted);
    match name.len() {
        13 if is(AUTHORIZATION) => out.authorization = Some(value),
        10 if is(CONNECTION) => match header::connection_token(value) {
            ConnectionToken::Close => out.keep_alive = false,
            ConnectionToken::KeepAlive => out.keep_alive = true,
            ConnectionToken::Neither => {}
        },
        14 if is(CONTENT_LENGTH) => {
            if std::mem::replace(seen_length, true) {
                return Err(Status::BadRequest);
            }
            match header::parse_content_length(value) {
                Length::Value(n) => out.content_length = n,
                Length::Malformed => return Err(Status::BadRequest),
            }
        }
        12 if is(CONTENT_TYPE) => out.json = header::is_json_content_type(value),
        17 if is(TRANSFER_ENCODING) => return Err(Status::LengthRequired),
        _ => {}
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// What `bench/cmd/loadgen/client.go` sends for a list request.
    const GO_GET: &[u8] = b"GET /api/articles?limit=10&offset=0 HTTP/1.1\r\nHost: 127.0.0.1:3000\r\nUser-Agent: conduit-loadgen/1\r\nAccept: application/json\r\nAccept-Encoding: gzip\r\n\r\n";

    fn go_post(body: &str) -> Vec<u8> {
        format!(
            "POST /api/users/login HTTP/1.1\r\nHost: 127.0.0.1:3000\r\nUser-Agent: conduit-loadgen/1\r\nAccept: application/json\r\nAccept-Encoding: gzip\r\nAuthorization: Token abc.def.ghi\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
            body.len()
        )
        .into_bytes()
    }

    fn request(buf: &[u8]) -> Request<'_> {
        match parse_request(buf) {
            Parse::Request(r) => r,
            other => panic!("expected a request, got {other:?}"),
        }
    }

    #[test]
    fn go_get_request() {
        let r = request(GO_GET);
        assert_eq!(r.method, Method::Get);
        assert_eq!(r.path, b"/api/articles");
        assert_eq!(r.query, b"limit=10&offset=0");
        assert_eq!(r.authorization, None);
        assert!(!r.has_content_type_json);
        assert!(r.body.is_empty());
        assert!(r.keep_alive);
        assert_eq!(r.consumed, GO_GET.len());
    }

    #[test]
    fn go_post_request_with_token_and_body() {
        let raw = go_post(r#"{"user":{"email":"a@b.c"}}"#);
        let r = request(&raw);
        assert_eq!(r.method, Method::Post);
        assert_eq!(r.path, b"/api/users/login");
        assert_eq!(r.query, b"");
        assert_eq!(r.authorization, Some(&b"Token abc.def.ghi"[..]));
        assert!(r.has_content_type_json);
        assert_eq!(r.body, br#"{"user":{"email":"a@b.c"}}"#);
        assert_eq!(r.consumed, raw.len());
    }

    #[test]
    fn go_delete_without_body() {
        let raw =
            b"DELETE /api/articles/x/favorite HTTP/1.1\r\nHost: h\r\nContent-Length: 0\r\n\r\n";
        let r = request(raw);
        assert_eq!(r.method, Method::Delete);
        assert!(r.body.is_empty());
    }

    #[test]
    fn every_prefix_is_incomplete() {
        let raw = go_post("{\"a\":1}");
        for cut in 0..raw.len() {
            assert_eq!(parse_request(&raw[..cut]), Parse::Incomplete, "cut {cut}");
        }
        assert!(matches!(parse_request(&raw), Parse::Request(_)));
    }

    #[test]
    fn two_requests_in_one_buffer_parse_one_at_a_time() {
        let mut raw = GO_GET.to_vec();
        raw.extend_from_slice(&go_post("{}"));
        let first = request(&raw);
        assert_eq!(first.consumed, GO_GET.len());
        assert_eq!(first.method, Method::Get);
        let second = request(&raw[first.consumed..]);
        assert_eq!(second.method, Method::Post);
        assert_eq!(second.body, b"{}");
    }

    #[test]
    fn header_names_are_case_insensitive() {
        let raw = b"POST /x HTTP/1.1\r\nAUTHORIZATION:   Token t  \r\ncontent-TYPE: Application/JSON\r\nCONTENT-LENGTH: 2\r\nconnection: CLOSE\r\n\r\nhi";
        let r = request(raw);
        assert_eq!(r.authorization, Some(&b"Token t"[..]));
        assert!(r.has_content_type_json);
        assert_eq!(r.body, b"hi");
        assert!(!r.keep_alive);
    }

    #[test]
    fn keep_alive_rules() {
        assert!(request(b"GET / HTTP/1.1\r\n\r\n").keep_alive);
        assert!(!request(b"GET / HTTP/1.1\r\nConnection: close\r\n\r\n").keep_alive);
        assert!(!request(b"GET / HTTP/1.0\r\n\r\n").keep_alive);
        assert!(request(b"GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n").keep_alive);
    }

    #[test]
    fn methods() {
        for (m, expected) in [
            ("GET", Method::Get),
            ("POST", Method::Post),
            ("PUT", Method::Put),
            ("DELETE", Method::Delete),
            ("HEAD", Method::Head),
            ("PATCH", Method::Other),
            ("get", Method::Other),
        ] {
            let raw = format!("{m} / HTTP/1.1\r\n\r\n");
            assert_eq!(request(raw.as_bytes()).method, expected, "{m}");
        }
    }

    #[test]
    fn missing_content_length_means_empty_body() {
        let raw = b"POST /api/x HTTP/1.1\r\nContent-Type: application/json\r\n\r\n";
        let r = request(raw);
        assert!(r.body.is_empty());
        assert_eq!(r.consumed, raw.len());
    }

    #[test]
    fn malformed_requests_are_400() {
        let cases: &[&[u8]] = &[
            b"\r\n\r\n",
            b"GET\r\n\r\n",
            b"GET /\r\n\r\n",
            b"GET / HTTP/2.0\r\n\r\n",
            b"GET / HTTP/1.1 extra\r\n\r\n",
            b"GET x HTTP/1.1\r\n\r\n",
            b"GET * HTTP/1.1\r\n\r\n",
            b"GET /a b HTTP/1.1\r\n\r\n",
            b"GET / HTTP/1.1\r\nNoColon\r\n\r\n",
            b"GET / HTTP/1.1\r\n: empty\r\n\r\n",
            b"GET / HTTP/1.1\r\nBad Name: v\r\n\r\n",
            b"GET / HTTP/1.1\r\n folded: v\r\n\r\n",
            b"GET / HTTP/1.1\rX\r\n\r\n",
            b"POST / HTTP/1.1\r\nContent-Length: abc\r\n\r\n",
            b"POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
            b"POST / HTTP/1.1\r\nContent-Length:\r\n\r\n",
            b"POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx",
        ];
        for case in cases {
            assert_eq!(
                parse_request(case),
                Parse::Bad(Status::BadRequest),
                "{}",
                String::from_utf8_lossy(case)
            );
        }
    }

    #[test]
    fn transfer_encoding_is_411() {
        let raw = b"POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n";
        assert_eq!(parse_request(raw), Parse::Bad(Status::LengthRequired));
    }

    #[test]
    fn body_limit_is_checked_before_the_body_arrives() {
        let ok = format!("POST / HTTP/1.1\r\nContent-Length: {MAX_BODY_BYTES}\r\n\r\n");
        assert_eq!(parse_request(ok.as_bytes()), Parse::Incomplete);
        let big = format!(
            "POST / HTTP/1.1\r\nContent-Length: {}\r\n\r\n",
            MAX_BODY_BYTES + 1
        );
        assert_eq!(
            parse_request(big.as_bytes()),
            Parse::Bad(Status::PayloadTooLarge)
        );
        let huge = "POST / HTTP/1.1\r\nContent-Length: 99999999999999999999999999\r\n\r\n";
        assert_eq!(
            parse_request(huge.as_bytes()),
            Parse::Bad(Status::PayloadTooLarge)
        );
    }

    #[test]
    fn head_limit() {
        // Exactly at the limit: accepted.
        let prefix = "GET / HTTP/1.1\r\nX: ";
        let fill = MAX_HEAD_BYTES - prefix.len() - 4;
        let at_limit = format!("{prefix}{}\r\n\r\n", "a".repeat(fill));
        assert_eq!(at_limit.len(), MAX_HEAD_BYTES);
        assert!(matches!(
            parse_request(at_limit.as_bytes()),
            Parse::Request(_)
        ));
        // One byte over: 431, whether or not the blank line has arrived.
        let over = format!("{prefix}{}\r\n\r\n", "a".repeat(fill + 1));
        assert_eq!(
            parse_request(over.as_bytes()),
            Parse::Bad(Status::RequestHeaderFieldsTooLarge)
        );
        let endless = format!("{prefix}{}", "a".repeat(MAX_HEAD_BYTES));
        assert_eq!(
            parse_request(endless.as_bytes()),
            Parse::Bad(Status::RequestHeaderFieldsTooLarge)
        );
    }

    #[test]
    fn expect_continue_is_ignored() {
        let r = request(b"POST / HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 1\r\n\r\nx");
        assert_eq!(r.body, b"x");
    }

    #[test]
    fn garbage_without_line_end_is_incomplete_until_the_limit() {
        assert_eq!(parse_request(b"\x16\x03\x01\x02\x00"), Parse::Incomplete);
    }

    #[test]
    #[ignore = "benchmark: cargo test --release -- --ignored --nocapture"]
    fn bench_parse_request() {
        const ROUNDS: u32 = 5_000_000;
        let mut consumed = 0usize;
        let start = std::time::Instant::now();
        for _ in 0..ROUNDS {
            if let Parse::Request(r) = parse_request(std::hint::black_box(GO_GET)) {
                consumed += r.consumed + r.query.len();
            }
        }
        let ns = start.elapsed().as_nanos() as f64 / f64::from(ROUNDS);
        println!(
            "parse_request (GET /api/articles?limit=10&offset=0, Go headers): {ns:.1} ns ({consumed})"
        );
    }
}

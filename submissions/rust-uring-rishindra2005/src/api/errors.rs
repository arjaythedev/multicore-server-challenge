//! Conduit error responses and HTTP framing helpers.
//! Written from scratch for rust-uring-rishindra2005.

use super::render::{escape_json_str, frame_response};
pub use super::render::{STATIC_204_CLOSE, STATIC_204_KEEPALIVE};

/// Pre-rendered static HTTP 401 Unauthorized response (keep-alive)
pub const STATIC_401_KEEPALIVE: &[u8] = b"HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: 36\r\nConnection: keep-alive\r\n\r\n{\"errors\":{\"body\":[\"unauthorized\"]}}";

/// Pre-rendered static HTTP 401 Unauthorized response (close)
pub const STATIC_401_CLOSE: &[u8] = b"HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: 36\r\nConnection: close\r\n\r\n{\"errors\":{\"body\":[\"unauthorized\"]}}";

/// Pre-rendered static HTTP 404 Not Found response (keep-alive)
pub const STATIC_404_KEEPALIVE: &[u8] = b"HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: 33\r\nConnection: keep-alive\r\n\r\n{\"errors\":{\"body\":[\"not found\"]}}";

/// Pre-rendered static HTTP 404 Not Found response (close)
pub const STATIC_404_CLOSE: &[u8] = b"HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: 33\r\nConnection: close\r\n\r\n{\"errors\":{\"body\":[\"not found\"]}}";

/// Pre-rendered static HTTP 500 Internal Server Error response (keep-alive)
pub const STATIC_500_KEEPALIVE: &[u8] = b"HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: 38\r\nConnection: keep-alive\r\n\r\n{\"errors\":{\"body\":[\"database error\"]}}";

/// Pre-rendered static HTTP 500 Internal Server Error response (close)
pub const STATIC_500_CLOSE: &[u8] = b"HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: 38\r\nConnection: close\r\n\r\n{\"errors\":{\"body\":[\"database error\"]}}";

/// Build a framed error response with the given status code and message.
pub fn error_reply(status_code: u16, message: &str, keepalive: bool) -> Vec<u8> {
    let mut body = Vec::with_capacity(64);
    body.extend_from_slice(b"{\"errors\":{\"body\":[\"");
    escape_json_str(message, &mut body);
    body.extend_from_slice(b"\"]}}");

    let status_text = match status_code {
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        422 => "Unprocessable Entity",
        500 => "Internal Server Error",
        _ => "Error",
    };

    frame_response(status_code, status_text, &body, keepalive)
}

#[inline]
pub fn reply_401(message: &str, keepalive: bool) -> Vec<u8> {
    if message == "unauthorized" {
        return if keepalive {
            STATIC_401_KEEPALIVE.to_vec()
        } else {
            STATIC_401_CLOSE.to_vec()
        };
    }
    error_reply(401, message, keepalive)
}

#[inline]
pub fn reply_403(message: &str, keepalive: bool) -> Vec<u8> {
    error_reply(403, message, keepalive)
}

#[inline]
pub fn reply_404(keepalive: bool) -> Vec<u8> {
    if keepalive {
        STATIC_404_KEEPALIVE.to_vec()
    } else {
        STATIC_404_CLOSE.to_vec()
    }
}

#[inline]
pub fn reply_404_msg(message: &str, keepalive: bool) -> Vec<u8> {
    if message == "not found" {
        return reply_404(keepalive);
    }
    error_reply(404, message, keepalive)
}

#[inline]
pub fn reply_422(message: &str, keepalive: bool) -> Vec<u8> {
    error_reply(422, message, keepalive)
}

#[inline]
pub fn reply_500(keepalive: bool) -> Vec<u8> {
    if keepalive {
        STATIC_500_KEEPALIVE.to_vec()
    } else {
        STATIC_500_CLOSE.to_vec()
    }
}

#[inline]
pub fn reply_204(keepalive: bool) -> Vec<u8> {
    if keepalive {
        STATIC_204_KEEPALIVE.to_vec()
    } else {
        STATIC_204_CLOSE.to_vec()
    }
}

#[cfg(test)]
mod framing_tests {
    use super::*;

    /// Every pre-rendered response must declare the exact body length, or keep-alive clients hang.
    #[test]
    fn static_responses_have_exact_content_length() {
        for r in [
            STATIC_401_KEEPALIVE,
            STATIC_401_CLOSE,
            STATIC_404_KEEPALIVE,
            STATIC_404_CLOSE,
            STATIC_500_KEEPALIVE,
            STATIC_500_CLOSE,
            STATIC_204_KEEPALIVE,
            STATIC_204_CLOSE,
        ] {
            let s = std::str::from_utf8(r).unwrap();
            let (head, body) = s.split_once("\r\n\r\n").unwrap();
            let cl: usize = head
                .lines()
                .find_map(|l| l.strip_prefix("Content-Length: "))
                .unwrap()
                .parse()
                .unwrap();
            assert_eq!(cl, body.len(), "bad Content-Length in {head:?}");
        }
    }
}

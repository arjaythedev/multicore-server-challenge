//! The response statuses this server can produce, with their wire text.

/// Every status the server sends. A closed set keeps the status line a `&'static [u8]` lookup.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    Ok,
    Created,
    NoContent,
    BadRequest,
    Unauthorized,
    Forbidden,
    NotFound,
    LengthRequired,
    PayloadTooLarge,
    Unprocessable,
    RequestHeaderFieldsTooLarge,
    Internal,
    ServiceUnavailable,
}

impl Status {
    /// All statuses, for tests and table-driven checks.
    pub const ALL: [Status; 13] = [
        Status::Ok,
        Status::Created,
        Status::NoContent,
        Status::BadRequest,
        Status::Unauthorized,
        Status::Forbidden,
        Status::NotFound,
        Status::LengthRequired,
        Status::PayloadTooLarge,
        Status::Unprocessable,
        Status::RequestHeaderFieldsTooLarge,
        Status::Internal,
        Status::ServiceUnavailable,
    ];

    /// Numeric status code.
    pub const fn code(self) -> u16 {
        match self {
            Status::Ok => 200,
            Status::Created => 201,
            Status::NoContent => 204,
            Status::BadRequest => 400,
            Status::Unauthorized => 401,
            Status::Forbidden => 403,
            Status::NotFound => 404,
            Status::LengthRequired => 411,
            Status::PayloadTooLarge => 413,
            Status::Unprocessable => 422,
            Status::RequestHeaderFieldsTooLarge => 431,
            Status::Internal => 500,
            Status::ServiceUnavailable => 503,
        }
    }

    /// Reason phrase as in RFC 9110.
    pub const fn reason(self) -> &'static str {
        match self {
            Status::Ok => "OK",
            Status::Created => "Created",
            Status::NoContent => "No Content",
            Status::BadRequest => "Bad Request",
            Status::Unauthorized => "Unauthorized",
            Status::Forbidden => "Forbidden",
            Status::NotFound => "Not Found",
            Status::LengthRequired => "Length Required",
            Status::PayloadTooLarge => "Payload Too Large",
            Status::Unprocessable => "Unprocessable Entity",
            Status::RequestHeaderFieldsTooLarge => "Request Header Fields Too Large",
            Status::Internal => "Internal Server Error",
            Status::ServiceUnavailable => "Service Unavailable",
        }
    }

    /// The complete status line including the trailing CRLF, e.g. `HTTP/1.1 200 OK\r\n`.
    /// Spelled out per variant so the response writer does one `memcpy` and no formatting.
    pub const fn status_line(self) -> &'static [u8] {
        match self {
            Status::Ok => b"HTTP/1.1 200 OK\r\n",
            Status::Created => b"HTTP/1.1 201 Created\r\n",
            Status::NoContent => b"HTTP/1.1 204 No Content\r\n",
            Status::BadRequest => b"HTTP/1.1 400 Bad Request\r\n",
            Status::Unauthorized => b"HTTP/1.1 401 Unauthorized\r\n",
            Status::Forbidden => b"HTTP/1.1 403 Forbidden\r\n",
            Status::NotFound => b"HTTP/1.1 404 Not Found\r\n",
            Status::LengthRequired => b"HTTP/1.1 411 Length Required\r\n",
            Status::PayloadTooLarge => b"HTTP/1.1 413 Payload Too Large\r\n",
            Status::Unprocessable => b"HTTP/1.1 422 Unprocessable Entity\r\n",
            Status::RequestHeaderFieldsTooLarge => {
                b"HTTP/1.1 431 Request Header Fields Too Large\r\n"
            }
            Status::Internal => b"HTTP/1.1 500 Internal Server Error\r\n",
            Status::ServiceUnavailable => b"HTTP/1.1 503 Service Unavailable\r\n",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_line_matches_code_and_reason() {
        for s in Status::ALL {
            let expected = format!("HTTP/1.1 {} {}\r\n", s.code(), s.reason());
            assert_eq!(s.status_line(), expected.as_bytes(), "{s:?}");
        }
    }
}

//! Types a parsed request is handed over in. All borrowed from the connection's read buffer.

use super::status::Status;

/// Request method. Anything the router does not know is [`Method::Other`] (it will answer 404/405 itself).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Method {
    Get,
    Post,
    Put,
    Delete,
    Head,
    Other,
}

impl Method {
    /// Case-sensitive, as HTTP methods are.
    pub(super) fn from_bytes(token: &[u8]) -> Method {
        match token {
            b"GET" => Method::Get,
            b"POST" => Method::Post,
            b"PUT" => Method::Put,
            b"DELETE" => Method::Delete,
            b"HEAD" => Method::Head,
            _ => Method::Other,
        }
    }
}

/// One complete request, borrowed from the buffer given to [`super::parse_request`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Request<'a> {
    pub method: Method,
    /// Request target without the query string. Not percent-decoded.
    pub path: &'a [u8],
    /// Bytes after the first `?` (empty when there is none). Not decoded; see [`super::query_param`].
    pub query: &'a [u8],
    /// Raw `Authorization` header value (e.g. `Token eyJ...`), trimmed of surrounding blanks.
    pub authorization: Option<&'a [u8]>,
    /// `Content-Type` is `application/json`, optionally followed by parameters.
    pub has_content_type_json: bool,
    /// Request body; empty when no `Content-Length` was sent.
    pub body: &'a [u8],
    /// Whether the connection stays open after the response.
    pub keep_alive: bool,
    /// Bytes of the buffer this request occupies (head + body); the caller drains exactly this many.
    pub consumed: usize,
}

/// Result of looking at the bytes received so far.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Parse<'a> {
    /// More bytes are needed; call again after the next read.
    Incomplete,
    Request(Request<'a>),
    /// The request cannot be served; answer with this status and close the connection.
    Bad(Status),
}

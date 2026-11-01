//! Response buffer that puts the header block in front of an already rendered body without copying.
//!
//! The Content-Length is only known after the body is rendered, so the handler writes the body at
//! `HEAD_RESERVE..` and [`ResponseBuf::finish`] writes the header block *backwards* from byte `HEAD_RESERVE`.
//! The response then starts at the returned offset, and one `write(2)` sends header and body together.
//!
//! ```text
//! 0          start                 HEAD_RESERVE            len
//! |  unused  | HTTP/1.1 200 OK ... \r\n\r\n | body ........ |
//! ```

use super::status::Status;
use crate::json::{JsonWriter, itoa};

/// Bytes reserved in front of the body. The longest head is about 140 bytes (status line of 431, both
/// headers, `Connection: close`, 20 digits of length); a test builds every status to prove it fits.
pub const HEAD_RESERVE: usize = 160;

const CONTENT_TYPE_JSON: &[u8] = b"Content-Type: application/json\r\n";
const CONTENT_LENGTH: &[u8] = b"Content-Length: ";
const CONNECTION_CLOSE: &[u8] = b"Connection: close\r\n";
const CRLF: &[u8] = b"\r\n";

/// A reusable response under construction. One per lane or connection; `begin` resets it.
#[derive(Default)]
pub struct ResponseBuf {
    buf: Vec<u8>,
}

impl ResponseBuf {
    pub fn new() -> Self {
        Self::default()
    }

    /// Builds on an existing allocation (for example a pooled buffer); the contents are discarded by `begin`.
    pub fn from_vec(buf: Vec<u8>) -> Self {
        ResponseBuf { buf }
    }

    /// Forget the previous response and reserve the head area. Keeps the allocation.
    pub fn begin(&mut self) {
        self.buf.clear();
        self.buf.resize(HEAD_RESERVE, 0);
    }

    /// The buffer the body is appended to (everything before `HEAD_RESERVE` belongs to the head).
    /// Do not shrink it below [`HEAD_RESERVE`].
    pub fn body(&mut self) -> &mut Vec<u8> {
        &mut self.buf
    }

    /// Body bytes rendered so far.
    pub fn body_len(&self) -> usize {
        self.buf.len().saturating_sub(HEAD_RESERVE)
    }

    /// Write the header block for `status` and return the offset where the response starts.
    /// Send `bytes_from(offset)`. `204 No Content` drops the body and has no `Content-Type`/`Content-Length`.
    pub fn finish(&mut self, status: Status, keep_alive: bool) -> usize {
        if self.buf.len() < HEAD_RESERVE {
            self.begin(); // finish without begin: answer with an empty body rather than panic
        }
        let has_body = status != Status::NoContent;
        if !has_body {
            self.buf.truncate(HEAD_RESERVE);
        }
        let body_len = self.body_len();
        let mut head = HeadWriter {
            area: &mut self.buf[..HEAD_RESERVE],
            start: HEAD_RESERVE,
        };

        // Written in reverse order of appearance on the wire.
        head.prepend(CRLF);
        if !keep_alive {
            head.prepend(CONNECTION_CLOSE);
        }
        if has_body {
            head.prepend(CRLF);
            let mut digits = [0u8; itoa::MAX_U64_DIGITS];
            let first = itoa::format_u64(body_len as u64, &mut digits);
            head.prepend(&digits[first..]);
            head.prepend(CONTENT_LENGTH);
            head.prepend(CONTENT_TYPE_JSON);
        }
        head.prepend(status.status_line());
        head.start
    }

    /// Finish with the standard error body `{"errors":{"body":["message"]}}`.
    pub fn finish_error(&mut self, status: Status, keep_alive: bool, message: &str) -> usize {
        self.begin();
        error_body(&mut self.buf, message);
        self.finish(status, keep_alive)
    }

    /// The bytes to send: head and body from `start` (as returned by `finish`) to the end.
    pub fn bytes_from(&self, start: usize) -> &[u8] {
        &self.buf[start..]
    }

    /// Give the buffer away, e.g. to hand a finished response to another thread. Combine with the offset
    /// from `finish`.
    pub fn into_vec(self) -> Vec<u8> {
        self.buf
    }
}

/// Fills a fixed area from its end towards its start.
struct HeadWriter<'a> {
    area: &'a mut [u8],
    start: usize,
}

impl HeadWriter<'_> {
    /// Place `piece` directly before what has been written so far. Panics only if `HEAD_RESERVE` is too small,
    /// which the `every_status_fits_in_the_reserve` test rules out.
    fn prepend(&mut self, piece: &[u8]) {
        self.start -= piece.len();
        self.area[self.start..self.start + piece.len()].copy_from_slice(piece);
    }
}

/// Append the Conduit error document `{"errors":{"body":["message"]}}` to `out`.
pub fn error_body(out: &mut Vec<u8>, message: &str) {
    let mut w = JsonWriter::new(out);
    w.begin_object();
    w.key("errors");
    w.begin_object();
    w.key("body");
    w.begin_array();
    w.string(message);
    w.end_array();
    w.end_object();
    w.end_object();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn render(status: Status, keep_alive: bool, body: &str) -> String {
        let mut r = ResponseBuf::new();
        r.begin();
        r.body().extend_from_slice(body.as_bytes());
        let start = r.finish(status, keep_alive);
        String::from_utf8(r.bytes_from(start).to_vec()).unwrap()
    }

    #[test]
    fn ok_keep_alive_layout() {
        assert_eq!(
            render(Status::Ok, true, r#"{"a":1}"#),
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 7\r\n\r\n{\"a\":1}"
        );
    }

    #[test]
    fn connection_close_goes_before_the_blank_line() {
        assert_eq!(
            render(Status::NotFound, false, "{}"),
            "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
        );
    }

    #[test]
    fn no_content_has_no_body_and_no_entity_headers() {
        assert_eq!(
            render(Status::NoContent, true, "ignored"),
            "HTTP/1.1 204 No Content\r\n\r\n"
        );
        assert_eq!(
            render(Status::NoContent, false, ""),
            "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
        );
    }

    #[test]
    fn empty_body_and_large_length() {
        assert!(render(Status::Created, true, "").contains("Content-Length: 0\r\n\r\n"));
        let big = "x".repeat(1_048_576);
        assert!(render(Status::Ok, true, &big).contains("Content-Length: 1048576\r\n\r\n"));
    }

    #[test]
    fn every_status_fits_in_the_reserve() {
        for s in Status::ALL {
            for keep_alive in [true, false] {
                let mut r = ResponseBuf::new();
                r.begin();
                r.body().extend_from_slice(&[b'x'; 123_456]);
                let start = r.finish(s, keep_alive);
                assert!(start < HEAD_RESERVE, "{s:?}");
            }
        }
        // Worst case: longest status line, close, and a 20-digit length.
        let worst = Status::RequestHeaderFieldsTooLarge.status_line().len()
            + CONTENT_TYPE_JSON.len()
            + CONTENT_LENGTH.len()
            + itoa::MAX_U64_DIGITS
            + CRLF.len()
            + CONNECTION_CLOSE.len()
            + CRLF.len();
        assert!(worst <= HEAD_RESERVE, "{worst}");
    }

    #[test]
    fn buffer_is_reusable() {
        let mut r = ResponseBuf::new();
        r.begin();
        r.body().extend_from_slice(b"first body that is long");
        r.finish(Status::Ok, true);
        r.begin();
        r.body().extend_from_slice(b"b");
        let start = r.finish(Status::Ok, true);
        assert!(r.bytes_from(start).ends_with(b"Content-Length: 1\r\n\r\nb"));
    }

    #[test]
    fn error_document() {
        let mut r = ResponseBuf::new();
        let start = r.finish_error(Status::Unprocessable, true, "can't be \"blank\"");
        let text = String::from_utf8(r.bytes_from(start).to_vec()).unwrap();
        assert!(text.starts_with("HTTP/1.1 422 Unprocessable Entity\r\n"));
        assert!(text.ends_with("\r\n\r\n{\"errors\":{\"body\":[\"can't be \\\"blank\\\"\"]}}"));
    }

    #[test]
    fn finish_without_begin_does_not_panic() {
        let mut r = ResponseBuf::new();
        let start = r.finish(Status::Ok, true);
        assert!(r.bytes_from(start).ends_with(b"Content-Length: 0\r\n\r\n"));
    }
}

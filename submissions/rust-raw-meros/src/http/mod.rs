//! HTTP/1.1 for a closed set of clients (Go's `net/http` in the load generator and the conformance suite).
//!
//! What is here: a one-pass request parser ([`parse_request`]), query-string helpers ([`query`]), a status table
//! ([`Status`]) and a response buffer that writes the header block in front of an already rendered body
//! ([`ResponseBuf`]).
//!
//! What is deliberately not handled (all safe for this workload, each answered with a clean status):
//! chunked request bodies (411), trailers, `Expect: 100-continue` (ignored), HTTP/0.9 and HTTP/2, absolute-form
//! and `*` request targets (400), pipelining beyond "a buffer holding two requests parses one at a time".

pub mod query;
pub mod request;
pub mod response;
pub mod status;

mod header;
mod parser;
mod scan;

pub use query::{parse_int, percent_decode, query_param};
pub use request::{Method, Parse, Request};
pub use response::{HEAD_RESERVE, ResponseBuf, error_body};
pub use status::Status;

pub use parser::{MAX_BODY_BYTES, MAX_HEAD_BYTES, parse_request};

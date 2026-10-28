//! JSON for this server: a streaming writer for responses and a small strict reader for request bodies.
//!
//! - [`JsonWriter`] appends compact JSON to a `Vec<u8>` with no allocation of its own (string escaping has an
//!   SSE2 fast path, integers use a two-digit table, timestamps are formatted from microseconds directly).
//! - [`parse`] builds a [`Value`] tree that borrows from the input where it can. Request bodies are small
//!   (a few hundred bytes), so a DOM is simpler than a streaming reader and costs little.
//!
//! Not handled on purpose: pretty printing, floating point output (the API has no floats), number
//! conversion on read (numbers are kept as validated text), streaming input.

mod escape;
pub mod itoa;
mod reader;
mod time;
mod value;
mod writer;

pub use reader::{MAX_DEPTH, MAX_INPUT_BYTES, parse};
pub use time::write_timestamp_micros;
pub use value::{JsonError, Value};
pub use writer::JsonWriter;

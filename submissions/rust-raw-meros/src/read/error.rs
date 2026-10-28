//! Why a group of requests could not be answered from its rows.

use std::fmt;

use crate::pg::PgError;

/// A problem with the rows of one statement. It fails the requests that statement was answering (500); it is the
/// query or the mapping that is wrong, not the client.
#[derive(Debug)]
pub enum ReadError {
    /// A value could not be decoded (wrong width, NULL where none is allowed, bad UTF-8).
    Decode(PgError),
    /// The rows contradict each other (an unknown article id, an `ord` outside the batch, a request answered twice).
    Inconsistent(&'static str),
}

impl From<PgError> for ReadError {
    fn from(e: PgError) -> Self {
        ReadError::Decode(e)
    }
}

impl fmt::Display for ReadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ReadError::Decode(e) => write!(f, "cannot decode a row: {e}"),
            ReadError::Inconsistent(what) => write!(f, "inconsistent rows: {what}"),
        }
    }
}

impl std::error::Error for ReadError {}

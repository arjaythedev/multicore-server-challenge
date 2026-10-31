//! Column reads straight from a row's binary DataRow bytes. Every statement's column types are fixed by sql.rs and
//! read_batch.rs (int8, bool, text, timestamptz, text[], int8[]), so the handlers skip `Row::get`'s per-call type
//! check and `FromSql` dispatch; a value of the wrong size still panics, as `get` would. Text is borrowed as bytes:
//! tokio-postgres connects with `client_encoding=UTF8` and PostgreSQL validates every text value it stores, so it
//! is written to JSON without a second UTF-8 check.

use tokio_postgres::Row;

pub trait Col {
    /// A non-NULL text column.
    fn text(&self, k: usize) -> &[u8];
    /// A text column, None for NULL.
    fn opt_text(&self, k: usize) -> Option<&[u8]>;
    /// A non-NULL int8 column.
    fn int(&self, k: usize) -> i64;
    /// An int8 column, None for NULL.
    fn opt_int(&self, k: usize) -> Option<i64>;
    /// A non-NULL bool column.
    fn flag(&self, k: usize) -> bool;
    /// A non-NULL timestamptz column: microseconds since 2000-01-01 UTC.
    fn ts(&self, k: usize) -> i64;
    /// A non-NULL column's bytes (text[] / int8[]).
    fn bytes(&self, k: usize) -> &[u8];
}

#[cold]
#[inline(never)]
#[track_caller]
fn bad(k: usize) -> ! {
    panic!("error retrieving column {k}: unexpected NULL or size")
}

#[inline]
#[track_caller]
fn be8(raw: &[u8], k: usize) -> i64 {
    match <[u8; 8]>::try_from(raw) {
        Ok(b) => i64::from_be_bytes(b),
        Err(_) => bad(k),
    }
}

impl Col for Row {
    #[inline]
    #[track_caller]
    fn text(&self, k: usize) -> &[u8] {
        self.raw(k).unwrap_or_else(|| bad(k))
    }
    #[inline]
    fn opt_text(&self, k: usize) -> Option<&[u8]> {
        self.raw(k)
    }
    #[inline]
    #[track_caller]
    fn int(&self, k: usize) -> i64 {
        be8(self.raw(k).unwrap_or_else(|| bad(k)), k)
    }
    #[inline]
    #[track_caller]
    fn opt_int(&self, k: usize) -> Option<i64> {
        self.raw(k).map(|raw| be8(raw, k))
    }
    #[inline]
    #[track_caller]
    fn flag(&self, k: usize) -> bool {
        match self.raw(k) {
            Some([b]) => *b != 0,
            _ => bad(k),
        }
    }
    #[inline]
    #[track_caller]
    fn ts(&self, k: usize) -> i64 {
        self.int(k)
    }
    #[inline]
    #[track_caller]
    fn bytes(&self, k: usize) -> &[u8] {
        self.raw(k).unwrap_or_else(|| bad(k))
    }
}

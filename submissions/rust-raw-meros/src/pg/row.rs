//! [`Row`]: typed access to the columns of one result row.
//!
//! A row is a pair of borrowed slices (the arena's bytes and this row's cells), so it is `Copy` and free to create.
//! Accessors never panic: a column index out of range, a NULL where a value is required, or a value of the wrong
//! width is a `PgError::Protocol`. The caller knows the SQL it sent, so such an error means a bug in the query or the
//! mapping, not a bad connection.

use super::codec::{self, Int8Array, TextArray};
use super::error::PgError;
use super::results::Cell;

#[derive(Clone, Copy)]
pub struct Row<'a> {
    data: &'a [u8],
    cells: &'a [Cell],
}

impl<'a> Row<'a> {
    pub(super) fn new(data: &'a [u8], cells: &'a [Cell]) -> Self {
        Row { data, cells }
    }

    /// Number of columns.
    pub fn len(&self) -> usize {
        self.cells.len()
    }

    pub fn is_empty(&self) -> bool {
        self.cells.is_empty()
    }

    /// True for a NULL value (and for a column index that does not exist).
    pub fn is_null(&self, col: usize) -> bool {
        self.cells.get(col).is_none_or(|c| c.len == Cell::NULL_LEN)
    }

    /// Raw bytes of a column; empty for NULL or an out-of-range index (check [`is_null`](Self::is_null) to tell).
    pub fn bytes(&self, col: usize) -> &'a [u8] {
        self.value(col).ok().flatten().unwrap_or(&[])
    }

    /// `Ok(None)` for NULL, `Err` for a missing column.
    fn value(&self, col: usize) -> Result<Option<&'a [u8]>, PgError> {
        let cell = self.cells.get(col).ok_or_else(|| {
            PgError::protocol(format!(
                "column {col} out of range ({} columns)",
                self.cells.len()
            ))
        })?;
        if cell.len == Cell::NULL_LEN {
            return Ok(None);
        }
        let start = cell.offset as usize;
        // Offsets and lengths were validated against `data` when the row was collected.
        self.data
            .get(start..start + cell.len as usize)
            .map(Some)
            .ok_or_else(|| PgError::protocol("cell out of bounds"))
    }

    /// Like [`value`](Self::value) but NULL is an error.
    fn required(&self, col: usize) -> Result<&'a [u8], PgError> {
        self.value(col)?
            .ok_or_else(|| PgError::protocol(format!("column {col} is NULL")))
    }

    pub fn i64(&self, col: usize) -> Result<i64, PgError> {
        codec::decode_i64(self.required(col)?)
    }

    pub fn i32(&self, col: usize) -> Result<i32, PgError> {
        codec::decode_i32(self.required(col)?)
    }

    pub fn bool(&self, col: usize) -> Result<bool, PgError> {
        codec::decode_bool(self.required(col)?)
    }

    /// Text column, validated as UTF-8.
    pub fn str(&self, col: usize) -> Result<&'a str, PgError> {
        codec::decode_str(self.required(col)?)
    }

    /// `timestamptz` as microseconds since 2000-01-01 00:00:00 UTC (the binary wire value, unconverted).
    pub fn timestamptz_micros(&self, col: usize) -> Result<i64, PgError> {
        codec::decode_i64(self.required(col)?)
    }

    /// `text[]` column. The array structure and every element are validated up front, so iterating cannot fail.
    pub fn text_array(&self, col: usize) -> Result<TextArray<'a>, PgError> {
        TextArray::parse(self.required(col)?)
    }

    /// `int8[]` column, validated up front like [`text_array`](Self::text_array).
    pub fn i64_array(&self, col: usize) -> Result<Int8Array<'a>, PgError> {
        Int8Array::parse(self.required(col)?)
    }
}

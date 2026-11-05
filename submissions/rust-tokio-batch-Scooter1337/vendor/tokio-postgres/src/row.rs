//! Rows.

use crate::row::sealed::{AsName, Sealed};
use crate::simple_query::SimpleColumn;
use crate::statement::Column;
use crate::types::{FromSql, Type, WrongType};
use crate::{Error, Statement};
use fallible_iterator::FallibleIterator;
use postgres_protocol::message::backend::DataRowBody;
use std::fmt;
use std::io;
use std::ops::Range;
use std::str;
use std::sync::{Arc, OnceLock};

mod sealed {
    pub trait Sealed {}

    pub trait AsName {
        fn as_name(&self) -> &str;
    }
}

impl AsName for Column {
    fn as_name(&self) -> &str {
        self.name()
    }
}

impl AsName for String {
    fn as_name(&self) -> &str {
        self
    }
}

/// A trait implemented by types that can index into columns of a row.
///
/// This cannot be implemented outside of this crate.
pub trait RowIndex: Sealed {
    #[doc(hidden)]
    fn __idx<T>(&self, columns: &[T]) -> Option<usize>
    where
        T: AsName;
}

impl Sealed for usize {}

impl RowIndex for usize {
    #[inline]
    fn __idx<T>(&self, columns: &[T]) -> Option<usize>
    where
        T: AsName,
    {
        if *self >= columns.len() {
            None
        } else {
            Some(*self)
        }
    }
}

impl Sealed for str {}

impl RowIndex for str {
    #[inline]
    fn __idx<T>(&self, columns: &[T]) -> Option<usize>
    where
        T: AsName,
    {
        if let Some(idx) = columns.iter().position(|d| d.as_name() == self) {
            return Some(idx);
        };

        // FIXME ASCII-only case insensitivity isn't really the right thing to
        // do. Postgres itself uses a dubious wrapper around tolower and JDBC
        // uses the US locale.
        columns
            .iter()
            .position(|d| d.as_name().eq_ignore_ascii_case(self))
    }
}

impl<T> Sealed for &T where T: ?Sized + Sealed {}

impl<T> RowIndex for &T
where
    T: ?Sized + RowIndex,
{
    #[inline]
    fn __idx<U>(&self, columns: &[U]) -> Option<usize>
    where
        U: AsName,
    {
        T::__idx(*self, columns)
    }
}

/// A row of data returned from the database by a query.
///
/// All the rows of one result share one allocation (`Group`: the statement, the DataRow bodies and their column
/// offsets), so a clone or drop is a single reference-count update.
#[derive(Clone)]
pub struct Row {
    group: Arc<Group>,
    /// This row's position in `group.bodies`.
    index: usize,
}

struct Group {
    statement: Statement,
    bodies: Vec<DataRowBody>,
    /// One entry per (row, column), row-major.
    ranges: Vec<Field>,
    // Optional serialization of immutable shared rows. Lifetime is exactly this result set.
    json: OnceLock<Box<[OnceLock<(Vec<u8>, [usize; 2])>]>>,
}

/// A column's byte range within its DataRow body; `start == u32::MAX` is NULL. A DataRow's length is an
/// int32, so its offsets fit in u32.
#[derive(Clone, Copy)]
struct Field {
    start: u32,
    end: u32,
}

/// Appends `body`'s column ranges to `out`, checking the field count against `columns`.
fn push_ranges(out: &mut Vec<Field>, body: &DataRowBody, columns: usize) -> Result<(), Error> {
    let start = out.len();
    let mut ranges = body.ranges();
    while let Some(range) = ranges.next().map_err(Error::parse)? {
        out.push(match range {
            Some(r) => Field {
                start: u32::try_from(r.start).map_err(|_| too_long())?,
                end: u32::try_from(r.end).map_err(|_| too_long())?,
            },
            None => Field {
                start: u32::MAX,
                end: 0,
            },
        });
    }
    // The DataRow field count is sent by the server independently of the
    // RowDescription column count; a mismatch would make column accessors
    // index `ranges` out of bounds and panic, so reject it up front.
    if out.len() - start != columns {
        return Err(Error::parse(io::Error::new(
            io::ErrorKind::InvalidData,
            "DataRow field count does not match the number of columns",
        )));
    }
    Ok(())
}

#[cold]
fn too_long() -> Error {
    Error::parse(io::Error::new(io::ErrorKind::InvalidData, "DataRow too long"))
}

impl fmt::Debug for Row {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Row")
            .field("columns", &self.columns())
            .finish()
    }
}

impl Row {
    pub(crate) fn new(statement: Statement, body: DataRowBody) -> Result<Row, Error> {
        let mut ranges = Vec::with_capacity(statement.columns().len());
        push_ranges(&mut ranges, &body, statement.columns().len())?;
        Ok(Row {
            group: Arc::new(Group {
                statement,
                bodies: vec![body],
                ranges,
                json: OnceLock::new(),
            }),
            index: 0,
        })
    }

    /// The rows of one result (drained from `bodies`), sharing one `Group`.
    pub(crate) fn group(statement: &Statement, bodies: &mut Vec<DataRowBody>) -> Result<Vec<Row>, Error> {
        let columns = statement.columns().len();
        let mut ranges = Vec::with_capacity(bodies.len() * columns);
        for body in bodies.iter() {
            if let Err(e) = push_ranges(&mut ranges, body, columns) {
                bodies.clear();
                return Err(e);
            }
        }
        let n = bodies.len();
        let group = Arc::new(Group {
            statement: statement.clone(),
            bodies: std::mem::take(bodies),
            ranges,
            json: OnceLock::new(),
        });
        Ok((0..n)
            .map(|index| Row {
                group: group.clone(),
                index,
            })
            .collect())
    }

    /// Memoizes viewer-independent serialization only within this immutable query result.
    /// Cloned handles to the same row share it; dropping the last result handle drops all bytes.
    pub fn shared_json(&self, build: impl FnOnce() -> (Vec<u8>, [usize; 2])) -> (&[u8], [usize; 2]) {
        let slots = self.group.json.get_or_init(||
            (0..self.group.bodies.len()).map(|_| OnceLock::new()).collect());
        let (bytes, cuts) = slots[self.index].get_or_init(build);
        (bytes, *cuts)
    }

    /// Returns information about the columns of data in the row.
    pub fn columns(&self) -> &[Column] {
        self.group.statement.columns()
    }

    /// Determines if the row contains no values.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Returns the number of values in the row.
    pub fn len(&self) -> usize {
        self.columns().len()
    }

    /// Deserializes a value from the row.
    ///
    /// The value can be specified either by its numeric index in the row, or by its column name.
    ///
    /// # Panics
    ///
    /// Panics if the index is out of bounds or if the value cannot be converted to the specified type.
    #[track_caller]
    pub fn get<'a, I, T>(&'a self, idx: I) -> T
    where
        I: RowIndex + fmt::Display,
        T: FromSql<'a>,
    {
        match self.get_inner(&idx) {
            Ok(ok) => ok,
            Err(err) => panic!("error retrieving column {}: {}", idx, err),
        }
    }

    /// Like `Row::get`, but returns a `Result` rather than panicking.
    pub fn try_get<'a, I, T>(&'a self, idx: I) -> Result<T, Error>
    where
        I: RowIndex + fmt::Display,
        T: FromSql<'a>,
    {
        self.get_inner(&idx)
    }

    fn get_inner<'a, I, T>(&'a self, idx: &I) -> Result<T, Error>
    where
        I: RowIndex + fmt::Display,
        T: FromSql<'a>,
    {
        let idx = match idx.__idx(self.columns()) {
            Some(idx) => idx,
            None => return Err(Error::column(idx.to_string())),
        };

        let ty = self.columns()[idx].type_();
        if !T::accepts(ty) {
            return Err(Error::from_sql(
                Box::new(WrongType::new::<T>(ty.clone())),
                idx,
            ));
        }

        FromSql::from_sql_nullable(ty, self.col_buffer(idx)).map_err(|e| Error::from_sql(e, idx))
    }

    /// Returns the raw size of the row in bytes.
    pub fn raw_size_bytes(&self) -> usize {
        self.body().buffer_bytes().len()
    }

    /// The binary value of column `idx` as Postgres sent it (None for NULL), without `get`'s type check: for
    /// callers that know the statement's column types.
    ///
    /// # Panics
    ///
    /// Panics if `idx` is out of bounds.
    #[inline]
    pub fn raw(&self, idx: usize) -> Option<&[u8]> {
        assert!(idx < self.len(), "column index out of bounds");
        self.col_buffer(idx)
    }

    #[inline]
    fn body(&self) -> &DataRowBody {
        &self.group.bodies[self.index]
    }

    /// Get the raw bytes for the column at the given index (`idx < self.len()`).
    #[inline]
    fn col_buffer(&self, idx: usize) -> Option<&[u8]> {
        let group = &*self.group;
        let Field { start, end } = group.ranges[self.index * group.statement.columns().len() + idx];
        if start == u32::MAX {
            return None;
        }
        // `push_ranges` took both offsets from this body's own field lengths.
        Some(&group.bodies[self.index].buffer()[start as usize..end as usize])
    }
}

impl AsName for SimpleColumn {
    fn as_name(&self) -> &str {
        self.name()
    }
}

/// A row of data returned from the database by a simple query.
#[derive(Debug)]
pub struct SimpleQueryRow {
    columns: Arc<[SimpleColumn]>,
    body: DataRowBody,
    ranges: Vec<Option<Range<usize>>>,
}

impl SimpleQueryRow {
    #[allow(clippy::new_ret_no_self)]
    pub(crate) fn new(
        columns: Arc<[SimpleColumn]>,
        body: DataRowBody,
    ) -> Result<SimpleQueryRow, Error> {
        let ranges = body.ranges().collect().map_err(Error::parse)?;
        let row = SimpleQueryRow {
            columns,
            body,
            ranges,
        };
        // The DataRow field count is sent by the server independently of the
        // RowDescription column count; a mismatch would make column accessors
        // index `ranges` out of bounds and panic, so reject it up front.
        if row.ranges.len() != row.columns.len() {
            return Err(Error::parse(io::Error::new(
                io::ErrorKind::InvalidData,
                "DataRow field count does not match the number of columns",
            )));
        }
        Ok(row)
    }

    /// Returns information about the columns of data in the row.
    pub fn columns(&self) -> &[SimpleColumn] {
        &self.columns
    }

    /// Determines if the row contains no values.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Returns the number of values in the row.
    pub fn len(&self) -> usize {
        self.columns.len()
    }

    /// Returns a value from the row.
    ///
    /// The value can be specified either by its numeric index in the row, or by its column name.
    ///
    /// # Panics
    ///
    /// Panics if the index is out of bounds or if the value cannot be converted to the specified type.
    #[track_caller]
    pub fn get<I>(&self, idx: I) -> Option<&str>
    where
        I: RowIndex + fmt::Display,
    {
        match self.get_inner(&idx) {
            Ok(ok) => ok,
            Err(err) => panic!("error retrieving column {}: {}", idx, err),
        }
    }

    /// Like `SimpleQueryRow::get`, but returns a `Result` rather than panicking.
    pub fn try_get<I>(&self, idx: I) -> Result<Option<&str>, Error>
    where
        I: RowIndex + fmt::Display,
    {
        self.get_inner(&idx)
    }

    fn get_inner<I>(&self, idx: &I) -> Result<Option<&str>, Error>
    where
        I: RowIndex + fmt::Display,
    {
        let idx = match idx.__idx(&self.columns) {
            Some(idx) => idx,
            None => return Err(Error::column(idx.to_string())),
        };

        let buf = self.ranges[idx].clone().map(|r| &self.body.buffer()[r]);
        FromSql::from_sql_nullable(&Type::TEXT, buf).map_err(|e| Error::from_sql(e, idx))
    }
}

#[cfg(test)]
mod test {
    use bytes::BytesMut;
    use postgres_protocol::message::backend::{DataRowBody, Message};

    use super::*;

    fn data_row(field_count: u16, fields: &[&[u8]]) -> DataRowBody {
        let mut body = BytesMut::new();
        body.extend_from_slice(&field_count.to_be_bytes());
        for field in fields {
            body.extend_from_slice(&(field.len() as i32).to_be_bytes());
            body.extend_from_slice(field);
        }

        let mut buf = BytesMut::new();
        buf.extend_from_slice(b"D");
        buf.extend_from_slice(&(body.len() as i32 + 4).to_be_bytes());
        buf.extend_from_slice(&body);

        match Message::parse(&mut buf).unwrap().unwrap() {
            Message::DataRow(body) => body,
            _ => unreachable!("expected DataRow"),
        }
    }

    fn column(name: &str) -> Column {
        Column {
            name: name.to_string(),
            table_oid: None,
            column_id: None,
            type_modifier: 0,
            r#type: Type::TEXT,
        }
    }

    #[test]
    fn fewer_data_row_fields_than_columns_is_rejected() {
        // a server advertising two columns but sending a DataRow with a single
        // field would make column accessors index out of bounds and panic.
        let body = data_row(1, &[b""]);
        let statement = Statement::unnamed(vec![], vec![column("a"), column("b")]);
        assert!(Row::new(statement, body).is_err());
    }

    #[test]
    fn matching_data_row_field_count_is_accepted() {
        let body = data_row(2, &[b"x", b"y"]);
        let statement = Statement::unnamed(vec![], vec![column("a"), column("b")]);
        assert!(Row::new(statement, body).is_ok());
    }
}

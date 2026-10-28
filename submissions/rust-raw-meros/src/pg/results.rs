//! [`Results`]: a reusable arena that holds the answers of one pipeline.
//!
//! Layout (all vectors keep their capacity between pipelines, so steady state allocates nothing):
//!
//! ```text
//! data   : every DataRow payload, copied once, back to back
//! cells  : one {offset, length} per column value, pointing into `data` (length -1 = NULL)
//! rows   : one {first cell, column count} per row, in statement order
//! stmts  : one {row range, outcome} per pushed statement, in push order
//! errors : the ServerErrors that `Outcome::Failed` refers to
//! ```
//!
//! Filling the arena is `collect.rs`; reading it is `StmtResult` and [`Row`].

use super::error::ServerError;
use super::row::Row;

/// Location of one column value inside `Results::data`.
#[derive(Debug, Clone, Copy)]
pub(super) struct Cell {
    pub offset: u32,
    /// Byte length, or [`Cell::NULL_LEN`].
    pub len: i32,
}

impl Cell {
    pub const NULL_LEN: i32 = -1;
}

/// Rows of one statement are the contiguous `rows[first_row..end_row]`.
#[derive(Debug, Clone, Copy)]
pub(super) struct RowEntry {
    pub first_cell: u32,
    pub cell_count: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Outcome {
    Done,
    /// Index into `Results::errors`.
    Failed(u32),
    /// Not executed because an earlier statement of the pipeline failed.
    Skipped,
}

#[derive(Debug, Clone, Copy)]
pub(super) struct StmtEntry {
    pub first_row: u32,
    pub end_row: u32,
    pub outcome: Outcome,
    /// Row count from the CommandComplete tag (`INSERT 0 3` -> 3, `SELECT 5` -> 5); 0 if absent.
    pub affected: u64,
}

#[derive(Default)]
pub struct Results {
    pub(super) data: Vec<u8>,
    pub(super) cells: Vec<Cell>,
    pub(super) rows: Vec<RowEntry>,
    pub(super) stmts: Vec<StmtEntry>,
    pub(super) errors: Vec<ServerError>,
    /// Statements the current pipeline expects an answer for.
    pub(super) expected: usize,
    /// An error that arrived after every statement had completed (e.g. a deferred constraint failing at commit).
    pub(super) trailing_error: Option<ServerError>,
}

impl Results {
    pub fn new() -> Self {
        Self::default()
    }

    /// Empties the arena, keeping its allocations.
    pub fn clear(&mut self) {
        self.data.clear();
        self.cells.clear();
        self.rows.clear();
        self.stmts.clear();
        self.errors.clear();
        self.expected = 0;
        self.trailing_error = None;
    }

    /// Number of statements: the pushes of the last pipeline, in order.
    pub fn len(&self) -> usize {
        self.stmts.len()
    }

    pub fn is_empty(&self) -> bool {
        self.stmts.is_empty()
    }

    /// Answer for the `i`-th pushed statement. Panics if `i >= len()`, like slice indexing.
    pub fn statement(&self, i: usize) -> StmtResult<'_> {
        StmtResult {
            results: self,
            entry: self.stmts[i],
        }
    }

    /// Statement answers in push order.
    pub fn iter(&self) -> impl ExactSizeIterator<Item = StmtResult<'_>> {
        self.stmts.iter().map(|&entry| StmtResult {
            results: self,
            entry,
        })
    }

    /// Bytes currently held (for tests and capacity decisions).
    pub fn data_bytes(&self) -> usize {
        self.data.len()
    }

    /// Releases memory if one huge pipeline inflated the arena; call between batches if memory matters.
    pub fn shrink_if_above(&mut self, max_data_capacity: usize) {
        if self.data.capacity() > max_data_capacity {
            self.data = Vec::new();
        }
    }
}

/// The answer to one statement: rows, a server error, or "skipped".
#[derive(Clone, Copy)]
pub struct StmtResult<'a> {
    results: &'a Results,
    entry: StmtEntry,
}

impl<'a> StmtResult<'a> {
    /// The server error if this statement failed.
    pub fn error(&self) -> Option<&'a ServerError> {
        match self.entry.outcome {
            Outcome::Failed(i) => self.results.errors.get(i as usize),
            _ => None,
        }
    }

    /// True if an earlier statement failed, so the server never ran this one.
    pub fn is_skipped(&self) -> bool {
        self.entry.outcome == Outcome::Skipped
    }

    /// True if the statement ran without error (it may still have returned zero rows).
    pub fn is_ok(&self) -> bool {
        self.entry.outcome == Outcome::Done
    }

    pub fn row_count(&self) -> usize {
        (self.entry.end_row - self.entry.first_row) as usize
    }

    /// Rows affected as reported by CommandComplete (INSERT/UPDATE/DELETE/SELECT), else 0.
    pub fn rows_affected(&self) -> u64 {
        self.entry.affected
    }

    pub fn row(&self, i: usize) -> Option<Row<'a>> {
        if i >= self.row_count() {
            return None;
        }
        Some(self.results.row_at(self.entry.first_row as usize + i))
    }

    pub fn rows(&self) -> Rows<'a> {
        Rows {
            results: self.results,
            next: self.entry.first_row as usize,
            end: self.entry.end_row as usize,
        }
    }
}

/// Iterator over the rows of one statement.
#[derive(Clone)]
pub struct Rows<'a> {
    results: &'a Results,
    next: usize,
    end: usize,
}

impl<'a> Iterator for Rows<'a> {
    type Item = Row<'a>;

    fn next(&mut self) -> Option<Row<'a>> {
        if self.next >= self.end {
            return None;
        }
        let row = self.results.row_at(self.next);
        self.next += 1;
        Some(row)
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        let n = self.end - self.next;
        (n, Some(n))
    }
}

impl ExactSizeIterator for Rows<'_> {}

impl Results {
    /// Builds a [`Row`] view. Indices were produced by the collector, which validated every range.
    fn row_at(&self, row_index: usize) -> Row<'_> {
        let entry = self.rows[row_index];
        let first = entry.first_cell as usize;
        Row::new(
            &self.data,
            &self.cells[first..first + entry.cell_count as usize],
        )
    }
}

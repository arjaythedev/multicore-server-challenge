//! Turns backend messages into [`Results`]: the state machine behind `Connection::flush_and_collect`.
//!
//! A pipeline of N statements is answered with, per statement, `BindComplete`, any number of `DataRow`s and one
//! `CommandComplete` (or `EmptyQueryResponse`), then a single `ReadyForQuery` for the Sync. When a statement fails
//! the server sends an `ErrorResponse` instead and discards everything up to the Sync, so the statements after it
//! get no answer at all: they are recorded as `Skipped` when ReadyForQuery arrives.
//!
//! The DataRow path is the hot one. It copies the whole payload into the arena with one `extend_from_slice` and
//! then walks it once to record `{offset, length}` per column; the interleaved length prefixes stay in the arena as
//! harmless padding, which saves one copy per column.

use super::error::{PgError, ServerError};
use super::results::{Cell, Outcome, Results, RowEntry, StmtEntry};
use super::transport::Flow;
use super::wire::{self, tag};

/// Bytes of the column count at the start of a DataRow payload.
const COLUMN_COUNT_LEN: usize = 2;
/// Bytes of a column's length prefix.
const COLUMN_LEN_PREFIX: usize = 4;

impl Results {
    /// Prepares the arena for a pipeline of `expected` statements.
    pub(super) fn begin(&mut self, expected: usize) {
        self.clear();
        self.expected = expected;
    }

    /// Processes one backend message of the pipeline.
    pub(super) fn on_message(&mut self, msg_tag: u8, payload: &[u8]) -> Result<Flow, PgError> {
        match msg_tag {
            tag::DATA_ROW => self.on_data_row(payload)?,
            tag::COMMAND_COMPLETE => self.complete_statement(parse_rows_affected(payload))?,
            tag::EMPTY_QUERY => self.complete_statement(0)?,
            tag::ERROR => self.on_error(wire::parse_error_response(payload)),
            tag::READY_FOR_QUERY => return self.on_ready().map(|()| Flow::Done),
            // Expected noise: acknowledgements, row descriptions we never asked for, asynchronous messages.
            tag::BIND_COMPLETE
            | tag::PARSE_COMPLETE
            | tag::NO_DATA
            | tag::ROW_DESCRIPTION
            | tag::PARAMETER_DESCRIPTION
            | tag::NOTICE
            | tag::PARAMETER_STATUS => {}
            other => {
                return Err(PgError::protocol(format!(
                    "unexpected message '{}' in a pipeline",
                    other as char
                )));
            }
        }
        Ok(Flow::Continue)
    }

    /// True once a statement failed: everything up to ReadyForQuery is then discarded by the server.
    fn has_failed(&self) -> bool {
        !self.errors.is_empty()
    }

    fn on_data_row(&mut self, payload: &[u8]) -> Result<(), PgError> {
        if self.stmts.len() >= self.expected {
            return Err(PgError::protocol("DataRow after the last statement"));
        }
        let (count, body) = payload
            .split_first_chunk::<COLUMN_COUNT_LEN>()
            .ok_or_else(truncated_row)?;
        let cell_count = u16::from_be_bytes(*count);
        let base = self.data.len();
        // Every offset stored below is below this bound, so the `as u32` casts cannot truncate.
        if u32::try_from(base + body.len()).is_err()
            || u32::try_from(self.cells.len() + cell_count as usize).is_err()
        {
            return Err(PgError::protocol("result set larger than 4 GiB"));
        }
        self.data.extend_from_slice(body);
        let first_cell = self.cells.len() as u32;
        let mut pos = 0;
        for _ in 0..cell_count {
            let prefix = body
                .get(pos..pos + COLUMN_LEN_PREFIX)
                .ok_or_else(truncated_row)?;
            let len = i32::from_be_bytes([prefix[0], prefix[1], prefix[2], prefix[3]]);
            pos += COLUMN_LEN_PREFIX;
            let offset = (base + pos) as u32;
            match usize::try_from(len) {
                Ok(n) => {
                    if pos + n > body.len() {
                        return Err(truncated_row());
                    }
                    pos += n;
                    self.cells.push(Cell { offset, len });
                }
                Err(_) if len == Cell::NULL_LEN => self.cells.push(Cell {
                    offset,
                    len: Cell::NULL_LEN,
                }),
                Err(_) => return Err(PgError::protocol("negative column length")),
            }
        }
        if pos != body.len() {
            return Err(PgError::protocol("DataRow has trailing bytes"));
        }
        self.rows.push(RowEntry {
            first_cell,
            cell_count,
        });
        Ok(())
    }

    /// Index of the first row of the statement being answered (where the previous statement's rows ended).
    fn current_first_row(&self) -> u32 {
        self.stmts.last().map_or(0, |s| s.end_row)
    }

    fn complete_statement(&mut self, affected: u64) -> Result<(), PgError> {
        if self.stmts.len() >= self.expected {
            return Err(PgError::protocol(
                "CommandComplete after the last statement",
            ));
        }
        self.stmts.push(StmtEntry {
            first_row: self.current_first_row(),
            end_row: self.rows.len() as u32,
            outcome: Outcome::Done,
            affected,
        });
        Ok(())
    }

    fn on_error(&mut self, error: ServerError) {
        if self.has_failed() || self.trailing_error.is_some() {
            return; // The server sends one error per pipeline; a second one carries no new information.
        }
        if self.stmts.len() >= self.expected {
            self.trailing_error = Some(error);
            return;
        }
        // Rows of the failed statement are partial: drop them so the statement reads as "no rows, error".
        let first_row = self.current_first_row() as usize;
        if let Some(row) = self.rows.get(first_row) {
            self.cells.truncate(row.first_cell as usize);
        }
        self.rows.truncate(first_row);
        self.errors.push(error);
        self.stmts.push(StmtEntry {
            first_row: first_row as u32,
            end_row: first_row as u32,
            outcome: Outcome::Failed(self.errors.len() as u32 - 1),
            affected: 0,
        });
    }

    fn on_ready(&mut self) -> Result<(), PgError> {
        if self.has_failed() {
            let at = self.rows.len() as u32;
            while self.stmts.len() < self.expected {
                self.stmts.push(StmtEntry {
                    first_row: at,
                    end_row: at,
                    outcome: Outcome::Skipped,
                    affected: 0,
                });
            }
        }
        if self.stmts.len() != self.expected {
            return Err(PgError::protocol(format!(
                "ReadyForQuery after {} of {} statements",
                self.stmts.len(),
                self.expected
            )));
        }
        Ok(())
    }
}

fn truncated_row() -> PgError {
    PgError::protocol("malformed DataRow")
}

/// Last number of a CommandComplete tag (`"INSERT 0 3"`, `"UPDATE 2"`, `"SELECT 7"`); 0 for `"BEGIN"` and friends.
fn parse_rows_affected(payload: &[u8]) -> u64 {
    let tag_text = payload.split(|&b| b == 0).next().unwrap_or(&[]);
    let last_word = tag_text.rsplit(|&b| b == b' ').next().unwrap_or(&[]);
    let mut n: u64 = 0;
    if last_word.is_empty() {
        return 0;
    }
    for &b in last_word {
        if !b.is_ascii_digit() {
            return 0;
        }
        n = n.saturating_mul(10).saturating_add(u64::from(b - b'0'));
    }
    n
}

#[cfg(test)]
mod tests {
    use super::*;

    fn data_row(cols: &[Option<&[u8]>]) -> Vec<u8> {
        let mut v = (cols.len() as u16).to_be_bytes().to_vec();
        for c in cols {
            match c {
                Some(b) => {
                    v.extend_from_slice(&(b.len() as i32).to_be_bytes());
                    v.extend_from_slice(b);
                }
                None => v.extend_from_slice(&(-1_i32).to_be_bytes()),
            }
        }
        v
    }

    fn error_payload(code: &str, msg: &str) -> Vec<u8> {
        format!("SERROR\0C{code}\0M{msg}\0\0").into_bytes()
    }

    fn feed(r: &mut Results, msgs: &[(u8, Vec<u8>)]) -> Result<(), PgError> {
        for (t, p) in msgs {
            if r.on_message(*t, p)? == Flow::Done {
                return Ok(());
            }
        }
        Err(PgError::protocol("no ReadyForQuery in test input"))
    }

    #[test]
    fn rows_nulls_and_empty_statements() {
        let mut r = Results::new();
        r.begin(3);
        feed(
            &mut r,
            &[
                (b'2', vec![]),
                (
                    b'D',
                    data_row(&[Some(&7_i64.to_be_bytes()), None, Some(b"hi")]),
                ),
                (
                    b'D',
                    data_row(&[Some(&8_i64.to_be_bytes()), Some(b""), None]),
                ),
                (b'C', b"SELECT 2\0".to_vec()),
                (b'2', vec![]),
                (b'C', b"UPDATE 5\0".to_vec()),
                (b'2', vec![]),
                (b'C', b"SELECT 0\0".to_vec()),
                (b'Z', b"I".to_vec()),
            ],
        )
        .unwrap();
        assert_eq!(r.len(), 3);
        let s0 = r.statement(0);
        assert_eq!(s0.row_count(), 2);
        let rows: Vec<_> = s0.rows().collect();
        assert_eq!(rows[0].i64(0).unwrap(), 7);
        assert!(rows[0].is_null(1));
        assert_eq!(rows[0].str(2).unwrap(), "hi");
        assert!(rows[1].is_null(2));
        assert_eq!(rows[1].str(1).unwrap(), "");
        assert_eq!(rows[1].len(), 3);
        assert_eq!(r.statement(1).rows_affected(), 5);
        assert_eq!(r.statement(1).row_count(), 0);
        assert!(r.statement(2).is_ok());
    }

    #[test]
    fn failure_marks_the_rest_skipped_and_drops_partial_rows() {
        let mut r = Results::new();
        r.begin(4);
        feed(
            &mut r,
            &[
                (b'2', vec![]),
                (b'C', b"SELECT 0\0".to_vec()),
                (b'2', vec![]),
                (b'D', data_row(&[Some(b"partial")])),
                (b'E', error_payload("23505", "dup")),
                (b'Z', b"I".to_vec()),
            ],
        )
        .unwrap();
        assert_eq!(r.len(), 4);
        assert!(r.statement(0).is_ok());
        let failed = r.statement(1);
        assert_eq!(failed.error().unwrap().sqlstate, *b"23505");
        assert_eq!(failed.row_count(), 0);
        assert!(r.statement(2).is_skipped() && r.statement(3).is_skipped());
        assert!(r.statement(2).error().is_none());
    }

    #[test]
    fn error_after_all_statements_is_a_trailing_error() {
        let mut r = Results::new();
        r.begin(1);
        feed(
            &mut r,
            &[
                (b'C', b"INSERT 0 1\0".to_vec()),
                (b'E', error_payload("23514", "commit")),
                (b'Z', b"I".to_vec()),
            ],
        )
        .unwrap();
        assert!(r.statement(0).is_ok());
        assert_eq!(r.trailing_error.as_ref().unwrap().sqlstate, *b"23514");
    }

    #[test]
    fn protocol_violations_are_errors() {
        let ready_early = |msgs: &[(u8, Vec<u8>)]| {
            let mut r = Results::new();
            r.begin(2);
            feed(&mut r, msgs).is_err()
        };
        assert!(
            ready_early(&[(b'C', b"SELECT 1\0".to_vec()), (b'Z', b"I".to_vec())]),
            "missing answer"
        );
        assert!(
            ready_early(&[
                (b'C', b"x\0".to_vec()),
                (b'C', b"x\0".to_vec()),
                (b'C', b"x\0".to_vec())
            ]),
            "extra answer"
        );
        assert!(
            ready_early(&[(b'D', vec![0, 1, 0, 0, 0, 9, 1])]),
            "truncated column"
        );
        assert!(
            ready_early(&[(b'D', vec![0, 1, 0, 0, 0, 1, 1, 9])]),
            "trailing bytes"
        );
        assert!(
            ready_early(&[(b'D', vec![0, 1, 0xff, 0xff, 0xff, 0xfe])]),
            "negative length"
        );
        assert!(ready_early(&[(b'D', vec![0])]), "no column count");
        assert!(ready_early(&[(b'q', vec![])]), "unknown tag");
    }

    #[test]
    fn reuse_keeps_nothing_from_before() {
        let mut r = Results::new();
        r.begin(1);
        feed(
            &mut r,
            &[
                (b'D', data_row(&[Some(b"x")])),
                (b'C', b"SELECT 1\0".to_vec()),
                (b'Z', b"I".to_vec()),
            ],
        )
        .unwrap();
        r.begin(1);
        feed(
            &mut r,
            &[(b'C', b"SELECT 0\0".to_vec()), (b'Z', b"I".to_vec())],
        )
        .unwrap();
        assert_eq!(r.statement(0).row_count(), 0);
        assert_eq!(r.data_bytes(), 0);
    }

    #[test]
    fn command_tag_parsing() {
        assert_eq!(parse_rows_affected(b"INSERT 0 12\0"), 12);
        assert_eq!(parse_rows_affected(b"SELECT 3\0"), 3);
        assert_eq!(parse_rows_affected(b"BEGIN\0"), 0);
        assert_eq!(parse_rows_affected(b"\0"), 0);
        assert_eq!(
            parse_rows_affected(b"X 99999999999999999999999\0"),
            u64::MAX
        );
    }
}

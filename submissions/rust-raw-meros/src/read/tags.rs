//! The tag table of a batch: `tags.sql` returns every tag in name order, which gives two things at once.
//!
//! * the body of `GET /api/tags` (rendered once, copied into each reply), and
//! * the *rank* of every tag id in name order. The article statements return tag ids; sorting an article's ranks
//!   sorts its tags by name without comparing strings and without a join in SQL.

use crate::json::JsonWriter;
use crate::pg::StmtResult;

use super::error::ReadError;
use super::table::IdTable;

const COL_ID: usize = 0;
const COL_NAME: usize = 1;

/// Names by rank and the rank of each tag id. Borrows the names from the `Results` arena.
pub struct TagView<'t> {
    pub names: &'t [&'t str],
    pub ranks: &'t IdTable,
}

/// Fills `names` and `ranks` from the tag statement's rows.
pub fn load<'a>(
    stmt: StmtResult<'a>,
    names: &mut Vec<&'a str>,
    ranks: &mut IdTable,
) -> Result<(), ReadError> {
    names.clear();
    ranks.reset(stmt.row_count());
    for row in stmt.rows() {
        let rank =
            u32::try_from(names.len()).map_err(|_| ReadError::Inconsistent("too many tags"))?;
        if !ranks.insert(row.i64(COL_ID)?, rank) {
            return Err(ReadError::Inconsistent("duplicate tag id"));
        }
        names.push(row.str(COL_NAME)?);
    }
    Ok(())
}

/// `{"tags":["a","b",...]}` appended to `out`.
pub fn write_json(out: &mut Vec<u8>, names: &[&str]) {
    let mut w = JsonWriter::new(out);
    w.begin_object();
    w.key("tags");
    w.begin_array();
    for name in names {
        w.string(name);
    }
    w.end_array();
    w.end_object();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tag_list_json() {
        let mut out = Vec::new();
        write_json(&mut out, &["a", "b\"c"]);
        assert_eq!(out, br#"{"tags":["a","b\"c"]}"#);
        out.clear();
        write_json(&mut out, &[]);
        assert_eq!(out, br#"{"tags":[]}"#);
    }
}

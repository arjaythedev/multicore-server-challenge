//! Answers for `comments.sql`: the newest 100 comments of every distinct article in the batch.
//!
//! Rows are of two kinds (column `kind`):
//!
//! * kind 0: one comment with its author, tagged with its `article_id`. The rows of one article arrive newest first
//!   (`created_at DESC, id DESC`), which is the order of the response. They are indexed as (article id, row number)
//!   pairs sorted by that pair, so a request finds its thread with two binary searches and the order inside a thread
//!   stays the row order.
//! * kind 1: one row per request: the article id (NULL when the slug does not exist: 404) and the author ids of the
//!   thread that the viewer follows.
//!
//! A thread requested by several clients is fetched once and rendered once per client, by borrow from the rows.

use crate::app::jobs::ReadJob;
use crate::http::Status;
use crate::json::JsonWriter;
use crate::pg::{Row, StmtResult};
use crate::render::{self, Profile};

use super::articles::{GroupCtx, optional_str};
use super::error::ReadError;
use super::sink::Sink;

mod col {
    pub const KIND: usize = 0;
    pub const ORD: usize = 1;
    pub const ARTICLE_ID: usize = 2;
    pub const COMMENT_ID: usize = 3;
    pub const BODY: usize = 4;
    pub const CREATED: usize = 5;
    pub const UPDATED: usize = 6;
    pub const AUTHOR_ID: usize = 7;
    pub const USERNAME: usize = 8;
    pub const BIO: usize = 9;
    pub const IMAGE: usize = 10;
    pub const FOLLOWED_IDS: usize = 11;
}

const KIND_COMMENT: i32 = 0;
const KIND_REQUEST: i32 = 1;
const NOT_FOUND_MESSAGE: &str = "article not found";

#[derive(Default)]
pub struct Comments {
    /// (article id, row number among the statement's rows), sorted.
    threads: Vec<(i64, u32)>,
    followed: Vec<i64>,
}

impl Comments {
    #[cfg(test)]
    pub fn footprint(&self) -> usize {
        self.threads.capacity() * 16 + self.followed.capacity() * 8
    }

    pub fn answer(
        &mut self,
        stmt: StmtResult<'_>,
        ctx: &GroupCtx<'_>,
        sink: &mut Sink,
    ) -> Result<(), ReadError> {
        self.threads.clear();
        for (at, row) in stmt.rows().enumerate() {
            if row.i32(col::KIND)? == KIND_COMMENT {
                self.threads.push((row.i64(col::ARTICLE_ID)?, at as u32));
            }
        }
        self.threads.sort_unstable();
        for row in stmt.rows() {
            if row.i32(col::KIND)? == KIND_REQUEST {
                self.render_request(row, stmt, ctx.jobs, ctx.members, sink)?;
            }
        }
        Ok(())
    }

    fn render_request(
        &mut self,
        row: Row<'_>,
        stmt: StmtResult<'_>,
        jobs: &[ReadJob],
        members: &[u32],
        sink: &mut Sink,
    ) -> Result<(), ReadError> {
        let member = sink.claim(row.i64(col::ORD)?)?;
        let origin = jobs[members[member] as usize].origin;
        if row.is_null(col::ARTICLE_ID) {
            sink.error(origin, Status::NotFound, NOT_FOUND_MESSAGE);
            return Ok(());
        }
        let article = row.i64(col::ARTICLE_ID)?;
        self.followed.clear();
        self.followed.extend(row.i64_array(col::FOLLOWED_IDS)?);
        self.followed.sort_unstable();
        let first = self.threads.partition_point(|&(a, _)| a < article);
        let end = self.threads.partition_point(|&(a, _)| a <= article);
        let thread = &self.threads[first..end];
        let followed = &self.followed;
        sink.json(origin, Status::Ok, |w| {
            write_thread(w, thread, stmt, followed)
        });
        Ok(())
    }
}

/// `{"comments":[...]}`
fn write_thread(
    w: &mut JsonWriter<'_>,
    thread: &[(i64, u32)],
    stmt: StmtResult<'_>,
    followed: &[i64],
) -> Result<(), ReadError> {
    w.begin_object();
    w.key("comments");
    w.begin_array();
    for &(_, at) in thread {
        let row = stmt
            .row(at as usize)
            .ok_or(ReadError::Inconsistent("comment row vanished"))?;
        write_comment(w, row, followed)?;
    }
    w.end_array();
    w.end_object();
    Ok(())
}

fn write_comment(w: &mut JsonWriter<'_>, row: Row<'_>, followed: &[i64]) -> Result<(), ReadError> {
    let author_id = row.i64(col::AUTHOR_ID)?;
    render::comment_object(
        w,
        &render::Comment {
            id: row.i64(col::COMMENT_ID)?,
            created_micros: row.timestamptz_micros(col::CREATED)?,
            updated_micros: row.timestamptz_micros(col::UPDATED)?,
            body: row.str(col::BODY)?,
            author: Profile {
                username: row.str(col::USERNAME)?,
                bio: optional_str(row, col::BIO)?,
                image: optional_str(row, col::IMAGE)?,
                following: followed.binary_search(&author_id).is_ok(),
            },
        },
    );
    Ok(())
}

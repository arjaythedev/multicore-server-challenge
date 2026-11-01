//! Answers for the statements of the "articles" shape: the five lists and the single article.
//!
//! The statement returns two kinds of rows (column `kind`):
//!
//! * kind 0: one row per *distinct* article of the group, with everything an article object needs and the ids of
//!   its tags. This is the batch-sharing ruling: an article that ten requests list is fetched, and decoded here,
//!   once. [`Articles`] decodes each such row into an [`ArticleRow`] and indexes it by id in an [`IdTable`].
//! * kind 1: one row per request (`ord` = position in the group): the count, the ids of its page in order, and the
//!   ids among them that the viewer favorited, and among their authors that the viewer follows.
//!
//! Rendering a request walks its page ids and renders each article *by borrow* from the shared rows. Nothing is
//! cloned: strings go from the arena through the escaper into the response buffer.
//!
//! Not handled: a page id without an article row (inconsistent rows: the request gets a 500); tags created after
//! the tag table was read (left out of the list).

use std::ops::Range;

use crate::app::jobs::ReadJob;
use crate::http::Status;
use crate::json::JsonWriter;
use crate::pg::{Row, StmtResult};
use crate::render::{self, Profile};

use super::error::ReadError;
use super::sink::Sink;
use super::statements::Group;
use super::table::IdTable;
use super::tags::TagView;

/// Columns of the "articles" shape (see the header of each `.sql` file).
mod col {
    pub const KIND: usize = 0;
    pub const ORD: usize = 1;
    pub const ID: usize = 2;
    pub const SLUG: usize = 3;
    pub const TITLE: usize = 4;
    pub const DESCRIPTION: usize = 5;
    pub const BODY: usize = 6;
    pub const CREATED: usize = 7;
    pub const UPDATED: usize = 8;
    pub const AUTHOR_ID: usize = 9;
    pub const TAG_IDS: usize = 10;
    pub const FAVORITES: usize = 11;
    pub const USERNAME: usize = 12;
    pub const BIO: usize = 13;
    pub const IMAGE: usize = 14;
    pub const TOTAL: usize = 15;
    pub const PAGE_IDS: usize = 16;
    pub const FAVORITED_IDS: usize = 17;
    pub const FOLLOWED_IDS: usize = 18;
}

const KIND_ARTICLE: i32 = 0;
const KIND_REQUEST: i32 = 1;
const NOT_FOUND_MESSAGE: &str = "article not found";

/// One article, decoded once per batch. Text borrows from the `Results` arena.
#[derive(Clone)]
pub struct ArticleRow<'a> {
    id: i64,
    slug: &'a str,
    title: &'a str,
    description: &'a str,
    body: Option<&'a str>,
    created_micros: i64,
    updated_micros: i64,
    author_id: i64,
    favorites: i64,
    username: &'a str,
    bio: Option<&'a str>,
    image: Option<&'a str>,
    /// Range of this article's tag ranks (sorted, so name order) in `Articles::ranks`.
    tags: Range<u32>,
}

impl<'a> ArticleRow<'a> {
    const BLANK: ArticleRow<'static> = ArticleRow {
        id: 0,
        slug: "",
        title: "",
        description: "",
        body: None,
        created_micros: 0,
        updated_micros: 0,
        author_id: 0,
        favorites: 0,
        username: "",
        bio: None,
        image: None,
        tags: 0..0,
    };

    fn decode(
        row: Row<'a>,
        tags: &TagView<'_>,
        ranks: &mut Vec<u32>,
    ) -> Result<ArticleRow<'a>, ReadError> {
        let first = ranks.len();
        ranks.extend(
            row.i64_array(col::TAG_IDS)?
                .filter_map(|id| tags.ranks.get(id)),
        );
        ranks[first..].sort_unstable();
        Ok(ArticleRow {
            id: row.i64(col::ID)?,
            slug: row.str(col::SLUG)?,
            title: row.str(col::TITLE)?,
            description: row.str(col::DESCRIPTION)?,
            body: optional_str(row, col::BODY)?,
            created_micros: row.timestamptz_micros(col::CREATED)?,
            updated_micros: row.timestamptz_micros(col::UPDATED)?,
            author_id: row.i64(col::AUTHOR_ID)?,
            favorites: row.i64(col::FAVORITES)?,
            username: row.str(col::USERNAME)?,
            bio: optional_str(row, col::BIO)?,
            image: optional_str(row, col::IMAGE)?,
            tags: first as u32..ranks.len() as u32,
        })
    }
}

/// `Some(text)` or `None` for SQL NULL.
pub fn optional_str<'a>(row: Row<'a>, column: usize) -> Result<Option<&'a str>, ReadError> {
    if row.is_null(column) {
        Ok(None)
    } else {
        Ok(Some(row.str(column)?))
    }
}

/// An empty `Vec` of rows with the allocation of `v`, usable for any lifetime.
fn recycle_rows<'a, 'b>(mut v: Vec<ArticleRow<'a>>) -> Vec<ArticleRow<'b>> {
    v.clear();
    v.into_iter().map(|_| ArticleRow::BLANK).collect()
}

/// Reusable memory for answering article-shaped groups (kept by the lane between batches).
#[derive(Default)]
pub struct Articles {
    rows: Vec<ArticleRow<'static>>,
    /// Tag ranks of all rows, back to back.
    ranks: Vec<u32>,
    by_id: IdTable,
    /// The viewer's favorited ids / followed author ids of the request being rendered, sorted for lookup.
    favorited: Vec<i64>,
    followed: Vec<i64>,
}

/// What `answer` needs to know about the group it answers.
pub struct GroupCtx<'x> {
    pub group: Group,
    pub members: &'x [u32],
    pub jobs: &'x [ReadJob],
}

impl Articles {
    #[cfg(test)]
    pub fn footprint(&self) -> usize {
        self.rows.capacity() * size_of::<ArticleRow<'static>>()
            + self.ranks.capacity() * 4
            + self.by_id.footprint()
            + (self.favorited.capacity() + self.followed.capacity()) * 8
    }

    /// Decodes the group's article rows once, then renders one response per request row into `sink`.
    pub fn answer<'a>(
        &mut self,
        stmt: StmtResult<'a>,
        ctx: &GroupCtx<'_>,
        tags: &TagView<'_>,
        sink: &mut Sink,
    ) -> Result<(), ReadError> {
        let mut rows = recycle_rows(std::mem::take(&mut self.rows));
        let result = self.decode_and_render(stmt, ctx, tags, sink, &mut rows);
        self.rows = recycle_rows(rows);
        result
    }

    fn decode_and_render<'a>(
        &mut self,
        stmt: StmtResult<'a>,
        ctx: &GroupCtx<'_>,
        tags: &TagView<'_>,
        sink: &mut Sink,
        rows: &mut Vec<ArticleRow<'a>>,
    ) -> Result<(), ReadError> {
        self.by_id.reset(stmt.row_count());
        self.ranks.clear();
        for row in stmt.rows() {
            if row.i32(col::KIND)? != KIND_ARTICLE {
                continue;
            }
            let article = ArticleRow::decode(row, tags, &mut self.ranks)?;
            if self.by_id.insert(article.id, rows.len() as u32) {
                rows.push(article);
            }
        }
        for row in stmt.rows() {
            if row.i32(col::KIND)? == KIND_REQUEST {
                self.render_request(row, rows, ctx, tags, sink)?;
            }
        }
        Ok(())
    }

    fn render_request(
        &mut self,
        row: Row<'_>,
        rows: &[ArticleRow<'_>],
        ctx: &GroupCtx<'_>,
        tags: &TagView<'_>,
        sink: &mut Sink,
    ) -> Result<(), ReadError> {
        let member = sink.claim(row.i64(col::ORD)?)?;
        let origin = ctx.jobs[ctx.members[member] as usize].origin;
        let page = row.i64_array(col::PAGE_IDS)?;
        sorted_into(&mut self.favorited, row.i64_array(col::FAVORITED_IDS)?);
        sorted_into(&mut self.followed, row.i64_array(col::FOLLOWED_IDS)?);
        let view = View {
            shared: self,
            rows,
            tags,
            feed: ctx.group == Group::Feed,
        };
        if ctx.group == Group::Article {
            match page.clone().next() {
                None => sink.error(origin, Status::NotFound, NOT_FOUND_MESSAGE),
                Some(id) => sink.json(origin, Status::Ok, |w| view.single(w, id)),
            }
            return Ok(());
        }
        let total = row.i64(col::TOTAL)?;
        sink.json(origin, Status::Ok, |w| view.list(w, page, total));
        Ok(())
    }
}

fn sorted_into(out: &mut Vec<i64>, ids: impl Iterator<Item = i64>) {
    out.clear();
    out.extend(ids);
    out.sort_unstable();
}

/// Everything needed to render the articles of one request.
struct View<'v, 'a> {
    shared: &'v Articles,
    rows: &'v [ArticleRow<'a>],
    tags: &'v TagView<'v>,
    /// A feed only lists authors the viewer follows.
    feed: bool,
}

impl View<'_, '_> {
    fn lookup(&self, id: i64) -> Result<&ArticleRow<'_>, ReadError> {
        self.shared
            .by_id
            .get(id)
            .and_then(|at| self.rows.get(at as usize))
            .ok_or(ReadError::Inconsistent("page id without an article row"))
    }

    /// `{"article":{...with body}}`
    fn single(&self, w: &mut JsonWriter<'_>, id: i64) -> Result<(), ReadError> {
        w.begin_object();
        w.key("article");
        self.article(w, self.lookup(id)?, true);
        w.end_object();
        Ok(())
    }

    /// `{"articles":[...without body],"articlesCount":n}`
    fn list(
        &self,
        w: &mut JsonWriter<'_>,
        page: impl Iterator<Item = i64>,
        total: i64,
    ) -> Result<(), ReadError> {
        w.begin_object();
        w.key("articles");
        w.begin_array();
        for id in page {
            self.article(w, self.lookup(id)?, false);
        }
        w.end_array();
        w.key("articlesCount");
        w.int(total);
        w.end_object();
        Ok(())
    }

    fn article(&self, w: &mut JsonWriter<'_>, a: &ArticleRow<'_>, with_body: bool) {
        let ranks = &self.shared.ranks[a.tags.start as usize..a.tags.end as usize];
        let names = self.tags.names;
        render::article_object(
            w,
            &render::Article {
                slug: a.slug,
                title: a.title,
                description: a.description,
                body: if with_body { a.body } else { None },
                tags: ranks.iter().filter_map(|&r| names.get(r as usize).copied()),
                created_micros: a.created_micros,
                updated_micros: a.updated_micros,
                favorited: self.shared.favorited.binary_search(&a.id).is_ok(),
                favorites_count: a.favorites,
                author: Profile {
                    username: a.username,
                    bio: a.bio,
                    image: a.image,
                    following: self.feed
                        || self.shared.followed.binary_search(&a.author_id).is_ok(),
                },
            },
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn row_scratch_keeps_its_allocation_across_lifetimes() {
        let owner = String::from("text");
        let mut rows: Vec<ArticleRow<'_>> = Vec::with_capacity(32);
        rows.push(ArticleRow {
            slug: &owner,
            ..ArticleRow::BLANK
        });
        let pointer = rows.as_ptr();
        let again: Vec<ArticleRow<'static>> = recycle_rows(rows);
        assert!(again.is_empty());
        assert_eq!(again.as_ptr(), pointer);
        assert!(again.capacity() >= 32);
    }

    #[test]
    fn sorted_into_replaces_the_contents() {
        let mut out = vec![99];
        sorted_into(&mut out, [5, 1, 3].into_iter());
        assert_eq!(out, [1, 3, 5]);
    }
}

//! Response bodies: JSON rendered straight from the borrowed rows of the lane's `Results` arena into the pooled
//! response buffer. No intermediate `String`, no copy of a column value besides the escaping write itself.
//!
//! Column positions follow the headers of the `sql/*.sql` files. The "article_full" shape is
//! `id, slug, title, description, body, created_at, updated_at, author_id, tag_names, fav, favorited, username,
//! bio, image, following`; `update_article` prepends `found_id, found_author`, hence the `offset` argument.

use crate::http::Status;
use crate::json::JsonWriter;
use crate::pg::{PgError, Row, StmtResult};
use crate::render::{
    Article, Comment, Profile, User, article_object, comment_object, profile_object, user_object,
};

/// Message for a register or profile update that collides on username or email.
pub const TAKEN: &str = "username or email already taken";
const NO_ARTICLE: &str = "article not found";
const NO_PROFILE: &str = "profile not found";
const NO_COMMENT: &str = "comment not found";
const NO_USER: &str = "user not found";
const FORBIDDEN: &str = "only the author may do this";

/// How a finished job is answered.
#[derive(Debug, PartialEq, Eq)]
pub enum Verdict {
    /// A JSON body was written (or, for `NoContent`, none is wanted).
    Body(Status),
    Error(Status, &'static str),
}

/// Column holding the first column of the article in `update_article`'s rows.
const UPDATE_ARTICLE_OFFSET: usize = 2;

fn optional<'r>(row: &Row<'r>, col: usize) -> Result<Option<&'r str>, PgError> {
    if row.is_null(col) {
        Ok(None)
    } else {
        row.str(col).map(Some)
    }
}

fn wrapped(out: &mut Vec<u8>, key: &'static str, fill: impl FnOnce(&mut JsonWriter<'_>)) {
    let mut w = JsonWriter::new(out);
    w.begin_object();
    w.key(key);
    fill(&mut w);
    w.end_object();
}

/// `users` columns `id, username, email, bio, image` plus a token, as `{"user": ...}`.
fn write_user(out: &mut Vec<u8>, row: &Row<'_>, token: &str) -> Result<(), PgError> {
    let user = User {
        email: row.str(2)?,
        token,
        username: row.str(1)?,
        bio: optional(row, 3)?,
        image: optional(row, 4)?,
    };
    wrapped(out, "user", |w| user_object(w, &user));
    Ok(())
}

/// The user id a successful register or update names (column 0 of the first row), for signing the token.
pub fn user_id(result: &StmtResult<'_>) -> Result<Option<i64>, PgError> {
    result.row(0).map(|row| row.i64(0)).transpose()
}

pub fn register(
    result: &StmtResult<'_>,
    token: &str,
    out: &mut Vec<u8>,
) -> Result<Verdict, PgError> {
    let Some(row) = result.row(0) else {
        return Ok(Verdict::Error(Status::Unprocessable, TAKEN));
    };
    write_user(out, &row, token)?;
    Ok(Verdict::Body(Status::Created))
}

pub fn update_user(
    result: &StmtResult<'_>,
    token: &str,
    out: &mut Vec<u8>,
) -> Result<Verdict, PgError> {
    let Some(row) = result.row(0) else {
        return Ok(Verdict::Error(Status::Unauthorized, NO_USER));
    };
    write_user(out, &row, token)?;
    Ok(Verdict::Body(Status::Ok))
}

/// `id, username, bio, image` as `{"profile": ...}` with the constant `following` the request implies.
pub fn profile(
    result: &StmtResult<'_>,
    following: bool,
    out: &mut Vec<u8>,
) -> Result<Verdict, PgError> {
    let Some(row) = result.row(0) else {
        return Ok(Verdict::Error(Status::NotFound, NO_PROFILE));
    };
    let profile = Profile {
        username: row.str(1)?,
        bio: optional(&row, 2)?,
        image: optional(&row, 3)?,
        following,
    };
    wrapped(out, "profile", |w| profile_object(w, &profile));
    Ok(Verdict::Body(Status::Ok))
}

fn write_article(out: &mut Vec<u8>, row: &Row<'_>, offset: usize) -> Result<(), PgError> {
    let col = |i: usize| offset + i;
    let article = Article {
        slug: row.str(col(1))?,
        title: row.str(col(2))?,
        description: row.str(col(3))?,
        body: Some(row.str(col(4))?),
        tags: row.text_array(col(8))?,
        created_micros: row.timestamptz_micros(col(5))?,
        updated_micros: row.timestamptz_micros(col(6))?,
        favorited: row.bool(col(10))?,
        favorites_count: row.i64(col(9))?,
        author: Profile {
            username: row.str(col(11))?,
            bio: optional(row, col(12))?,
            image: optional(row, col(13))?,
            following: row.bool(col(14))?,
        },
    };
    wrapped(out, "article", |w| article_object(w, &article));
    Ok(())
}

/// An "article_full" row (create, favorite, unfavorite); no row is a 404.
pub fn article(
    result: &StmtResult<'_>,
    success: Status,
    out: &mut Vec<u8>,
) -> Result<Verdict, PgError> {
    let Some(row) = result.row(0) else {
        return Ok(Verdict::Error(Status::NotFound, NO_ARTICLE));
    };
    write_article(out, &row, 0)?;
    Ok(Verdict::Body(success))
}

/// `update_article`: `found_id` NULL is a 404, a found article without an updated row a 403.
pub fn update_article(result: &StmtResult<'_>, out: &mut Vec<u8>) -> Result<Verdict, PgError> {
    let Some(row) = result.row(0) else {
        return Ok(Verdict::Error(Status::NotFound, NO_ARTICLE));
    };
    if row.is_null(0) {
        return Ok(Verdict::Error(Status::NotFound, NO_ARTICLE));
    }
    if row.is_null(UPDATE_ARTICLE_OFFSET) {
        return Ok(Verdict::Error(Status::Forbidden, FORBIDDEN));
    }
    write_article(out, &row, UPDATE_ARTICLE_OFFSET)?;
    Ok(Verdict::Body(Status::Ok))
}

/// `delete_article` / `delete_comment`: `found_id, found_author, deleted_id`.
pub fn removal(result: &StmtResult<'_>, missing: Kind) -> Result<Verdict, PgError> {
    let Some(row) = result.row(0) else {
        return Ok(Verdict::Error(Status::NotFound, missing.message()));
    };
    if row.is_null(0) {
        return Ok(Verdict::Error(Status::NotFound, missing.message()));
    }
    if row.is_null(2) {
        return Ok(Verdict::Error(Status::Forbidden, FORBIDDEN));
    }
    Ok(Verdict::Body(Status::NoContent))
}

/// What a removal was looking for, for the 404 text.
#[derive(Clone, Copy)]
pub enum Kind {
    Article,
    Comment,
}

impl Kind {
    fn message(self) -> &'static str {
        match self {
            Kind::Article => NO_ARTICLE,
            Kind::Comment => NO_COMMENT,
        }
    }
}

/// `add_comment`: columns `article_id, id, body, created_at, updated_at, username, bio, image`; `article_id` NULL is a 404; the author is the viewer, who does not follow themselves.
pub fn comment(result: &StmtResult<'_>, out: &mut Vec<u8>) -> Result<Verdict, PgError> {
    let Some(row) = result.row(0) else {
        return Ok(Verdict::Error(Status::NotFound, NO_ARTICLE));
    };
    if row.is_null(0) {
        return Ok(Verdict::Error(Status::NotFound, NO_ARTICLE));
    }
    let comment = Comment {
        id: row.i64(1)?,
        created_micros: row.timestamptz_micros(3)?,
        updated_micros: row.timestamptz_micros(4)?,
        body: row.str(2)?,
        author: Profile {
            username: row.str(5)?,
            bio: optional(&row, 6)?,
            image: optional(&row, 7)?,
            following: false,
        },
    };
    wrapped(out, "comment", |w| comment_object(w, &comment));
    Ok(Verdict::Body(Status::Created))
}

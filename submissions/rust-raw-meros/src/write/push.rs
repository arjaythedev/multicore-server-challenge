//! Turning a [`WriteJob`] into pipelined statements. Pure encoding: nothing is sent until the lane flushes.
//!
//! Parameters are `&str` slices of the job's own request buffer (zero-copy); `push` copies them once, into the
//! connection's outgoing buffer. The statements of one job are pushed back to back, which `link_tags` and
//! `created_article` rely on (`currval` of the article identity sequence names the article `insert_article` made).

use super::statements::Statements;
use crate::app::jobs::{Field, WriteJob, WriteKind};
use crate::pg::{Connection, Param, PgError};

/// Tags kept on the stack while building the `text[]` parameter. More tags than this take one heap allocation.
const INLINE_TAGS: usize = 16;

/// What pushing a job did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Pushed {
    /// This many statements were pushed (the last one carries the answer).
    Statements(usize),
    /// The job cannot be sent (a password hash that is not UTF-8, which the app never produces). Nothing was
    /// pushed for it and it is answered with a 500.
    Rejected,
}

/// The parts of a [`WriteJob`] every `push_*` function needs: the request buffer the fields point into and the
/// acting user. It only builds borrowed parameters; nothing is copied until `Connection::push`.
struct Args<'a> {
    buf: &'a [u8],
    viewer: i64,
}

impl<'a> Args<'a> {
    fn text(&self, f: &Field) -> Param<'a> {
        Param::Text(f.text(self.buf))
    }

    /// `NULL` when the field was not sent, so the statement keeps the stored value.
    fn optional(&self, f: &Option<Field>) -> Param<'a> {
        f.as_ref().map_or(Param::Null, |f| self.text(f))
    }

    fn viewer(&self) -> Param<'a> {
        Param::Int8(self.viewer)
    }
}

/// A job that is one statement: its answer is that statement's.
fn one(r: Result<(), PgError>) -> Result<Pushed, PgError> {
    r.map(|()| Pushed::Statements(1))
}

/// Pushes the statements of `job`, one `push_*` function per [`WriteKind`]. An `Err` means the connection is
/// unusable (nothing else can fail: every field of a job is bounded by the 1 MiB request limit, far below what the
/// wire encoding accepts).
pub fn push_job(conn: &mut Connection, s: &Statements, job: &WriteJob) -> Result<Pushed, PgError> {
    let a = Args {
        buf: job.buf.as_slice(),
        viewer: job.viewer,
    };
    match &job.kind {
        WriteKind::Register {
            username,
            email,
            password_hash,
        } => push_register(conn, s, &a, username, email, password_hash),
        WriteKind::UpdateUser {
            email,
            username,
            password_hash,
            bio,
            image,
            ..
        } => push_update_user(conn, s, &a, [email, username, bio, image], password_hash),
        WriteKind::Follow { username, follow } => {
            let stmt = if *follow { &s.follow } else { &s.unfollow };
            one(conn.push(stmt, &[a.viewer(), a.text(username)]))
        }
        WriteKind::CreateArticle {
            slug_base,
            title,
            description,
            body,
            tags,
        } => push_create_article(conn, s, &a, slug_base, [title, description, body], tags),
        WriteKind::UpdateArticle {
            slug,
            slug_base,
            title,
            description,
            body,
        } => push_update_article(
            conn,
            s,
            &a,
            slug,
            slug_base.as_deref(),
            [title, description, body],
        ),
        WriteKind::DeleteArticle { slug } => {
            one(conn.push(&s.delete_article, &[a.text(slug), a.viewer()]))
        }
        WriteKind::Favorite { slug, favorite } => {
            let stmt = if *favorite {
                &s.favorite
            } else {
                &s.unfavorite
            };
            one(conn.push(stmt, &[a.viewer(), a.text(slug)]))
        }
        WriteKind::AddComment { slug, body } => {
            one(conn.push(&s.add_comment, &[a.text(slug), a.viewer(), a.text(body)]))
        }
        WriteKind::DeleteComment { slug, comment_id } => one(conn.push(
            &s.delete_comment,
            &[Param::Int8(*comment_id), a.text(slug), a.viewer()],
        )),
    }
}

/// One `insert` of a new user. A hash that is not UTF-8 is `Rejected` before anything is pushed.
fn push_register(
    conn: &mut Connection,
    s: &Statements,
    a: &Args<'_>,
    username: &Field,
    email: &Field,
    password_hash: &[u8],
) -> Result<Pushed, PgError> {
    let Some(hash) = hash_text(password_hash) else {
        return Ok(Pushed::Rejected);
    };
    one(conn.push(
        &s.register,
        &[a.text(username), a.text(email), Param::Text(hash)],
    ))
}

/// One `update` of the viewer. `fields` is `[email, username, bio, image]`; every field and the hash that was not
/// sent is `NULL`, which the statement reads as "keep". A hash that is not UTF-8 is `Rejected`.
fn push_update_user(
    conn: &mut Connection,
    s: &Statements,
    a: &Args<'_>,
    fields: [&Option<Field>; 4],
    password_hash: &Option<[u8; 60]>,
) -> Result<Pushed, PgError> {
    let [email, username, bio, image] = fields;
    let hash = match password_hash {
        Some(raw) => match hash_text(raw) {
            Some(hash) => Param::Text(hash),
            None => return Ok(Pushed::Rejected),
        },
        None => Param::Null,
    };
    let params = [
        a.viewer(),
        a.optional(email),
        a.optional(username),
        hash,
        a.optional(bio),
        a.optional(image),
    ];
    one(conn.push(&s.update_user, &params))
}

/// The article insert, then (only with tags) the tag insert and the tag link, then the statement that reads the
/// article back. They go back to back: `link_tags` and `created_article` use `currval` of the sequence that
/// `insert_article` advanced. `fields` is `[title, description, body]`.
fn push_create_article(
    conn: &mut Connection,
    s: &Statements,
    a: &Args<'_>,
    slug_base: &str,
    fields: [&Field; 3],
    tags: &[Field],
) -> Result<Pushed, PgError> {
    let [title, description, body] = fields;
    let params = [
        Param::Text(slug_base),
        a.viewer(),
        a.text(title),
        a.text(description),
        a.text(body),
    ];
    conn.push(&s.insert_article, &params)?;
    let mut count = 1;
    if !tags.is_empty() {
        with_names(a.buf, tags, |names| {
            conn.push(&s.insert_tags, &[Param::TextArray(names)])?;
            conn.push(&s.link_tags, &[Param::TextArray(names)])
        })?;
        count += 2;
    }
    conn.push(&s.created_article, &[a.viewer()])?;
    Ok(Pushed::Statements(count + 1))
}

/// One `update` of an article by slug. `fields` is `[title, description, body]`; unsent values and a missing
/// `slug_base` (the title did not change, so the slug stays) are `NULL`. Tags are not editable.
fn push_update_article(
    conn: &mut Connection,
    s: &Statements,
    a: &Args<'_>,
    slug: &Field,
    slug_base: Option<&str>,
    fields: [&Option<Field>; 3],
) -> Result<Pushed, PgError> {
    let [title, description, body] = fields;
    let base = slug_base.map_or(Param::Null, Param::Text);
    let params = [
        a.text(slug),
        a.viewer(),
        a.optional(title),
        a.optional(description),
        a.optional(body),
        base,
    ];
    one(conn.push(&s.update_article, &params))
}

/// The bcrypt hash as text. It is ASCII by construction; anything else is refused instead of stored.
fn hash_text(hash: &[u8]) -> Option<&str> {
    std::str::from_utf8(hash).ok()
}

/// Calls `f` with the tag names as `&str` slices of the request buffer, on the stack when there are few.
fn with_names<R>(buf: &[u8], tags: &[Field], f: impl FnOnce(&[&str]) -> R) -> R {
    if tags.len() <= INLINE_TAGS {
        let mut names = [""; INLINE_TAGS];
        for (slot, tag) in names.iter_mut().zip(tags) {
            *slot = tag.text(buf);
        }
        f(&names[..tags.len()])
    } else {
        let names: Vec<&str> = tags.iter().map(|t| t.text(buf)).collect();
        f(&names)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_borrow_the_request_buffer_inline_and_spilled() {
        let buf = b"abcdefgh".to_vec();
        for count in [1usize, INLINE_TAGS, INLINE_TAGS + 5] {
            let tags: Vec<Field> = (0..count).map(|i| Field::new(i % 6..i % 6 + 2)).collect();
            let seen = with_names(&buf, &tags, |names| {
                names.iter().map(|n| n.to_string()).collect::<Vec<_>>()
            });
            assert_eq!(seen.len(), count);
            assert_eq!(seen[0], "ab");
            assert!(seen.iter().all(|n| n.len() == 2));
        }
    }

    #[test]
    fn a_hash_that_is_not_utf8_is_refused() {
        assert_eq!(hash_text(&[0xff; 60]), None);
        assert_eq!(hash_text(&[b'a'; 60]).map(str::len), Some(60));
    }
}

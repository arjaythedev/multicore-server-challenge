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

/// Pushes the statements of `job`. An `Err` means the connection is unusable (nothing else can fail: every field
/// of a job is bounded by the 1 MiB request limit, far below what the wire encoding accepts).
pub fn push_job(conn: &mut Connection, s: &Statements, job: &WriteJob) -> Result<Pushed, PgError> {
    let buf = job.buf.as_slice();
    let text = |f: &Field| Param::Text(f.text(buf));
    let optional = |f: &Option<Field>| f.as_ref().map_or(Param::Null, text);
    let viewer = Param::Int8(job.viewer);
    let one = |r: Result<(), PgError>| r.map(|()| Pushed::Statements(1));
    match &job.kind {
        WriteKind::Register {
            username,
            email,
            password_hash,
        } => {
            let Some(hash) = hash_text(password_hash) else {
                return Ok(Pushed::Rejected);
            };
            one(conn.push(
                &s.register,
                &[text(username), text(email), Param::Text(hash)],
            ))
        }
        WriteKind::UpdateUser {
            email,
            username,
            password_hash,
            bio,
            image,
            ..
        } => {
            let hash = match password_hash {
                Some(raw) => match hash_text(raw) {
                    Some(hash) => Param::Text(hash),
                    None => return Ok(Pushed::Rejected),
                },
                None => Param::Null,
            };
            let params = [
                viewer,
                optional(email),
                optional(username),
                hash,
                optional(bio),
                optional(image),
            ];
            one(conn.push(&s.update_user, &params))
        }
        WriteKind::Follow { username, follow } => {
            let stmt = if *follow { &s.follow } else { &s.unfollow };
            one(conn.push(stmt, &[viewer, text(username)]))
        }
        WriteKind::CreateArticle {
            slug_base,
            title,
            description,
            body,
            tags,
        } => {
            let params = [
                Param::Text(slug_base),
                viewer,
                text(title),
                text(description),
                text(body),
            ];
            conn.push(&s.insert_article, &params)?;
            let mut count = 1;
            if !tags.is_empty() {
                with_names(buf, tags, |names| {
                    conn.push(&s.insert_tags, &[Param::TextArray(names)])?;
                    conn.push(&s.link_tags, &[Param::TextArray(names)])
                })?;
                count += 2;
            }
            conn.push(&s.created_article, &[viewer])?;
            Ok(Pushed::Statements(count + 1))
        }
        WriteKind::UpdateArticle {
            slug,
            slug_base,
            title,
            description,
            body,
        } => {
            let base = slug_base.as_deref().map_or(Param::Null, Param::Text);
            let params = [
                text(slug),
                viewer,
                optional(title),
                optional(description),
                optional(body),
                base,
            ];
            one(conn.push(&s.update_article, &params))
        }
        WriteKind::DeleteArticle { slug } => {
            one(conn.push(&s.delete_article, &[text(slug), viewer]))
        }
        WriteKind::Favorite { slug, favorite } => {
            let stmt = if *favorite {
                &s.favorite
            } else {
                &s.unfavorite
            };
            one(conn.push(stmt, &[viewer, text(slug)]))
        }
        WriteKind::AddComment { slug, body } => {
            one(conn.push(&s.add_comment, &[text(slug), viewer, text(body)]))
        }
        WriteKind::DeleteComment { slug, comment_id } => one(conn.push(
            &s.delete_comment,
            &[Param::Int8(*comment_id), text(slug), viewer],
        )),
    }
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

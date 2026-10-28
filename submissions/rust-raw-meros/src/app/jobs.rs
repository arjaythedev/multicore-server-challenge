//! Work handed from the io threads to the lanes. A job owns the request buffer it was parsed from (moved, not
//! copied) and addresses its fields as [`Field`] ranges into it. The lane lends `&str` slices of those fields to
//! Postgres as parameters.

use std::ops::Range;

use crate::net::ConnId;

/// Where a response goes and how to leave the connection afterwards.
#[derive(Clone, Copy, Debug)]
pub struct Origin {
    pub conn: ConnId,
    pub keep_alive: bool,
}

/// A byte range inside a job's request buffer.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Field {
    pub start: u32,
    pub end: u32,
}

impl Field {
    pub fn new(range: Range<usize>) -> Field {
        Field {
            start: range.start as u32,
            end: range.end as u32,
        }
    }

    /// The field's text. The app validated UTF-8 once when it built the job, so this is cheap in release builds.
    pub fn text<'b>(&self, buf: &'b [u8]) -> &'b str {
        std::str::from_utf8(&buf[self.start as usize..self.end as usize]).unwrap_or("")
    }

    pub fn is_empty(&self) -> bool {
        self.start == self.end
    }
}

/// Which articles a list shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ListKind {
    All,
    Tag,
    Author,
    Favorited,
    Feed,
}

/// A request that only reads (batched by kind).
#[derive(Clone, Copy, Debug)]
pub enum ReadKind {
    Tags,
    CurrentUser,
    Profile,
    List(ListKind),
    Article,
    Comments,
    /// Login step 1: fetch the stored hash; the password check follows on a password thread.
    LoginLookup,
}

/// A read job. `viewer` is the token's user id, 0 for anonymous. `key` is the slug, username, tag or email the kind
/// needs; for `Feed` it is empty (the viewer is the key). `token` is the presented JWT for `CurrentUser`.
pub struct ReadJob {
    pub origin: Origin,
    pub kind: ReadKind,
    pub buf: Vec<u8>,
    pub viewer: i64,
    pub key: Field,
    pub token: Field,
    pub password: Field,
    pub limit: i64,
    pub offset: i64,
    pub queued_at: std::time::Instant,
}

/// A request that writes. Optional fields are `None` when the request left them out or sent `null`.
pub enum WriteKind {
    Register {
        username: Field,
        email: Field,
        password_hash: [u8; 60],
    },
    UpdateUser {
        email: Option<Field>,
        username: Option<Field>,
        password_hash: Option<[u8; 60]>,
        bio: Option<Field>,
        image: Option<Field>,
        token: Field,
    },
    Follow {
        username: Field,
        follow: bool,
    },
    CreateArticle {
        slug_base: String,
        title: Field,
        description: Field,
        body: Field,
        tags: Vec<Field>,
    },
    UpdateArticle {
        slug: Field,
        slug_base: Option<String>,
        title: Option<Field>,
        description: Option<Field>,
        body: Option<Field>,
    },
    DeleteArticle {
        slug: Field,
    },
    Favorite {
        slug: Field,
        favorite: bool,
    },
    AddComment {
        slug: Field,
        body: Field,
    },
    DeleteComment {
        slug: Field,
        comment_id: i64,
    },
}

pub struct WriteJob {
    pub origin: Origin,
    pub viewer: i64,
    pub buf: Vec<u8>,
    pub kind: WriteKind,
}

/// A password operation for the bcrypt thread.
pub enum PasswordKind {
    /// Check `password` against the stored hash of a user row fetched by `LoginLookup`; on success answer with the
    /// user and a fresh token, on failure with 401.
    Verify { user: StoredUser },
    /// Hash the password, then continue as the given write (`Register` or `UpdateUser`, with the hash filled in).
    Hash { then: Box<WriteJob> },
}

/// The columns of a `users` row that a login answer needs.
pub struct StoredUser {
    pub id: i64,
    pub username: String,
    pub email: String,
    pub bio: Option<String>,
    pub image: Option<String>,
    pub password_hash: [u8; 60],
}

pub struct PasswordJob {
    pub origin: Origin,
    /// The request buffer, with the password at `password`.
    pub buf: Vec<u8>,
    pub password: Field,
    pub kind: PasswordKind,
    pub queued_at: std::time::Instant,
}

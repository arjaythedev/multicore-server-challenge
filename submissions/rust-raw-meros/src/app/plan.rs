//! Turns one parsed request into a [`Plan`]: an immediate rejection, or the data of a read, write or password job.
//! No I/O happens here and no buffer is moved; the plan holds only `Field` ranges and small values.

use super::auth::{Auth, authenticate};
use super::body;
use super::jobs::{Field, ListKind, ReadKind, WriteKind};
use super::route::{Route, route};
use super::scratch::{Scratch, field_of};
use crate::http::{Request, Status, parse_int, percent_decode, query_param};
use crate::jwt::Jwt;

/// Largest page and the default, from the SPEC.
const MAX_LIMIT: i64 = 100;
const DEFAULT_LIMIT: i64 = 20;

pub enum Plan {
    /// Answer now with this status and message.
    Reject(Status, &'static str),
    Read(ReadPlan),
    Write {
        viewer: i64,
        kind: WriteKind,
    },
    /// Hash `password` on a password thread, then continue as `then`.
    Hash {
        viewer: i64,
        password: Field,
        then: WriteKind,
    },
}

/// The fields of a `ReadJob` that the request decides.
pub struct ReadPlan {
    pub kind: ReadKind,
    pub viewer: i64,
    pub key: Field,
    pub token: Field,
    pub password: Field,
    pub limit: i64,
    pub offset: i64,
}

impl ReadPlan {
    fn new(kind: ReadKind, viewer: i64) -> ReadPlan {
        ReadPlan {
            kind,
            viewer,
            key: Field::default(),
            token: Field::default(),
            password: Field::default(),
            limit: 0,
            offset: 0,
        }
    }

    pub fn fields_mut(&mut self) -> [&mut Field; 3] {
        [&mut self.key, &mut self.token, &mut self.password]
    }
}

/// Every `Field` of a write that may point into the scratch area.
pub fn write_fields_mut(kind: &mut WriteKind) -> Vec<&mut Field> {
    match kind {
        WriteKind::Register {
            username, email, ..
        } => vec![username, email],
        WriteKind::UpdateUser {
            email,
            username,
            bio,
            image,
            token,
            ..
        } => {
            let mut fields: Vec<&mut Field> = vec![token];
            fields.extend([email, username, bio, image].into_iter().flatten());
            fields
        }
        WriteKind::Follow { username, .. } => vec![username],
        WriteKind::CreateArticle {
            title,
            description,
            body,
            tags,
            ..
        } => {
            let mut fields: Vec<&mut Field> = vec![title, description, body];
            fields.extend(tags.iter_mut());
            fields
        }
        WriteKind::UpdateArticle {
            slug,
            title,
            description,
            body,
            ..
        } => {
            let mut fields: Vec<&mut Field> = vec![slug];
            fields.extend([title, description, body].into_iter().flatten());
            fields
        }
        WriteKind::DeleteArticle { slug } | WriteKind::Favorite { slug, .. } => vec![slug],
        WriteKind::AddComment { slug, body } => vec![slug, body],
        WriteKind::DeleteComment { slug, .. } => vec![slug],
    }
}

type Rejection = (Status, &'static str);

const UNAUTHORIZED: Rejection = (Status::Unauthorized, "missing or invalid token");
const NOT_FOUND: Rejection = (Status::NotFound, "not found");

/// Parses, authenticates, routes and validates. Never blocks, never allocates beyond small vectors for tags.
pub fn plan(jwt: &Jwt, now: u64, buf: &[u8], req: &Request<'_>, scratch: &mut Scratch) -> Plan {
    match plan_inner(jwt, now, buf, req, scratch) {
        Ok(plan) => plan,
        Err((status, message)) => Plan::Reject(status, message),
    }
}

/// What the caller may do: a token is required, optional, or irrelevant.
enum Access {
    Required,
    Optional,
    None,
}

fn plan_inner(
    jwt: &Jwt,
    now: u64,
    buf: &[u8],
    req: &Request<'_>,
    scratch: &mut Scratch,
) -> Result<Plan, Rejection> {
    let found = route(req.method, req.path);
    let access = match found {
        Route::Register | Route::Login | Route::Tags | Route::NotFound => Access::None,
        Route::Profile { .. }
        | Route::ListArticles
        | Route::Article { .. }
        | Route::Comments { .. } => Access::Optional,
        _ => Access::Required,
    };
    let auth = match access {
        Access::None => Auth::Anonymous,
        _ => authenticate(jwt, req.authorization, now),
    };
    let (viewer, token): (i64, &[u8]) = match (&access, auth) {
        (_, Auth::Invalid) | (Access::Required, Auth::Anonymous) => return Err(UNAUTHORIZED),
        (_, Auth::User { id, token }) => (id, token),
        (_, Auth::Anonymous) => (0, &[]),
    };
    let segment = |scratch: &mut Scratch, raw: &[u8]| -> Field {
        lookup_key(buf, scratch, &percent_decode(raw))
    };

    Ok(match found {
        Route::NotFound => return Err(NOT_FOUND),
        Route::Tags => Plan::Read(ReadPlan::new(ReadKind::Tags, 0)),
        Route::Register => {
            let r = body::register(buf, req.body, scratch).map_err(unprocessable)?;
            Plan::Hash {
                viewer: 0,
                password: r.password,
                then: WriteKind::Register {
                    username: r.username,
                    email: r.email,
                    password_hash: [0; 60],
                },
            }
        }
        Route::Login => {
            let r = body::login(buf, req.body, scratch).map_err(unprocessable)?;
            let mut read = ReadPlan::new(ReadKind::LoginLookup, 0);
            read.key = r.email;
            read.password = r.password;
            Plan::Read(read)
        }
        Route::CurrentUser => {
            let mut read = ReadPlan::new(ReadKind::CurrentUser, viewer);
            read.token = field_of(buf, token);
            Plan::Read(read)
        }
        Route::UpdateUser => {
            let u = body::update_user(buf, req.body, scratch).map_err(unprocessable)?;
            let kind = WriteKind::UpdateUser {
                email: u.email,
                username: u.username,
                password_hash: None,
                bio: u.bio,
                image: u.image,
                token: field_of(buf, token),
            };
            match u.password {
                Some(password) => Plan::Hash {
                    viewer,
                    password,
                    then: kind,
                },
                None => Plan::Write { viewer, kind },
            }
        }
        Route::Profile { username } => {
            let mut read = ReadPlan::new(ReadKind::Profile, viewer);
            read.key = segment(scratch, username);
            Plan::Read(read)
        }
        Route::Follow { username, follow } => Plan::Write {
            viewer,
            kind: WriteKind::Follow {
                username: segment(scratch, username),
                follow,
            },
        },
        Route::ListArticles => {
            let (limit, offset) = paging(req.query)?;
            let (kind, key) = list_filter(buf, req.query, scratch);
            let mut read = ReadPlan::new(ReadKind::List(kind), viewer);
            read.key = key;
            read.limit = limit;
            read.offset = offset;
            Plan::Read(read)
        }
        Route::Feed => {
            let (limit, offset) = paging(req.query)?;
            let mut read = ReadPlan::new(ReadKind::List(ListKind::Feed), viewer);
            read.limit = limit;
            read.offset = offset;
            Plan::Read(read)
        }
        Route::Article { slug } => {
            let mut read = ReadPlan::new(ReadKind::Article, viewer);
            read.key = segment(scratch, slug);
            Plan::Read(read)
        }
        Route::Comments { slug } => {
            let mut read = ReadPlan::new(ReadKind::Comments, viewer);
            read.key = segment(scratch, slug);
            Plan::Read(read)
        }
        Route::CreateArticle => {
            let a = body::new_article(buf, req.body, scratch).map_err(unprocessable)?;
            Plan::Write {
                viewer,
                kind: WriteKind::CreateArticle {
                    slug_base: a.slug_base,
                    title: a.title,
                    description: a.description,
                    body: a.body,
                    tags: a.tags,
                },
            }
        }
        Route::UpdateArticle { slug } => {
            let e = body::article_edit(buf, req.body, scratch).map_err(unprocessable)?;
            Plan::Write {
                viewer,
                kind: WriteKind::UpdateArticle {
                    slug: segment(scratch, slug),
                    slug_base: e.slug_base,
                    title: e.title,
                    description: e.description,
                    body: e.body,
                },
            }
        }
        Route::DeleteArticle { slug } => Plan::Write {
            viewer,
            kind: WriteKind::DeleteArticle {
                slug: segment(scratch, slug),
            },
        },
        Route::Favorite { slug, favorite } => Plan::Write {
            viewer,
            kind: WriteKind::Favorite {
                slug: segment(scratch, slug),
                favorite,
            },
        },
        Route::AddComment { slug } => {
            let text = body::comment(buf, req.body, scratch).map_err(unprocessable)?;
            Plan::Write {
                viewer,
                kind: WriteKind::AddComment {
                    slug: segment(scratch, slug),
                    body: text,
                },
            }
        }
        Route::DeleteComment { slug, id } => {
            let comment_id = parse_int(id).filter(|&n| n >= 0).ok_or(NOT_FOUND)?;
            Plan::Write {
                viewer,
                kind: WriteKind::DeleteComment {
                    slug: segment(scratch, slug),
                    comment_id,
                },
            }
        }
    })
}

fn unprocessable(message: &'static str) -> Rejection {
    (Status::Unprocessable, message)
}

/// `limit` (default 20, 1..=100) and `offset` (default 0, >= 0) must be integers in range, otherwise 422.
fn paging(query: &[u8]) -> Result<(i64, i64), Rejection> {
    let number = |name: &str,
                  default: i64,
                  valid: std::ops::RangeInclusive<i64>|
     -> Result<i64, Rejection> {
        match query_param(query, name) {
            None => Ok(default),
            Some(raw) => parse_int(&raw).filter(|n| valid.contains(n)).ok_or((
                Status::Unprocessable,
                "limit and offset must be integers in range",
            )),
        }
    };
    Ok((
        number("limit", DEFAULT_LIMIT, 1..=MAX_LIMIT)?,
        number("offset", 0, 0..=i64::MAX)?,
    ))
}

/// A path segment or query value used to look something up. Postgres rejects NUL in text, which would fail the whole
/// batch the lookup travels in, so such a key becomes the empty key, which names nothing (no slug, username or tag is
/// empty) and gives 404 or an empty list as it should.
#[allow(clippy::ptr_arg)] // `Scratch::field` needs the Cow variant
fn lookup_key(buf: &[u8], scratch: &mut Scratch, decoded: &std::borrow::Cow<'_, [u8]>) -> Field {
    if decoded.contains(&0) {
        Field::default()
    } else {
        scratch.field(buf, decoded)
    }
}

/// The list filter. If several are given only the first of tag, author, favorited applies. A filter with an empty
/// value is ignored (conformance step "empty-tag-ignored").
fn list_filter(buf: &[u8], query: &[u8], scratch: &mut Scratch) -> (ListKind, Field) {
    for (name, kind) in [
        ("tag", ListKind::Tag),
        ("author", ListKind::Author),
        ("favorited", ListKind::Favorited),
    ] {
        if let Some(value) = query_param(query, name).filter(|value| !value.is_empty()) {
            return (kind, lookup_key(buf, scratch, &value));
        }
    }
    (ListKind::All, Field::default())
}

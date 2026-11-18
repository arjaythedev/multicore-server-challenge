//! Turns the rows of a finished Postgres batch into the JSON bodies required by SPEC.md.

use crate::auth::Jwt;
use crate::json::{push_bool, push_i64, push_opt_str, push_str, push_ts};
use crate::pg::{RowReader, Scan};

/// What to do with the result of a database batch (stored on the client connection while waiting).
/// The u8 is the index of the statement whose rows contain the payload of the response.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Tags,
    UserGet,
    UserUpdate,
    Register,
    Login,
    Profile(u8),
    ArticleList,
    /// (statement index, HTTP status on success)
    ArticleOne(u8, u16),
    ArticleUpdate,
    ArticleDelete,
    CommentsList,
    CommentCreate,
    CommentDelete,
}

pub struct LoginRow {
    pub id: i64,
    pub username: String,
    pub email: String,
    pub bio: Option<String>,
    pub image: Option<String>,
    pub hash: String,
}

pub enum Done {
    /// Body is already in `out`.
    Json(u16),
    NoContent,
    Err(u16, &'static str),
    /// Login needs a bcrypt verification before it can answer.
    Login(LoginRow),
}

fn to_string(b: &[u8]) -> String {
    String::from_utf8_lossy(b).into_owned()
}

pub fn finish(
    kind: Kind,
    viewer: i64,
    token: &[u8],
    rx: &[u8],
    scan: &Scan,
    out: &mut Vec<u8>,
    now: i64,
    jwt: &Jwt,
) -> Done {
    if scan.has_err {
        // unique_violation on username/email
        if &scan.err_code == b"23505" && (kind == Kind::Register || kind == Kind::UserUpdate) {
            return Done::Err(422, "username or email has already been taken");
        }
        return Done::Err(500, "internal server error");
    }

    match kind {
        Kind::Tags => {
            out.extend_from_slice(b"{\"tags\":[");
            for (i, r) in scan.stmt_rows(0).iter().enumerate() {
                if i > 0 {
                    out.push(b',');
                }
                let mut rr = RowReader::new(rx, *r);
                push_str(out, rr.bytes());
            }
            out.extend_from_slice(b"]}");
            Done::Json(200)
        }

        Kind::UserGet | Kind::UserUpdate => {
            let rows = scan.stmt_rows(0);
            if rows.is_empty() {
                return Done::Err(401, "unauthorized");
            }
            let mut rr = RowReader::new(rx, rows[0]);
            let _id = rr.field();
            write_user(out, &mut rr, token);
            Done::Json(200)
        }

        Kind::Register => {
            let rows = scan.stmt_rows(0);
            if rows.is_empty() {
                return Done::Err(500, "internal server error");
            }
            let mut rr = RowReader::new(rx, rows[0]);
            let id = rr.int8();
            let mut tok: Vec<u8> = Vec::with_capacity(200);
            jwt.sign(id, now, &mut tok);
            write_user(out, &mut rr, &tok);
            Done::Json(201)
        }

        Kind::Login => {
            let rows = scan.stmt_rows(0);
            if rows.is_empty() {
                return Done::Err(401, "invalid email or password");
            }
            let mut rr = RowReader::new(rx, rows[0]);
            let id = rr.int8();
            let username = to_string(rr.bytes());
            let email = to_string(rr.bytes());
            let bio = rr.field().map(to_string);
            let image = rr.field().map(to_string);
            let hash = to_string(rr.bytes());
            Done::Login(LoginRow {
                id,
                username,
                email,
                bio,
                image,
                hash,
            })
        }

        Kind::Profile(si) => {
            let rows = scan.stmt_rows(si as usize);
            if rows.is_empty() {
                return Done::Err(404, "profile not found");
            }
            let mut rr = RowReader::new(rx, rows[0]);
            let username = rr.bytes();
            let bio = rr.field();
            let image = rr.field();
            let following = rr.boolean();
            out.extend_from_slice(b"{\"profile\":");
            write_profile(out, username, bio, image, following);
            out.push(b'}');
            Done::Json(200)
        }

        Kind::ArticleList => {
            out.extend_from_slice(b"{\"articles\":[");
            for (i, r) in scan.stmt_rows(0).iter().enumerate() {
                if i > 0 {
                    out.push(b',');
                }
                let mut rr = RowReader::new(rx, *r);
                write_article(out, &mut rr, false);
            }
            out.extend_from_slice(b"],\"articlesCount\":");
            let crows = scan.stmt_rows(1);
            let count = if crows.is_empty() {
                0
            } else {
                RowReader::new(rx, crows[0]).int8()
            };
            push_i64(out, count);
            out.push(b'}');
            Done::Json(200)
        }

        Kind::ArticleOne(si, status) => {
            let rows = scan.stmt_rows(si as usize);
            if rows.is_empty() {
                return Done::Err(404, "article not found");
            }
            let mut rr = RowReader::new(rx, rows[0]);
            out.extend_from_slice(b"{\"article\":");
            write_article(out, &mut rr, true);
            out.push(b'}');
            Done::Json(status)
        }

        Kind::ArticleUpdate => {
            let auth_rows = scan.stmt_rows(0);
            if auth_rows.is_empty() {
                return Done::Err(404, "article not found");
            }
            let author = RowReader::new(rx, auth_rows[0]).int8();
            if author != viewer {
                return Done::Err(403, "forbidden");
            }
            let rows = scan.stmt_rows(1);
            if rows.is_empty() {
                return Done::Err(404, "article not found");
            }
            let mut rr = RowReader::new(rx, rows[0]);
            out.extend_from_slice(b"{\"article\":");
            write_article(out, &mut rr, true);
            out.push(b'}');
            Done::Json(200)
        }

        Kind::ArticleDelete | Kind::CommentDelete => {
            let auth_rows = scan.stmt_rows(0);
            if auth_rows.is_empty() {
                return Done::Err(404, "not found");
            }
            let author = RowReader::new(rx, auth_rows[0]).int8();
            if author != viewer {
                return Done::Err(403, "forbidden");
            }
            Done::NoContent
        }

        Kind::CommentsList => {
            if scan.stmt_rows(0).is_empty() {
                return Done::Err(404, "article not found");
            }
            out.extend_from_slice(b"{\"comments\":[");
            for (i, r) in scan.stmt_rows(1).iter().enumerate() {
                if i > 0 {
                    out.push(b',');
                }
                let mut rr = RowReader::new(rx, *r);
                write_comment(out, &mut rr, true);
            }
            out.extend_from_slice(b"]}");
            Done::Json(200)
        }

        Kind::CommentCreate => {
            if scan.stmt_rows(0).is_empty() {
                return Done::Err(404, "article not found");
            }
            let rows = scan.stmt_rows(1);
            if rows.is_empty() {
                return Done::Err(404, "article not found");
            }
            let mut rr = RowReader::new(rx, rows[0]);
            out.extend_from_slice(b"{\"comment\":");
            write_comment(out, &mut rr, false);
            out.push(b'}');
            Done::Json(201)
        }
    }
}

// ---------------------------------------------------------------------------- writers

fn write_profile(out: &mut Vec<u8>, username: &[u8], bio: Option<&[u8]>, image: Option<&[u8]>, following: bool) {
    out.extend_from_slice(b"{\"username\":");
    push_str(out, username);
    out.extend_from_slice(b",\"bio\":");
    push_opt_str(out, bio);
    out.extend_from_slice(b",\"image\":");
    push_opt_str(out, image);
    out.extend_from_slice(b",\"following\":");
    push_bool(out, following);
    out.push(b'}');
}

/// Reads (username, email, bio, image) from the reader and writes the `user` envelope.
fn write_user(out: &mut Vec<u8>, rr: &mut RowReader, token: &[u8]) {
    let username = rr.bytes();
    let email = rr.bytes();
    let bio = rr.field();
    let image = rr.field();
    write_user_fields(out, username, email, bio, image, token);
}

fn write_user_fields(
    out: &mut Vec<u8>,
    username: &[u8],
    email: &[u8],
    bio: Option<&[u8]>,
    image: Option<&[u8]>,
    token: &[u8],
) {
    out.extend_from_slice(b"{\"user\":{\"email\":");
    push_str(out, email);
    out.extend_from_slice(b",\"token\":");
    push_str(out, token);
    out.extend_from_slice(b",\"username\":");
    push_str(out, username);
    out.extend_from_slice(b",\"bio\":");
    push_opt_str(out, bio);
    out.extend_from_slice(b",\"image\":");
    push_opt_str(out, image);
    out.extend_from_slice(b"}}");
}

/// Used after a successful login verification.
pub fn write_user_json(
    out: &mut Vec<u8>,
    username: &str,
    email: &str,
    bio: Option<&str>,
    image: Option<&str>,
    token: &[u8],
) {
    write_user_fields(
        out,
        username.as_bytes(),
        email.as_bytes(),
        bio.map(|s| s.as_bytes()),
        image.map(|s| s.as_bytes()),
        token,
    );
}

fn be_i32(b: &[u8]) -> i32 {
    i32::from_be_bytes([b[0], b[1], b[2], b[3]])
}

/// Binary `text[]` (one dimension) -> JSON array of strings.
fn write_text_array(out: &mut Vec<u8>, a: Option<&[u8]>) {
    out.push(b'[');
    if let Some(a) = a {
        if a.len() >= 12 {
            let ndim = be_i32(&a[0..4]);
            if ndim >= 1 && a.len() >= 12 + 8 * ndim as usize {
                let n = be_i32(&a[12..16]);
                let mut p = 12 + 8 * ndim as usize;
                let mut i = 0;
                while i < n {
                    if p + 4 > a.len() {
                        break;
                    }
                    let len = be_i32(&a[p..p + 4]);
                    p += 4;
                    if i > 0 {
                        out.push(b',');
                    }
                    if len < 0 {
                        out.extend_from_slice(b"null");
                    } else {
                        let l = len as usize;
                        if p + l > a.len() {
                            break;
                        }
                        push_str(out, &a[p..p + l]);
                        p += l;
                    }
                    i += 1;
                }
            }
        }
    }
    out.push(b']');
}

/// Article row (see sql::COLS for the column order); `full` adds the body column at the end.
fn write_article(out: &mut Vec<u8>, rr: &mut RowReader, full: bool) {
    let _id = rr.field();
    let slug = rr.bytes();
    let title = rr.bytes();
    let description = rr.bytes();
    let created = rr.int8();
    let updated = rr.int8();
    let tags = rr.field();
    let favorites = rr.int8();
    let favorited = rr.boolean();
    let username = rr.bytes();
    let bio = rr.field();
    let image = rr.field();
    let following = rr.boolean();

    out.extend_from_slice(b"{\"slug\":");
    push_str(out, slug);
    out.extend_from_slice(b",\"title\":");
    push_str(out, title);
    out.extend_from_slice(b",\"description\":");
    push_str(out, description);
    if full {
        let body = rr.bytes();
        out.extend_from_slice(b",\"body\":");
        push_str(out, body);
    }
    out.extend_from_slice(b",\"tagList\":");
    write_text_array(out, tags);
    out.extend_from_slice(b",\"createdAt\":");
    push_ts(out, created);
    out.extend_from_slice(b",\"updatedAt\":");
    push_ts(out, updated);
    out.extend_from_slice(b",\"favorited\":");
    push_bool(out, favorited);
    out.extend_from_slice(b",\"favoritesCount\":");
    push_i64(out, favorites);
    out.extend_from_slice(b",\"author\":");
    write_profile(out, username, bio, image, following);
    out.push(b'}');
}

/// Comment row: id, body, created_at, updated_at, username, bio, image, [following].
fn write_comment(out: &mut Vec<u8>, rr: &mut RowReader, with_following: bool) {
    let id = rr.int8();
    let body = rr.bytes();
    let created = rr.int8();
    let updated = rr.int8();
    let username = rr.bytes();
    let bio = rr.field();
    let image = rr.field();
    let following = if with_following { rr.boolean() } else { false };

    out.extend_from_slice(b"{\"id\":");
    push_i64(out, id);
    out.extend_from_slice(b",\"createdAt\":");
    push_ts(out, created);
    out.extend_from_slice(b",\"updatedAt\":");
    push_ts(out, updated);
    out.extend_from_slice(b",\"body\":");
    push_str(out, body);
    out.extend_from_slice(b",\"author\":");
    write_profile(out, username, bio, image, following);
    out.push(b'}');
}

//! Routing, validation and the per-endpoint state machines.
//!
//! The event loop calls `start` for a parsed request and `resume` whenever a database group or a bcrypt job finishes.
//! Both return what to do next. Response bodies are written into `out`; `Next::Respond` carries only the status.

use serde_json::{Map, Value};

use crate::auth::{Auth, Jwt};
use crate::json;
use crate::pg::{GroupResult, P, PgError, Row, StmtResult};
use crate::pool::{Job, JobResult};
use crate::sql::*;
use crate::util::{decode_segment, parse_digits_i64};

pub struct Ctx<'a> {
    pub jwt: &'a Jwt,
    pub now: i64,
}

pub struct Req<'a> {
    pub method: &'a str,
    pub path: &'a str,
    pub query: &'a str,
    pub auth: Option<&'a [u8]>,
    pub body: &'a [u8],
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Read,
    /// Reads that take 0.2-0.5 ms (feed, list pages); same pool as `Read`, their cost is in `sql::COST_US`.
    Heavy,
    Write,
}

pub type Group = Vec<(usize, Vec<P>)>;

pub enum Next {
    Respond(u16),
    Db(Kind, Group, Cont),
    Bcrypt(Job, Cont),
}

pub enum Outcome {
    Db(GroupResult),
    Bcrypt(JobResult),
}

/// What a request is waiting for, with the state it needs to continue.
pub enum Cont {
    Tags,
    Profile,
    List,
    Article,
    Comments,
    Follow(bool),
    Favorite,
    CommentCreate,
    CommentDelete { viewer: i64, id: i64, slug: String },
    CommentProbe { viewer: i64 },
    ArticleDelete { viewer: i64, slug: String },
    ArticleUpdate { viewer: i64, slug: String },
    ArticleProbe { viewer: i64 },
    ArticleCreate(Box<NewArticle>),
    RegisterHash { username: String, email: String },
    RegisterInsert,
    LoginLookup { password: String },
    LoginVerify(Box<UserRow>),
    UserGet { token: String },
    UserUpdateHash(Box<UserUpdate>),
    UserUpdate { token: String },
}

pub struct NewArticle {
    viewer: i64,
    title: String,
    description: String,
    body: String,
    tags: Vec<String>,
    retried: bool,
}

pub struct UserRow {
    id: i64,
    username: String,
    email: String,
    bio: Option<String>,
    image: Option<String>,
}

pub struct UserUpdate {
    viewer: i64,
    token: String,
    email: Option<String>,
    username: Option<String>,
    bio: Option<String>,
    image: Option<String>,
}

// ---------------------------------------------------------------- entry points

pub fn start(ctx: &Ctx, req: &Req, out: &mut Vec<u8>) -> Next {
    out.clear();
    let Some(rest) = req.path.strip_prefix("/api/") else { return fail(out, 404, "not found") };
    let mut segs = [""; 5];
    let mut n = 0;
    for s in rest.split('/') {
        if n == segs.len() {
            return fail(out, 404, "not found");
        }
        segs[n] = s;
        n += 1;
    }
    match (req.method, &segs[..n]) {
        ("GET", ["tags"]) => db(Kind::Read, TAGS, vec![], Cont::Tags),
        ("POST", ["users"]) => register(req, out),
        ("POST", ["users", "login"]) => login(req, out),
        ("GET", ["user"]) => match required(ctx, req, out) {
            Ok(viewer) => db(Kind::Read, USER_BY_ID, vec![P::I64(viewer)], Cont::UserGet { token: token_of(req) }),
            Err(n) => n,
        },
        ("PUT", ["user"]) => update_user(ctx, req, out),
        ("GET", ["profiles", u]) => with_seg(u, out, |u, out| match optional(ctx, req, out) {
            Ok(viewer) => db(Kind::Read, PROFILE, vec![P::I64(viewer), P::Text(u)], Cont::Profile),
            Err(n) => n,
        }),
        (m @ ("POST" | "DELETE"), ["profiles", u, "follow"]) => match required(ctx, req, out) {
            Ok(viewer) => with_seg(u, out, |u, _| {
                let follow = m == "POST";
                db(Kind::Write, if follow { FOLLOW } else { UNFOLLOW }, vec![P::I64(viewer), P::Text(u)], Cont::Follow(follow))
            }),
            Err(n) => n,
        },
        ("GET", ["articles"]) => list(ctx, req, out),
        ("POST", ["articles"]) => create_article(ctx, req, out),
        ("GET", ["articles", "feed"]) => feed(ctx, req, out),
        ("GET", ["articles", slug]) => with_seg(slug, out, |slug, out| match optional(ctx, req, out) {
            Ok(viewer) => db(Kind::Read, ARTICLE_BY_SLUG, vec![P::I64(viewer), P::Text(slug)], Cont::Article),
            Err(n) => n,
        }),
        ("PUT", ["articles", slug]) => update_article(ctx, req, slug, out),
        ("DELETE", ["articles", slug]) => match required(ctx, req, out) {
            Ok(viewer) => with_seg(slug, out, |slug, _| {
                db(Kind::Write, ARTICLE_DELETE, vec![P::I64(viewer), P::Text(slug.clone())], Cont::ArticleDelete { viewer, slug })
            }),
            Err(n) => n,
        },
        (m @ ("POST" | "DELETE"), ["articles", slug, "favorite"]) => match required(ctx, req, out) {
            Ok(viewer) => with_seg(slug, out, |slug, _| {
                let stmt = if m == "POST" { FAVORITE } else { UNFAVORITE };
                db(Kind::Write, stmt, vec![P::I64(viewer), P::Text(slug)], Cont::Favorite)
            }),
            Err(n) => n,
        },
        ("GET", ["articles", slug, "comments"]) => with_seg(slug, out, |slug, out| match optional(ctx, req, out) {
            Ok(viewer) => db(Kind::Read, COMMENTS, vec![P::I64(viewer), P::Text(slug)], Cont::Comments),
            Err(n) => n,
        }),
        ("POST", ["articles", slug, "comments"]) => create_comment(ctx, req, slug, out),
        ("DELETE", ["articles", slug, "comments", id]) => match required(ctx, req, out) {
            Ok(viewer) => match (parse_digits_i64(id), decode_segment(slug)) {
                (Some(id), Some(slug)) => db(
                    Kind::Write,
                    COMMENT_DELETE,
                    vec![P::I64(viewer), P::I64(id), P::Text(slug.clone())],
                    Cont::CommentDelete { viewer, id, slug },
                ),
                _ => fail(out, 404, "comment not found"),
            },
            Err(n) => n,
        },
        _ => fail(out, 404, "not found"),
    }
}

pub fn resume(ctx: &Ctx, cont: Cont, outcome: Outcome, out: &mut Vec<u8>) -> Next {
    out.clear();
    let res = match outcome {
        Outcome::Bcrypt(r) => return resume_bcrypt(ctx, cont, r, out),
        Outcome::Db(Ok(res)) => res,
        Outcome::Db(Err(e)) => return resume_error(cont, e, out),
    };
    let rows = last_rows(&res);
    match cont {
        Cont::Tags => {
            out.extend_from_slice(b"{\"tags\":[");
            let mut first = true;
            if let Some(r) = rows.first() {
                r.text_array(0, |t| {
                    if !std::mem::take(&mut first) {
                        out.push(b',');
                    }
                    json::str(out, t);
                });
            }
            out.extend_from_slice(b"]}");
            Next::Respond(200)
        }
        Cont::Profile => match rows.first() {
            None => fail(out, 404, "profile not found"),
            Some(r) => {
                out.extend_from_slice(b"{\"profile\":");
                write_profile(out, r.str(1), r.opt_str(2), r.opt_str(3), r.bool(4));
                out.push(b'}');
                Next::Respond(200)
            }
        },
        Cont::Follow(following) => match rows.first() {
            None => fail(out, 404, "profile not found"),
            Some(r) => {
                out.extend_from_slice(b"{\"profile\":");
                write_profile(out, r.str(0), r.opt_str(1), r.opt_str(2), following);
                out.push(b'}');
                Next::Respond(200)
            }
        },
        Cont::List => {
            let count = rows.first().map_or(0, |r| r.i64(0));
            out.extend_from_slice(b"{\"articles\":[");
            for (i, r) in rows.iter().filter(|r| !r.is_null(1)).enumerate() {
                if i > 0 {
                    out.push(b',');
                }
                write_article(out, r, 1, false);
            }
            out.extend_from_slice(b"],\"articlesCount\":");
            json::int(out, count);
            out.push(b'}');
            Next::Respond(200)
        }
        Cont::Article | Cont::Favorite => match rows.first() {
            None => fail(out, 404, "article not found"),
            Some(r) => article_envelope(out, r, 200),
        },
        Cont::ArticleCreate(_) => match rows.first() {
            None => fail(out, 500, "created article not found"),
            Some(r) => article_envelope(out, r, 201),
        },
        Cont::Comments => match rows.first() {
            None => fail(out, 404, "article not found"),
            Some(_) => {
                out.extend_from_slice(b"{\"comments\":[");
                for (i, r) in rows.iter().filter(|r| !r.is_null(1)).enumerate() {
                    if i > 0 {
                        out.push(b',');
                    }
                    write_comment(out, r.i64(1), r.str(2), r.ts(3), r.ts(4), r.str(5), r.opt_str(6), r.opt_str(7), r.bool(8));
                }
                out.extend_from_slice(b"]}");
                Next::Respond(200)
            }
        },
        Cont::CommentCreate => match rows.first() {
            None => fail(out, 404, "article not found"),
            Some(r) => {
                out.extend_from_slice(b"{\"comment\":");
                write_comment(out, r.i64(0), r.str(1), r.ts(2), r.ts(3), r.str(4), r.opt_str(5), r.opt_str(6), false);
                out.push(b'}');
                Next::Respond(201)
            }
        },
        Cont::CommentDelete { viewer, id, slug } => {
            if rows.is_empty() {
                // Not deleted: either it doesn't exist (404) or it isn't the viewer's (403).
                db(Kind::Read, COMMENT_PROBE, vec![P::I64(id), P::Text(slug)], Cont::CommentProbe { viewer })
            } else {
                Next::Respond(204)
            }
        }
        Cont::CommentProbe { viewer } | Cont::ArticleProbe { viewer } => match rows.first() {
            // An author match here means the row went away between the two statements: report it as gone.
            Some(r) if r.i64(0) != viewer => fail(out, 403, "forbidden"),
            _ => fail(out, 404, "not found"),
        },
        Cont::ArticleDelete { viewer, slug } => {
            if rows.is_empty() {
                db(Kind::Read, ARTICLE_PROBE, vec![P::Text(slug)], Cont::ArticleProbe { viewer })
            } else {
                Next::Respond(204)
            }
        }
        Cont::ArticleUpdate { viewer, slug } => match rows.first() {
            Some(r) => article_envelope(out, r, 200),
            None => db(Kind::Read, ARTICLE_PROBE, vec![P::Text(slug)], Cont::ArticleProbe { viewer }),
        },
        Cont::RegisterInsert => match rows.first() {
            None => fail(out, 500, "user not created"),
            Some(r) => {
                let token = ctx.jwt.issue(r.i64(0), ctx.now);
                user_envelope(out, r.str(2), &token, r.str(1), r.opt_str(3), r.opt_str(4));
                Next::Respond(201)
            }
        },
        Cont::LoginLookup { password } => match rows.first() {
            None => fail(out, 401, "invalid email or password"),
            Some(r) => Next::Bcrypt(
                Job::Verify { password, hash: r.str(5).to_string() },
                Cont::LoginVerify(Box::new(UserRow {
                    id: r.i64(0),
                    username: r.str(1).to_string(),
                    email: r.str(2).to_string(),
                    bio: r.opt_str(3).map(str::to_string),
                    image: r.opt_str(4).map(str::to_string),
                })),
            ),
        },
        Cont::UserGet { token } | Cont::UserUpdate { token } => match rows.first() {
            None => fail(out, 401, "unauthorized"),
            Some(r) => {
                user_envelope(out, r.str(2), &token, r.str(1), r.opt_str(3), r.opt_str(4));
                Next::Respond(200)
            }
        },
        Cont::RegisterHash { .. } | Cont::LoginVerify(_) | Cont::UserUpdateHash(_) => fail(out, 500, "unexpected database result"),
    }
}

fn resume_bcrypt(ctx: &Ctx, cont: Cont, r: JobResult, out: &mut Vec<u8>) -> Next {
    match (cont, r) {
        (Cont::RegisterHash { username, email }, JobResult::Hashed(Some(hash))) => {
            db(Kind::Write, USER_INSERT, vec![P::Text(username), P::Text(email), P::Text(hash)], Cont::RegisterInsert)
        }
        (Cont::LoginVerify(u), JobResult::Verified(true)) => {
            let token = ctx.jwt.issue(u.id, ctx.now);
            user_envelope(out, &u.email, &token, &u.username, u.bio.as_deref(), u.image.as_deref());
            Next::Respond(200)
        }
        (Cont::LoginVerify(_), JobResult::Verified(false)) => fail(out, 401, "invalid email or password"),
        (Cont::UserUpdateHash(u), JobResult::Hashed(Some(hash))) => user_update_stmt(*u, Some(hash)),
        _ => fail(out, 500, "password hashing failed"),
    }
}

fn resume_error(cont: Cont, e: PgError, out: &mut Vec<u8>) -> Next {
    match cont {
        Cont::ArticleCreate(mut a) if !a.retried && matches!(e.code.as_str(), "40P01" | "40001") => {
            a.retried = true;
            create_group(a)
        }
        _ => match e.code.as_str() {
            "23505" => fail(out, 422, "has already been taken"),
            // An indexed value (slug, username, email) over the btree row limit: a validation error, not a crash.
            "54000" => fail(out, 422, "is too long"),
            "23503" => fail(out, 404, "not found"),
            "57014" | "55P03" | "53300" => fail(out, 503, "database busy"),
            c if c.starts_with("08") => fail(out, 503, "database unavailable"),
            _ => {
                eprintln!("[pg] error {}: {}", e.code, e.message);
                fail(out, 500, "database error")
            }
        },
    }
}

// ---------------------------------------------------------------- endpoints

fn list(ctx: &Ctx, req: &Req, out: &mut Vec<u8>) -> Next {
    let viewer = match optional(ctx, req, out) {
        Ok(v) => v,
        Err(n) => return n,
    };
    let q = Query::parse(req.query);
    let Some((limit, offset)) = q.page() else { return fail(out, 422, "limit/offset must be integers in range") };
    let (stmt, filter) = if let Some(t) = q.tag {
        (LIST_TAG, Some(t))
    } else if let Some(a) = q.author {
        (LIST_AUTHOR, Some(a))
    } else if let Some(f) = q.favorited {
        (LIST_FAVORITED, Some(f))
    } else {
        (LIST_ALL, None)
    };
    let mut params = vec![P::I64(viewer), P::I64(limit), P::I64(offset)];
    if let Some(f) = filter {
        if f.contains('\0') {
            // Postgres text can't hold NUL, so no tag or user can match.
            out.extend_from_slice(b"{\"articles\":[],\"articlesCount\":0}");
            return Next::Respond(200);
        }
        params.push(P::Text(f));
    }
    db(Kind::Heavy, stmt, params, Cont::List)
}

fn feed(ctx: &Ctx, req: &Req, out: &mut Vec<u8>) -> Next {
    let viewer = match required(ctx, req, out) {
        Ok(v) => v,
        Err(n) => return n,
    };
    let Some((limit, offset)) = Query::parse(req.query).page() else {
        return fail(out, 422, "limit/offset must be integers in range");
    };
    db(Kind::Heavy, FEED, vec![P::I64(viewer), P::I64(limit), P::I64(offset), P::I64(limit.saturating_add(offset))], Cont::List)
}

fn register(req: &Req, out: &mut Vec<u8>) -> Next {
    let Some(body) = parse_body(req.body) else { return fail(out, 422, "invalid JSON body") };
    let Some(u) = wrapper(&body, "user") else { return fail(out, 422, "user is required") };
    let (Ok(username), Ok(email), Ok(password)) = (req_str(u, "username"), req_str(u, "email"), req_str(u, "password")) else {
        return fail(out, 422, "username, email and password are required");
    };
    if password.len() > 72 {
        return fail(out, 422, "password is too long");
    }
    Next::Bcrypt(
        Job::Hash(password.to_string()),
        Cont::RegisterHash { username: username.to_string(), email: email.to_string() },
    )
}

fn login(req: &Req, out: &mut Vec<u8>) -> Next {
    let Some(body) = parse_body(req.body) else { return fail(out, 422, "invalid JSON body") };
    let Some(u) = wrapper(&body, "user") else { return fail(out, 422, "user is required") };
    let (Ok(email), Ok(password)) = (req_str(u, "email"), req_str(u, "password")) else {
        return fail(out, 422, "email and password are required");
    };
    db(Kind::Read, USER_BY_EMAIL, vec![P::Text(email.to_string())], Cont::LoginLookup { password: password.to_string() })
}

fn update_user(ctx: &Ctx, req: &Req, out: &mut Vec<u8>) -> Next {
    let viewer = match required(ctx, req, out) {
        Ok(v) => v,
        Err(n) => return n,
    };
    let Some(body) = parse_body(req.body) else { return fail(out, 422, "invalid JSON body") };
    let Some(u) = wrapper(&body, "user") else { return fail(out, 422, "user is required") };
    let fields = (
        opt_str(u, "email", true),
        opt_str(u, "username", true),
        opt_str(u, "password", true),
        opt_str(u, "bio", false),
        opt_str(u, "image", false),
    );
    let (Ok(email), Ok(username), Ok(password), Ok(bio), Ok(image)) = fields else {
        return fail(out, 422, "invalid user fields");
    };
    if password.is_some_and(|p| p.len() > 72) {
        return fail(out, 422, "password is too long");
    }
    let upd = UserUpdate {
        viewer,
        token: token_of(req),
        email: email.map(str::to_string),
        username: username.map(str::to_string),
        bio: bio.map(str::to_string),
        image: image.map(str::to_string),
    };
    match password {
        Some(pw) => Next::Bcrypt(Job::Hash(pw.to_string()), Cont::UserUpdateHash(Box::new(upd))),
        None => user_update_stmt(upd, None),
    }
}

fn user_update_stmt(u: UserUpdate, hash: Option<String>) -> Next {
    db(
        Kind::Write,
        USER_UPDATE,
        vec![
            P::I64(u.viewer),
            P::opt_text(u.email.as_deref()),
            P::opt_text(u.username.as_deref()),
            P::opt_text(hash.as_deref()),
            P::opt_text(u.bio.as_deref()),
            P::opt_text(u.image.as_deref()),
        ],
        Cont::UserUpdate { token: u.token },
    )
}

fn create_article(ctx: &Ctx, req: &Req, out: &mut Vec<u8>) -> Next {
    let viewer = match required(ctx, req, out) {
        Ok(v) => v,
        Err(n) => return n,
    };
    let Some(body) = parse_body(req.body) else { return fail(out, 422, "invalid JSON body") };
    let Some(a) = wrapper(&body, "article") else { return fail(out, 422, "article is required") };
    let (Ok(title), Ok(description), Ok(text)) = (req_str(a, "title"), req_str(a, "description"), req_str(a, "body")) else {
        return fail(out, 422, "title, description and body are required");
    };
    let tags = match a.get("tagList") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(items)) => {
            let mut tags = Vec::with_capacity(items.len());
            for t in items {
                match t {
                    Value::String(s) if !s.is_empty() && !s.contains('\0') => tags.push(s.clone()),
                    _ => return fail(out, 422, "tagList must be an array of non-empty strings"),
                }
            }
            tags
        }
        Some(_) => return fail(out, 422, "tagList must be an array of non-empty strings"),
    };
    create_group(Box::new(NewArticle {
        viewer,
        title: title.to_string(),
        description: description.to_string(),
        body: text.to_string(),
        tags,
        retried: false,
    }))
}

/// INSERT article [+ tags + article_tags] + SELECT, as one Sync group on one connection (one transaction).
fn create_group(a: Box<NewArticle>) -> Next {
    let mut g: Group = vec![(
        ARTICLE_INSERT,
        vec![P::I64(a.viewer), P::Text(a.title.clone()), P::Text(a.description.clone()), P::Text(a.body.clone())],
    )];
    if !a.tags.is_empty() {
        g.push((TAGS_INSERT, vec![P::TextArr(a.tags.clone())]));
        g.push((ARTICLE_TAGS_INSERT, vec![P::TextArr(a.tags.clone())]));
    }
    g.push((ARTICLE_BY_CURRVAL, vec![P::I64(a.viewer)]));
    Next::Db(Kind::Write, g, Cont::ArticleCreate(a))
}

fn update_article(ctx: &Ctx, req: &Req, slug: &str, out: &mut Vec<u8>) -> Next {
    let viewer = match required(ctx, req, out) {
        Ok(v) => v,
        Err(n) => return n,
    };
    let Some(body) = parse_body(req.body) else { return fail(out, 422, "invalid JSON body") };
    let Some(a) = wrapper(&body, "article") else { return fail(out, 422, "article is required") };
    let (Ok(title), Ok(description), Ok(text)) =
        (opt_str(a, "title", true), opt_str(a, "description", true), opt_str(a, "body", true))
    else {
        return fail(out, 422, "title, description and body must be non-empty strings");
    };
    let Some(slug) = decode_segment(slug) else { return fail(out, 404, "article not found") };
    db(
        Kind::Write,
        ARTICLE_UPDATE,
        vec![P::I64(viewer), P::Text(slug.clone()), P::opt_text(title), P::opt_text(description), P::opt_text(text)],
        Cont::ArticleUpdate { viewer, slug },
    )
}

fn create_comment(ctx: &Ctx, req: &Req, slug: &str, out: &mut Vec<u8>) -> Next {
    let viewer = match required(ctx, req, out) {
        Ok(v) => v,
        Err(n) => return n,
    };
    // The body is validated before the article lookup: an invalid body on an unknown article is 422.
    let Some(body) = parse_body(req.body) else { return fail(out, 422, "invalid JSON body") };
    let Some(c) = wrapper(&body, "comment") else { return fail(out, 422, "comment is required") };
    let Ok(text) = req_str(c, "body") else { return fail(out, 422, "body is required") };
    let Some(slug) = decode_segment(slug) else { return fail(out, 404, "article not found") };
    db(Kind::Write, COMMENT_CREATE, vec![P::I64(viewer), P::Text(slug), P::Text(text.to_string())], Cont::CommentCreate)
}

// ---------------------------------------------------------------- helpers

fn db(kind: Kind, stmt: usize, params: Vec<P>, cont: Cont) -> Next {
    Next::Db(kind, vec![(stmt, params)], cont)
}

pub fn fail(out: &mut Vec<u8>, status: u16, msg: &str) -> Next {
    out.clear();
    json::error(out, msg);
    Next::Respond(status)
}

fn with_seg(seg: &str, out: &mut Vec<u8>, f: impl FnOnce(String, &mut Vec<u8>) -> Next) -> Next {
    match decode_segment(seg) {
        Some(s) if !s.is_empty() => f(s, out),
        _ => fail(out, 404, "not found"),
    }
}

fn required(ctx: &Ctx, req: &Req, out: &mut Vec<u8>) -> Result<i64, Next> {
    match ctx.jwt.check(req.auth, ctx.now) {
        Auth::User(id) => Ok(id),
        _ => Err(fail(out, 401, "unauthorized")),
    }
}

fn optional(ctx: &Ctx, req: &Req, out: &mut Vec<u8>) -> Result<i64, Next> {
    match ctx.jwt.check(req.auth, ctx.now) {
        Auth::User(id) => Ok(id),
        Auth::Anonymous => Ok(0),
        Auth::Invalid => Err(fail(out, 401, "unauthorized")),
    }
}

/// The presented token (only called after `required` accepted it).
fn token_of(req: &Req) -> String {
    req.auth
        .and_then(|h| h.strip_prefix(b"Token "))
        .and_then(|t| std::str::from_utf8(t).ok())
        .unwrap_or_default()
        .to_string()
}

fn last_rows(res: &[StmtResult]) -> &[Row] {
    res.last().map_or(&[], |r| &r.rows[..])
}

fn parse_body(body: &[u8]) -> Option<Value> {
    serde_json::from_slice(body).ok()
}

fn wrapper<'a>(body: &'a Value, key: &str) -> Option<&'a Map<String, Value>> {
    body.as_object()?.get(key)?.as_object()
}

fn req_str<'a>(obj: &'a Map<String, Value>, key: &str) -> Result<&'a str, ()> {
    match obj.get(key) {
        Some(Value::String(s)) if !s.is_empty() && !s.contains('\0') => Ok(s),
        _ => Err(()),
    }
}

/// Absent or null: unchanged. A string must be non-empty when `nonempty`. Any other type is invalid.
fn opt_str<'a>(obj: &'a Map<String, Value>, key: &str, nonempty: bool) -> Result<Option<&'a str>, ()> {
    match obj.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) if (!nonempty || !s.is_empty()) && !s.contains('\0') => Ok(Some(s)),
        _ => Err(()),
    }
}

#[derive(Default)]
struct Query {
    limit: Option<String>,
    offset: Option<String>,
    tag: Option<String>,
    author: Option<String>,
    favorited: Option<String>,
}

impl Query {
    /// First occurrence of each parameter wins; empty filters count as absent.
    fn parse(query: &str) -> Query {
        let mut q = Query::default();
        for (k, v) in form_urlencoded::parse(query.as_bytes()) {
            let slot = match &*k {
                "limit" => &mut q.limit,
                "offset" => &mut q.offset,
                "tag" if !v.is_empty() => &mut q.tag,
                "author" if !v.is_empty() => &mut q.author,
                "favorited" if !v.is_empty() => &mut q.favorited,
                _ => continue,
            };
            if slot.is_none() {
                *slot = Some(v.into_owned());
            }
        }
        q
    }

    fn page(&self) -> Option<(i64, i64)> {
        let limit = match &self.limit {
            None => 20,
            Some(v) => parse_digits_i64(v).filter(|l| (1..=100).contains(l))?,
        };
        let offset = match &self.offset {
            None => 0,
            Some(v) => parse_digits_i64(v)?,
        };
        Some((limit, offset))
    }
}

fn write_profile(out: &mut Vec<u8>, username: &str, bio: Option<&str>, image: Option<&str>, following: bool) {
    out.extend_from_slice(b"{\"username\":");
    json::str(out, username);
    out.extend_from_slice(b",\"bio\":");
    json::opt_str(out, bio);
    out.extend_from_slice(b",\"image\":");
    json::opt_str(out, image);
    out.extend_from_slice(b",\"following\":");
    json::bool(out, following);
    out.push(b'}');
}

/// An article from columns starting at `b`: id, slug, title, description, [body], created_at, updated_at, tag_list,
/// favorites_count, favorited, username, bio, image, following.
fn write_article(out: &mut Vec<u8>, r: &Row, b: usize, full: bool) {
    let k = b + full as usize;
    out.extend_from_slice(b"{\"slug\":");
    json::str(out, r.str(b + 1));
    out.extend_from_slice(b",\"title\":");
    json::str(out, r.str(b + 2));
    out.extend_from_slice(b",\"description\":");
    json::str(out, r.str(b + 3));
    if full {
        out.extend_from_slice(b",\"body\":");
        json::str(out, r.str(b + 4));
    }
    out.extend_from_slice(b",\"tagList\":[");
    let mut first = true;
    r.text_array(k + 6, |t| {
        if !std::mem::take(&mut first) {
            out.push(b',');
        }
        json::str(out, t);
    });
    out.extend_from_slice(b"],\"createdAt\":");
    json::ts(out, r.ts(k + 4));
    out.extend_from_slice(b",\"updatedAt\":");
    json::ts(out, r.ts(k + 5));
    out.extend_from_slice(b",\"favorited\":");
    json::bool(out, r.bool(k + 8));
    out.extend_from_slice(b",\"favoritesCount\":");
    json::int(out, r.i64(k + 7));
    out.extend_from_slice(b",\"author\":");
    write_profile(out, r.str(k + 9), r.opt_str(k + 10), r.opt_str(k + 11), r.bool(k + 12));
    out.push(b'}');
}

fn article_envelope(out: &mut Vec<u8>, r: &Row, status: u16) -> Next {
    out.extend_from_slice(b"{\"article\":");
    write_article(out, r, 0, true);
    out.push(b'}');
    Next::Respond(status)
}

#[allow(clippy::too_many_arguments)]
fn write_comment(
    out: &mut Vec<u8>,
    id: i64,
    body: &str,
    created: i64,
    updated: i64,
    username: &str,
    bio: Option<&str>,
    image: Option<&str>,
    following: bool,
) {
    out.extend_from_slice(b"{\"id\":");
    json::int(out, id);
    out.extend_from_slice(b",\"createdAt\":");
    json::ts(out, created);
    out.extend_from_slice(b",\"updatedAt\":");
    json::ts(out, updated);
    out.extend_from_slice(b",\"body\":");
    json::str(out, body);
    out.extend_from_slice(b",\"author\":");
    write_profile(out, username, bio, image, following);
    out.push(b'}');
}

fn user_envelope(out: &mut Vec<u8>, email: &str, token: &str, username: &str, bio: Option<&str>, image: Option<&str>) {
    out.extend_from_slice(b"{\"user\":{\"email\":");
    json::str(out, email);
    out.extend_from_slice(b",\"token\":");
    json::str(out, token);
    out.extend_from_slice(b",\"username\":");
    json::str(out, username);
    out.extend_from_slice(b",\"bio\":");
    json::opt_str(out, bio);
    out.extend_from_slice(b",\"image\":");
    json::opt_str(out, image);
    out.extend_from_slice(b"}}");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn query_rules() {
        let page = |q: &str| Query::parse(q).page();
        assert_eq!(page(""), Some((20, 0)));
        assert_eq!(page("limit=05&offset=005"), Some((5, 5)));
        for bad in ["limit=0", "limit=101", "limit=-1", "limit=abc", "limit=", "limit=1.5", "limit=%2B5", "limit=%205",
                    "offset=-1", "offset=abc", "offset=", "offset=99999999999999999999"] {
            assert_eq!(page(bad), None, "{bad}");
        }
        assert_eq!(page("limit=3&limit=500"), Some((3, 0)));
        let q = Query::parse("tag=&author=bob&favorited=al");
        assert_eq!((q.tag, q.author.as_deref()), (None, Some("bob")));
    }

    #[test]
    fn strings() {
        let v: Value = serde_json::from_str(r#"{"u":{"a":"x","b":"","c":null,"d":5,"e":"n\u0000"}}"#).unwrap();
        let u = wrapper(&v, "u").unwrap();
        assert_eq!(req_str(u, "a"), Ok("x"));
        assert!(req_str(u, "b").is_err() && req_str(u, "c").is_err() && req_str(u, "z").is_err() && req_str(u, "e").is_err());
        assert_eq!(opt_str(u, "b", false), Ok(Some("")));
        assert!(opt_str(u, "b", true).is_err() && opt_str(u, "d", false).is_err());
        assert_eq!(opt_str(u, "c", true), Ok(None));
        assert!(wrapper(&serde_json::from_str::<Value>(r#"{"u":"x"}"#).unwrap(), "u").is_none());
    }
}

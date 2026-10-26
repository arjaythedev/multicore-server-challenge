use serde_json::{Map, Value};

use crate::http::{self, Method, Request};
use crate::json;
use crate::jwt::Jwt;
use crate::pg::{P, PgResult, Row, bind_exec};
use crate::sql;

#[derive(Clone, Copy, PartialEq, Eq)]
pub struct ClientRef {
    pub slot: u32,
    pub generation: u32,
}

pub struct Job {
    pub client: ClientRef,
    pub kind: Kind,
}

pub enum Kind {
    Tags,
    List,
    Article {
        stmt: u16,
        status: u16,
    },
    Comments,
    CommentCreated,
    CommentDelete {
        viewer: i64,
    },
    Profile,
    Follow {
        following: bool,
    },
    UserGet {
        token: Vec<u8>,
    },
    UserUpdate {
        token: Vec<u8>,
    },
    UserUpdateHash {
        viewer: i64,
        token: Vec<u8>,
        fields: [Option<Vec<u8>>; 4],
    },
    Login {
        password: Vec<u8>,
    },
    LoginVerify {
        user: Vec<u8>,
        id: i64,
    },
    Register,
    RegisterHash {
        username: Vec<u8>,
        email: Vec<u8>,
    },
    ArticleUpdate {
        viewer: i64,
    },
    ArticleDelete {
        viewer: i64,
    },
}

pub enum Val {
    I64(i64),
    Text(Vec<u8>),
}

pub struct ReadReq {
    pub stmt: usize,
    pub vals: Vec<Val>,
}

pub struct PgReq {
    pub msgs: Vec<u8>,
    pub read: Option<ReadReq>,
    pub write: bool,
    pub batchable: bool,
    pub stmts: u16,
    pub job: Job,
}

impl PgReq {
    pub fn new(msgs: Vec<u8>, write: bool, job: Job) -> PgReq {
        let batchable = write
            && !matches!(
                job.kind,
                Kind::Register | Kind::UserUpdate { .. } | Kind::Article { status: 201, .. }
            );
        let mut stmts = 0;
        let mut p = 0;
        while p + 5 <= msgs.len() {
            if msgs[p] == b'E' {
                stmts += 1;
            }
            p += 1 + u32::from_be_bytes(msgs[p + 1..p + 5].try_into().unwrap()) as usize;
        }
        PgReq {
            msgs,
            read: None,
            write,
            batchable,
            stmts,
            job,
        }
    }

    pub fn read(stmt: usize, vals: Vec<Val>, job: Job) -> PgReq {
        PgReq {
            msgs: Vec::new(),
            read: Some(ReadReq { stmt, vals }),
            write: false,
            batchable: false,
            stmts: 1,
            job,
        }
    }
}

pub enum Work {
    Hash(Vec<u8>),
    Verify(Vec<u8>, Vec<u8>),
}

pub enum CryptDone {
    Hashed(Vec<u8>),
    Verified(bool),
    Failed,
}

pub struct CryptReq {
    pub work: Work,
    pub job: Job,
}

#[derive(Default)]
pub struct Effects {
    pub pg: Vec<PgReq>,
    pub crypt: Vec<CryptReq>,
}

pub enum Reply {
    Now(u16),
    Later,
}

pub struct Api {
    jwt: Jwt,
    app_sort: bool,
}

fn err(out: &mut Vec<u8>, status: u16, msg: &str) -> Reply {
    json::error(out, msg);
    Reply::Now(status)
}

enum Auth {
    None,
    User(i64),
    Invalid,
}

enum Field<'a> {
    Absent,
    Str(&'a str),
    Bad,
}

fn field<'a>(m: &'a Map<String, Value>, key: &str) -> Field<'a> {
    match m.get(key) {
        None | Some(Value::Null) => Field::Absent,
        Some(Value::String(s)) => Field::Str(s),
        Some(_) => Field::Bad,
    }
}

fn required<'a>(m: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    match field(m, key) {
        Field::Str(s) if !s.is_empty() => Some(s),
        _ => None,
    }
}

fn optional<'a>(
    m: &'a Map<String, Value>,
    key: &str,
    non_empty: bool,
) -> Result<Option<&'a str>, ()> {
    match field(m, key) {
        Field::Absent => Ok(None),
        Field::Str(s) if !non_empty || !s.is_empty() => Ok(Some(s)),
        _ => Err(()),
    }
}

fn wrapped(body: &[u8], key: &str) -> Option<Map<String, Value>> {
    match serde_json::from_slice::<Value>(body).ok()? {
        Value::Object(mut m) => match m.remove(key)? {
            Value::Object(inner) => Some(inner),
            _ => None,
        },
        _ => None,
    }
}

fn parse_uint(v: &[u8]) -> Option<i64> {
    if v.is_empty() || v.len() > 19 || !v.iter().all(u8::is_ascii_digit) {
        return None;
    }
    std::str::from_utf8(v).ok()?.parse().ok()
}

pub fn slugify(title: &str) -> Vec<u8> {
    let mut out = Vec::with_capacity(title.len());
    let mut dash = false;
    for &c in title.as_bytes() {
        if c.is_ascii_alphanumeric() {
            if dash && !out.is_empty() {
                out.push(b'-');
            }
            dash = false;
            out.push(c.to_ascii_lowercase());
        } else {
            dash = true;
        }
    }
    out
}

struct Segments<'a> {
    parts: [&'a [u8]; 5],
    len: usize,
}

fn split_path(path: &[u8]) -> Option<Segments<'_>> {
    let rest = path.strip_prefix(b"/api/")?;
    let rest = rest.strip_suffix(b"/").unwrap_or(rest);
    let mut seg = Segments {
        parts: [b""; 5],
        len: 0,
    };
    for part in rest.split(|&c| c == b'/') {
        if seg.len == 5 {
            return None;
        }
        seg.parts[seg.len] = part;
        seg.len += 1;
    }
    Some(seg)
}

impl Api {
    pub fn new(secret: &[u8], app_sort: bool) -> Api {
        Api {
            jwt: Jwt::new(secret),
            app_sort,
        }
    }

    fn auth(&self, req: &Request) -> Auth {
        let Some(h) = req.auth else {
            return Auth::None;
        };
        match h.strip_prefix(b"Token ").and_then(|t| self.jwt.verify(t)) {
            Some(id) => Auth::User(id),
            None => Auth::Invalid,
        }
    }

    pub fn handle(
        &self,
        req: &Request,
        client: ClientRef,
        out: &mut Vec<u8>,
        fx: &mut Effects,
    ) -> Reply {
        let Some(seg) = split_path(req.path) else {
            return err(out, 404, "not found");
        };
        let p = &seg.parts[..seg.len];
        let m = req.method;
        let tags_only = m == Method::Get && p == [b"tags"];
        let auth = if tags_only {
            Auth::None
        } else {
            self.auth(req)
        };
        let viewer = match auth {
            Auth::Invalid => return err(out, 401, "invalid token"),
            Auth::User(id) => id,
            Auth::None => 0,
        };
        let job = |kind| Job { client, kind };
        macro_rules! need_auth {
            () => {
                if viewer == 0 {
                    return err(out, 401, "authentication required");
                }
            };
        }
        let mut msgs = Vec::with_capacity(128);
        let write;
        let kind;
        match (m, p) {
            (Method::Get, [b"tags"]) => {
                fx.pg
                    .push(PgReq::read(sql::TAGS, vec![Val::I64(0)], job(Kind::Tags)));
                return Reply::Later;
            }
            (Method::Get, [b"articles"]) | (Method::Get, [b"articles", b"feed"]) => {
                let feed = p.len() == 2;
                if feed {
                    need_auth!();
                }
                let Some((limit, offset, stmt, filter)) = parse_list_query(req.query) else {
                    return err(out, 422, "invalid limit or offset");
                };
                let stmt = if feed { sql::LIST_FEED } else { stmt };
                let vals = vec![
                    Val::I64(viewer),
                    Val::I64(limit),
                    Val::I64(offset),
                    Val::Text(filter),
                ];
                fx.pg.push(PgReq::read(stmt, vals, job(Kind::List)));
                return Reply::Later;
            }
            (Method::Get, [b"articles", slug]) => {
                let vals = vec![Val::I64(viewer), Val::Text(http::pct_decode(slug, false))];
                let kind = Kind::Article {
                    stmt: 0,
                    status: 200,
                };
                fx.pg
                    .push(PgReq::read(sql::ARTICLE_BY_SLUG, vals, job(kind)));
                return Reply::Later;
            }
            (Method::Get, [b"articles", slug, b"comments"]) => {
                let vals = vec![Val::I64(viewer), Val::Text(http::pct_decode(slug, false))];
                fx.pg
                    .push(PgReq::read(sql::COMMENTS, vals, job(Kind::Comments)));
                return Reply::Later;
            }
            (Method::Get, [b"profiles", name]) => {
                let vals = vec![Val::I64(viewer), Val::Text(http::pct_decode(name, false))];
                fx.pg
                    .push(PgReq::read(sql::PROFILE, vals, job(Kind::Profile)));
                return Reply::Later;
            }
            (Method::Get, [b"user"]) => {
                need_auth!();
                let kind = Kind::UserGet {
                    token: req.auth.unwrap_or(b"")[6..].to_vec(),
                };
                fx.pg.push(PgReq::read(
                    sql::USER_BY_ID,
                    vec![Val::I64(viewer)],
                    job(kind),
                ));
                return Reply::Later;
            }
            (Method::Post | Method::Delete, [b"profiles", name, b"follow"]) => {
                need_auth!();
                let name = http::pct_decode(name, false);
                let following = m == Method::Post;
                let stmt = if following {
                    sql::FOLLOW
                } else {
                    sql::UNFOLLOW
                };
                bind_exec(&mut msgs, stmt, &[P::I64(viewer), P::Text(&name)]);
                write = true;
                kind = Kind::Follow { following };
            }
            (Method::Post | Method::Delete, [b"articles", slug, b"favorite"]) => {
                need_auth!();
                let slug = http::pct_decode(slug, false);
                let stmt = if m == Method::Post {
                    sql::FAVORITE
                } else {
                    sql::UNFAVORITE
                };
                bind_exec(&mut msgs, stmt, &[P::I64(viewer), P::Text(&slug)]);
                bind_exec(
                    &mut msgs,
                    sql::ARTICLE_BY_SLUG,
                    &[P::I64(viewer), P::Text(&slug)],
                );
                write = true;
                kind = Kind::Article {
                    stmt: 1,
                    status: 200,
                };
            }
            (Method::Post, [b"articles", slug, b"comments"]) => {
                need_auth!();
                let Some(c) = wrapped(req.body, "comment") else {
                    return err(out, 422, "comment wrapper required");
                };
                let Some(body) = required(&c, "body") else {
                    return err(out, 422, "body is required");
                };
                let slug = http::pct_decode(slug, false);
                bind_exec(
                    &mut msgs,
                    sql::COMMENT_INSERT,
                    &[P::I64(viewer), P::Text(&slug), P::Text(body.as_bytes())],
                );
                write = true;
                kind = Kind::CommentCreated;
            }
            (Method::Delete, [b"articles", slug, b"comments", id]) => {
                need_auth!();
                let Some(id) = parse_uint(id) else {
                    return err(out, 404, "comment not found");
                };
                let slug = http::pct_decode(slug, false);
                bind_exec(
                    &mut msgs,
                    sql::COMMENT_DELETE,
                    &[P::I64(viewer), P::I64(id), P::Text(&slug)],
                );
                write = true;
                kind = Kind::CommentDelete { viewer };
            }
            (Method::Post, [b"users", b"login"]) => {
                let Some(u) = wrapped(req.body, "user") else {
                    return err(out, 422, "user wrapper required");
                };
                let (Some(email), Some(password)) =
                    (required(&u, "email"), required(&u, "password"))
                else {
                    return err(out, 422, "email and password are required");
                };
                bind_exec(&mut msgs, sql::USER_BY_EMAIL, &[P::Text(email.as_bytes())]);
                write = false;
                kind = Kind::Login {
                    password: password.as_bytes().to_vec(),
                };
            }
            (Method::Post, [b"users"]) => {
                let Some(u) = wrapped(req.body, "user") else {
                    return err(out, 422, "user wrapper required");
                };
                let (Some(username), Some(email), Some(password)) = (
                    required(&u, "username"),
                    required(&u, "email"),
                    required(&u, "password"),
                ) else {
                    return err(out, 422, "username, email and password are required");
                };
                if password.len() > 72 {
                    return err(out, 422, "password is longer than 72 bytes");
                }
                fx.crypt.push(CryptReq {
                    work: Work::Hash(password.as_bytes().to_vec()),
                    job: job(Kind::RegisterHash {
                        username: username.as_bytes().to_vec(),
                        email: email.as_bytes().to_vec(),
                    }),
                });
                return Reply::Later;
            }
            (Method::Put, [b"user"]) => {
                need_auth!();
                let Some(u) = wrapped(req.body, "user") else {
                    return err(out, 422, "user wrapper required");
                };
                let parsed = (
                    optional(&u, "email", true),
                    optional(&u, "username", true),
                    optional(&u, "password", true),
                    optional(&u, "bio", false),
                    optional(&u, "image", false),
                );
                let (Ok(email), Ok(username), Ok(password), Ok(bio), Ok(image)) = parsed else {
                    return err(out, 422, "invalid user fields");
                };
                let token = req.auth.unwrap_or(b"")[6..].to_vec();
                let own = |s: Option<&str>| s.map(|s| s.as_bytes().to_vec());
                let fields = [own(email), own(username), own(bio), own(image)];
                if let Some(password) = password {
                    if password.len() > 72 {
                        return err(out, 422, "password is longer than 72 bytes");
                    }
                    fx.crypt.push(CryptReq {
                        work: Work::Hash(password.as_bytes().to_vec()),
                        job: job(Kind::UserUpdateHash {
                            viewer,
                            token,
                            fields,
                        }),
                    });
                    return Reply::Later;
                }
                fx.pg
                    .push(user_update(client, viewer, token, &fields, None));
                return Reply::Later;
            }
            (Method::Post, [b"articles"]) => {
                need_auth!();
                let Some(a) = wrapped(req.body, "article") else {
                    return err(out, 422, "article wrapper required");
                };
                let (Some(title), Some(description), Some(body)) = (
                    required(&a, "title"),
                    required(&a, "description"),
                    required(&a, "body"),
                ) else {
                    return err(out, 422, "title, description and body are required");
                };
                let mut tags: Vec<Vec<u8>> = Vec::new();
                match a.get("tagList") {
                    None | Some(Value::Null) => {}
                    Some(Value::Array(items)) => {
                        for it in items {
                            match it {
                                Value::String(s) if !s.is_empty() => {
                                    tags.push(s.as_bytes().to_vec())
                                }
                                _ => return err(out, 422, "tagList must hold non-empty strings"),
                            }
                        }
                    }
                    Some(_) => return err(out, 422, "tagList must be an array"),
                }
                tags.sort();
                tags.dedup();
                let slug = slugify(title);
                bind_exec(
                    &mut msgs,
                    sql::ARTICLE_INSERT,
                    &[
                        P::I64(viewer),
                        P::Text(title.as_bytes()),
                        P::Text(description.as_bytes()),
                        P::Text(body.as_bytes()),
                        P::Text(&slug),
                    ],
                );
                let mut stmt = 1;
                if !tags.is_empty() {
                    bind_exec(&mut msgs, sql::TAGS_INSERT, &[P::TextArray(&tags)]);
                    bind_exec(&mut msgs, sql::ARTICLE_TAGS_INSERT, &[P::TextArray(&tags)]);
                    stmt = 3;
                }
                bind_exec(&mut msgs, sql::ARTICLE_BY_CURRVAL, &[P::I64(viewer)]);
                write = true;
                kind = Kind::Article { stmt, status: 201 };
            }
            (Method::Put, [b"articles", slug]) => {
                need_auth!();
                let Some(a) = wrapped(req.body, "article") else {
                    return err(out, 422, "article wrapper required");
                };
                let parsed = (
                    optional(&a, "title", true),
                    optional(&a, "description", true),
                    optional(&a, "body", true),
                );
                let (Ok(title), Ok(description), Ok(body)) = parsed else {
                    return err(out, 422, "invalid article fields");
                };
                let slug = http::pct_decode(slug, false);
                let new_slug = slugify(title.unwrap_or(""));
                bind_exec(
                    &mut msgs,
                    sql::ARTICLE_UPDATE,
                    &[
                        P::I64(viewer),
                        P::Text(&slug),
                        P::OptText(title.map(str::as_bytes)),
                        P::OptText(description.map(str::as_bytes)),
                        P::OptText(body.map(str::as_bytes)),
                        P::Text(&new_slug),
                    ],
                );
                write = true;
                kind = Kind::ArticleUpdate { viewer };
            }
            (Method::Delete, [b"articles", slug]) => {
                need_auth!();
                let slug = http::pct_decode(slug, false);
                bind_exec(
                    &mut msgs,
                    sql::ARTICLE_DELETE,
                    &[P::I64(viewer), P::Text(&slug)],
                );
                write = true;
                kind = Kind::ArticleDelete { viewer };
            }
            _ => return err(out, 404, "not found"),
        }
        fx.pg.push(PgReq::new(msgs, write, job(kind)));
        Reply::Later
    }

    pub fn on_pg(&self, job: Job, res: &PgResult, out: &mut Vec<u8>, fx: &mut Effects) -> Reply {
        if let Some(e) = &res.err {
            return match job.kind {
                Kind::Register | Kind::UserUpdate { .. } if e.is("23505") => {
                    err(out, 422, "username or email is already taken")
                }
                _ if e.is("08006") => err(out, 503, "database unavailable"),
                _ => {
                    eprintln!(
                        "postgres error {}: {}",
                        String::from_utf8_lossy(&e.code),
                        e.message
                    );
                    err(out, 500, "database error")
                }
            };
        }
        match job.kind {
            Kind::Tags => {
                let mut names = Vec::new();
                if let Some(mut row) = res.first(0) {
                    row.text_array(&mut names);
                }
                if self.app_sort {
                    names.sort_unstable();
                }
                out.extend_from_slice(b"{\"tags\":[");
                for (i, n) in names.iter().enumerate() {
                    if i > 0 {
                        out.push(b',');
                    }
                    json::string(out, n);
                }
                out.extend_from_slice(b"]}");
                Reply::Now(200)
            }
            Kind::List => {
                let mut count = 0;
                let mut first = true;
                let mut tags = Vec::new();
                out.extend_from_slice(b"{\"articles\":[");
                for mut row in res.rows(0) {
                    count = row.i64();
                    if row.next_is_null() {
                        continue;
                    }
                    row.field();
                    if !first {
                        out.push(b',');
                    }
                    first = false;
                    self.article(out, &mut row, false, &mut tags);
                }
                out.extend_from_slice(b"],\"articlesCount\":");
                json::int(out, count);
                out.push(b'}');
                Reply::Now(200)
            }
            Kind::Article { stmt, status } => {
                let Some(mut row) = res.first(stmt) else {
                    return err(out, 404, "article not found");
                };
                row.field();
                out.extend_from_slice(b"{\"article\":");
                self.article(out, &mut row, true, &mut Vec::new());
                out.push(b'}');
                Reply::Now(status)
            }
            Kind::ArticleUpdate { viewer } => {
                let Some(mut row) = res.first(0) else {
                    return err(out, 404, "article not found");
                };
                if row.i64() != viewer {
                    return err(out, 403, "not the author");
                }
                row.field();
                out.extend_from_slice(b"{\"article\":");
                self.article(out, &mut row, true, &mut Vec::new());
                out.push(b'}');
                Reply::Now(200)
            }
            Kind::ArticleDelete { viewer } | Kind::CommentDelete { viewer } => {
                let Some(mut row) = res.first(0) else {
                    return err(out, 404, "not found");
                };
                if row.i64() != viewer {
                    return err(out, 403, "not the author");
                }
                Reply::Now(204)
            }
            Kind::Comments => {
                let mut rows = res.rows(0).peekable();
                if rows.peek().is_none() {
                    return err(out, 404, "article not found");
                }
                out.extend_from_slice(b"{\"comments\":[");
                let mut first = true;
                for mut row in rows {
                    if row.next_is_null() {
                        continue;
                    }
                    if !first {
                        out.push(b',');
                    }
                    first = false;
                    comment(out, &mut row, None);
                }
                out.extend_from_slice(b"]}");
                Reply::Now(200)
            }
            Kind::CommentCreated => {
                let Some(mut row) = res.first(0) else {
                    return err(out, 404, "article not found");
                };
                out.extend_from_slice(b"{\"comment\":");
                comment(out, &mut row, Some(false));
                out.push(b'}');
                Reply::Now(201)
            }
            Kind::Profile => {
                let Some(mut row) = res.first(0) else {
                    return err(out, 404, "profile not found");
                };
                out.extend_from_slice(b"{\"profile\":");
                profile(out, &mut row, None);
                out.push(b'}');
                Reply::Now(200)
            }
            Kind::Follow { following } => {
                let Some(mut row) = res.first(0) else {
                    return err(out, 404, "profile not found");
                };
                out.extend_from_slice(b"{\"profile\":");
                profile(out, &mut row, Some(following));
                out.push(b'}');
                Reply::Now(200)
            }
            Kind::UserGet { token } | Kind::UserUpdate { token } => {
                let Some(mut row) = res.first(0) else {
                    return err(out, 401, "user not found");
                };
                row.field();
                user(out, &mut row, &token);
                Reply::Now(200)
            }
            Kind::Register => {
                let Some(mut row) = res.first(0) else {
                    return err(out, 500, "insert returned nothing");
                };
                let id = row.i64();
                let mut token = Vec::with_capacity(160);
                self.jwt.issue(id, &mut token);
                user(out, &mut row, &token);
                Reply::Now(201)
            }
            Kind::Login { password } => {
                let Some(mut row) = res.first(0) else {
                    return err(out, 401, "invalid email or password");
                };
                let id = row.i64();
                let mut user_json = Vec::with_capacity(256);
                let username = row.text();
                let email = row.text();
                let bio = row.opt_text();
                let image = row.opt_text();
                user_fields(&mut user_json, email, username, bio, image);
                let hash = row.text().to_vec();
                fx.crypt.push(CryptReq {
                    work: Work::Verify(password, hash),
                    job: Job {
                        client: job.client,
                        kind: Kind::LoginVerify {
                            user: user_json,
                            id,
                        },
                    },
                });
                Reply::Later
            }
            _ => err(out, 500, "unexpected continuation"),
        }
    }

    pub fn on_crypt(
        &self,
        job: Job,
        done: CryptDone,
        out: &mut Vec<u8>,
        fx: &mut Effects,
    ) -> Reply {
        match (job.kind, done) {
            (Kind::LoginVerify { user, id }, CryptDone::Verified(true)) => {
                out.extend_from_slice(b"{\"user\":{\"token\":\"");
                self.jwt.issue(id, out);
                out.extend_from_slice(b"\",");
                out.extend_from_slice(&user);
                out.extend_from_slice(b"}}");
                Reply::Now(200)
            }
            (Kind::LoginVerify { .. }, _) => err(out, 401, "invalid email or password"),
            (Kind::RegisterHash { username, email }, CryptDone::Hashed(hash)) => {
                let mut msgs = Vec::with_capacity(160);
                bind_exec(
                    &mut msgs,
                    sql::USER_INSERT,
                    &[P::Text(&username), P::Text(&email), P::Text(&hash)],
                );
                let job = Job {
                    client: job.client,
                    kind: Kind::Register,
                };
                fx.pg.push(PgReq::new(msgs, true, job));
                Reply::Later
            }
            (
                Kind::UserUpdateHash {
                    viewer,
                    token,
                    fields,
                },
                CryptDone::Hashed(hash),
            ) => {
                fx.pg
                    .push(user_update(job.client, viewer, token, &fields, Some(&hash)));
                Reply::Later
            }
            _ => err(out, 500, "password hashing failed"),
        }
    }

    fn article<'a>(
        &self,
        out: &mut Vec<u8>,
        row: &mut Row<'a>,
        with_body: bool,
        tags: &mut Vec<&'a [u8]>,
    ) {
        out.extend_from_slice(b"{\"slug\":");
        json::string(out, row.text());
        out.extend_from_slice(b",\"title\":");
        json::string(out, row.text());
        out.extend_from_slice(b",\"description\":");
        json::string(out, row.text());
        if with_body {
            out.extend_from_slice(b",\"body\":");
            json::string(out, row.text());
        }
        out.extend_from_slice(b",\"createdAt\":");
        json::timestamp(out, row.i64());
        out.extend_from_slice(b",\"updatedAt\":");
        json::timestamp(out, row.i64());
        row.text_array(tags);
        if self.app_sort {
            tags.sort_unstable();
        }
        out.extend_from_slice(b",\"tagList\":[");
        for (i, t) in tags.iter().enumerate() {
            if i > 0 {
                out.push(b',');
            }
            json::string(out, t);
        }
        out.extend_from_slice(b"],\"favoritesCount\":");
        json::int(out, row.i64());
        out.extend_from_slice(b",\"favorited\":");
        json::boolean(out, row.boolean());
        out.extend_from_slice(b",\"author\":");
        profile(out, row, None);
        out.push(b'}');
    }
}

fn parse_list_query(q: &[u8]) -> Option<(i64, i64, usize, Vec<u8>)> {
    let mut limit = 20;
    let mut offset = 0;
    let mut tag = Vec::new();
    let mut author = Vec::new();
    let mut favorited = Vec::new();
    for pair in q.split(|&c| c == b'&') {
        if pair.is_empty() {
            continue;
        }
        let (k, v) = match pair.iter().position(|&c| c == b'=') {
            Some(i) => (&pair[..i], &pair[i + 1..]),
            None => (pair, &b""[..]),
        };
        match k {
            b"limit" => {
                limit = parse_uint(&http::pct_decode(v, true)).filter(|n| (1..=100).contains(n))?;
            }
            b"offset" => offset = parse_uint(&http::pct_decode(v, true))?,
            b"tag" => tag = http::pct_decode(v, true),
            b"author" => author = http::pct_decode(v, true),
            b"favorited" => favorited = http::pct_decode(v, true),
            _ => {}
        }
    }
    let (stmt, filter) = if !tag.is_empty() {
        (sql::LIST_TAG, tag)
    } else if !author.is_empty() {
        (sql::LIST_AUTHOR, author)
    } else if !favorited.is_empty() {
        (sql::LIST_FAVORITED, favorited)
    } else {
        (sql::LIST_GLOBAL, Vec::new())
    };
    Some((limit, offset, stmt, filter))
}

fn user_update(
    client: ClientRef,
    viewer: i64,
    token: Vec<u8>,
    fields: &[Option<Vec<u8>>; 4],
    hash: Option<&[u8]>,
) -> PgReq {
    let mut msgs = Vec::with_capacity(160);
    bind_exec(
        &mut msgs,
        sql::USER_UPDATE,
        &[
            P::I64(viewer),
            P::OptText(fields[0].as_deref()),
            P::OptText(fields[1].as_deref()),
            P::OptText(hash),
            P::OptText(fields[2].as_deref()),
            P::OptText(fields[3].as_deref()),
        ],
    );
    PgReq::new(
        msgs,
        true,
        Job {
            client,
            kind: Kind::UserUpdate { token },
        },
    )
}

fn user_fields(
    out: &mut Vec<u8>,
    email: &[u8],
    username: &[u8],
    bio: Option<&[u8]>,
    image: Option<&[u8]>,
) {
    out.extend_from_slice(b"\"email\":");
    json::string(out, email);
    out.extend_from_slice(b",\"username\":");
    json::string(out, username);
    out.extend_from_slice(b",\"bio\":");
    json::opt_string(out, bio);
    out.extend_from_slice(b",\"image\":");
    json::opt_string(out, image);
}

fn user(out: &mut Vec<u8>, row: &mut Row, token: &[u8]) {
    let username = row.text();
    let email = row.text();
    let bio = row.opt_text();
    let image = row.opt_text();
    out.extend_from_slice(b"{\"user\":{\"token\":");
    json::string(out, token);
    out.push(b',');
    user_fields(out, email, username, bio, image);
    out.extend_from_slice(b"}}");
}

fn profile(out: &mut Vec<u8>, row: &mut Row, following: Option<bool>) {
    out.extend_from_slice(b"{\"username\":");
    json::string(out, row.text());
    out.extend_from_slice(b",\"bio\":");
    json::opt_string(out, row.opt_text());
    out.extend_from_slice(b",\"image\":");
    json::opt_string(out, row.opt_text());
    out.extend_from_slice(b",\"following\":");
    let f = match following {
        Some(f) => f,
        None => row.boolean(),
    };
    json::boolean(out, f);
    out.push(b'}');
}

fn comment(out: &mut Vec<u8>, row: &mut Row, following: Option<bool>) {
    out.extend_from_slice(b"{\"id\":");
    json::int(out, row.i64());
    let body = row.text();
    out.extend_from_slice(b",\"createdAt\":");
    json::timestamp(out, row.i64());
    out.extend_from_slice(b",\"updatedAt\":");
    json::timestamp(out, row.i64());
    out.extend_from_slice(b",\"body\":");
    json::string(out, body);
    out.extend_from_slice(b",\"author\":");
    profile(out, row, following);
    out.push(b'}');
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugs() {
        assert_eq!(
            slugify("Conformance: Hello, World! 2026"),
            b"conformance-hello-world-2026"
        );
        assert_eq!(
            slugify("  Conformance -- Renamed Title!  "),
            b"conformance-renamed-title"
        );
        assert_eq!(slugify("!!!"), b"");
        assert_eq!(slugify("ab\u{e9}cd"), b"ab-cd");
    }

    #[test]
    fn list_query() {
        assert!(parse_list_query(b"limit=05&offset=005").is_some());
        assert!(parse_list_query(b"limit=%2B5").is_none());
        assert!(parse_list_query(b"limit=").is_none());
        assert!(parse_list_query(b"offset=99999999999999999999").is_none());
        let (_, _, stmt, f) = parse_list_query(b"tag=&author=bob").unwrap();
        assert_eq!(stmt, sql::LIST_AUTHOR);
        assert_eq!(f, b"bob");
    }
}

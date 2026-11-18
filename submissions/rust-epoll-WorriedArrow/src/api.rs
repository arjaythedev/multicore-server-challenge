//! Request routing and validation: turns an HTTP request into an immediate response or a queued job.

use serde_json::Value;

use crate::db::{self, BcryptJob, Read, ReadJob, Write, WriteJob};
use crate::reply::{self, ReplyTo};

pub struct Request<'a> {
    pub method: &'a [u8],
    pub path: &'a [u8],
    pub query: &'a [u8],
    pub auth: Option<&'a [u8]>,
    pub body: &'a [u8],
}

pub enum Outcome {
    Now(u16, Vec<u8>),
    Queued,
}

fn err(status: u16, msg: &str) -> Outcome {
    Outcome::Now(status, reply::error_body(msg))
}

fn hex(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

/// Percent-decodes; `plus` also turns '+' into ' ' (query strings). Invalid escapes, invalid UTF-8 and NUL (which
/// Postgres text can't hold, so it can't match anything) give None.
fn unescape(s: &[u8], plus: bool) -> Option<String> {
    let s = unescape_raw(s, plus)?;
    if s.contains('\0') {
        return None;
    }
    Some(s)
}

fn unescape_raw(s: &[u8], plus: bool) -> Option<String> {
    if !s.iter().any(|&b| b == b'%' || (plus && b == b'+')) {
        return String::from_utf8(s.to_vec()).ok();
    }
    let mut out = Vec::with_capacity(s.len());
    let mut i = 0;
    while i < s.len() {
        match s[i] {
            b'%' => {
                let h = hex(*s.get(i + 1)?)?;
                let l = hex(*s.get(i + 2)?)?;
                out.push(h << 4 | l);
                i += 3;
            }
            b'+' if plus => {
                out.push(b' ');
                i += 1;
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8(out).ok()
}

/// The first value of each query parameter we care about. `None` = absent.
#[derive(Default)]
struct Query {
    /// limit / offset: Some(None) when present but not a plain non-negative integer.
    limit: Option<Option<i64>>,
    offset: Option<Option<i64>>,
    tag: Option<String>,
    author: Option<String>,
    favorited: Option<String>,
    /// A tag/author/favorited value that can't match any row (NUL or invalid UTF-8).
    unmatchable: bool,
}

fn has_escape(s: &[u8]) -> bool {
    s.iter().any(|&b| b == b'%' || b == b'+')
}

/// ASCII digits only, fitting in i64, straight from the query bytes (percent-decoded first only if escaped).
fn query_uint(v: &[u8]) -> Option<i64> {
    if has_escape(v) {
        return unescape(v, true).as_deref().and_then(parse_uint);
    }
    if v.is_empty() || !v.iter().all(|b| b.is_ascii_digit()) {
        return None;
    }
    std::str::from_utf8(v).ok()?.parse().ok()
}

fn parse_query(q: &[u8]) -> Query {
    let mut out = Query::default();
    for part in q.split(|&b| b == b'&') {
        if part.is_empty() {
            continue;
        }
        let (k, v) = match memchr::memchr(b'=', part) {
            Some(i) => (&part[..i], &part[i + 1..]),
            None => (part, &b""[..]),
        };
        // Keys compare as bytes; only an escaped key is decoded first.
        let decoded;
        let k: &[u8] = if has_escape(k) {
            match unescape(k, true) {
                Some(d) => {
                    decoded = d;
                    decoded.as_bytes()
                }
                None => continue,
            }
        } else {
            k
        };
        match k {
            b"limit" if out.limit.is_none() => out.limit = Some(query_uint(v)),
            b"offset" if out.offset.is_none() => out.offset = Some(query_uint(v)),
            b"tag" | b"author" | b"favorited" => {
                let slot = match k {
                    b"tag" => &mut out.tag,
                    b"author" => &mut out.author,
                    _ => &mut out.favorited,
                };
                if slot.is_none() {
                    match unescape(v, true) {
                        Some(v) => *slot = Some(v),
                        None => {
                            *slot = Some(String::new());
                            out.unmatchable = true;
                        }
                    }
                }
            }
            _ => {}
        }
    }
    out
}

/// ASCII digits only, fitting in i64.
fn parse_uint(s: &str) -> Option<i64> {
    if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    s.parse().ok()
}

fn limit_offset(q: &Query) -> Option<(i64, i64)> {
    let mut lim = 20;
    let mut off = 0;
    if let Some(l) = q.limit {
        lim = l.filter(|n| (1..=100).contains(n))?;
    }
    if let Some(o) = q.offset {
        // Past any real row count either way; capped so `limit + offset` can't overflow bigint in SQL.
        off = o?.min(i64::MAX / 2);
    }
    Some((lim, off))
}

/// `{"<key>": {...}}` -> the inner object.
fn wrapper(body: &[u8], key: &str) -> Option<serde_json::Map<String, Value>> {
    let v: Value = serde_json::from_slice(body).ok()?;
    match v {
        Value::Object(mut top) => match top.remove(key)? {
            Value::Object(inner) => Some(inner),
            _ => None,
        },
        _ => None,
    }
}

/// True if any string in the object (or its arrays) contains NUL, which Postgres text can't store.
fn has_nul(m: &serde_json::Map<String, Value>) -> bool {
    fn v(x: &Value) -> bool {
        match x {
            Value::String(s) => s.contains('\0'),
            Value::Array(a) => a.iter().any(v),
            Value::Object(o) => o.values().any(v),
            _ => false,
        }
    }
    m.values().any(v)
}

/// A request body object whose strings Postgres can store.
fn body_obj(body: &[u8], key: &str) -> Result<serde_json::Map<String, Value>, Outcome> {
    match wrapper(body, key) {
        Some(m) if has_nul(&m) => Err(err(422, "strings must not contain NUL")),
        Some(m) => Ok(m),
        None => Err(err(422, "invalid body")),
    }
}

/// Absent or null -> Ok(None); a string -> Ok(Some); anything else (or "" with non_empty) -> Err.
fn opt_string(m: &serde_json::Map<String, Value>, k: &str, non_empty: bool) -> Result<Option<String>, ()> {
    match m.get(k) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) if non_empty && s.is_empty() => Err(()),
        Some(Value::String(s)) => Ok(Some(s.clone())),
        Some(_) => Err(()),
    }
}

fn req_string(m: &serde_json::Map<String, Value>, k: &str) -> Result<String, ()> {
    opt_string(m, k, true)?.ok_or(())
}

enum Auth<'a> {
    None,
    Invalid,
    /// The user id and the token as sent (only GET/PUT /api/user echo it back).
    User(i64, &'a [u8]),
}

fn auth<'a>(keys: &crate::jwt::Keys, h: Option<&'a [u8]>) -> Auth<'a> {
    let Some(h) = h else { return Auth::None };
    let Some(tok) = h.strip_prefix(b"Token ") else { return Auth::Invalid };
    match keys.verify(tok) {
        Some(id) => Auth::User(id, tok),
        None => Auth::Invalid,
    }
}

fn read(kind: Read, viewer: i64, to: ReplyTo) -> Outcome {
    db::push_read(ReadJob { kind, viewer, to });
    Outcome::Queued
}

fn write(kind: Write, viewer: i64, to: ReplyTo) -> Outcome {
    db::WRITES.push(WriteJob { kind, viewer, to });
    Outcome::Queued
}

const MAX_PASSWORD: usize = 72;

pub fn handle(keys: &crate::jwt::Keys, r: &Request, to: ReplyTo) -> Outcome {
    // Path segments after /api/ (no route has more than four).
    let mut seg_buf: [&[u8]; 5] = [b""; 5];
    let mut nseg = 0;
    match r.path.strip_prefix(b"/api/") {
        Some(rest) => {
            for s in rest.split(|&b| b == b'/') {
                if nseg == seg_buf.len() {
                    return err(404, "not found");
                }
                seg_buf[nseg] = s;
                nseg += 1;
            }
        }
        None => return err(404, "not found"),
    }
    let segs = &seg_buf[..nseg];
    let m = r.method;
    // Auth variants per route (the token is only checked on routes that use it).
    fn required<'a>(a: Auth<'a>, f: impl FnOnce(i64, &'a [u8]) -> Outcome) -> Outcome {
        match a {
            Auth::User(id, tok) => f(id, tok),
            _ => err(401, "unauthorized"),
        }
    }
    fn optional(a: Auth<'_>, f: impl FnOnce(i64) -> Outcome) -> Outcome {
        match a {
            Auth::User(id, _) => f(id),
            Auth::None => f(0),
            Auth::Invalid => err(401, "unauthorized"),
        }
    }
    let auth = || auth(keys, r.auth);
    let seg = |i: usize| -> Option<String> { segs.get(i).filter(|s| !s.is_empty()).and_then(|s| unescape(s, false)) };

    match (m, segs) {
        (b"GET", [b"tags"]) => read(Read::Tags, 0, to),
        (b"POST", [b"users"]) => register(r.body, to),
        (b"POST", [b"users", b"login"]) => login(r.body, to),
        (b"GET", [b"user"]) => required(auth(), |id, tok| read(Read::CurrentUser { id, token: String::from_utf8_lossy(tok).into_owned() }, id, to)),
        (b"PUT", [b"user"]) => required(auth(), |id, tok| update_user(r.body, id, String::from_utf8_lossy(tok).into_owned(), to)),
        (b"GET", [b"profiles", u]) if !u.is_empty() => {
            let Some(u) = seg(1) else { return err(404, "not found") };
            optional(auth(), |v| read(Read::Profile { username: u }, v, to))
        }
        (b"POST" | b"DELETE", [b"profiles", u, b"follow"]) if !u.is_empty() => {
            let Some(u) = seg(1) else { return err(404, "not found") };
            let on = m == b"POST";
            required(auth(), |v, _| write(Write::Follow { username: u, on }, v, to))
        }
        (b"GET", [b"articles"]) => optional(auth(), |v| list(r.query, v, to)),
        (b"POST", [b"articles"]) => required(auth(), |v, _| create_article(r.body, v, to)),
        (b"GET", [b"articles", b"feed"]) => required(auth(), |v, _| {
            let q = parse_query(r.query);
            match limit_offset(&q) {
                Some((lim, off)) => read(Read::Feed { lim, off }, v, to),
                None => err(422, "limit must be 1-100 and offset >= 0"),
            }
        }),
        (b"GET", [b"articles", s]) if !s.is_empty() => {
            let Some(slug) = seg(1) else { return err(404, "not found") };
            optional(auth(), |v| read(Read::Article { slug: slug }, v, to))
        }
        (b"PUT", [b"articles", s]) if !s.is_empty() => {
            let Some(slug) = seg(1) else { return err(404, "not found") };
            required(auth(), |v, _| update_article(r.body, slug, v, to))
        }
        (b"DELETE", [b"articles", s]) if !s.is_empty() => {
            let Some(slug) = seg(1) else { return err(404, "not found") };
            required(auth(), |v, _| write(Write::DeleteArticle { slug: slug }, v, to))
        }
        (b"POST" | b"DELETE", [b"articles", s, b"favorite"]) if !s.is_empty() => {
            let Some(slug) = seg(1) else { return err(404, "not found") };
            let on = m == b"POST";
            required(auth(), |v, _| write(Write::Favorite { slug: slug, on }, v, to))
        }
        (b"GET", [b"articles", s, b"comments"]) if !s.is_empty() => {
            let Some(slug) = seg(1) else { return err(404, "not found") };
            optional(auth(), |v| read(Read::Comments { slug: slug }, v, to))
        }
        (b"POST", [b"articles", s, b"comments"]) if !s.is_empty() => {
            let Some(slug) = seg(1) else { return err(404, "not found") };
            required(auth(), |v, _| {
                let c = match body_obj(r.body, "comment") { Ok(c) => c, Err(e) => return e };
                match req_string(&c, "body") {
                    Ok(body) => write(Write::CreateComment { slug: slug, body }, v, to),
                    Err(()) => err(422, "body is required"),
                }
            })
        }
        (b"DELETE", [b"articles", s, b"comments", id]) if !s.is_empty() && !id.is_empty() => {
            let Some(slug) = seg(1) else { return err(404, "not found") };
            let id = seg(3);
            required(auth(), |v, _| match id.as_deref().and_then(parse_uint) {
                Some(id) => write(Write::DeleteComment { slug: slug, id }, v, to),
                None => err(404, "comment not found"),
            })
        }
        _ => err(404, "not found"),
    }
}

fn list(query: &[u8], v: i64, to: ReplyTo) -> Outcome {
    let q = parse_query(query);
    let Some((lim, off)) = limit_offset(&q) else { return err(422, "limit must be 1-100 and offset >= 0") };
    if q.unmatchable {
        return Outcome::Now(200, b"{\"articles\":[],\"articlesCount\":0}".to_vec());
    }
    let nonempty = |s: Option<String>| s.filter(|s| !s.is_empty());
    let kind = if let Some(tag) = nonempty(q.tag) {
        Read::Tag { tag, lim, off }
    } else if let Some(username) = nonempty(q.author) {
        Read::Author { username, lim, off }
    } else if let Some(username) = nonempty(q.favorited) {
        Read::Favorited { username, lim, off }
    } else {
        Read::Global { lim, off }
    };
    read(kind, v, to)
}

fn register(body: &[u8], to: ReplyTo) -> Outcome {
    let m = match body_obj(body, "user") { Ok(m) => m, Err(e) => return e };
    let (Ok(username), Ok(email), Ok(password)) = (req_string(&m, "username"), req_string(&m, "email"), req_string(&m, "password"))
    else {
        return err(422, "username, email and password are required");
    };
    if password.len() > MAX_PASSWORD {
        return err(422, "password is too long");
    }
    let write = WriteJob { kind: Write::Register { username, email, hash: String::new() }, viewer: 0, to };
    db::BCRYPT.push_all(BcryptJob::Hash { password: password.into_bytes(), write });
    Outcome::Queued
}

fn login(body: &[u8], to: ReplyTo) -> Outcome {
    let Some(m) = wrapper(body, "user") else { return err(422, "invalid body") };
    let (Ok(email), Ok(password)) = (req_string(&m, "email"), req_string(&m, "password")) else {
        return err(422, "email and password are required");
    };
    // No stored email contains NUL (Postgres text can't), and bcrypt cannot match a password this long.
    if email.contains('\0') || password.len() > MAX_PASSWORD {
        return err(401, "invalid email or password");
    }
    read(Read::Login { email, password: password.into_bytes() }, 0, to)
}

fn update_user(body: &[u8], id: i64, token: String, to: ReplyTo) -> Outcome {
    let m = match body_obj(body, "user") { Ok(m) => m, Err(e) => return e };
    let (Ok(email), Ok(username), Ok(password), Ok(bio), Ok(image)) = (
        opt_string(&m, "email", true),
        opt_string(&m, "username", true),
        opt_string(&m, "password", true),
        opt_string(&m, "bio", false),
        opt_string(&m, "image", false),
    ) else {
        return err(422, "invalid user fields");
    };
    let kind = Write::UpdateUser { token, email, username, hash: None, bio, image };
    match password {
        Some(p) if p.len() > MAX_PASSWORD => err(422, "password is too long"),
        Some(p) => {
            db::BCRYPT.push_all(BcryptJob::Hash { password: p.into_bytes(), write: WriteJob { kind, viewer: id, to } });
            Outcome::Queued
        }
        None => write(kind, id, to),
    }
}

fn create_article(body: &[u8], v: i64, to: ReplyTo) -> Outcome {
    let m = match body_obj(body, "article") { Ok(m) => m, Err(e) => return e };
    let (Ok(title), Ok(description), Ok(body)) = (req_string(&m, "title"), req_string(&m, "description"), req_string(&m, "body"))
    else {
        return err(422, "title, description and body are required");
    };
    let mut tags = Vec::new();
    match m.get("tagList") {
        None | Some(Value::Null) => {}
        Some(Value::Array(items)) => {
            for it in items {
                match it {
                    Value::String(s) if !s.is_empty() => tags.push(s.clone()),
                    _ => return err(422, "tagList must be an array of non-empty strings"),
                }
            }
        }
        Some(_) => return err(422, "tagList must be an array of non-empty strings"),
    }
    write(Write::CreateArticle { title, description, body, tags }, v, to)
}

fn update_article(body: &[u8], slug: String, v: i64, to: ReplyTo) -> Outcome {
    let m = match body_obj(body, "article") { Ok(m) => m, Err(e) => return e };
    let (Ok(title), Ok(description), Ok(body)) =
        (opt_string(&m, "title", true), opt_string(&m, "description", true), opt_string(&m, "body", true))
    else {
        return err(422, "title, description and body must be non-empty strings");
    };
    write(Write::UpdateArticle { slug, title, description, body }, v, to)
}

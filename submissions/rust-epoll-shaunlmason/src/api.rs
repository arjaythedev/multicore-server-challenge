//! Routing and validation: an HTTP request becomes an immediate answer (validation errors, 401, 404) or a job for
//! the database lanes. Validation follows SPEC.md and the conformance suite.

use serde_json::{Map, Value};

use crate::db::{self, Hash, Read, Write};
use crate::reply::{self, Addr, Reply};

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

/// bcrypt only reads the first 72 bytes, so a longer password is rejected (on login: can't match).
const MAX_PASSWORD: usize = 72;

fn hex(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

/// Percent-decoding (`plus`: '+' is a space, as in query strings). Bad escapes, invalid UTF-8 and NUL (Postgres
/// text can't hold it, so nothing could match) give None.
fn unescape(s: &[u8], plus: bool) -> Option<String> {
    let out = if s.iter().any(|&b| b == b'%' || (plus && b == b'+')) {
        let mut out = Vec::with_capacity(s.len());
        let mut i = 0;
        while i < s.len() {
            match s[i] {
                b'%' => {
                    out.push(hex(*s.get(i + 1)?)? << 4 | hex(*s.get(i + 2)?)?);
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
        String::from_utf8(out).ok()?
    } else {
        String::from_utf8(s.to_vec()).ok()?
    };
    (!out.contains('\0')).then_some(out)
}

/// The first value of each list parameter. `unmatchable`: a filter value no row can have (bad encoding, NUL).
#[derive(Default)]
struct Query {
    limit: Option<Option<String>>,
    offset: Option<Option<String>>,
    tag: Option<String>,
    author: Option<String>,
    favorited: Option<String>,
    unmatchable: bool,
}

fn parse_query(q: &[u8]) -> Query {
    let mut out = Query::default();
    for part in q.split(|&b| b == b'&').filter(|p| !p.is_empty()) {
        let (k, v) = match memchr::memchr(b'=', part) {
            Some(i) => (&part[..i], &part[i + 1..]),
            None => (part, &b""[..]),
        };
        let Some(k) = unescape(k, true) else { continue };
        match k.as_str() {
            "limit" if out.limit.is_none() => out.limit = Some(unescape(v, true)),
            "offset" if out.offset.is_none() => out.offset = Some(unescape(v, true)),
            "tag" | "author" | "favorited" => {
                let slot = match k.as_str() {
                    "tag" => &mut out.tag,
                    "author" => &mut out.author,
                    _ => &mut out.favorited,
                };
                if slot.is_none() {
                    *slot = Some(unescape(v, true).unwrap_or_else(|| {
                        out.unmatchable = true;
                        String::new()
                    }));
                }
            }
            _ => {}
        }
    }
    out
}

/// ASCII digits only, fitting in i64.
fn uint(s: &str) -> Option<i64> {
    (!s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())).then(|| s.parse().ok()).flatten()
}

/// limit 1..=100 (default 20), offset >= 0 (default 0); anything else is a 422.
fn page(q: &Query) -> Option<(i64, i64)> {
    let lim = match &q.limit {
        None => 20,
        Some(v) => v.as_deref().and_then(uint).filter(|n| (1..=100).contains(n))?,
    };
    let off = match &q.offset {
        None => 0,
        // capped so limit + offset can't overflow in SQL; any offset this large is past every row anyway
        Some(v) => v.as_deref().and_then(uint)?.min(i64::MAX / 4),
    };
    Some((lim, off))
}

/// `{"<key>": {...}}`: the inner object, or the 422 to answer.
fn object(body: &[u8], key: &str) -> Result<Map<String, Value>, Outcome> {
    let Ok(Value::Object(mut top)) = serde_json::from_slice::<Value>(body) else { return Err(err(422, "invalid body")) };
    let Some(Value::Object(inner)) = top.remove(key) else { return Err(err(422, "invalid body")) };
    fn nul(v: &Value) -> bool {
        match v {
            Value::String(s) => s.contains('\0'),
            Value::Array(a) => a.iter().any(nul),
            Value::Object(o) => o.values().any(nul),
            _ => false,
        }
    }
    if inner.values().any(nul) {
        return Err(err(422, "strings must not contain NUL"));
    }
    Ok(inner)
}

/// Absent or null: None. A string (non-empty if `non_empty`): Some. Anything else: Err.
fn opt_str(m: &Map<String, Value>, k: &str, non_empty: bool) -> Result<Option<String>, ()> {
    match m.get(k) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) if non_empty && s.is_empty() => Err(()),
        Some(Value::String(s)) => Ok(Some(s.clone())),
        Some(_) => Err(()),
    }
}

fn req_str(m: &Map<String, Value>, k: &str) -> Result<String, ()> {
    opt_str(m, k, true)?.ok_or(())
}

enum Auth {
    Anonymous,
    Invalid,
    User(i64, String),
}

fn auth(keys: &crate::jwt::Keys, header: Option<&[u8]>) -> Auth {
    let Some(h) = header else { return Auth::Anonymous };
    let Some(tok) = h.strip_prefix(b"Token ") else { return Auth::Invalid };
    match keys.verify(tok) {
        Some(id) => Auth::User(id, String::from_utf8_lossy(tok).into_owned()),
        None => Auth::Invalid,
    }
}

fn read(kind: Read, viewer: i64, to: Addr) -> Outcome {
    db::read(kind, viewer, Reply::new(to));
    Outcome::Queued
}

fn write(kind: Write, viewer: i64, to: Addr) -> Outcome {
    db::write(kind, viewer, Reply::new(to));
    Outcome::Queued
}

pub fn handle(keys: &crate::jwt::Keys, r: &Request, to: Addr) -> Outcome {
    let Some(rest) = r.path.strip_prefix(b"/api/") else { return err(404, "not found") };
    let segs: smallvec_lite::Segs = smallvec_lite::split(rest);
    let segs = segs.as_slice();
    let seg = |i: usize| -> Option<String> { segs.get(i).filter(|s| !s.is_empty()).and_then(|s| unescape(s, false)) };
    let required = |f: &dyn Fn(i64, String) -> Outcome| match auth(keys, r.auth) {
        Auth::User(id, tok) => f(id, tok),
        _ => err(401, "unauthorized"),
    };
    let optional = |f: &dyn Fn(i64) -> Outcome| match auth(keys, r.auth) {
        Auth::User(id, _) => f(id),
        Auth::Anonymous => f(0),
        Auth::Invalid => err(401, "unauthorized"),
    };
    let m = r.method;
    match (m, segs) {
        (b"GET", [b"tags"]) => read(Read::Tags, 0, to),
        (b"POST", [b"users"]) => register(r.body, to),
        (b"POST", [b"users", b"login"]) => login(r.body, to),
        (b"GET", [b"user"]) => required(&|id, token| read(Read::CurrentUser { token }, id, to)),
        (b"PUT", [b"user"]) => required(&|id, token| update_user(r.body, id, token, to)),
        (b"GET", [b"profiles", u]) if !u.is_empty() => {
            let Some(username) = seg(1) else { return err(404, "profile not found") };
            optional(&|v| read(Read::Profile { username: username.clone() }, v, to))
        }
        (b"POST" | b"DELETE", [b"profiles", u, b"follow"]) if !u.is_empty() => {
            let Some(username) = seg(1) else { return err(404, "profile not found") };
            let on = m == b"POST";
            required(&|v, _| write(Write::Follow { username: username.clone(), on }, v, to))
        }
        (b"GET", [b"articles"]) => optional(&|v| list(r.query, v, to)),
        (b"POST", [b"articles"]) => required(&|v, _| create_article(r.body, v, to)),
        (b"GET", [b"articles", b"feed"]) => required(&|v, _| match page(&parse_query(r.query)) {
            Some((lim, off)) => read(Read::Feed { lim, off }, v, to),
            None => err(422, "limit must be 1-100 and offset >= 0"),
        }),
        (b"GET", [b"articles", s]) if !s.is_empty() => {
            let Some(slug) = seg(1) else { return err(404, "article not found") };
            optional(&|v| read(Read::Article { slug: slug.clone() }, v, to))
        }
        (b"PUT", [b"articles", s]) if !s.is_empty() => {
            let Some(slug) = seg(1) else { return err(404, "article not found") };
            required(&|v, _| update_article(r.body, slug.clone(), v, to))
        }
        (b"DELETE", [b"articles", s]) if !s.is_empty() => {
            let Some(slug) = seg(1) else { return err(404, "article not found") };
            required(&|v, _| write(Write::DeleteArticle { slug: slug.clone() }, v, to))
        }
        (b"POST" | b"DELETE", [b"articles", s, b"favorite"]) if !s.is_empty() => {
            let Some(slug) = seg(1) else { return err(404, "article not found") };
            let on = m == b"POST";
            required(&|v, _| write(Write::Favorite { slug: slug.clone(), on }, v, to))
        }
        (b"GET", [b"articles", s, b"comments"]) if !s.is_empty() => {
            let Some(slug) = seg(1) else { return err(404, "article not found") };
            optional(&|v| read(Read::Comments { slug: slug.clone() }, v, to))
        }
        (b"POST", [b"articles", s, b"comments"]) if !s.is_empty() => {
            let Some(slug) = seg(1) else { return err(404, "article not found") };
            required(&|v, _| {
                let c = match object(r.body, "comment") {
                    Ok(c) => c,
                    Err(e) => return e,
                };
                match req_str(&c, "body") {
                    Ok(body) => write(Write::CreateComment { slug: slug.clone(), body }, v, to),
                    Err(()) => err(422, "comment body is required"),
                }
            })
        }
        (b"DELETE", [b"articles", s, b"comments", id]) if !s.is_empty() && !id.is_empty() => {
            let Some(slug) = seg(1) else { return err(404, "article not found") };
            let id = seg(3).as_deref().and_then(uint);
            required(&|v, _| match id {
                Some(id) => write(Write::DeleteComment { slug: slug.clone(), id }, v, to),
                None => err(404, "comment not found"),
            })
        }
        _ => err(404, "not found"),
    }
}

fn list(query: &[u8], v: i64, to: Addr) -> Outcome {
    let q = parse_query(query);
    let Some((lim, off)) = page(&q) else { return err(422, "limit must be 1-100 and offset >= 0") };
    if q.unmatchable {
        return Outcome::Now(200, b"{\"articles\":[],\"articlesCount\":0}".to_vec());
    }
    let some = |s: &Option<String>| s.clone().filter(|s| !s.is_empty());
    let kind = if let Some(tag) = some(&q.tag) {
        Read::Tag { tag, lim, off }
    } else if let Some(username) = some(&q.author) {
        Read::Author { username, lim, off }
    } else if let Some(username) = some(&q.favorited) {
        Read::Favorited { username, lim, off }
    } else {
        Read::Global { lim, off }
    };
    read(kind, v, to)
}

fn register(body: &[u8], to: Addr) -> Outcome {
    let m = match object(body, "user") {
        Ok(m) => m,
        Err(e) => return e,
    };
    let (Ok(username), Ok(email), Ok(password)) = (req_str(&m, "username"), req_str(&m, "email"), req_str(&m, "password"))
    else {
        return err(422, "username, email and password are required");
    };
    if password.len() > MAX_PASSWORD {
        return err(422, "password is longer than 72 bytes");
    }
    db::hash(Hash { password: password.into_bytes(), kind: Write::Register { username, email, hash: String::new() }, viewer: 0 }, Reply::new(to));
    Outcome::Queued
}

fn login(body: &[u8], to: Addr) -> Outcome {
    let m = match object(body, "user") {
        Ok(m) => m,
        Err(_) => return err(422, "invalid body"),
    };
    let (Ok(email), Ok(password)) = (req_str(&m, "email"), req_str(&m, "password")) else {
        return err(422, "email and password are required");
    };
    if password.len() > MAX_PASSWORD {
        return err(401, "invalid email or password");
    }
    read(Read::Login { email, password: password.into_bytes() }, 0, to)
}

fn update_user(body: &[u8], id: i64, token: String, to: Addr) -> Outcome {
    let m = match object(body, "user") {
        Ok(m) => m,
        Err(e) => return e,
    };
    let (Ok(email), Ok(username), Ok(password), Ok(bio), Ok(image)) = (
        opt_str(&m, "email", true),
        opt_str(&m, "username", true),
        opt_str(&m, "password", true),
        opt_str(&m, "bio", false),
        opt_str(&m, "image", false),
    ) else {
        return err(422, "invalid user fields");
    };
    let kind = Write::UpdateUser { token, email, username, hash: None, bio, image };
    match password {
        Some(p) if p.len() > MAX_PASSWORD => err(422, "password is longer than 72 bytes"),
        Some(p) => {
            db::hash(Hash { password: p.into_bytes(), kind, viewer: id }, Reply::new(to));
            Outcome::Queued
        }
        None => write(kind, id, to),
    }
}

fn create_article(body: &[u8], v: i64, to: Addr) -> Outcome {
    let m = match object(body, "article") {
        Ok(m) => m,
        Err(e) => return e,
    };
    let (Ok(title), Ok(description), Ok(body)) = (req_str(&m, "title"), req_str(&m, "description"), req_str(&m, "body"))
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

fn update_article(body: &[u8], slug: String, v: i64, to: Addr) -> Outcome {
    let m = match object(body, "article") {
        Ok(m) => m,
        Err(e) => return e,
    };
    let (Ok(title), Ok(description), Ok(body)) =
        (opt_str(&m, "title", true), opt_str(&m, "description", true), opt_str(&m, "body", true))
    else {
        return err(422, "title, description and body must be non-empty strings");
    };
    write(Write::UpdateArticle { slug, title, description, body }, v, to)
}

/// Path segments without a heap allocation for the usual (<= 6 segment) paths.
mod smallvec_lite {
    pub struct Segs<'a> {
        n: usize,
        a: [&'a [u8]; 6],
        overflow: bool,
    }
    impl<'a> Segs<'a> {
        pub fn as_slice(&self) -> &[&'a [u8]] {
            // more than 6 segments matches no route: an empty-named 7th makes every pattern miss
            if self.overflow { &[b"" as &[u8]; 6][..] } else { &self.a[..self.n] }
        }
    }
    pub fn split(p: &[u8]) -> Segs<'_> {
        let mut s = Segs { n: 0, a: [b""; 6], overflow: false };
        for part in p.split(|&b| b == b'/') {
            if s.n == 6 {
                s.overflow = true;
                break;
            }
            s.a[s.n] = part;
            s.n += 1;
        }
        s
    }
}

//! Routing, auth, validation and the 19 endpoints.

use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use hmac::{Hmac, Mac};
use serde_json::{Map, Value};
use sha2::Sha256;
use tokio_postgres::Row;
use tokio_postgres::error::SqlState;
use tokio_postgres::types::ToSql;

use crate::db::{self, Q, db};
use crate::json;

pub type Resp = (u16, Vec<u8>);

fn err(code: u16, msg: &str) -> Resp {
    (code, format!("{{\"errors\":{{\"body\":[\"{msg}\"]}}}}").into_bytes())
}
fn e401() -> Resp {
    err(401, "unauthorized")
}
fn e404() -> Resp {
    err(404, "not found")
}
fn e422() -> Resp {
    err(422, "invalid request")
}
fn e500() -> Resp {
    err(500, "internal error")
}

// ---------- JWT (HS256, verified on every request) ----------

static MAC: OnceLock<Hmac<Sha256>> = OnceLock::new();
const HEADER: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"; // {"alg":"HS256","typ":"JWT"}
const DAYS_30: u64 = 30 * 24 * 3600;

pub fn init_secret(s: &str) {
    let _ = MAC.set(Hmac::new_from_slice(s.as_bytes()).unwrap());
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs()
}

fn issue(id: i64) -> String {
    let n = now();
    let mut t = format!("{HEADER}.");
    B64.encode_string(format!("{{\"sub\":\"{id}\",\"iat\":{n},\"exp\":{}}}", n + DAYS_30), &mut t);
    let sig = MAC.get().unwrap().clone().chain_update(t.as_bytes()).finalize().into_bytes();
    t.push('.');
    B64.encode_string(sig, &mut t);
    t
}

/// The user id of a valid token: signature, alg HS256, exp in the future, sub a decimal string.
fn verify(tok: &str) -> Option<i64> {
    let (signed, sig) = tok.rsplit_once('.')?;
    let (h, p) = signed.split_once('.')?;
    let mut sb = [0u8; 32];
    if B64.decode_slice(sig, &mut sb).ok()? != 32 {
        return None;
    }
    MAC.get().unwrap().clone().chain_update(signed.as_bytes()).verify_slice(&sb).ok()?;
    let h: Value = serde_json::from_slice(&B64.decode(h).ok()?).ok()?;
    if h.get("alg")?.as_str()? != "HS256" {
        return None;
    }
    let p: Value = serde_json::from_slice(&B64.decode(p).ok()?).ok()?;
    if p.get("exp")?.as_f64()? <= now() as f64 {
        return None;
    }
    let sub = p.get("sub")?.as_str()?;
    if sub.is_empty() || !sub.bytes().all(|c| c.is_ascii_digit()) {
        return None;
    }
    sub.parse().ok().filter(|&id| id > 0)
}

/// Ok(None): no header (anonymous). Err: a header that isn't a valid `Token <jwt>`.
fn auth(h: Option<&[u8]>) -> Result<Option<(i64, &str)>, ()> {
    let Some(h) = h else { return Ok(None) };
    let tok = std::str::from_utf8(h).ok().and_then(|s| s.strip_prefix("Token ")).ok_or(())?;
    verify(tok).map(|id| Some((id, tok))).ok_or(())
}

// ---------- request parsing ----------

/// Percent-decoding; `plus` turns '+' into a space (query strings). None for invalid UTF-8 or a NUL.
fn decode(s: &str, plus: bool) -> Option<String> {
    let b = s.as_bytes();
    let mut o = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'%' => {
                let hex = |j: usize| b.get(j).and_then(|&c| (c as char).to_digit(16));
                let (Some(h), Some(l)) = (hex(i + 1), hex(i + 2)) else { return None };
                o.push((h * 16 + l) as u8);
                i += 3;
                continue;
            }
            b'+' if plus => o.push(b' '),
            c => o.push(c),
        }
        i += 1;
    }
    String::from_utf8(o).ok().filter(|s| !s.contains('\0'))
}

fn num(s: &str) -> Option<i64> {
    if s.is_empty() || !s.bytes().all(|c| c.is_ascii_digit()) {
        return None;
    }
    s.parse().ok()
}

struct ListQuery {
    limit: i64,
    offset: i64,
    filter: Option<(usize, String)>, // the first non-empty of tag, author, favorited
}

fn list_query(qs: &str) -> Option<ListQuery> {
    let (mut limit, mut offset) = (20, 0);
    let mut f: [Option<String>; 3] = [None, None, None];
    for kv in qs.split('&').filter(|kv| !kv.is_empty()) {
        let (k, v) = kv.split_once('=').unwrap_or((kv, ""));
        let v = decode(v, true)?;
        match k {
            "limit" => limit = num(&v).filter(|n| (1..=100).contains(n))?,
            // Past any real row count the page is empty either way; the cap keeps limit + offset inside bigint in SQL.
            "offset" => offset = num(&v)?.min(1 << 40),
            "tag" => f[0] = Some(v),
            "author" => f[1] = Some(v),
            "favorited" => f[2] = Some(v),
            _ => {}
        }
    }
    let kinds = [db::LIST_TAG, db::LIST_AUTHOR, db::LIST_FAV];
    let filter = f.into_iter().zip(kinds).find_map(|(v, k)| v.filter(|v| !v.is_empty()).map(|v| (k, v)));
    Some(ListQuery { limit, offset, filter })
}

/// The object under `key` in a JSON body.
fn wrapper(body: &[u8], key: &str) -> Option<Map<String, Value>> {
    match serde_json::from_slice::<Value>(body).ok()? {
        Value::Object(mut m) => match m.remove(key)? {
            Value::Object(o) => Some(o),
            _ => None,
        },
        _ => None,
    }
}

/// Ok(None): absent or null. Err: not a string, or a string Postgres can't store (NUL).
fn field<'a>(o: &'a Map<String, Value>, k: &str) -> Result<Option<&'a str>, ()> {
    match o.get(k) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) if !s.contains('\0') => Ok(Some(s)),
        _ => Err(()),
    }
}
/// Absent/null is fine, but a value given must be a non-empty string.
fn nonempty<'a>(o: &'a Map<String, Value>, k: &str) -> Result<Option<&'a str>, ()> {
    match field(o, k)? {
        Some("") => Err(()),
        x => Ok(x),
    }
}
fn required<'a>(o: &'a Map<String, Value>, k: &str) -> Result<&'a str, ()> {
    nonempty(o, k)?.ok_or(())
}

// ---------- database helpers ----------

async fn read(kind: usize, v: i64, n1: i64, n2: i64, s: String) -> Result<Vec<Row>, Resp> {
    match db().read(kind, Q { v, n1, n2, s }).await {
        Ok(db::Reply::Rows(rows)) => Ok(rows),
        _ => Err(e500()),
    }
}

/// A read answered by the cross-kind statement (Ok(Ok(body)), empty = not found), or its rows when that
/// statement is off (READ_CROSS=0).
async fn read_any(kind: usize, v: i64, n1: i64, n2: i64, s: String) -> Result<Result<Vec<u8>, Vec<Row>>, Resp> {
    match db().read(kind, Q { v, n1, n2, s }).await {
        Ok(db::Reply::Body(b)) => Ok(Ok(b)),
        Ok(db::Reply::Rows(rows)) => Ok(Err(rows)),
        _ => Err(e500()),
    }
}

/// A cross-kind body: 404 when empty.
fn found(b: Vec<u8>) -> R {
    if b.is_empty() { Err(e404()) } else { Ok((200, b)) }
}

async fn write(st: usize, params: &[&(dyn ToSql + Sync)]) -> Result<Option<Row>, Resp> {
    let c = db().write();
    match c.c.query_opt(&c.st[st], params).await {
        Ok(r) => Ok(r),
        Err(e) => match e.code() {
            Some(&SqlState::UNIQUE_VIOLATION) => Err(e422()),
            Some(&SqlState::FOREIGN_KEY_VIOLATION) => Err(e401()), // the token's user no longer exists
            _ => {
                eprintln!("write {st}: {e}");
                Err(e500())
            }
        },
    }
}

fn user_json(r: &Row, b: usize, token: &str) -> Vec<u8> {
    let mut o = Vec::with_capacity(512);
    o.extend_from_slice(b"{\"user\":{\"email\":");
    json::str(&mut o, r.get(b + 2));
    o.extend_from_slice(b",\"token\":");
    json::str(&mut o, token);
    o.extend_from_slice(b",\"username\":");
    json::str(&mut o, r.get(b + 1));
    o.extend_from_slice(b",\"bio\":");
    json::opt(&mut o, r.get(b + 3));
    o.extend_from_slice(b",\"image\":");
    json::opt(&mut o, r.get(b + 4));
    o.extend_from_slice(b"}}");
    o
}

fn article_json(r: &Row, b: usize) -> Vec<u8> {
    let mut o = Vec::with_capacity(2048);
    o.extend_from_slice(b"{\"article\":");
    json::article(&mut o, r, b, true);
    o.push(b'}');
    o
}

fn profile_json(username: &str, bio: Option<&str>, image: Option<&str>, following: bool) -> Vec<u8> {
    let mut o = Vec::with_capacity(256);
    o.extend_from_slice(b"{\"profile\":");
    json::profile(&mut o, username, bio, image, following);
    o.push(b'}');
    o
}

fn comment_json(o: &mut Vec<u8>, r: &Row, b: usize, following: bool) {
    o.extend_from_slice(b"{\"id\":");
    json::int(o, r.get(b));
    o.extend_from_slice(b",\"createdAt\":");
    json::time(o, r.get(b + 2));
    o.extend_from_slice(b",\"updatedAt\":");
    json::time(o, r.get(b + 3));
    o.extend_from_slice(b",\"body\":");
    json::str(o, r.get(b + 1));
    o.extend_from_slice(b",\"author\":");
    json::profile(o, r.get(b + 4), r.get(b + 5), r.get(b + 6), following);
    o.push(b'}');
}

// ---------- routing ----------

pub async fn handle(method: &str, target: &str, h: Option<&[u8]>, body: &[u8]) -> Resp {
    let (path, qs) = target.split_once('?').unwrap_or((target, ""));
    let Some(rest) = path.strip_prefix("/api/") else { return e404() };
    let seg: Vec<&str> = rest.split('/').collect();
    // auth required: (id, token); auth optional: viewer id or 0
    macro_rules! user {
        () => {
            match auth(h) {
                Ok(Some(u)) => u,
                _ => return e401(),
            }
        };
    }
    macro_rules! viewer {
        () => {
            match auth(h) {
                Ok(u) => u.map_or(0, |u| u.0),
                Err(()) => return e401(),
            }
        };
    }
    macro_rules! param {
        ($s:expr) => {
            match decode($s, false) {
                Some(s) => s,
                None => return e404(),
            }
        };
    }
    let r = match (method, seg.as_slice()) {
        ("GET", ["tags"]) => tags().await,
        ("POST", ["users"]) => register(body).await,
        ("POST", ["users", "login"]) => login(body).await,
        ("GET", ["user"]) => {
            let (id, tok) = user!();
            get_user(id, tok).await
        }
        ("PUT", ["user"]) => {
            let (id, tok) = user!();
            update_user(id, tok, body).await
        }
        ("GET", ["profiles", u]) => {
            let v = viewer!();
            profile(v, param!(u)).await
        }
        (m @ ("POST" | "DELETE"), ["profiles", u, "follow"]) => {
            let (v, _) = user!();
            follow(v, param!(u), m == "POST").await
        }
        ("GET", ["articles"]) => {
            let v = viewer!();
            list(v, qs, false).await
        }
        ("GET", ["articles", "feed"]) => {
            let (v, _) = user!();
            list(v, qs, true).await
        }
        ("POST", ["articles"]) => {
            let (v, _) = user!();
            create_article(v, body).await
        }
        ("GET", ["articles", s]) => {
            let v = viewer!();
            article(v, param!(s)).await
        }
        ("PUT", ["articles", s]) => {
            let (v, _) = user!();
            update_article(v, param!(s), body).await
        }
        ("DELETE", ["articles", s]) => {
            let (v, _) = user!();
            delete_article(v, param!(s)).await
        }
        (m @ ("POST" | "DELETE"), ["articles", s, "favorite"]) => {
            let (v, _) = user!();
            favorite(v, param!(s), m == "POST").await
        }
        ("GET", ["articles", s, "comments"]) => {
            let v = viewer!();
            comments(v, param!(s)).await
        }
        ("POST", ["articles", s, "comments"]) => {
            let (v, _) = user!();
            add_comment(v, param!(s), body).await
        }
        ("DELETE", ["articles", s, "comments", id]) => {
            let (v, _) = user!();
            delete_comment(v, param!(s), id).await
        }
        _ => Err(e404()),
    };
    r.unwrap_or_else(|e| e)
}

type R = Result<Resp, Resp>;

async fn tags() -> R {
    match db().read(db::TAGS, Q { v: 0, n1: 0, n2: 0, s: String::new() }).await {
        Ok(db::Reply::Tags(b)) => Ok((200, b.to_vec())),
        Ok(db::Reply::Body(b)) => Ok((200, b)),
        _ => Err(e500()),
    }
}

async fn register(body: &[u8]) -> R {
    let o = wrapper(body, "user").ok_or_else(e422)?;
    let (Ok(username), Ok(email), Ok(password)) = (required(&o, "username"), required(&o, "email"), required(&o, "password")) else {
        return Err(e422());
    };
    if password.len() > 72 {
        return Err(e422()); // bcrypt only uses the first 72 bytes
    }
    let hash = crate::bcrypt::hash(password).await;
    let row = write(db::W_REGISTER, &[&username, &email, &hash]).await?.ok_or_else(e500)?;
    Ok((201, user_json(&row, 0, &issue(row.get(0)))))
}

async fn login(body: &[u8]) -> R {
    let o = wrapper(body, "user").ok_or_else(e422)?;
    let (Ok(email), Ok(password)) = (required(&o, "email"), required(&o, "password")) else {
        return Err(e422());
    };
    let rows = read(db::USER_EMAIL, 0, 0, 0, email.to_owned()).await?;
    let row = rows.into_iter().next().ok_or_else(e401)?;
    if !crate::bcrypt::verify(password, row.get(6)).await {
        return Err(e401());
    }
    Ok((200, user_json(&row, 1, &issue(row.get(1)))))
}

async fn get_user(id: i64, tok: &str) -> R {
    let rows = read(db::USER_ID, id, 0, 0, String::new()).await?;
    let row = rows.first().ok_or_else(e401)?;
    Ok((200, user_json(row, 1, tok)))
}

async fn update_user(id: i64, tok: &str, body: &[u8]) -> R {
    let o = wrapper(body, "user").ok_or_else(e422)?;
    let (Ok(email), Ok(username), Ok(password), Ok(bio), Ok(image)) =
        (nonempty(&o, "email"), nonempty(&o, "username"), nonempty(&o, "password"), field(&o, "bio"), field(&o, "image"))
    else {
        return Err(e422());
    };
    let hash = match password {
        Some(p) if p.len() > 72 => return Err(e422()),
        Some(p) => Some(crate::bcrypt::hash(p).await),
        None => None,
    };
    let row = write(db::W_USER_UPDATE, &[&id, &email, &username, &hash, &bio, &image]).await?.ok_or_else(e401)?;
    Ok((200, user_json(&row, 0, tok)))
}

async fn profile(v: i64, name: String) -> R {
    let rows = match read_any(db::PROFILE, v, 0, 0, name).await? {
        Ok(b) => return found(b),
        Err(rows) => rows,
    };
    let r = rows.first().ok_or_else(e404)?;
    Ok((200, profile_json(r.get(1), r.get(2), r.get(3), r.get(4))))
}

async fn follow(v: i64, name: String, on: bool) -> R {
    let st = if on { db::W_FOLLOW } else { db::W_UNFOLLOW };
    let r = write(st, &[&v, &name]).await?.ok_or_else(e404)?;
    Ok((200, profile_json(r.get(0), r.get(1), r.get(2), on)))
}

async fn list(v: i64, qs: &str, feed: bool) -> R {
    let q = list_query(qs).ok_or_else(e422)?;
    let (kind, s) = match q.filter {
        _ if feed => (db::FEED, String::new()),
        Some(f) => f,
        None => (db::LIST_ALL, String::new()),
    };
    let mut rows = match read_any(kind, v, q.limit, q.offset, s).await? {
        Ok(b) => return Ok((200, b)),
        Err(rows) => rows,
    };
    let n: i64 = rows.first().map_or(0, |r| r.get(1));
    rows.retain(|r| r.get::<_, Option<i64>>(2).is_some());
    rows.sort_unstable_by_key(|r| std::cmp::Reverse(r.get::<_, i64>(2)));
    let mut o = Vec::with_capacity(512 + rows.len() * 900);
    o.extend_from_slice(b"{\"articles\":[");
    for (i, r) in rows.iter().enumerate() {
        if i > 0 {
            o.push(b',');
        }
        json::article(&mut o, r, 2, false);
    }
    o.extend_from_slice(b"],\"articlesCount\":");
    json::int(&mut o, n);
    o.push(b'}');
    Ok((200, o))
}

async fn article(v: i64, slug: String) -> R {
    let rows = match read_any(db::ARTICLE_SLUG, v, 0, 0, slug).await? {
        Ok(b) => return found(b),
        Err(rows) => rows,
    };
    Ok((200, article_json(rows.first().ok_or_else(e404)?, 1)))
}

async fn article_by_id(v: i64, id: i64) -> R {
    let rows = match read_any(db::ARTICLE_ID, v, id, 0, String::new()).await? {
        Ok(b) => return found(b),
        Err(rows) => rows,
    };
    Ok((200, article_json(rows.first().ok_or_else(e404)?, 1)))
}

async fn create_article(v: i64, body: &[u8]) -> R {
    let o = wrapper(body, "article").ok_or_else(e422)?;
    let (Ok(title), Ok(description), Ok(text)) = (required(&o, "title"), required(&o, "description"), required(&o, "body")) else {
        return Err(e422());
    };
    let tags: Vec<&str> = match o.get("tagList") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(a)) => a
            .iter()
            .map(|t| t.as_str().filter(|t| !t.is_empty() && !t.contains('\0')))
            .collect::<Option<_>>()
            .ok_or_else(e422)?,
        _ => return Err(e422()),
    };
    let row = write(db::W_ARTICLE_CREATE, &[&v, &title, &description, &text, &tags]).await?.ok_or_else(e401)?;
    Ok((201, article_json(&row, 0)))
}

async fn update_article(v: i64, slug: String, body: &[u8]) -> R {
    let o = wrapper(body, "article").ok_or_else(e422)?;
    let (Ok(title), Ok(description), Ok(text)) = (nonempty(&o, "title"), nonempty(&o, "description"), nonempty(&o, "body")) else {
        return Err(e422());
    };
    let r = write(db::W_ARTICLE_UPDATE, &[&slug, &title, &description, &text, &v]).await?.ok_or_else(e404)?;
    if r.get::<_, i64>(1) != v {
        return Err(err(403, "forbidden"));
    }
    article_by_id(v, r.get(0)).await
}

async fn delete_article(v: i64, slug: String) -> R {
    let r = write(db::W_ARTICLE_DELETE, &[&slug, &v]).await?.ok_or_else(e404)?;
    if r.get::<_, i64>(0) != v {
        return Err(err(403, "forbidden"));
    }
    Ok((204, Vec::new()))
}

async fn favorite(v: i64, slug: String, on: bool) -> R {
    let st = if on { db::W_FAV } else { db::W_UNFAV };
    let r = write(st, &[&v, &slug]).await?.ok_or_else(e404)?;
    // a new statement: its snapshot sees the committed change
    article_by_id(v, r.get(0)).await
}

async fn comments(v: i64, slug: String) -> R {
    let mut rows = match read_any(db::COMMENTS, v, 0, 0, slug).await? {
        Ok(b) => return found(b),
        Err(rows) => rows,
    };
    if rows.is_empty() {
        return Err(e404());
    }
    rows.retain(|r| r.get::<_, Option<i64>>(2).is_some());
    rows.sort_unstable_by_key(|r| std::cmp::Reverse((r.get::<_, SystemTime>(4), r.get::<_, i64>(2))));
    let mut o = Vec::with_capacity(64 + rows.len() * 400);
    o.extend_from_slice(b"{\"comments\":[");
    for (i, r) in rows.iter().enumerate() {
        if i > 0 {
            o.push(b',');
        }
        comment_json(&mut o, r, 2, r.get(9));
    }
    o.extend_from_slice(b"]}");
    Ok((200, o))
}

async fn add_comment(v: i64, slug: String, body: &[u8]) -> R {
    let o = wrapper(body, "comment").ok_or_else(e422)?;
    let text = required(&o, "body").map_err(|_| e422())?;
    let r = write(db::W_COMMENT_CREATE, &[&slug, &v, &text]).await?.ok_or_else(e404)?;
    let mut o = Vec::with_capacity(512);
    o.extend_from_slice(b"{\"comment\":");
    comment_json(&mut o, &r, 0, false);
    o.push(b'}');
    Ok((201, o))
}

async fn delete_comment(v: i64, slug: String, id: &str) -> R {
    let id = num(id).ok_or_else(e404)?;
    let r = write(db::W_COMMENT_DELETE, &[&id, &slug, &v]).await?.ok_or_else(e404)?;
    if r.get::<_, i64>(0) != v {
        return Err(err(403, "forbidden"));
    }
    Ok((204, Vec::new()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokens_and_queries() {
        init_secret("s");
        let t = issue(42);
        assert_eq!(verify(&t), Some(42));
        assert_eq!(verify(&(t.clone() + "x")), None);
        assert_eq!(auth(Some(format!("Bearer {t}").as_bytes())), Err(()));
        assert_eq!(decode("a%20b+c", true).as_deref(), Some("a b c"));
        assert_eq!(decode("a%2", false), None);
        assert_eq!(decode("%00", false), None);
        assert!(list_query("limit=05&offset=005").is_some_and(|q| q.limit == 5 && q.offset == 5));
        for bad in ["limit=0", "limit=101", "limit=%2B5", "limit=%205", "offset=-1", "offset=99999999999999999999", "limit="] {
            assert!(list_query(bad).is_none(), "{bad}");
        }
        assert!(list_query("tag=&author=x").is_some_and(|q| q.filter == Some((db::LIST_AUTHOR, "x".into()))));
    }
}

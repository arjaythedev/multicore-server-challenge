//! Routing and request handlers for the 19 Conduit endpoints (see SPEC.md).

use std::borrow::Cow;
use std::convert::Infallible;
use std::sync::Arc;

use bytes::Bytes;
use http_body_util::{BodyExt, Full, Limited};
use hyper::body::Incoming;
use hyper::header::{HeaderValue, AUTHORIZATION, CONTENT_TYPE};
use hyper::{HeaderMap, Request, Response, StatusCode};
use serde::Deserialize;
use tokio_postgres::error::SqlState;
use tokio_postgres::Row;

use crate::auth::{BcryptPool, Jwt};
use crate::db::Db;
use crate::json::{
    error_body, push_int, push_str, write_article, write_comment, write_profile, write_user,
};

/// Request bodies are tiny JSON documents; refuse anything above 1 MiB.
const MAX_BODY: usize = 1 << 20;

/// bcrypt only uses the first 72 bytes of a password. The reference (Go's bcrypt) rejects longer ones
/// when hashing instead of silently truncating, so registering or changing to one is a 422.
const MAX_PASSWORD_BYTES: usize = 72;

/// Per-thread application state.
pub struct App {
    pub db: Db,
    pub jwt: Arc<Jwt>,
    pub bc: Arc<BcryptPool>,
}

struct ApiErr {
    status: u16,
    msg: &'static str,
}

fn err(status: u16, msg: &'static str) -> ApiErr {
    ApiErr { status, msg }
}

impl From<tokio_postgres::Error> for ApiErr {
    fn from(e: tokio_postgres::Error) -> ApiErr {
        eprintln!("database error: {e}");
        err(500, "internal server error")
    }
}

/// (status, JSON body). 204 carries an empty body.
type Res = Result<(u16, Vec<u8>), ApiErr>;

pub async fn handle(
    app: Arc<App>,
    req: Request<Incoming>,
) -> Result<Response<Full<Bytes>>, Infallible> {
    let (status, body) = match route(&app, req).await {
        Ok(r) => r,
        Err(e) => (e.status, error_body(e.msg)),
    };
    let mut resp = Response::new(Full::new(Bytes::from(body)));
    *resp.status_mut() = StatusCode::from_u16(status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    if status != 204 {
        resp.headers_mut().insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
    }
    Ok(resp)
}

async fn route(app: &App, req: Request<Incoming>) -> Res {
    let (parts, body) = req.into_parts();
    let segs: Vec<&str> = match parts.uri.path().strip_prefix('/') {
        Some(rest) => rest.split('/').collect(),
        None => return Err(err(404, "not found")),
    };
    if segs.iter().any(|s| s.is_empty()) {
        return Err(err(404, "not found"));
    }
    let headers = &parts.headers;
    let query = parts.uri.query();

    match (parts.method.as_str(), segs.as_slice()) {
        ("GET", ["api", "tags"]) => h_tags(app).await,

        ("POST", ["api", "users"]) => h_register(app, body).await,
        ("POST", ["api", "users", "login"]) => h_login(app, body).await,
        ("GET", ["api", "user"]) => h_current_user(app, headers).await,
        ("PUT", ["api", "user"]) => h_update_user(app, headers, body).await,

        ("GET", ["api", "profiles", name]) => h_profile(app, headers, &pdecode(name, false)).await,
        ("POST", ["api", "profiles", name, "follow"]) => {
            h_follow(app, headers, &pdecode(name, false), true).await
        }
        ("DELETE", ["api", "profiles", name, "follow"]) => {
            h_follow(app, headers, &pdecode(name, false), false).await
        }

        ("GET", ["api", "articles"]) => h_list(app, headers, query).await,
        ("POST", ["api", "articles"]) => h_create_article(app, headers, body).await,
        ("GET", ["api", "articles", "feed"]) => h_feed(app, headers, query).await,
        ("GET", ["api", "articles", slug]) => h_article(app, headers, &pdecode(slug, false)).await,
        ("PUT", ["api", "articles", slug]) => {
            h_update_article(app, headers, &pdecode(slug, false), body).await
        }
        ("DELETE", ["api", "articles", slug]) => {
            h_delete_article(app, headers, &pdecode(slug, false)).await
        }
        ("POST", ["api", "articles", slug, "favorite"]) => {
            h_favorite(app, headers, &pdecode(slug, false), true).await
        }
        ("DELETE", ["api", "articles", slug, "favorite"]) => {
            h_favorite(app, headers, &pdecode(slug, false), false).await
        }
        ("GET", ["api", "articles", slug, "comments"]) => {
            h_comments(app, headers, &pdecode(slug, false)).await
        }
        ("POST", ["api", "articles", slug, "comments"]) => {
            h_add_comment(app, headers, &pdecode(slug, false), body).await
        }
        ("DELETE", ["api", "articles", slug, "comments", id]) => {
            h_delete_comment(app, headers, &pdecode(slug, false), id).await
        }

        _ => Err(err(404, "not found")),
    }
}

// ---------------------------------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------------------------------

struct Auth<'a> {
    id: i64,
    token: &'a str,
}

fn unauthorized() -> ApiErr {
    err(401, "unauthorized")
}

/// `Authorization: Token <jwt>`. No header -> `Ok(None)`; a header that is present but not a valid token
/// is an error (401), also on endpoints where authentication is optional.
fn parse_auth<'a>(app: &App, headers: &'a HeaderMap) -> Result<Option<Auth<'a>>, ApiErr> {
    let value = match headers.get(AUTHORIZATION) {
        None => return Ok(None),
        Some(v) => v,
    };
    let s = value.to_str().map_err(|_| unauthorized())?;
    let token = s.strip_prefix("Token ").ok_or_else(unauthorized)?;
    let id = app.jwt.verify(token).ok_or_else(unauthorized)?;
    Ok(Some(Auth { id, token }))
}

fn auth_required<'a>(app: &App, headers: &'a HeaderMap) -> Result<Auth<'a>, ApiErr> {
    parse_auth(app, headers)?.ok_or_else(unauthorized)
}

/// The viewer id for endpoints with optional auth: 0 when anonymous.
fn viewer_of(app: &App, headers: &HeaderMap) -> Result<i64, ApiErr> {
    Ok(parse_auth(app, headers)?.map(|a| a.id).unwrap_or(0))
}

async fn read_body(body: Incoming) -> Result<Bytes, ApiErr> {
    match Limited::new(body, MAX_BODY).collect().await {
        Ok(collected) => Ok(collected.to_bytes()),
        Err(_) => Err(err(422, "invalid request body")),
    }
}

fn parse_json<'a, T: Deserialize<'a>>(bytes: &'a [u8]) -> Result<T, ApiErr> {
    serde_json::from_slice(bytes).map_err(|_| err(422, "invalid request body"))
}

fn nonempty(v: Option<String>, msg: &'static str) -> Result<String, ApiErr> {
    match v {
        Some(s) if !s.is_empty() => Ok(s),
        _ => Err(err(422, msg)),
    }
}

/// Digits only: no sign, no whitespace, no separators. (`str::parse::<i64>` would accept "+5".)
fn parse_uint(s: &str) -> Option<i64> {
    if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    s.parse::<i64>().ok()
}

/// A field that is present (not null) must not be the empty string.
fn check_not_empty(v: &Option<String>, msg: &'static str) -> Result<(), ApiErr> {
    match v {
        Some(s) if s.is_empty() => Err(err(422, msg)),
        _ => Ok(()),
    }
}

fn check_password_len(p: &str) -> Result<(), ApiErr> {
    if p.len() > MAX_PASSWORD_BYTES {
        Err(err(422, "password must be at most 72 bytes"))
    } else {
        Ok(())
    }
}

fn hex_val(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}

/// Percent-decoding for path segments and query values (`+` is a space in query values only).
fn pdecode(s: &str, plus_is_space: bool) -> Cow<'_, str> {
    let bytes = s.as_bytes();
    if !bytes.iter().any(|&b| b == b'%' || (plus_is_space && b == b'+')) {
        return Cow::Borrowed(s);
    }
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        if b == b'%' && i + 2 < bytes.len() {
            if let (Some(h), Some(l)) = (hex_val(bytes[i + 1]), hex_val(bytes[i + 2])) {
                out.push(h * 16 + l);
                i += 3;
                continue;
            }
        }
        out.push(if plus_is_space && b == b'+' { b' ' } else { b });
        i += 1;
    }
    Cow::Owned(String::from_utf8_lossy(&out).into_owned())
}

struct ListQuery {
    limit: i64,
    offset: i64,
    tag: Option<String>,
    author: Option<String>,
    favorited: Option<String>,
}

/// `limit` (default 20, 1..=100) and `offset` (default 0, >= 0) must be integers in range, else 422.
/// Filters: the first value of each key wins; empty values count as absent.
fn parse_list_query(q: Option<&str>) -> Result<ListQuery, ApiErr> {
    let mut lq = ListQuery { limit: 20, offset: 0, tag: None, author: None, favorited: None };
    let (mut seen_limit, mut seen_offset) = (false, false);
    for pair in q.unwrap_or("").split('&') {
        if pair.is_empty() {
            continue;
        }
        let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
        match k {
            "limit" if !seen_limit => {
                seen_limit = true;
                let n = parse_uint(&pdecode(v, true)).ok_or_else(|| err(422, "limit must be an integer"))?;
                if !(1..=100).contains(&n) {
                    return Err(err(422, "limit must be between 1 and 100"));
                }
                lq.limit = n;
            }
            "offset" if !seen_offset => {
                seen_offset = true;
                lq.offset = parse_uint(&pdecode(v, true))
                    .ok_or_else(|| err(422, "offset must be a non-negative integer"))?;
            }
            "tag" if lq.tag.is_none() && !v.is_empty() => {
                lq.tag = Some(pdecode(v, true).into_owned());
            }
            "author" if lq.author.is_none() && !v.is_empty() => {
                lq.author = Some(pdecode(v, true).into_owned());
            }
            "favorited" if lq.favorited.is_none() && !v.is_empty() => {
                lq.favorited = Some(pdecode(v, true).into_owned());
            }
            _ => {}
        }
    }
    Ok(lq)
}

fn build_list(rows: &[Row], total: i64) -> Result<Vec<u8>, tokio_postgres::Error> {
    let mut out = Vec::with_capacity(64 + rows.len() * 900);
    out.extend_from_slice(b"{\"articles\":[");
    for (i, row) in rows.iter().enumerate() {
        if i > 0 {
            out.push(b',');
        }
        write_article(&mut out, row, false)?;
    }
    out.extend_from_slice(b"],\"articlesCount\":");
    push_int(&mut out, total);
    out.push(b'}');
    Ok(out)
}

fn article_json(row: &Row) -> Result<Vec<u8>, tokio_postgres::Error> {
    let mut out = Vec::with_capacity(2048);
    out.extend_from_slice(b"{\"article\":");
    write_article(&mut out, row, true)?;
    out.push(b'}');
    Ok(out)
}

// ---------------------------------------------------------------------------------------------------
// Tags
// ---------------------------------------------------------------------------------------------------

async fn h_tags(app: &App) -> Res {
    let g = app.db.get();
    let row = g.client.query_one(&g.st.tags, &[]).await?;
    let names: Vec<&str> = row.try_get(0)?;
    let mut out = Vec::with_capacity(16 + names.len() * 16);
    out.extend_from_slice(b"{\"tags\":[");
    for (i, n) in names.iter().enumerate() {
        if i > 0 {
            out.push(b',');
        }
        push_str(&mut out, n);
    }
    out.extend_from_slice(b"]}");
    Ok((200, out))
}

// ---------------------------------------------------------------------------------------------------
// Users and auth
// ---------------------------------------------------------------------------------------------------

#[derive(Deserialize)]
struct RegisterEnvelope {
    user: Option<RegisterIn>,
}

#[derive(Deserialize)]
struct RegisterIn {
    username: Option<String>,
    email: Option<String>,
    password: Option<String>,
}

async fn h_register(app: &App, body: Incoming) -> Res {
    let bytes = read_body(body).await?;
    let env: RegisterEnvelope = parse_json(&bytes)?;
    let u = env.user.ok_or_else(|| err(422, "user is required"))?;
    let username = nonempty(u.username, "username can't be blank")?;
    let email = nonempty(u.email, "email can't be blank")?;
    let password = nonempty(u.password, "password can't be blank")?;
    check_password_len(&password)?;

    let hash = app.bc.hash(password).await.ok_or_else(|| err(500, "could not hash password"))?;

    let g = app.db.get();
    let row = match g.client.query_one(&g.st.user_insert, &[&username, &email, &hash]).await {
        Ok(r) => r,
        Err(e) if e.code() == Some(&SqlState::UNIQUE_VIOLATION) => {
            return Err(err(422, "username or email is already taken"));
        }
        Err(e) => return Err(e.into()),
    };
    let id: i64 = row.try_get(0)?;
    let token = app.jwt.sign(id);
    let mut out = Vec::with_capacity(256);
    write_user(&mut out, &row, &token)?;
    Ok((201, out))
}

#[derive(Deserialize)]
struct LoginEnvelope {
    user: Option<LoginIn>,
}

#[derive(Deserialize)]
struct LoginIn {
    email: Option<String>,
    password: Option<String>,
}

async fn h_login(app: &App, body: Incoming) -> Res {
    let bytes = read_body(body).await?;
    let env: LoginEnvelope = parse_json(&bytes)?;
    let u = env.user.ok_or_else(|| err(422, "user is required"))?;
    let email = nonempty(u.email, "email can't be blank")?;
    let password = nonempty(u.password, "password can't be blank")?;

    let found = {
        let g = app.db.get();
        let r = g.client.query_opt(&g.st.user_by_email, &[&email]).await?;
        r
    };
    let row = found.ok_or_else(|| err(401, "invalid email or password"))?;
    let hash = row.try_get::<_, &str>(5)?.to_string();
    if !app.bc.verify(password, hash).await {
        return Err(err(401, "invalid email or password"));
    }
    let id: i64 = row.try_get(0)?;
    let token = app.jwt.sign(id);
    let mut out = Vec::with_capacity(256);
    write_user(&mut out, &row, &token)?;
    Ok((200, out))
}

async fn h_current_user(app: &App, headers: &HeaderMap) -> Res {
    let au = auth_required(app, headers)?;
    let g = app.db.get();
    let row = g
        .client
        .query_opt(&g.st.user_by_id, &[&au.id])
        .await?
        .ok_or_else(|| err(401, "user not found"))?;
    let mut out = Vec::with_capacity(256);
    write_user(&mut out, &row, au.token)?;
    Ok((200, out))
}

#[derive(Deserialize)]
struct UpdateUserEnvelope {
    user: Option<UpdateUserIn>,
}

#[derive(Deserialize)]
struct UpdateUserIn {
    email: Option<String>,
    username: Option<String>,
    password: Option<String>,
    bio: Option<String>,
    image: Option<String>,
}

async fn h_update_user(app: &App, headers: &HeaderMap, body: Incoming) -> Res {
    let au = auth_required(app, headers)?;
    let bytes = read_body(body).await?;
    let env: UpdateUserEnvelope = parse_json(&bytes)?;
    let u = env.user.ok_or_else(|| err(422, "user is required"))?;
    // Absent or null = unchanged; present = must be a non-empty string (bio and image may be cleared).
    check_not_empty(&u.email, "email can't be blank")?;
    check_not_empty(&u.username, "username can't be blank")?;
    check_not_empty(&u.password, "password can't be blank")?;
    if let Some(p) = &u.password {
        check_password_len(p)?;
    }

    let hash: Option<String> = match u.password {
        Some(p) => Some(app.bc.hash(p).await.ok_or_else(|| err(500, "could not hash password"))?),
        None => None,
    };

    let g = app.db.get();
    let res = g
        .client
        .query_opt(&g.st.user_update, &[&au.id, &u.email, &u.username, &hash, &u.bio, &u.image])
        .await;
    let row = match res {
        Ok(Some(r)) => r,
        Ok(None) => return Err(err(401, "user not found")),
        Err(e) if e.code() == Some(&SqlState::UNIQUE_VIOLATION) => {
            return Err(err(422, "username or email is already taken"));
        }
        Err(e) => return Err(e.into()),
    };
    let mut out = Vec::with_capacity(256);
    write_user(&mut out, &row, au.token)?;
    Ok((200, out))
}

// ---------------------------------------------------------------------------------------------------
// Profiles
// ---------------------------------------------------------------------------------------------------

async fn h_profile(app: &App, headers: &HeaderMap, username: &str) -> Res {
    let viewer = viewer_of(app, headers)?;
    let g = app.db.get();
    let row = g
        .client
        .query_opt(&g.st.profile, &[&viewer, &username])
        .await?
        .ok_or_else(|| err(404, "profile not found"))?;
    let mut out = Vec::with_capacity(192);
    out.extend_from_slice(b"{\"profile\":");
    write_profile(
        &mut out,
        row.try_get::<_, &str>(0)?,
        row.try_get::<_, Option<&str>>(1)?,
        row.try_get::<_, Option<&str>>(2)?,
        row.try_get::<_, bool>(3)?,
    );
    out.push(b'}');
    Ok((200, out))
}

async fn h_follow(app: &App, headers: &HeaderMap, username: &str, follow: bool) -> Res {
    let au = auth_required(app, headers)?;
    let g = app.db.get();
    let st = if follow { &g.st.follow_add } else { &g.st.follow_del };
    let row = g
        .client
        .query_opt(st, &[&au.id, &username])
        .await?
        .ok_or_else(|| err(404, "profile not found"))?;
    let mut out = Vec::with_capacity(192);
    out.extend_from_slice(b"{\"profile\":");
    write_profile(
        &mut out,
        row.try_get::<_, &str>(0)?,
        row.try_get::<_, Option<&str>>(1)?,
        row.try_get::<_, Option<&str>>(2)?,
        follow,
    );
    out.push(b'}');
    Ok((200, out))
}

// ---------------------------------------------------------------------------------------------------
// Articles
// ---------------------------------------------------------------------------------------------------

async fn h_list(app: &App, headers: &HeaderMap, query: Option<&str>) -> Res {
    let viewer = viewer_of(app, headers)?;
    let q = parse_list_query(query)?;
    let (limit, offset) = (q.limit, q.offset);
    let g = app.db.get();

    // Only the first of tag / author / favorited applies, in that order.
    let rows: Vec<Row> = if let Some(t) = &q.tag {
        g.client.query(&g.st.list_tag, &[&viewer, &limit, &offset, t]).await?
    } else if let Some(a) = &q.author {
        g.client.query(&g.st.list_author, &[&viewer, &limit, &offset, a]).await?
    } else if let Some(f) = &q.favorited {
        g.client.query(&g.st.list_fav, &[&viewer, &limit, &offset, f]).await?
    } else {
        g.client.query(&g.st.list_all, &[&viewer, &limit, &offset]).await?
    };

    let total: i64 = match rows.first() {
        Some(r) => r.try_get::<_, i64>(12)?,
        None => {
            // Empty page: the count did not ride along, ask for it (offset past the end, unknown tag...).
            let row = if let Some(t) = &q.tag {
                g.client.query_one(&g.st.count_tag, &[t]).await?
            } else if let Some(a) = &q.author {
                g.client.query_one(&g.st.count_author, &[a]).await?
            } else if let Some(f) = &q.favorited {
                g.client.query_one(&g.st.count_fav, &[f]).await?
            } else {
                g.client.query_one(&g.st.count_all, &[]).await?
            };
            row.try_get::<_, i64>(0)?
        }
    };
    Ok((200, build_list(&rows, total)?))
}

async fn h_feed(app: &App, headers: &HeaderMap, query: Option<&str>) -> Res {
    let au = auth_required(app, headers)?;
    let q = parse_list_query(query)?;
    // The feed statement uses int4 parameters (as the reference SQL does); clamp so that
    // limit + offset cannot overflow. An offset this large is past the end of any feed anyway.
    let limit32 = q.limit as i32;
    let offset32 = q.offset.min(1_000_000_000) as i32;
    let g = app.db.get();
    let rows = g.client.query(&g.st.list_feed, &[&au.id, &limit32, &offset32]).await?;
    let total: i64 = match rows.first() {
        Some(r) => r.try_get::<_, i64>(12)?,
        None => g.client.query_one(&g.st.count_feed, &[&au.id]).await?.try_get::<_, i64>(0)?,
    };
    Ok((200, build_list(&rows, total)?))
}

async fn h_article(app: &App, headers: &HeaderMap, slug: &str) -> Res {
    let viewer = viewer_of(app, headers)?;
    let g = app.db.get();
    let row = g
        .client
        .query_opt(&g.st.article_by_slug, &[&viewer, &slug])
        .await?
        .ok_or_else(|| err(404, "article not found"))?;
    Ok((200, article_json(&row)?))
}

#[derive(Deserialize)]
struct CreateArticleEnvelope {
    article: Option<CreateArticleIn>,
}

#[derive(Deserialize)]
struct CreateArticleIn {
    title: Option<String>,
    description: Option<String>,
    body: Option<String>,
    #[serde(rename = "tagList")]
    tag_list: Option<Vec<String>>,
}

async fn h_create_article(app: &App, headers: &HeaderMap, body: Incoming) -> Res {
    let au = auth_required(app, headers)?;
    let bytes = read_body(body).await?;
    let env: CreateArticleEnvelope = parse_json(&bytes)?;
    let a = env.article.ok_or_else(|| err(422, "article is required"))?;
    let title = nonempty(a.title, "title can't be blank")?;
    let description = nonempty(a.description, "description can't be blank")?;
    let text = nonempty(a.body, "body can't be blank")?;
    let tags: Vec<String> = a.tag_list.unwrap_or_default();
    if tags.iter().any(|t| t.is_empty()) {
        return Err(err(422, "tags can't be blank"));
    }

    let g = app.db.get();
    let created = g
        .client
        .query_one(&g.st.article_insert, &[&au.id, &title, &description, &text, &tags])
        .await?;
    let id: i64 = created.try_get(0)?;
    let row = g.client.query_one(&g.st.article_by_id, &[&au.id, &id]).await?;
    Ok((201, article_json(&row)?))
}

#[derive(Deserialize)]
struct UpdateArticleEnvelope {
    article: Option<UpdateArticleIn>,
}

#[derive(Deserialize)]
struct UpdateArticleIn {
    title: Option<String>,
    description: Option<String>,
    body: Option<String>,
}

async fn h_update_article(app: &App, headers: &HeaderMap, slug: &str, body: Incoming) -> Res {
    let au = auth_required(app, headers)?;
    let bytes = read_body(body).await?;
    let env: UpdateArticleEnvelope = parse_json(&bytes)?;
    let a = env.article.ok_or_else(|| err(422, "article is required"))?;
    // Absent or null = unchanged; present = must be a non-empty string.
    check_not_empty(&a.title, "title can't be blank")?;
    check_not_empty(&a.description, "description can't be blank")?;
    check_not_empty(&a.body, "body can't be blank")?;

    let g = app.db.get();
    let found = g
        .client
        .query_opt(&g.st.article_lookup, &[&slug])
        .await?
        .ok_or_else(|| err(404, "article not found"))?;
    let id: i64 = found.try_get(0)?;
    let author: i64 = found.try_get(1)?;
    if author != au.id {
        return Err(err(403, "forbidden"));
    }
    g.client.execute(&g.st.article_update, &[&id, &a.title, &a.description, &a.body]).await?;
    let row = g.client.query_one(&g.st.article_by_id, &[&au.id, &id]).await?;
    Ok((200, article_json(&row)?))
}

async fn h_delete_article(app: &App, headers: &HeaderMap, slug: &str) -> Res {
    let au = auth_required(app, headers)?;
    let g = app.db.get();
    let found = g
        .client
        .query_opt(&g.st.article_lookup, &[&slug])
        .await?
        .ok_or_else(|| err(404, "article not found"))?;
    let id: i64 = found.try_get(0)?;
    let author: i64 = found.try_get(1)?;
    if author != au.id {
        return Err(err(403, "forbidden"));
    }
    g.client.execute(&g.st.article_delete, &[&id]).await?;
    Ok((204, Vec::new()))
}

// ---------------------------------------------------------------------------------------------------
// Favorites
// ---------------------------------------------------------------------------------------------------

async fn h_favorite(app: &App, headers: &HeaderMap, slug: &str, add: bool) -> Res {
    let au = auth_required(app, headers)?;
    let g = app.db.get();
    let st = if add { &g.st.fav_add } else { &g.st.fav_del };
    let found = g
        .client
        .query_opt(st, &[&au.id, &slug])
        .await?
        .ok_or_else(|| err(404, "article not found"))?;
    let id: i64 = found.try_get(0)?;
    // The write above is committed (single autocommit statement); read the article back.
    let row = g.client.query_one(&g.st.article_by_id, &[&au.id, &id]).await?;
    Ok((200, article_json(&row)?))
}

// ---------------------------------------------------------------------------------------------------
// Comments
// ---------------------------------------------------------------------------------------------------

async fn h_comments(app: &App, headers: &HeaderMap, slug: &str) -> Res {
    let viewer = viewer_of(app, headers)?;
    let g = app.db.get();
    let rows = g.client.query(&g.st.comments, &[&viewer, &slug]).await?;
    if rows.is_empty() {
        return Err(err(404, "article not found"));
    }
    let mut out = Vec::with_capacity(32 + rows.len() * 320);
    out.extend_from_slice(b"{\"comments\":[");
    let mut first = true;
    for row in &rows {
        // An existing article without comments comes back as a single all-NULL comment row.
        if row.try_get::<_, Option<i64>>(0)?.is_none() {
            continue;
        }
        if !first {
            out.push(b',');
        }
        first = false;
        let following: bool = row.try_get(7)?;
        write_comment(&mut out, row, following)?;
    }
    out.extend_from_slice(b"]}");
    Ok((200, out))
}

#[derive(Deserialize)]
struct CommentEnvelope {
    comment: Option<CommentIn>,
}

#[derive(Deserialize)]
struct CommentIn {
    body: Option<String>,
}

async fn h_add_comment(app: &App, headers: &HeaderMap, slug: &str, body: Incoming) -> Res {
    let au = auth_required(app, headers)?;
    let bytes = read_body(body).await?;
    let env: CommentEnvelope = parse_json(&bytes)?;
    let text = nonempty(env.comment.and_then(|c| c.body), "comment body can't be blank")?;

    let g = app.db.get();
    let row = g
        .client
        .query_opt(&g.st.comment_insert, &[&au.id, &slug, &text])
        .await?
        .ok_or_else(|| err(404, "article not found"))?;
    let mut out = Vec::with_capacity(384);
    out.extend_from_slice(b"{\"comment\":");
    write_comment(&mut out, &row, false)?;
    out.push(b'}');
    Ok((201, out))
}

async fn h_delete_comment(app: &App, headers: &HeaderMap, slug: &str, id: &str) -> Res {
    let au = auth_required(app, headers)?;
    let cid: i64 = id.parse().map_err(|_| err(404, "comment not found"))?;
    let g = app.db.get();
    let deleted = g.client.execute(&g.st.comment_delete, &[&cid, &slug, &au.id]).await?;
    if deleted > 0 {
        return Ok((204, Vec::new()));
    }
    // Nothing deleted: either it does not exist (404) or it belongs to somebody else (403).
    match g.client.query_opt(&g.st.comment_lookup, &[&cid, &slug]).await? {
        None => Err(err(404, "comment not found")),
        Some(row) => {
            let author: i64 = row.try_get(0)?;
            if author != au.id {
                Err(err(403, "forbidden"))
            } else {
                Err(err(404, "comment not found"))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_percent_escapes() {
        assert_eq!(pdecode("plain", false), "plain");
        assert_eq!(pdecode("a%20b", false), "a b");
        assert_eq!(pdecode("a+b", false), "a+b");
        assert_eq!(pdecode("a+b", true), "a b");
        assert_eq!(pdecode("%41%42", false), "AB");
        assert_eq!(pdecode("100%", false), "100%");
        assert_eq!(pdecode("%zz", false), "%zz");
        assert_eq!(pdecode("caf%C3%A9", false), "café");
    }

    #[test]
    fn parses_list_query() {
        let q = parse_list_query(None).ok().unwrap();
        assert_eq!((q.limit, q.offset), (20, 0));
        let q = parse_list_query(Some("limit=10&offset=30&tag=rust%20lang")).ok().unwrap();
        assert_eq!((q.limit, q.offset), (10, 30));
        assert_eq!(q.tag.as_deref(), Some("rust lang"));
        assert!(parse_list_query(Some("limit=0")).is_err());
        assert!(parse_list_query(Some("limit=101")).is_err());
        assert!(parse_list_query(Some("limit=abc")).is_err());
        assert!(parse_list_query(Some("limit=")).is_err());
        assert!(parse_list_query(Some("offset=-1")).is_err());
        assert!(parse_list_query(Some("offset=1.5")).is_err());
        assert!(parse_list_query(Some("limit=%2B5")).is_err());
        assert!(parse_list_query(Some("limit=+5")).is_err());
        assert!(parse_list_query(Some("limit=-5")).is_err());
        assert!(parse_list_query(Some("offset=%2B5")).is_err());
        assert!(parse_list_query(Some("limit=5%20")).is_err());
        assert!(parse_list_query(Some("limit=99999999999999999999")).is_err());
        assert_eq!(parse_list_query(Some("limit=05")).ok().unwrap().limit, 5);
    }

    #[test]
    fn strict_unsigned_ints() {
        assert_eq!(parse_uint("0"), Some(0));
        assert_eq!(parse_uint("42"), Some(42));
        assert_eq!(parse_uint(""), None);
        assert_eq!(parse_uint("+1"), None);
        assert_eq!(parse_uint("-1"), None);
        assert_eq!(parse_uint(" 1"), None);
        assert_eq!(parse_uint("1_0"), None);
    }
}
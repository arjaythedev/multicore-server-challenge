//! Routing and the 19 endpoints. Order of checks everywhere: auth (401), then the request body (422), then the
//! database (404/403/422).

use std::borrow::Cow;

use http::{Method, StatusCode};
use serde_json::{Map, Value};
use tokio_postgres::{Row, error::SqlState};

use crate::{app, json, parse_uint};

pub struct Resp {
    pub status: u16,
    pub body: Vec<u8>,
}

pub enum ApiError {
    Unauthorized,
    Forbidden,
    NotFound,
    Unprocessable(&'static str),
    Internal(String),
}

impl From<crate::db::Error> for ApiError {
    fn from(e: crate::db::Error) -> Self {
        ApiError::Internal(e.to_string())
    }
}

type Result<T> = std::result::Result<T, ApiError>;

/// A unique violation (SQLSTATE 23505) is 422; any other database error is 500.
fn unique_to_422(e: crate::db::Error) -> ApiError {
    if e.code() == Some(&SqlState::UNIQUE_VIOLATION) {
        ApiError::Unprocessable("username or email already taken")
    } else {
        e.into()
    }
}

fn respond(status: StatusCode, body: Vec<u8>) -> Resp {
    Resp {
        status: status.as_u16(),
        body,
    }
}

fn ok(body: Vec<u8>) -> Result<Resp> {
    Ok(respond(StatusCode::OK, body))
}
fn no_content() -> Result<Resp> {
    Ok(respond(StatusCode::NO_CONTENT, Vec::new()))
}

pub fn error_response(e: ApiError) -> Resp {
    let (status, msg) = match e {
        ApiError::Unauthorized => (StatusCode::UNAUTHORIZED, "unauthorized"),
        ApiError::Forbidden => (StatusCode::FORBIDDEN, "forbidden"),
        ApiError::NotFound => (StatusCode::NOT_FOUND, "not found"),
        ApiError::Unprocessable(m) => (StatusCode::UNPROCESSABLE_ENTITY, m),
        ApiError::Internal(err) => {
            eprintln!("[error] {err}");
            (StatusCode::INTERNAL_SERVER_ERROR, "internal server error")
        }
    };
    let mut out = crate::http::take();
    out.extend_from_slice(b"{\"errors\":{\"body\":[");
    json::str(&mut out, msg);
    out.extend_from_slice(b"]}}");
    respond(status, out)
}

// ---------- request pieces ----------

/// The Authorization header: absent is anonymous; anything else must be a valid `Token <jwt>`.
pub struct Auth<'a>(pub Option<&'a [u8]>);

impl<'a> Auth<'a> {
    /// Auth-optional endpoints: the viewer id, 0 when anonymous.
    fn viewer(&self) -> Result<i64> {
        match self.0 {
            None => Ok(0),
            Some(_) => self.user().map(|(id, _)| id),
        }
    }

    /// Auth-required endpoints: the user id and the presented token.
    fn user(&self) -> Result<(i64, &'a str)> {
        let raw = self.0.ok_or(ApiError::Unauthorized)?;
        let token = std::str::from_utf8(raw)
            .ok()
            .and_then(|v| v.strip_prefix("Token "))
            .ok_or(ApiError::Unauthorized)?;
        let id = app().jwt.verify(token).ok_or(ApiError::Unauthorized)?;
        Ok((id, token))
    }
}

/// First value of each query parameter (like Go's `url.Values.Get`).
struct Query<'a>([Option<Cow<'a, str>>; 5]);

impl<'a> Query<'a> {
    fn index(key: &str) -> Option<usize> {
        match key {
            "limit" => Some(0),
            "offset" => Some(1),
            "tag" => Some(2),
            "author" => Some(3),
            "favorited" => Some(4),
            _ => None,
        }
    }
    fn parse(q: Option<&'a str>) -> Self {
        let mut values = [const { None }; 5];
        if let Some(q) = q {
            for (key, value) in form_urlencoded::parse(q.as_bytes()) {
                if let Some(i) = Self::index(&key)
                    && values[i].is_none()
                {
                    values[i] = Some(value);
                }
            }
        }
        Self(values)
    }
    fn get(&self, key: &str) -> Option<&str> {
        self.0[Self::index(key)?].as_deref()
    }

    /// A non-empty filter value.
    fn filter(&self, key: &str) -> Option<&str> {
        self.get(key).filter(|v| !v.is_empty())
    }

    /// `limit` (default 20, 1..=100) and `offset` (default 0, >= 0): ASCII digits only, otherwise 422.
    fn page(&self) -> Result<(i64, i64)> {
        let limit = match self.get("limit") {
            None => 20,
            Some(v) => parse_uint(v)
                .filter(|n| (1..=100).contains(n))
                .ok_or(ApiError::Unprocessable("invalid limit"))?,
        };
        let offset = match self.get("offset") {
            None => 0,
            Some(v) => parse_uint(v).ok_or(ApiError::Unprocessable("invalid offset"))?,
        };
        Ok((limit, offset))
    }
}

/// The object under `key` in a JSON body (`{"user": {...}}`), or 422.
fn body_object(body: &[u8], key: &str) -> Result<Map<String, Value>> {
    match serde_json::from_slice::<Value>(body) {
        Ok(Value::Object(mut m)) => match m.remove(key) {
            Some(Value::Object(o)) => Ok(o),
            _ => Err(ApiError::Unprocessable("missing or invalid request object")),
        },
        _ => Err(ApiError::Unprocessable("malformed JSON body")),
    }
}

/// A required, non-empty string field.
fn required(obj: &mut Map<String, Value>, key: &str) -> Result<String> {
    match obj.remove(key) {
        Some(Value::String(s)) if !s.is_empty() => Ok(s),
        _ => Err(ApiError::Unprocessable("required field missing or empty")),
    }
}

/// An optional string field: absent or null is None; a non-string (or an empty string when `non_empty`) is 422.
fn optional(obj: &mut Map<String, Value>, key: &str, non_empty: bool) -> Result<Option<String>> {
    match obj.remove(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) if !(non_empty && s.is_empty()) => Ok(Some(s)),
        _ => Err(ApiError::Unprocessable("field must be a non-empty string")),
    }
}

// ---------- routing ----------

pub async fn route(
    method: &Method,
    path: &str,
    query: Option<&str>,
    auth: Auth<'_>,
    body: &[u8],
) -> Result<Resp> {
    let rest = path.strip_prefix("/api/").ok_or(ApiError::NotFound)?;
    let mut segs: [Cow<str>; 4] = Default::default();
    let mut n = 0;
    for s in rest.split('/') {
        if n == 4 {
            return Err(ApiError::NotFound);
        }
        segs[n] = percent_encoding::percent_decode_str(s)
            .decode_utf8()
            .map_err(|_| ApiError::NotFound)?;
        n += 1;
    }
    let s: [&str; 4] = std::array::from_fn(|i| segs[i].as_ref());
    match (method, &s[..n]) {
        (&Method::GET, ["tags"]) => tags().await,
        (&Method::POST, ["users"]) => register(body).await,
        (&Method::POST, ["users", "login"]) => login(body).await,
        (&Method::GET, ["user"]) => current_user(auth).await,
        (&Method::PUT, ["user"]) => update_user(auth, body).await,
        (&Method::GET, ["profiles", u]) if !u.is_empty() => profile(auth, u).await,
        (&Method::POST, ["profiles", u, "follow"]) if !u.is_empty() => follow(auth, u, true).await,
        (&Method::DELETE, ["profiles", u, "follow"]) if !u.is_empty() => {
            follow(auth, u, false).await
        }
        (&Method::GET, ["articles"]) => list(auth, query).await,
        (&Method::POST, ["articles"]) => create_article(auth, body).await,
        (&Method::GET, ["articles", "feed"]) => feed(auth, query).await,
        (&Method::GET, ["articles", slug]) if !slug.is_empty() => get_article(auth, slug).await,
        (&Method::PUT, ["articles", slug]) if !slug.is_empty() => {
            update_article(auth, slug, body).await
        }
        (&Method::DELETE, ["articles", slug]) if !slug.is_empty() => {
            delete_article(auth, slug).await
        }
        (&Method::POST, ["articles", slug, "favorite"]) if !slug.is_empty() => {
            favorite(auth, slug, true).await
        }
        (&Method::DELETE, ["articles", slug, "favorite"]) if !slug.is_empty() => {
            favorite(auth, slug, false).await
        }
        (&Method::GET, ["articles", slug, "comments"]) if !slug.is_empty() => {
            comments(auth, slug).await
        }
        (&Method::POST, ["articles", slug, "comments"]) if !slug.is_empty() => {
            add_comment(auth, slug, body).await
        }
        (&Method::DELETE, ["articles", slug, "comments", id])
            if !slug.is_empty() && !id.is_empty() =>
        {
            delete_comment(auth, slug, id).await
        }
        _ => Err(ApiError::NotFound),
    }
}

// ---------- response writers ----------

fn write_profile(out: &mut Vec<u8>, row: &Row, k: usize, following: bool) {
    out.extend_from_slice(b"{\"username\":");
    json::str(out, row.get(k));
    out.extend_from_slice(b",\"bio\":");
    json::opt_str(out, row.get(k + 1));
    out.extend_from_slice(b",\"image\":");
    json::opt_str(out, row.get(k + 2));
    out.extend_from_slice(b",\"following\":");
    json::bool(out, following);
    out.push(b'}');
}

/// An Article from the column layout in sql.rs, starting at column `b` (the id).
fn write_article(out: &mut Vec<u8>, row: &Row, b: usize, with_body: bool) {
    out.extend_from_slice(b"{\"slug\":");
    json::str(out, row.get(b + 1));
    out.extend_from_slice(b",\"title\":");
    json::str(out, row.get(b + 2));
    out.extend_from_slice(b",\"description\":");
    json::str(out, row.get(b + 3));
    let mut k = b + 4;
    if with_body {
        out.extend_from_slice(b",\"body\":");
        json::str(out, row.get(k));
        k += 1;
    }
    out.extend_from_slice(b",\"tagList\":");
    row.get::<_, json::Tags<'_>>(k + 2).write(out);
    json::times(out, &row.get(k), &row.get(k + 1));
    out.extend_from_slice(b",\"favorited\":");
    json::bool(out, row.get(k + 4));
    out.extend_from_slice(b",\"favoritesCount\":");
    json::int(out, row.get(k + 3));
    out.extend_from_slice(b",\"author\":");
    write_profile(out, row, k + 5, row.get(k + 8));
    out.push(b'}');
}

fn article_envelope(row: &Row) -> Vec<u8> {
    let mut out = crate::http::take();
    out.extend_from_slice(b"{\"article\":");
    write_article(&mut out, row, 0, true);
    out.push(b'}');
    out
}

/// Rows of a list statement: column 0 is the capped count, then a list Article (all NULL on an empty page).
fn article_list(rows: &[Row]) -> Vec<u8> {
    let mut out = crate::http::take();
    out.extend_from_slice(b"{\"articles\":[");
    let mut count = 0i64;
    let mut first = true;
    for row in rows {
        count = row.get(0);
        if row.get::<_, Option<i64>>(1).is_none() {
            continue;
        }
        if !first {
            out.push(b',');
        }
        first = false;
        write_article(&mut out, row, 1, false);
    }
    out.extend_from_slice(b"],\"articlesCount\":");
    json::int(&mut out, count);
    out.push(b'}');
    out
}

/// `{"user": User}` from (id, username, email, bio, image).
fn user_envelope(row: &Row, token: &str) -> Vec<u8> {
    let mut out = crate::http::take();
    out.extend_from_slice(b"{\"user\":{\"email\":");
    json::str(&mut out, row.get(2));
    out.extend_from_slice(b",\"token\":");
    json::str(&mut out, token);
    out.extend_from_slice(b",\"username\":");
    json::str(&mut out, row.get(1));
    out.extend_from_slice(b",\"bio\":");
    json::opt_str(&mut out, row.get(3));
    out.extend_from_slice(b",\"image\":");
    json::opt_str(&mut out, row.get(4));
    out.extend_from_slice(b"}}");
    out
}

/// A Comment from (id, body, created_at, updated_at, username, bio, image) starting at column `b`.
fn write_comment(out: &mut Vec<u8>, row: &Row, b: usize, following: bool) {
    out.extend_from_slice(b"{\"id\":");
    json::int(out, row.get(b));
    json::times(out, &row.get(b + 2), &row.get(b + 3));
    out.extend_from_slice(b",\"body\":");
    json::str(out, row.get(b + 1));
    out.extend_from_slice(b",\"author\":");
    write_profile(out, row, b + 4, following);
    out.push(b'}');
}

// ---------- users ----------

/// bcrypt only uses the first 72 bytes, so longer passwords are rejected rather than silently truncated.
async fn hash_password(password: String) -> Result<String> {
    if password.len() > 72 {
        return Err(ApiError::Unprocessable("password is too long"));
    }
    #[cfg(all(feature = "batch-bcrypt", target_os = "linux"))]
    return app()
        .bcrypt_batch
        .hash(password)
        .await
        .map_err(ApiError::Internal);
    #[cfg(not(all(feature = "batch-bcrypt", target_os = "linux")))]
    {
        let _permit = app()
            .bcrypt
            .acquire()
            .await
            .map_err(|e| ApiError::Internal(e.to_string()))?;
        tokio::task::spawn_blocking(move || crate::password::hash(&password))
            .await
            .map_err(|e| ApiError::Internal(e.to_string()))?
            .map_err(|e| ApiError::Internal(e.to_string()))
    }
}

async fn verify_password(password: String, hash: String) -> Result<bool> {
    if password.len() > 72 {
        return Ok(false);
    }
    #[cfg(all(feature = "batch-bcrypt", target_os = "linux"))]
    return app()
        .bcrypt_batch
        .verify(password, hash)
        .await
        .map_err(ApiError::Internal);
    #[cfg(not(all(feature = "batch-bcrypt", target_os = "linux")))]
    {
        let _permit = app()
            .bcrypt
            .acquire()
            .await
            .map_err(|e| ApiError::Internal(e.to_string()))?;
        tokio::task::spawn_blocking(move || crate::password::verify(&password, &hash))
            .await
            .map_err(|e| ApiError::Internal(e.to_string()))
    }
}

async fn register(body: &[u8]) -> Result<Resp> {
    let mut obj = body_object(body, "user")?;
    let username = required(&mut obj, "username")?;
    let email = required(&mut obj, "email")?;
    let password = required(&mut obj, "password")?;
    let hash = hash_password(password).await?;
    let c = app().db.write();
    let row = c
        .client
        .query_one(&c.st.user_insert, &[&username, &email, &hash])
        .await
        .map_err(unique_to_422)?;
    let token = app().jwt.issue(row.get(0));
    Ok(respond(StatusCode::CREATED, user_envelope(&row, &token)))
}

async fn login(body: &[u8]) -> Result<Resp> {
    let mut obj = body_object(body, "user")?;
    let email = required(&mut obj, "email")?;
    let password = required(&mut obj, "password")?;
    let row = {
        let c = app().db.read(crate::db::ReadKind::UserEmail);
        c.client
            .query_opt(&c.st.user_by_email, &[&email])
            .await?
            .ok_or(ApiError::Unauthorized)?
    };
    let hash: String = row.get(5);
    if !verify_password(password, hash).await? {
        return Err(ApiError::Unauthorized);
    }
    let token = app().jwt.issue(row.get(0));
    ok(user_envelope(&row, &token))
}

async fn current_user(auth: Auth<'_>) -> Result<Resp> {
    let (id, token) = auth.user()?;
    let c = app().db.read(crate::db::ReadKind::UserId);
    let row = c
        .client
        .query_opt(&c.st.user_by_id, &[&id])
        .await?
        .ok_or(ApiError::Unauthorized)?;
    ok(user_envelope(&row, token))
}

async fn update_user(auth: Auth<'_>, body: &[u8]) -> Result<Resp> {
    let (id, token) = auth.user()?;
    let mut obj = body_object(body, "user")?;
    let email = optional(&mut obj, "email", true)?;
    let username = optional(&mut obj, "username", true)?;
    let password = optional(&mut obj, "password", true)?;
    let bio = optional(&mut obj, "bio", false)?;
    let image = optional(&mut obj, "image", false)?;
    let hash = match password {
        Some(p) => Some(hash_password(p).await?),
        None => None,
    };
    let c = app().db.write();
    let row = c
        .client
        .query_opt(
            &c.st.user_update,
            &[&id, &email, &username, &hash, &bio, &image],
        )
        .await
        .map_err(unique_to_422)?
        .ok_or(ApiError::Unauthorized)?;
    ok(user_envelope(&row, token))
}

// ---------- profiles ----------

async fn profile(auth: Auth<'_>, username: &str) -> Result<Resp> {
    let viewer = auth.viewer()?;
    let c = app().db.read(crate::db::ReadKind::Profile);
    let row = c
        .client
        .query_opt(&c.st.profile, &[&viewer, &username])
        .await?
        .ok_or(ApiError::NotFound)?;
    let mut out = crate::http::take();
    out.extend_from_slice(b"{\"profile\":");
    write_profile(&mut out, &row, 0, row.get(3));
    out.push(b'}');
    ok(out)
}

async fn follow(auth: Auth<'_>, username: &str, on: bool) -> Result<Resp> {
    let (viewer, _) = auth.user()?;
    let c = app().db.write();
    let st = if on { &c.st.follow } else { &c.st.unfollow };
    let row = c
        .client
        .query_opt(st, &[&viewer, &username])
        .await?
        .ok_or(ApiError::NotFound)?;
    let mut out = crate::http::take();
    out.extend_from_slice(b"{\"profile\":");
    write_profile(&mut out, &row, 0, on);
    out.push(b'}');
    ok(out)
}

// ---------- articles ----------

async fn list(auth: Auth<'_>, query: Option<&str>) -> Result<Resp> {
    let viewer = auth.viewer()?;
    let q = Query::parse(query);
    let (limit, offset) = q.page()?;
    use crate::db::ReadKind;
    let (family, filter) = if let Some(tag) = q.filter("tag") {
        (ReadKind::Tag, Some(tag))
    } else if let Some(author) = q.filter("author") {
        (ReadKind::Author, Some(author))
    } else if let Some(fav) = q.filter("favorited") {
        (ReadKind::Favorited, Some(fav))
    } else {
        (ReadKind::All, None)
    };
    let c = app().db.read(family);
    let rows = if let Some(filter) = filter {
        let st = match family {
            ReadKind::Tag => &c.st.list_tag,
            ReadKind::Author => &c.st.list_author,
            ReadKind::Favorited => &c.st.list_favorited,
            _ => unreachable!("filtered list family"),
        };
        c.client
            .query(st, &[&viewer, &limit, &offset, &filter])
            .await?
    } else {
        c.client
            .query(&c.st.list_all, &[&viewer, &limit, &offset])
            .await?
    };
    drop(c);
    ok(article_list(&rows))
}

async fn feed(auth: Auth<'_>, query: Option<&str>) -> Result<Resp> {
    let (viewer, _) = auth.user()?;
    let (limit, offset) = Query::parse(query).page()?;
    let c = app().db.read(crate::db::ReadKind::Feed);
    let rows = c
        .client
        .query(
            &c.st.list_feed,
            &[&viewer, &limit, &offset, &limit.saturating_add(offset)],
        )
        .await?;
    drop(c);
    ok(article_list(&rows))
}

async fn get_article(auth: Auth<'_>, slug: &str) -> Result<Resp> {
    let viewer = auth.viewer()?;
    let c = app().db.read(crate::db::ReadKind::ArticleSlug);
    let row = c
        .client
        .query_opt(&c.st.article_by_slug, &[&viewer, &slug])
        .await?
        .ok_or(ApiError::NotFound)?;
    drop(c);
    ok(article_envelope(&row))
}

async fn create_article(auth: Auth<'_>, body: &[u8]) -> Result<Resp> {
    let (viewer, _) = auth.user()?;
    let mut obj = body_object(body, "article")?;
    let title = required(&mut obj, "title")?;
    let description = required(&mut obj, "description")?;
    let text = required(&mut obj, "body")?;
    let tags: Vec<String> = match obj.remove("tagList") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(items)) => items
            .into_iter()
            .map(|t| match t {
                Value::String(s) if !s.is_empty() => Ok(s),
                _ => Err(ApiError::Unprocessable(
                    "tagList must be an array of non-empty strings",
                )),
            })
            .collect::<Result<_>>()?,
        Some(_) => {
            return Err(ApiError::Unprocessable(
                "tagList must be an array of non-empty strings",
            ));
        }
    };
    let c = app().db.write();
    let row = c
        .client
        .query_one(
            &c.st.article_create,
            &[&viewer, &title, &description, &text, &tags],
        )
        .await?;
    drop(c);
    Ok(respond(StatusCode::CREATED, article_envelope(&row)))
}

async fn update_article(auth: Auth<'_>, slug: &str, body: &[u8]) -> Result<Resp> {
    let (viewer, _) = auth.user()?;
    let mut obj = body_object(body, "article")?;
    let title = optional(&mut obj, "title", true)?;
    let description = optional(&mut obj, "description", true)?;
    let text = optional(&mut obj, "body", true)?;
    let c = app().db.write();
    let row = c
        .client
        .query_opt(
            &c.st.article_update,
            &[&slug, &title, &description, &text, &viewer],
        )
        .await?
        .ok_or(ApiError::NotFound)?;
    // Column 0..13 come from the UPDATE's RETURNING and are only present when the update
    // applied; the author id (14) comes from the always-present slug lookup.
    if row.get::<_, i64>(14) != viewer {
        return Err(ApiError::Forbidden);
    }
    drop(c);
    ok(article_envelope(&row))
}

async fn delete_article(auth: Auth<'_>, slug: &str) -> Result<Resp> {
    let (viewer, _) = auth.user()?;
    let c = app().db.write();
    let row = c
        .client
        .query_opt(&c.st.article_delete, &[&slug, &viewer])
        .await?
        .ok_or(ApiError::NotFound)?;
    if row.get::<_, i64>(0) != viewer {
        return Err(ApiError::Forbidden);
    }
    no_content()
}

async fn favorite(auth: Auth<'_>, slug: &str, on: bool) -> Result<Resp> {
    let (viewer, _) = auth.user()?;
    let c = app().db.write();
    let st = if on { &c.st.favorite } else { &c.st.unfavorite };
    let row = c
        .client
        .query_opt(st, &[&viewer, &slug])
        .await?
        .ok_or(ApiError::NotFound)?;
    ok(article_envelope(&row))
}

// ---------- comments ----------

async fn comments(auth: Auth<'_>, slug: &str) -> Result<Resp> {
    let viewer = auth.viewer()?;
    let c = app().db.read(crate::db::ReadKind::Comments);
    let rows = c
        .client
        .query(&c.st.comments_list, &[&viewer, &slug])
        .await?;
    drop(c);
    if rows.is_empty() {
        return Err(ApiError::NotFound);
    }
    let mut out = crate::http::take();
    out.extend_from_slice(b"{\"comments\":[");
    let mut first = true;
    for row in &rows {
        if row.get::<_, Option<i64>>(1).is_none() {
            continue;
        }
        if !first {
            out.push(b',');
        }
        first = false;
        write_comment(&mut out, row, 1, row.get(8));
    }
    out.extend_from_slice(b"]}");
    ok(out)
}

async fn add_comment(auth: Auth<'_>, slug: &str, body: &[u8]) -> Result<Resp> {
    let (viewer, _) = auth.user()?;
    let text = required(&mut body_object(body, "comment")?, "body")?;
    let c = app().db.write();
    let row = c
        .client
        .query_opt(&c.st.comment_create, &[&slug, &viewer, &text])
        .await?
        .ok_or(ApiError::NotFound)?;
    drop(c);
    let mut out = crate::http::take();
    out.extend_from_slice(b"{\"comment\":");
    write_comment(&mut out, &row, 0, false);
    out.push(b'}');
    Ok(respond(StatusCode::CREATED, out))
}

async fn delete_comment(auth: Auth<'_>, slug: &str, id: &str) -> Result<Resp> {
    let (viewer, _) = auth.user()?;
    let id = parse_uint(id).ok_or(ApiError::NotFound)?;
    let c = app().db.write();
    let row = c
        .client
        .query_opt(&c.st.comment_delete, &[&id, &slug, &viewer])
        .await?
        .ok_or(ApiError::NotFound)?;
    if row.get::<_, i64>(0) != viewer {
        return Err(ApiError::Forbidden);
    }
    no_content()
}

// ---------- tags ----------

async fn tags() -> Result<Resp> {
    let c = app().db.read(crate::db::ReadKind::Tags);
    let row = c.client.query_one(&c.st.tags, &[]).await?;
    drop(c);
    let mut out = crate::http::take();
    out.extend_from_slice(b"{\"tags\":");
    row.get::<_, json::Tags<'_>>(0).write(&mut out);
    out.push(b'}');
    ok(out)
}

//! The Conduit HTTP API: routes, the request context, and responses.
//!
//! Handlers are plain functions `fn(&Req) -> Result<Reply, AppError>`; [`routes`] wraps each in
//! a urus plug that builds the [`Req`] and turns the result into a response.

mod articles;
mod comments;
mod profiles;
mod users;

use std::sync::Arc;

use serde::de::DeserializeOwned;
use serde::Serialize;
use urus::{Conn, Next, Plug, Router};

use crate::auth::Jwt;
use crate::db::{Db, PgError};
use crate::http::{pct_decode, Query};

/// What every handler can reach. Shared by all connection actors; holds no mutable state.
pub struct App {
    pub db: Db,
    pub jwt: Jwt,
}

pub fn routes(app: Arc<App>) -> Router {
    let h = |f: Handler| handler(app.clone(), f);
    Router::new()
        .get("/api/tags", h(articles::tags))
        .post("/api/users", h(users::register))
        .post("/api/users/login", h(users::login))
        .get("/api/user", h(users::current))
        .put("/api/user", h(users::update))
        .get("/api/profiles/:username", h(profiles::get))
        .post("/api/profiles/:username/follow", h(profiles::follow))
        .delete("/api/profiles/:username/follow", h(profiles::unfollow))
        .get("/api/articles", h(articles::list))
        .post("/api/articles", h(articles::create))
        // before /api/articles/:slug, which would otherwise match "feed"
        .get("/api/articles/feed", h(articles::feed))
        .get("/api/articles/:slug", h(articles::get))
        .put("/api/articles/:slug", h(articles::update))
        .delete("/api/articles/:slug", h(articles::delete))
        .post("/api/articles/:slug/favorite", h(articles::favorite))
        .delete("/api/articles/:slug/favorite", h(articles::unfavorite))
        .get("/api/articles/:slug/comments", h(comments::list))
        .post("/api/articles/:slug/comments", h(comments::create))
        .delete("/api/articles/:slug/comments/:id", h(comments::delete))
}

/// Unmatched paths: JSON 404, like the reference servers.
pub fn not_found(c: Conn, _n: Next) -> Conn {
    respond(c, Err(AppError::NotFound))
}

type Handler = fn(&Req) -> Result<Reply, AppError>;

fn handler(app: Arc<App>, f: Handler) -> impl Plug {
    move |conn: Conn, _n: Next| {
        let req = Req { app: app.clone(), conn };
        let result = f(&req);
        respond(req.conn, result)
    }
}

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

/// One request, as a handler sees it.
pub struct Req {
    app: Arc<App>,
    conn: Conn,
}

/// An authenticated caller: the token's user id and the token itself (echoed in User objects).
pub struct Auth {
    pub id: i64,
    pub token: String,
}

impl Req {
    fn db(&self) -> &Db {
        &self.app.db
    }

    fn jwt(&self) -> &Jwt {
        &self.app.jwt
    }

    /// `Authorization: Token <jwt>`. No header: `None`. A header that doesn't verify: 401.
    fn auth_optional(&self) -> Result<Option<Auth>, AppError> {
        let Some(header) = self.conn.headers.get("authorization").filter(|v| !v.is_empty()) else {
            return Ok(None);
        };
        let token = header.strip_prefix("Token ").ok_or(AppError::Unauthorized)?;
        let id = self.jwt().verify(token).ok_or(AppError::Unauthorized)?;
        Ok(Some(Auth { id, token: token.to_owned() }))
    }

    fn auth(&self) -> Result<Auth, AppError> {
        self.auth_optional()?.ok_or(AppError::Unauthorized)
    }

    /// The caller's user id on endpoints where auth is optional; 0 when anonymous.
    fn viewer(&self) -> Result<i64, AppError> {
        Ok(self.auth_optional()?.map_or(0, |auth| auth.id))
    }

    /// The JSON request body. Anything that doesn't match `T` is 422.
    fn body<T: DeserializeOwned>(&self) -> Result<T, AppError> {
        serde_json::from_slice(self.conn.body.as_bytes()).map_err(|_| AppError::Unprocessable)
    }

    /// A percent-decoded path parameter.
    fn param(&self, name: &str) -> String {
        pct_decode(self.conn.params.get(name).unwrap_or(""), false)
    }

    fn query(&self) -> Query {
        Query::parse(self.conn.query.as_deref())
    }
}

// ---------------------------------------------------------------------------
// Responses
// ---------------------------------------------------------------------------

pub struct Reply {
    status: u16,
    body: Option<Vec<u8>>,
}

impl Reply {
    fn json(status: u16, value: &impl Serialize) -> Result<Reply, AppError> {
        let body = serde_json::to_vec(value).map_err(|e| AppError::Internal(e.to_string()))?;
        Ok(Reply { status, body: Some(body) })
    }

    fn ok(value: &impl Serialize) -> Result<Reply, AppError> {
        Reply::json(200, value)
    }

    fn created(value: &impl Serialize) -> Result<Reply, AppError> {
        Reply::json(201, value)
    }

    fn no_content() -> Result<Reply, AppError> {
        Ok(Reply { status: 204, body: None })
    }
}

#[derive(Debug)]
pub enum AppError {
    Unauthorized,
    Forbidden,
    NotFound,
    Unprocessable,
    Internal(String),
}

impl From<PgError> for AppError {
    fn from(e: PgError) -> Self {
        if e.is_unique_violation() {
            // A taken username, email or slug: the client's to fix.
            AppError::Unprocessable
        } else {
            AppError::Internal(e.to_string())
        }
    }
}

impl AppError {
    fn status(&self) -> u16 {
        match self {
            AppError::Unauthorized => 401,
            AppError::Forbidden => 403,
            AppError::NotFound => 404,
            AppError::Unprocessable => 422,
            AppError::Internal(_) => 500,
        }
    }
}

/// `{"errors": {"body": ["<message>"]}}`
#[derive(Serialize)]
struct ErrorBody {
    errors: ErrorMessages,
}

#[derive(Serialize)]
struct ErrorMessages {
    body: [&'static str; 1],
}

fn respond(conn: Conn, result: Result<Reply, AppError>) -> Conn {
    let reply = result.unwrap_or_else(|e| {
        let message = match &e {
            AppError::Unauthorized => "unauthorized",
            AppError::Forbidden => "forbidden",
            AppError::NotFound => "not found",
            AppError::Unprocessable => "unprocessable entity",
            AppError::Internal(err) => {
                eprintln!("[error] {err}");
                "internal server error"
            }
        };
        let body = serde_json::to_vec(&ErrorBody { errors: ErrorMessages { body: [message] } }).unwrap_or_default();
        Reply { status: e.status(), body: Some(body) }
    });
    let conn = conn.put_status(reply.status);
    match reply.body {
        Some(body) => conn
            .put_header("content-type", "application/json")
            .put_header("content-length", body.len().to_string())
            .put_body(body),
        None => conn.put_header("content-length", "0"),
    }
}

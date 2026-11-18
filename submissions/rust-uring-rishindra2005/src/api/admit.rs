//! Request admission, validation, authentication enforcement, and job creation.
//! Written from scratch for rust-uring-rishindra2005.

use std::borrow::Cow;
use crate::types::{ConnRef, Envelope, Job, KdfJob, Route, Viewer};
use super::errors::{reply_401, reply_404_msg, reply_422};
use super::routes::RequestParams;

/// Result of admitting a request at the API boundary.
#[derive(Debug)]
pub enum Admit {
    /// Request immediately answered without touching DB or KDF (e.g. 401, 404, 422).
    Reply(Vec<u8>),
    /// Validated database envelope to enqueue into the PG driver.
    Pg(Envelope),
    /// Cryptographic bcrypt job for the KDF worker.
    Kdf(KdfJob),
}

/// Minimal zero-copy JSON value representation.
#[derive(Debug, PartialEq)]
enum JsonVal<'a> {
    Null,
    Bool(bool),
    Number(&'a str),
    String(Cow<'a, str>),
    Array(Vec<JsonVal<'a>>),
    Object(Vec<(&'a str, JsonVal<'a>)>),
}

/// Lean zero-copy JSON parser for Conduit request bodies.
struct JsonParser<'a> {
    src: &'a [u8],
    pos: usize,
}

impl<'a> JsonParser<'a> {
    fn new(src: &'a [u8]) -> Self {
        Self { src, pos: 0 }
    }

    fn skip_whitespace(&mut self) {
        while self.pos < self.src.len() {
            match self.src[self.pos] {
                b' ' | b'\t' | b'\n' | b'\r' => self.pos += 1,
                _ => break,
            }
        }
    }

    fn peek(&mut self) -> Option<u8> {
        self.skip_whitespace();
        if self.pos < self.src.len() {
            Some(self.src[self.pos])
        } else {
            None
        }
    }

    fn parse_value(&mut self) -> Result<JsonVal<'a>, ()> {
        let b = self.peek().ok_or(())?;
        match b {
            b'{' => self.parse_object(),
            b'[' => self.parse_array(),
            b'"' => self.parse_string().map(JsonVal::String),
            b't' | b'f' => self.parse_bool(),
            b'n' => self.parse_null(),
            b'-' | b'0'..=b'9' => self.parse_number(),
            _ => Err(()),
        }
    }

    fn parse_null(&mut self) -> Result<JsonVal<'a>, ()> {
        self.skip_whitespace();
        if self.pos + 4 <= self.src.len() && &self.src[self.pos..self.pos + 4] == b"null" {
            self.pos += 4;
            Ok(JsonVal::Null)
        } else {
            Err(())
        }
    }

    fn parse_bool(&mut self) -> Result<JsonVal<'a>, ()> {
        self.skip_whitespace();
        if self.pos + 4 <= self.src.len() && &self.src[self.pos..self.pos + 4] == b"true" {
            self.pos += 4;
            Ok(JsonVal::Bool(true))
        } else if self.pos + 5 <= self.src.len() && &self.src[self.pos..self.pos + 5] == b"false" {
            self.pos += 5;
            Ok(JsonVal::Bool(false))
        } else {
            Err(())
        }
    }

    fn parse_number(&mut self) -> Result<JsonVal<'a>, ()> {
        self.skip_whitespace();
        let start = self.pos;
        if self.pos < self.src.len() && self.src[self.pos] == b'-' {
            self.pos += 1;
        }
        while self.pos < self.src.len() {
            match self.src[self.pos] {
                b'0'..=b'9' | b'.' | b'e' | b'E' | b'+' | b'-' => self.pos += 1,
                _ => break,
            }
        }
        if self.pos == start {
            return Err(());
        }
        let s = std::str::from_utf8(&self.src[start..self.pos]).map_err(|_| ())?;
        Ok(JsonVal::Number(s))
    }

    fn parse_string(&mut self) -> Result<Cow<'a, str>, ()> {
        self.skip_whitespace();
        if self.pos >= self.src.len() || self.src[self.pos] != b'"' {
            return Err(());
        }
        self.pos += 1; // skip opening quote
        let start = self.pos;
        let mut has_escapes = false;

        while self.pos < self.src.len() {
            match self.src[self.pos] {
                b'"' => {
                    let slice = &self.src[start..self.pos];
                    self.pos += 1; // skip closing quote
                    if !has_escapes {
                        let s = std::str::from_utf8(slice).map_err(|_| ())?;
                        return Ok(Cow::Borrowed(s));
                    }
                    return unescape_json(slice);
                }
                b'\\' => {
                    has_escapes = true;
                    self.pos += 2; // skip escape char
                }
                _ => self.pos += 1,
            }
        }
        Err(())
    }

    fn parse_array(&mut self) -> Result<JsonVal<'a>, ()> {
        self.skip_whitespace();
        if self.pos >= self.src.len() || self.src[self.pos] != b'[' {
            return Err(());
        }
        self.pos += 1; // skip '['

        let mut items = Vec::new();
        self.skip_whitespace();
        if self.pos < self.src.len() && self.src[self.pos] == b']' {
            self.pos += 1;
            return Ok(JsonVal::Array(items));
        }

        loop {
            let val = self.parse_value()?;
            items.push(val);
            self.skip_whitespace();
            if self.pos >= self.src.len() {
                return Err(());
            }
            match self.src[self.pos] {
                b',' => {
                    self.pos += 1;
                }
                b']' => {
                    self.pos += 1;
                    return Ok(JsonVal::Array(items));
                }
                _ => return Err(()),
            }
        }
    }

    fn parse_object(&mut self) -> Result<JsonVal<'a>, ()> {
        self.skip_whitespace();
        if self.pos >= self.src.len() || self.src[self.pos] != b'{' {
            return Err(());
        }
        self.pos += 1; // skip '{'

        let mut entries = Vec::new();
        self.skip_whitespace();
        if self.pos < self.src.len() && self.src[self.pos] == b'}' {
            self.pos += 1;
            return Ok(JsonVal::Object(entries));
        }

        loop {
            let key = match self.parse_string()? {
                Cow::Borrowed(s) => s,
                Cow::Owned(_) => return Err(()), // keys don't require escape allocation
            };
            self.skip_whitespace();
            if self.pos >= self.src.len() || self.src[self.pos] != b':' {
                return Err(());
            }
            self.pos += 1; // skip ':'
            let val = self.parse_value()?;
            entries.push((key, val));

            self.skip_whitespace();
            if self.pos >= self.src.len() {
                return Err(());
            }
            match self.src[self.pos] {
                b',' => {
                    self.pos += 1;
                }
                b'}' => {
                    self.pos += 1;
                    return Ok(JsonVal::Object(entries));
                }
                _ => return Err(()),
            }
        }
    }
}

fn unescape_json(bytes: &[u8]) -> Result<Cow<'static, str>, ()> {
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\\' && i + 1 < bytes.len() {
            match bytes[i + 1] {
                b'"' => out.push(b'"'),
                b'\\' => out.push(b'\\'),
                b'/' => out.push(b'/'),
                b'b' => out.push(0x08),
                b'f' => out.push(0x0C),
                b'n' => out.push(b'\n'),
                b'r' => out.push(b'\r'),
                b't' => out.push(b'\t'),
                b'u' if i + 5 < bytes.len() => {
                    let hex = std::str::from_utf8(&bytes[i + 2..i + 6]).map_err(|_| ())?;
                    let code = u16::from_str_radix(hex, 16).map_err(|_| ())?;
                    if let Some(ch) = char::from_u32(code as u32) {
                        let mut buf = [0u8; 4];
                        out.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
                    }
                    i += 6;
                    continue;
                }
                _ => return Err(()),
            }
            i += 2;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    let s = String::from_utf8(out).map_err(|_| ())?;
    Ok(Cow::Owned(s))
}

fn parse_body_wrapper<'a>(body: &'a [u8], wrapper_key: &str) -> Result<Vec<(&'a str, JsonVal<'a>)>, ()> {
    if body.is_empty() {
        return Err(());
    }
    let mut p = JsonParser::new(body);
    let root = p.parse_value()?;
    p.skip_whitespace();
    if p.pos != p.src.len() {
        return Err(());
    }
    match root {
        JsonVal::Object(entries) => {
            for (k, v) in entries {
                if k == wrapper_key {
                    if let JsonVal::Object(inner) = v {
                        return Ok(inner);
                    }
                    return Err(());
                }
            }
            Err(())
        }
        _ => Err(()),
    }
}

fn sanitize_token(token: Option<&str>) -> Option<Box<str>> {
    token.map(|t| {
        let stripped = if let Some(s) = t.strip_prefix("Token ") {
            s.trim()
        } else if let Some(s) = t.strip_prefix("token ") {
            s.trim()
        } else {
            t.trim()
        };
        stripped.to_string().into_boxed_str()
    })
}

/// Check auth permissions for the given route.
/// Returns Ok(viewer_id) or Err(401 reply).
fn check_auth(
    route: Route,
    viewer: Option<Viewer>,
    token: Option<&str>,
    keepalive: bool,
) -> Result<Viewer, Vec<u8>> {
    // Defense-in-depth: If a token is provided with an invalid scheme (e.g. "Bearer ")
    // or sentinel empty string "", it must never authenticate.
    let is_invalid_token = match token {
        Some(t) => {
            let trimmed = t.trim();
            trimmed.is_empty()
                || trimmed.starts_with("Bearer ")
                || trimmed.starts_with("bearer ")
        }
        None => false,
    };
    let viewer = if is_invalid_token { None } else { viewer };

    match route {
        // No Auth endpoints: header ignored completely
        Route::Tags | Route::UsersRegister | Route::UsersLogin => Ok(0),

        // Auth Optional endpoints:
        // - if header present but invalid -> 401
        // - if no header -> anonymous (viewer = 0)
        // - if header valid -> viewer = sub (> 0)
        Route::ProfileGet | Route::ArticlesList | Route::ArticleGet | Route::CommentsList => {
            if token.is_some() && viewer.is_none() {
                return Err(reply_401("invalid token", keepalive));
            }
            Ok(viewer.unwrap_or(0))
        }

        // Auth Required endpoints:
        // - requires valid token, else 401
        _ => {
            match viewer {
                Some(uid) if uid > 0 => Ok(uid),
                _ => Err(reply_401("unauthorized", keepalive)),
            }
        }
    }
}

/// Admit and validate an incoming request.
pub fn admit(
    route: Route,
    params: &RequestParams<'_>,
    body: &[u8],
    viewer: Option<Viewer>,
    token: Option<&str>,
    conn: ConnRef,
    keepalive: bool,
) -> Admit {
    let auth_viewer = match check_auth(route, viewer, token, keepalive) {
        Ok(v) => v,
        Err(err_reply) => return Admit::Reply(err_reply),
    };

    match route {
        Route::Tags => Admit::Pg(Envelope {
            conn,
            viewer: 0,
            token: None,
            keepalive,
            job: Job::Tags,
        }),

        Route::UsersLogin => {
            let inner = match parse_body_wrapper(body, "user") {
                Ok(obj) => obj,
                Err(_) => return Admit::Reply(reply_422("invalid login payload", keepalive)),
            };

            let mut email: Option<Box<str>> = None;
            let mut password: Option<Box<str>> = None;

            for (k, v) in inner {
                match (k, v) {
                    ("email", JsonVal::String(s)) if !s.is_empty() => {
                        email = Some(s.into_owned().into_boxed_str());
                    }
                    ("password", JsonVal::String(s)) if !s.is_empty() => {
                        password = Some(s.into_owned().into_boxed_str());
                    }
                    _ => {}
                }
            }

            match (email, password) {
                (Some(e), Some(p)) => Admit::Pg(Envelope {
                    conn,
                    viewer: 0,
                    token: None,
                    keepalive,
                    job: Job::LoginLookup { email: e, password: p },
                }),
                _ => Admit::Reply(reply_422("email and password required", keepalive)),
            }
        }

        Route::UsersRegister => {
            let inner = match parse_body_wrapper(body, "user") {
                Ok(obj) => obj,
                Err(_) => return Admit::Reply(reply_422("invalid user registration payload", keepalive)),
            };

            let mut username: Option<Box<str>> = None;
            let mut email: Option<Box<str>> = None;
            let mut password: Option<Box<str>> = None;

            for (k, v) in inner {
                match (k, v) {
                    ("username", JsonVal::String(s)) if !s.is_empty() => {
                        username = Some(s.into_owned().into_boxed_str());
                    }
                    ("email", JsonVal::String(s)) if !s.is_empty() => {
                        email = Some(s.into_owned().into_boxed_str());
                    }
                    ("password", JsonVal::String(s)) if !s.is_empty() => {
                        if s.len() > 72 {
                            return Admit::Reply(reply_422("password exceeds 72 bytes", keepalive));
                        }
                        password = Some(s.into_owned().into_boxed_str());
                    }
                    _ => {}
                }
            }

            match (username, email, password) {
                (Some(u), Some(e), Some(p)) => {
                    let env = Envelope {
                        conn,
                        viewer: 0,
                        token: None,
                        keepalive,
                        job: Job::Register {
                            username: u,
                            email: e,
                            password_hash: Box::default(),
                        },
                    };
                    Admit::Kdf(KdfJob::Hash { password: p, then: env })
                }
                _ => Admit::Reply(reply_422("username, email and password required", keepalive)),
            }
        }

        Route::UserGet => Admit::Pg(Envelope {
            conn,
            viewer: auth_viewer,
            token: sanitize_token(token),
            keepalive,
            job: Job::UserGet,
        }),

        Route::UserPut => {
            let inner = match parse_body_wrapper(body, "user") {
                Ok(obj) => obj,
                Err(_) => return Admit::Reply(reply_422("invalid user update payload", keepalive)),
            };

            let mut email: Option<Box<str>> = None;
            let mut username: Option<Box<str>> = None;
            let mut password: Option<Box<str>> = None;
            let mut bio: Option<Option<Box<str>>> = None;
            let mut image: Option<Option<Box<str>>> = None;

            for (k, v) in inner {
                match (k, v) {
                    ("email", JsonVal::String(s)) => {
                        if s.is_empty() {
                            return Admit::Reply(reply_422("email cannot be empty", keepalive));
                        }
                        email = Some(s.into_owned().into_boxed_str());
                    }
                    ("email", JsonVal::Null) => {}
                    ("email", _) => return Admit::Reply(reply_422("email must be a string", keepalive)),

                    ("username", JsonVal::String(s)) => {
                        if s.is_empty() {
                            return Admit::Reply(reply_422("username cannot be empty", keepalive));
                        }
                        username = Some(s.into_owned().into_boxed_str());
                    }
                    ("username", JsonVal::Null) => {}
                    ("username", _) => return Admit::Reply(reply_422("username must be a string", keepalive)),

                    ("password", JsonVal::String(s)) => {
                        if s.is_empty() {
                            return Admit::Reply(reply_422("password cannot be empty", keepalive));
                        }
                        if s.len() > 72 {
                            return Admit::Reply(reply_422("password exceeds 72 bytes", keepalive));
                        }
                        password = Some(s.into_owned().into_boxed_str());
                    }
                    ("password", JsonVal::Null) => {}
                    ("password", _) => return Admit::Reply(reply_422("password must be a string", keepalive)),

                    ("bio", JsonVal::String(s)) => {
                        bio = Some(Some(s.into_owned().into_boxed_str()));
                    }
                    ("bio", JsonVal::Null) => {} // Null is unchanged
                    ("bio", _) => return Admit::Reply(reply_422("bio must be a string or null", keepalive)),

                    ("image", JsonVal::String(s)) => {
                        image = Some(Some(s.into_owned().into_boxed_str()));
                    }
                    ("image", JsonVal::Null) => {} // Null is unchanged
                    ("image", _) => return Admit::Reply(reply_422("image must be a string or null", keepalive)),

                    _ => {}
                }
            }

            let env = Envelope {
                conn,
                viewer: auth_viewer,
                token: sanitize_token(token),
                keepalive,
                job: Job::UserUpdate {
                    email,
                    username,
                    password_hash: None,
                    bio,
                    image,
                },
            };

            if let Some(p) = password {
                Admit::Kdf(KdfJob::Hash { password: p, then: env })
            } else {
                Admit::Pg(env)
            }
        }

        Route::ProfileGet => match params.username {
            Some(u) => Admit::Pg(Envelope {
                conn,
                viewer: auth_viewer,
                token: None,
                keepalive,
                job: Job::Profile { username: u.to_string().into_boxed_str() },
            }),
            None => Admit::Reply(reply_404_msg("username not specified", keepalive)),
        },

        Route::ProfileFollow => match params.username {
            Some(u) => Admit::Pg(Envelope {
                conn,
                viewer: auth_viewer,
                token: None,
                keepalive,
                job: Job::Follow {
                    username: u.to_string().into_boxed_str(),
                    on: true,
                },
            }),
            None => Admit::Reply(reply_404_msg("username not specified", keepalive)),
        },

        Route::ProfileUnfollow => match params.username {
            Some(u) => Admit::Pg(Envelope {
                conn,
                viewer: auth_viewer,
                token: None,
                keepalive,
                job: Job::Follow {
                    username: u.to_string().into_boxed_str(),
                    on: false,
                },
            }),
            None => Admit::Reply(reply_404_msg("username not specified", keepalive)),
        },

        Route::ArticlesList => Admit::Pg(Envelope {
            conn,
            viewer: auth_viewer,
            token: None,
            keepalive,
            job: Job::List {
                filter: params.filter.clone(),
                limit: params.limit,
                offset: params.offset,
            },
        }),

        Route::ArticlesFeed => Admit::Pg(Envelope {
            conn,
            viewer: auth_viewer,
            token: None,
            keepalive,
            job: Job::Feed {
                limit: params.limit,
                offset: params.offset,
            },
        }),

        Route::ArticleGet => match params.slug {
            Some(s) => Admit::Pg(Envelope {
                conn,
                viewer: auth_viewer,
                token: None,
                keepalive,
                job: Job::ArticleGet { slug: s.to_string().into_boxed_str() },
            }),
            None => Admit::Reply(reply_404_msg("slug not specified", keepalive)),
        },

        Route::ArticleCreate => {
            let inner = match parse_body_wrapper(body, "article") {
                Ok(obj) => obj,
                Err(_) => return Admit::Reply(reply_422("invalid article payload", keepalive)),
            };

            let mut title: Option<Box<str>> = None;
            let mut description: Option<Box<str>> = None;
            let mut body_text: Option<Box<str>> = None;
            let mut tag_list: Vec<Box<str>> = Vec::new();

            for (k, v) in inner {
                match (k, v) {
                    ("title", JsonVal::String(s)) if !s.is_empty() => {
                        title = Some(s.into_owned().into_boxed_str());
                    }
                    ("title", _) => return Admit::Reply(reply_422("title must be non-empty string", keepalive)),

                    ("description", JsonVal::String(s)) if !s.is_empty() => {
                        description = Some(s.into_owned().into_boxed_str());
                    }
                    ("description", _) => return Admit::Reply(reply_422("description must be non-empty string", keepalive)),

                    ("body", JsonVal::String(s)) if !s.is_empty() => {
                        body_text = Some(s.into_owned().into_boxed_str());
                    }
                    ("body", _) => return Admit::Reply(reply_422("body must be non-empty string", keepalive)),

                    ("tagList", JsonVal::Array(arr)) => {
                        for item in arr {
                            match item {
                                JsonVal::String(t) if !t.is_empty() => {
                                    tag_list.push(t.into_owned().into_boxed_str());
                                }
                                _ => return Admit::Reply(reply_422("tagList items must be non-empty strings", keepalive)),
                            }
                        }
                    }
                    ("tagList", JsonVal::Null) => {}
                    ("tagList", _) => return Admit::Reply(reply_422("tagList must be an array", keepalive)),

                    _ => {}
                }
            }

            match (title, description, body_text) {
                (Some(t), Some(d), Some(b)) => Admit::Pg(Envelope {
                    conn,
                    viewer: auth_viewer,
                    token: None,
                    keepalive,
                    job: Job::ArticleCreate {
                        title: t,
                        description: d,
                        body: b,
                        tags: tag_list,
                    },
                }),
                _ => Admit::Reply(reply_422("title, description and body required", keepalive)),
            }
        }

        Route::ArticleUpdate => {
            let slug = match params.slug {
                Some(s) => s.to_string().into_boxed_str(),
                None => return Admit::Reply(reply_404_msg("slug not specified", keepalive)),
            };

            let inner = match parse_body_wrapper(body, "article") {
                Ok(obj) => obj,
                Err(_) => return Admit::Reply(reply_422("invalid article payload", keepalive)),
            };

            let mut title: Option<Box<str>> = None;
            let mut description: Option<Box<str>> = None;
            let mut body_text: Option<Box<str>> = None;

            for (k, v) in inner {
                match (k, v) {
                    ("title", JsonVal::String(s)) => {
                        if s.is_empty() {
                            return Admit::Reply(reply_422("title cannot be empty", keepalive));
                        }
                        title = Some(s.into_owned().into_boxed_str());
                    }
                    ("title", JsonVal::Null) => {}
                    ("title", _) => return Admit::Reply(reply_422("title must be a string", keepalive)),

                    ("description", JsonVal::String(s)) => {
                        if s.is_empty() {
                            return Admit::Reply(reply_422("description cannot be empty", keepalive));
                        }
                        description = Some(s.into_owned().into_boxed_str());
                    }
                    ("description", JsonVal::Null) => {}
                    ("description", _) => return Admit::Reply(reply_422("description must be a string", keepalive)),

                    ("body", JsonVal::String(s)) => {
                        if s.is_empty() {
                            return Admit::Reply(reply_422("body cannot be empty", keepalive));
                        }
                        body_text = Some(s.into_owned().into_boxed_str());
                    }
                    ("body", JsonVal::Null) => {}
                    ("body", _) => return Admit::Reply(reply_422("body must be a string", keepalive)),

                    _ => {}
                }
            }

            Admit::Pg(Envelope {
                conn,
                viewer: auth_viewer,
                token: None,
                keepalive,
                job: Job::ArticleUpdate {
                    slug,
                    title,
                    description,
                    body: body_text,
                },
            })
        }

        Route::ArticleDelete => match params.slug {
            Some(s) => Admit::Pg(Envelope {
                conn,
                viewer: auth_viewer,
                token: None,
                keepalive,
                job: Job::ArticleDelete { slug: s.to_string().into_boxed_str() },
            }),
            None => Admit::Reply(reply_404_msg("slug not specified", keepalive)),
        },

        Route::Favorite => match params.slug {
            Some(s) => Admit::Pg(Envelope {
                conn,
                viewer: auth_viewer,
                token: None,
                keepalive,
                job: Job::Favorite {
                    slug: s.to_string().into_boxed_str(),
                    on: true,
                },
            }),
            None => Admit::Reply(reply_404_msg("slug not specified", keepalive)),
        },

        Route::Unfavorite => match params.slug {
            Some(s) => Admit::Pg(Envelope {
                conn,
                viewer: auth_viewer,
                token: None,
                keepalive,
                job: Job::Favorite {
                    slug: s.to_string().into_boxed_str(),
                    on: false,
                },
            }),
            None => Admit::Reply(reply_404_msg("slug not specified", keepalive)),
        },

        Route::CommentsList => match params.slug {
            Some(s) => Admit::Pg(Envelope {
                conn,
                viewer: auth_viewer,
                token: None,
                keepalive,
                job: Job::Comments { slug: s.to_string().into_boxed_str() },
            }),
            None => Admit::Reply(reply_404_msg("slug not specified", keepalive)),
        },

        Route::CommentCreate => {
            let slug = match params.slug {
                Some(s) => s.to_string().into_boxed_str(),
                None => return Admit::Reply(reply_404_msg("slug not specified", keepalive)),
            };

            let inner = match parse_body_wrapper(body, "comment") {
                Ok(obj) => obj,
                Err(_) => return Admit::Reply(reply_422("invalid comment payload", keepalive)),
            };

            let mut comment_body: Option<Box<str>> = None;
            for (k, v) in inner {
                match (k, v) {
                    ("body", JsonVal::String(s)) if !s.is_empty() => {
                        comment_body = Some(s.into_owned().into_boxed_str());
                    }
                    ("body", _) => return Admit::Reply(reply_422("comment body must be non-empty string", keepalive)),
                    _ => {}
                }
            }

            match comment_body {
                Some(b) => Admit::Pg(Envelope {
                    conn,
                    viewer: auth_viewer,
                    token: None,
                    keepalive,
                    job: Job::CommentCreate { slug, body: b },
                }),
                None => Admit::Reply(reply_422("comment body required", keepalive)),
            }
        }

        Route::CommentDelete => match (params.slug, params.comment_id) {
            (Some(s), Some(cid)) => Admit::Pg(Envelope {
                conn,
                viewer: auth_viewer,
                token: None,
                keepalive,
                job: Job::CommentDelete {
                    slug: s.to_string().into_boxed_str(),
                    id: cid,
                },
            }),
            _ => Admit::Reply(reply_404_msg("comment not found", keepalive)),
        },
    }
}

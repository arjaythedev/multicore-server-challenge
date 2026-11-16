//! Route matching, parameter extraction, and query validation.
//! Written from scratch for rust-uring-rishindra2005.

use std::borrow::Cow;
use crate::types::ListFilter;

include!(concat!(env!("OUT_DIR"), "/codegen_router.rs"));

/// Extracted and validated parameters for an admitted request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RequestParams<'a> {
    pub slug: Option<&'a str>,
    pub username: Option<&'a str>,
    pub comment_id: Option<i64>,
    pub filter: ListFilter,
    pub limit: u16,
    pub offset: u32,
}

impl<'a> Default for RequestParams<'a> {
    fn default() -> Self {
        Self {
            slug: None,
            username: None,
            comment_id: None,
            filter: ListFilter::Global,
            limit: 20,
            offset: 0,
        }
    }
}

/// Parsed route ready for admission.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParsedRoute<'a> {
    pub route: Route,
    pub params: RequestParams<'a>,
}

/// Route error variants.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum RouteError {
    NotFound,
    InvalidQuery(&'static str),
    InvalidCommentId,
}

/// URL percent-decode a string slice. Returns Cow::Borrowed if no percent encoding exists.
pub fn url_decode(s: &str) -> Cow<'_, str> {
    if !s.bytes().any(|b| b == b'%' || b == b'+') {
        return Cow::Borrowed(s);
    }

    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' if i + 2 < bytes.len() => {
                let h1 = (bytes[i + 1] as char).to_digit(16);
                let h2 = (bytes[i + 2] as char).to_digit(16);
                if let (Some(d1), Some(d2)) = (h1, h2) {
                    out.push(((d1 << 4) | d2) as u8);
                    i += 3;
                } else {
                    out.push(bytes[i]);
                    i += 1;
                }
            }
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }

    match String::from_utf8(out) {
        Ok(decoded) => Cow::Owned(decoded),
        Err(err) => Cow::Owned(String::from_utf8_lossy(err.as_bytes()).into_owned()),
    }
}

/// Validates and parses the `limit` query param (integer 1..=100, default 20).
fn parse_limit(val: &str) -> Result<u16, RouteError> {
    if val.is_empty() {
        return Err(RouteError::InvalidQuery("limit must be non-empty"));
    }
    for &b in val.as_bytes() {
        if !b.is_ascii_digit() {
            return Err(RouteError::InvalidQuery("limit must be an integer"));
        }
    }
    match val.parse::<u32>() {
        Ok(n) if (1..=100).contains(&n) => Ok(n as u16),
        _ => Err(RouteError::InvalidQuery("limit out of range (1-100)")),
    }
}

/// Validates and parses the `offset` query param (integer >= 0, default 0).
fn parse_offset(val: &str) -> Result<u32, RouteError> {
    if val.is_empty() {
        return Err(RouteError::InvalidQuery("offset must be non-empty"));
    }
    for &b in val.as_bytes() {
        if !b.is_ascii_digit() {
            return Err(RouteError::InvalidQuery("offset must be an integer"));
        }
    }
    val.parse::<u32>()
        .map_err(|_| RouteError::InvalidQuery("offset invalid or overflow"))
}

/// Parse route, extract path params, and validate query string per SPEC.
pub fn parse_route<'a>(method: &str, raw_path: &'a str) -> Result<ParsedRoute<'a>, RouteError> {
    let (route, path_params) = match_route(method, raw_path).ok_or(RouteError::NotFound)?;

    let query_str = raw_path.find('?').map(|q| &raw_path[q + 1..]);

    let mut params = RequestParams {
        slug: path_params.slug,
        username: path_params.username,
        comment_id: None,
        filter: ListFilter::Global,
        limit: 20,
        offset: 0,
    };

    if route == Route::CommentDelete {
        let raw_id = path_params.comment_id.ok_or(RouteError::NotFound)?;
        if raw_id.is_empty() {
            return Err(RouteError::InvalidCommentId);
        }
        for &b in raw_id.as_bytes() {
            if !b.is_ascii_digit() {
                return Err(RouteError::InvalidCommentId);
            }
        }
        let cid = raw_id.parse::<i64>().map_err(|_| RouteError::InvalidCommentId)?;
        if cid <= 0 {
            return Err(RouteError::InvalidCommentId);
        }
        params.comment_id = Some(cid);
    }

    if route == Route::ArticlesList || route == Route::ArticlesFeed {
        let mut raw_tag: Option<&str> = None;
        let mut raw_author: Option<&str> = None;
        let mut raw_favorited: Option<&str> = None;

        if let Some(query) = query_str {
            for pair in query.split('&') {
                if pair.is_empty() {
                    continue;
                }
                let (key, val) = match pair.find('=') {
                    Some(idx) => (&pair[..idx], &pair[idx + 1..]),
                    None => (pair, ""),
                };

                match key {
                    "limit" => params.limit = parse_limit(val)?,
                    "offset" => params.offset = parse_offset(val)?,
                    "tag" if route == Route::ArticlesList => raw_tag = Some(val),
                    "author" if route == Route::ArticlesList => raw_author = Some(val),
                    "favorited" if route == Route::ArticlesList => raw_favorited = Some(val),
                    _ => {}
                }
            }
        }

        if route == Route::ArticlesList {
            params.filter = if let Some(t) = raw_tag.filter(|s| !s.is_empty()) {
                ListFilter::Tag(url_decode(t).into_owned().into_boxed_str())
            } else if let Some(a) = raw_author.filter(|s| !s.is_empty()) {
                ListFilter::Author(url_decode(a).into_owned().into_boxed_str())
            } else if let Some(f) = raw_favorited.filter(|s| !s.is_empty()) {
                ListFilter::Favorited(url_decode(f).into_owned().into_boxed_str())
            } else {
                ListFilter::Global
            };
        }
    }

    Ok(ParsedRoute { route, params })
}

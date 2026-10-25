//! How a list endpoint reads `limit`, `offset` and its filters: the first occurrence of a name wins.

use axum::extract::FromRequestParts;
use axum::http::request::Parts;

use crate::error::AppError;

pub const DEFAULT_LIMIT: i64 = 20;
pub const MAX_LIMIT: i64 = 100;

#[derive(Default)]
pub struct ListQuery {
    limit: Option<String>,
    offset: Option<String>,
    pub tag: Option<String>,
    pub author: Option<String>,
    pub favorited: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Page {
    pub limit: i64,
    pub offset: i64,
}

impl ListQuery {
    pub fn parse(query: &str) -> Self {
        let mut q = ListQuery::default();
        for (key, value) in form_urlencoded::parse(query.as_bytes()) {
            let slot = match key.as_ref() {
                "limit" => &mut q.limit,
                "offset" => &mut q.offset,
                "tag" => &mut q.tag,
                "author" => &mut q.author,
                "favorited" => &mut q.favorited,
                _ => continue,
            };
            if slot.is_none() {
                *slot = Some(value.into_owned());
            }
        }
        for filter in [&mut q.tag, &mut q.author, &mut q.favorited] {
            if filter.as_deref() == Some("") {
                *filter = None;
            }
        }
        q
    }

    /// `limit` 1..=100 (default 20) and `offset` >= 0 (default 0); anything else, an empty value included, is a 422.
    pub fn page(&self) -> Result<Page, AppError> {
        let limit = match self.limit.as_deref() {
            None => DEFAULT_LIMIT,
            Some(v) => digits(v)
                .filter(|n| (1..=MAX_LIMIT).contains(n))
                .ok_or(AppError::UnprocessableEntity("limit must be an integer from 1 to 100"))?,
        };
        let offset = match self.offset.as_deref() {
            None => 0,
            Some(v) => digits(v).ok_or(AppError::UnprocessableEntity("offset must be a non-negative integer"))?,
        };
        Ok(Page { limit, offset })
    }
}

impl<S: Send + Sync> FromRequestParts<S> for ListQuery {
    type Rejection = AppError;

    async fn from_request_parts(parts: &mut Parts, _state: &S) -> Result<Self, Self::Rejection> {
        Ok(ListQuery::parse(parts.uri.query().unwrap_or("")))
    }
}

/// ASCII digits only (no sign, no space) that fit in an i64.
pub fn digits(s: &str) -> Option<i64> {
    if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    s.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_missing_value_takes_the_default_and_a_wild_one_is_refused() {
        assert_eq!(ListQuery::parse("").page().unwrap(), Page { limit: 20, offset: 0 });
        assert_eq!(ListQuery::parse("limit=5&offset=10&limit=7").page().unwrap(), Page { limit: 5, offset: 10 });
        for bad in ["limit=0", "limit=101", "limit=", "limit=-1", "limit=1.5", "offset=-1", "offset=", "offset=+3"] {
            assert!(ListQuery::parse(bad).page().is_err(), "{bad}");
        }
    }

    #[test]
    fn an_empty_filter_counts_as_absent() {
        let q = ListQuery::parse("tag=&author=jake&favorited=");
        assert_eq!((q.tag, q.author.as_deref(), q.favorited), (None, Some("jake"), None));
    }
}

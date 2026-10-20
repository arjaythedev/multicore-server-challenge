//! The Conduit objects (SPEC.md "Objects"): read from result rows, written as response JSON.
//!
//! Each [`FromRow`] impl reads its columns in the order the matching SELECTs in `sql.rs` list
//! them.

use serde::{Serialize, Serializer};
use time::macros::format_description;
use time::OffsetDateTime;

use crate::db::{FromRow, FromSql, PgResult, Row, Rows};

/// A `timestamptz`, serialized as RFC 3339 UTC with exactly three (truncated) fractional digits.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Timestamp(OffsetDateTime);

impl FromSql for Timestamp {
    fn from_sql(rows: &Rows, row: usize, col: usize) -> PgResult<Self> {
        OffsetDateTime::from_sql(rows, row, col).map(Timestamp)
    }
}

impl Serialize for Timestamp {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let format = format_description!("[year]-[month]-[day]T[hour]:[minute]:[second].[subsecond digits:3]Z");
        let text = self.0.format(format).map_err(serde::ser::Error::custom)?;
        s.serialize_str(&text)
    }
}

#[derive(Serialize)]
pub struct User {
    #[serde(skip)]
    pub id: i64,
    pub email: String,
    /// Not stored: the caller's token, filled in by the handler.
    pub token: String,
    pub username: String,
    pub bio: Option<String>,
    pub image: Option<String>,
}

impl FromRow for User {
    fn from_row(row: &mut Row) -> PgResult<Self> {
        Ok(User {
            id: row.get()?,
            email: row.get()?,
            token: String::new(),
            username: row.get()?,
            bio: row.get()?,
            image: row.get()?,
        })
    }
}

/// A user and their stored bcrypt hash, for login.
pub struct Credentials {
    pub user: User,
    pub password_hash: String,
}

impl FromRow for Credentials {
    fn from_row(row: &mut Row) -> PgResult<Self> {
        Ok(Credentials { user: User::from_row(row)?, password_hash: row.get()? })
    }
}

#[derive(Serialize)]
pub struct Profile {
    pub username: String,
    pub bio: Option<String>,
    pub image: Option<String>,
    pub following: bool,
}

impl FromRow for Profile {
    fn from_row(row: &mut Row) -> PgResult<Self> {
        Ok(Profile { username: row.get()?, bio: row.get()?, image: row.get()?, following: row.get()? })
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Article {
    pub slug: String,
    pub title: String,
    pub description: String,
    /// Absent from list pages.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    pub tag_list: Vec<String>,
    pub created_at: Timestamp,
    pub updated_at: Timestamp,
    pub favorited: bool,
    pub favorites_count: i64,
    pub author: Profile,
}

impl FromRow for Article {
    fn from_row(row: &mut Row) -> PgResult<Self> {
        Ok(Article {
            slug: row.get()?,
            title: row.get()?,
            description: row.get()?,
            body: row.get()?,
            tag_list: row.get()?,
            created_at: row.get()?,
            updated_at: row.get()?,
            favorited: row.get()?,
            favorites_count: row.get()?,
            author: Profile::from_row(row)?,
        })
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Comment {
    pub id: i64,
    pub created_at: Timestamp,
    pub updated_at: Timestamp,
    pub body: String,
    pub author: Profile,
}

impl FromRow for Comment {
    fn from_row(row: &mut Row) -> PgResult<Self> {
        Ok(Comment {
            id: row.get()?,
            created_at: row.get()?,
            updated_at: row.get()?,
            body: row.get()?,
            author: Profile::from_row(row)?,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timestamps_truncate_to_milliseconds() {
        // 2025-04-01T12:00:00.1239Z
        let t = Timestamp(OffsetDateTime::from_unix_timestamp_nanos(1_743_508_800_123_900_000).unwrap());
        assert_eq!(serde_json::to_string(&t).unwrap(), "\"2025-04-01T12:00:00.123Z\"");
    }
}

use serde::Serialize;
use tokio_postgres::Row;

use crate::services::db::{FromRow, PgError};

pub struct ProfileRow {
    pub username: String,
    pub bio: Option<String>,
    pub image: Option<String>,
    pub following: bool,
}

impl FromRow for ProfileRow {
    fn from_row(row: &Row) -> Result<Self, PgError> {
        Ok(ProfileRow {
            username: row.try_get("username")?,
            bio: row.try_get("bio")?,
            image: row.try_get("image")?,
            following: row.try_get("following")?,
        })
    }
}

pub struct AuthorRow {
    pub username: String,
    pub bio: Option<String>,
    pub image: Option<String>,
}

impl FromRow for AuthorRow {
    fn from_row(row: &Row) -> Result<Self, PgError> {
        Ok(AuthorRow { username: row.try_get("username")?, bio: row.try_get("bio")?, image: row.try_get("image")? })
    }
}

#[derive(Serialize)]
pub struct Profile {
    pub username: String,
    pub bio: Option<String>,
    pub image: Option<String>,
    pub following: bool,
}

impl From<ProfileRow> for Profile {
    fn from(r: ProfileRow) -> Self {
        Profile { username: r.username, bio: r.bio, image: r.image, following: r.following }
    }
}

#[derive(Serialize)]
pub struct ProfileEnvelope {
    pub profile: Profile,
}

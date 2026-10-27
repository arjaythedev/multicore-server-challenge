use crate::error::AppError;
use crate::services::db::{Db, Stmt};

/// One row holding the array, read off the unique index in name order: no sort, one DataRow on the wire.
static TAGS: Stmt = Stmt { sql: "SELECT ARRAY(SELECT name FROM tags ORDER BY name)", types: &[] };

pub(crate) static STATEMENTS: &[&Stmt] = &[&TAGS];

pub async fn all_names(db: &Db) -> Result<Vec<String>, AppError> {
    Ok(db.read().scalar::<Vec<String>>(&TAGS, &[]).await.map_err(AppError::db("tags"))?.unwrap_or_default())
}

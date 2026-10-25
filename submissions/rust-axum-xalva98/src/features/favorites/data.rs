//! The change and the article it answers with are one statement. Its SELECT reads the snapshot from before the
//! change, so the count adds (or takes away) the row the change reported, and `favorited` is what was asked for.

use tokio_postgres::types::Type;

use crate::error::AppError;
use crate::features::articles::sql::{favorites_count, full_columns_with};
use crate::features::articles::ArticleRow;
use crate::services::db::{Db, Stmt};

static FAVORITE: Stmt = Stmt {
    sql: concat!(
        "WITH target AS (SELECT id FROM articles WHERE slug = $2),
              changed AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM target
                          ON CONFLICT DO NOTHING RETURNING 1)
         SELECT ",
        full_columns_with!(concat!(favorites_count!(), " + (SELECT count(*) FROM changed)"), "true"),
        " FROM target JOIN articles a ON a.id = target.id JOIN users u ON u.id = a.author_id"
    ),
    types: &[Type::INT8, Type::TEXT],
};

static UNFAVORITE: Stmt = Stmt {
    sql: concat!(
        "WITH target AS (SELECT id FROM articles WHERE slug = $2),
              changed AS (DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM target) RETURNING 1)
         SELECT ",
        full_columns_with!(concat!(favorites_count!(), " - (SELECT count(*) FROM changed)"), "false"),
        " FROM target JOIN articles a ON a.id = target.id JOIN users u ON u.id = a.author_id"
    ),
    types: &[Type::INT8, Type::TEXT],
};

pub(crate) static STATEMENTS: &[&Stmt] = &[&FAVORITE, &UNFAVORITE];

/// None: no article with that slug.
pub async fn set_favorite(db: &Db, user: i64, slug: &str, favorite: bool) -> Result<Option<ArticleRow>, AppError> {
    let stmt = if favorite { &FAVORITE } else { &UNFAVORITE };
    db.write().opt(stmt, &[&user, &slug]).await.map_err(AppError::db("set favorite"))
}

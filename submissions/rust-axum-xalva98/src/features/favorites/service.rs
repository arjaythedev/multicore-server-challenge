use super::data;
use crate::error::AppError;
use crate::features::articles::Article;
use crate::AppState;

pub async fn set_favorite(ctx: &AppState, user: i64, slug: &str, favorite: bool) -> Result<Article, AppError> {
    data::set_favorite(&ctx.db, user, slug, favorite).await?.map(Article::from).ok_or(AppError::NotFound)
}

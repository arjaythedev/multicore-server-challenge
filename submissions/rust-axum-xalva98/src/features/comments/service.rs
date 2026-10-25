use super::data;
use super::model::{Comment, CommentList};
use crate::error::AppError;
use crate::AppState;

pub async fn thread(ctx: &AppState, viewer: i64, slug: &str) -> Result<CommentList, AppError> {
    let rows = data::thread(&ctx.db, viewer, slug).await?;
    if rows.is_empty() {
        return Err(AppError::NotFound);
    }
    Ok(CommentList { comments: rows.into_iter().filter_map(|r| r.into_comment()).collect() })
}

pub async fn add(ctx: &AppState, author: i64, slug: &str, body: &str) -> Result<Comment, AppError> {
    data::insert(&ctx.db, author, slug, body).await?.map(Comment::from).ok_or(AppError::NotFound)
}

pub async fn delete(ctx: &AppState, author: i64, slug: &str, id: i64) -> Result<(), AppError> {
    let owner = data::delete_own(&ctx.db, author, slug, id).await?.ok_or(AppError::NotFound)?;
    if owner.author_id != author {
        return Err(AppError::Forbidden);
    }
    Ok(())
}

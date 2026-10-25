use super::data;
use crate::error::AppError;
use crate::AppState;

pub async fn all(ctx: &AppState) -> Result<Vec<String>, AppError> {
    data::all_names(&ctx.db).await
}

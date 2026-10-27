use super::data;
use super::model::Profile;
use crate::error::AppError;
use crate::AppState;

pub async fn profile(ctx: &AppState, viewer: i64, username: &str) -> Result<Profile, AppError> {
    data::profile(&ctx.db, viewer, username).await?.map(Profile::from).ok_or(AppError::NotFound)
}

pub async fn set_following(ctx: &AppState, viewer: i64, username: &str, following: bool) -> Result<Profile, AppError> {
    let row = if following {
        data::follow(&ctx.db, viewer, username).await?
    } else {
        data::unfollow(&ctx.db, viewer, username).await?
    };
    let row = row.ok_or(AppError::NotFound)?;
    Ok(Profile { username: row.username, bio: row.bio, image: row.image, following })
}

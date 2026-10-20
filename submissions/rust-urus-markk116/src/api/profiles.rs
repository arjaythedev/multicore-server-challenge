//! GET /api/profiles/:username, POST/DELETE /api/profiles/:username/follow.

use serde::Serialize;

use super::{AppError, Reply, Req};
use crate::db::{Rows, Stmt};
use crate::model::Profile;
use crate::sql::{FOLLOW, PROFILE, UNFOLLOW};

#[derive(Serialize)]
struct ProfileResponse {
    profile: Profile,
}

fn profile_response(rows: &Rows) -> Result<Reply, AppError> {
    let profile = rows.first()?.ok_or(AppError::NotFound)?;
    Reply::ok(&ProfileResponse { profile })
}

pub fn get(req: &Req) -> Result<Reply, AppError> {
    let viewer = req.viewer()?;
    let username = req.param("username");
    profile_response(&req.db().query(&PROFILE, &[&viewer, &username])?)
}

pub fn follow(req: &Req) -> Result<Reply, AppError> {
    change_follow(req, &FOLLOW)
}

pub fn unfollow(req: &Req) -> Result<Reply, AppError> {
    change_follow(req, &UNFOLLOW)
}

/// The change and the updated profile in one batch; an unknown username changes nothing (404).
fn change_follow(req: &Req, change: &'static Stmt) -> Result<Reply, AppError> {
    let auth = req.auth()?;
    let username = req.param("username");
    let [_, profile] = req.db().batch([(change, &[&auth.id, &username]), (&PROFILE, &[&auth.id, &username])])?;
    profile_response(&profile)
}

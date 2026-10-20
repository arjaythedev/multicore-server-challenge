//! GET/POST /api/articles/:slug/comments, DELETE /api/articles/:slug/comments/:id.

use serde::{Deserialize, Serialize};

use super::{AppError, Reply, Req};
use crate::http::{parse_uint, NonEmpty};
use crate::model::Comment;
use crate::sql::{ARTICLE_EXISTS, COMMENTS, COMMENT_AUTHOR, COMMENT_DELETE, COMMENT_INSERT};

#[derive(Deserialize)]
struct Body {
    comment: NewComment,
}

#[derive(Deserialize)]
struct NewComment {
    body: NonEmpty,
}

#[derive(Serialize)]
struct CommentResponse {
    comment: Comment,
}

#[derive(Serialize)]
struct CommentsResponse {
    comments: Vec<Comment>,
}

pub fn list(req: &Req) -> Result<Reply, AppError> {
    let viewer = req.viewer()?;
    let slug = req.param("slug");
    let [article, comments] = req.db().batch([(&ARTICLE_EXISTS, &[&slug]), (&COMMENTS, &[&viewer, &slug])])?;
    if article.is_empty() {
        return Err(AppError::NotFound);
    }
    Reply::ok(&CommentsResponse { comments: comments.all()? })
}

pub fn create(req: &Req) -> Result<Reply, AppError> {
    let auth = req.auth()?;
    let Body { comment: new } = req.body()?;
    let slug = req.param("slug");
    let rows = req.db().query(&COMMENT_INSERT, &[&slug, &auth.id, &new.body])?;
    let comment = rows.first()?.ok_or(AppError::NotFound)?;
    Reply::created(&CommentResponse { comment })
}

pub fn delete(req: &Req) -> Result<Reply, AppError> {
    let auth = req.auth()?;
    let slug = req.param("slug");
    let id = parse_uint(&req.param("id")).ok_or(AppError::NotFound)?;
    let author: i64 = req.db().query(&COMMENT_AUTHOR, &[&id, &slug])?.first()?.ok_or(AppError::NotFound)?;
    if author != auth.id {
        return Err(AppError::Forbidden);
    }
    req.db().query(&COMMENT_DELETE, &[&id, &slug, &auth.id])?;
    Reply::no_content()
}

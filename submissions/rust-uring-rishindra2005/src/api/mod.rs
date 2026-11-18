//! API layer: routing, admission, validation, JSON rendering, and error responses.
//! Owned by `api`.

pub mod admit;
pub mod errors;
pub mod render;
pub mod routes;

#[cfg(test)]
mod tests;

pub use admit::{admit, Admit};
pub use errors::{
    error_reply, reply_204, reply_401, reply_403, reply_404, reply_404_msg, reply_422, reply_500,
    STATIC_401_CLOSE, STATIC_401_KEEPALIVE, STATIC_404_CLOSE, STATIC_404_KEEPALIVE,
    STATIC_500_CLOSE, STATIC_500_KEEPALIVE,
};
pub use render::{
    escape_json_str, format_pg_timestamp, frame_response, render_article, render_article_list,
    render_article_object, render_comment, render_comment_object, render_comments_list,
    render_errors, render_profile, render_tags, render_user, ArticleRow, CommentRow, ProfileRow,
    UserRow, STATIC_204_CLOSE, STATIC_204_KEEPALIVE,
};
pub use routes::{parse_route, ParsedRoute, RequestParams, RouteError};

/// High-level single-entry request router and admission pipeline.
pub fn parse_and_admit(
    method: &str,
    raw_path: &str,
    body: &[u8],
    viewer: Option<crate::types::Viewer>,
    token: Option<&str>,
    conn: crate::types::ConnRef,
    keepalive: bool,
) -> Admit {
    match routes::parse_route(method, raw_path) {
        Ok(parsed) => admit(
            parsed.route,
            &parsed.params,
            body,
            viewer,
            token,
            conn,
            keepalive,
        ),
        Err(RouteError::NotFound) => Admit::Reply(errors::reply_404(keepalive)),
        Err(RouteError::InvalidCommentId) => {
            Admit::Reply(errors::reply_404_msg("comment id must be an integer", keepalive))
        }
        Err(RouteError::InvalidQuery(msg)) => Admit::Reply(errors::reply_422(msg, keepalive)),
    }
}

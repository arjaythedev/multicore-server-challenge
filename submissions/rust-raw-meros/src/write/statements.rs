//! The prepared statements of a write lane. The SQL lives in `sql/*.sql` (parameters and output shapes are
//! documented in each file's header) and is prepared once per connection, so a write costs one Bind/Execute.

use crate::pg::{Connection, INT8, PgError, Stmt, TEXT, TEXT_ARRAY};

/// One handle per SQL file. A handle works only on the connection that prepared it.
pub struct Statements {
    pub register: Stmt,
    pub update_user: Stmt,
    pub follow: Stmt,
    pub unfollow: Stmt,
    pub insert_article: Stmt,
    pub insert_tags: Stmt,
    pub link_tags: Stmt,
    pub created_article: Stmt,
    pub update_article: Stmt,
    pub delete_article: Stmt,
    pub favorite: Stmt,
    pub unfavorite: Stmt,
    pub add_comment: Stmt,
    pub delete_comment: Stmt,
}

impl Statements {
    /// Prepares every statement (14 round trips, once per connection).
    pub fn prepare(conn: &mut Connection) -> Result<Statements, PgError> {
        Ok(Statements {
            register: conn.prepare(
                "w_register",
                include_str!("sql/register.sql"),
                &[TEXT, TEXT, TEXT],
            )?,
            update_user: conn.prepare(
                "w_update_user",
                include_str!("sql/update_user.sql"),
                &[INT8, TEXT, TEXT, TEXT, TEXT, TEXT],
            )?,
            follow: conn.prepare("w_follow", include_str!("sql/follow.sql"), &[INT8, TEXT])?,
            unfollow: conn.prepare(
                "w_unfollow",
                include_str!("sql/unfollow.sql"),
                &[INT8, TEXT],
            )?,
            insert_article: conn.prepare(
                "w_insert_article",
                include_str!("sql/insert_article.sql"),
                &[TEXT, INT8, TEXT, TEXT, TEXT],
            )?,
            insert_tags: conn.prepare(
                "w_insert_tags",
                include_str!("sql/insert_tags.sql"),
                &[TEXT_ARRAY],
            )?,
            link_tags: conn.prepare(
                "w_link_tags",
                include_str!("sql/link_tags.sql"),
                &[TEXT_ARRAY],
            )?,
            created_article: conn.prepare(
                "w_created_article",
                include_str!("sql/created_article.sql"),
                &[INT8],
            )?,
            update_article: conn.prepare(
                "w_update_article",
                include_str!("sql/update_article.sql"),
                &[TEXT, INT8, TEXT, TEXT, TEXT, TEXT],
            )?,
            delete_article: conn.prepare(
                "w_delete_article",
                include_str!("sql/delete_article.sql"),
                &[TEXT, INT8],
            )?,
            favorite: conn.prepare(
                "w_favorite",
                include_str!("sql/favorite.sql"),
                &[INT8, TEXT],
            )?,
            unfavorite: conn.prepare(
                "w_unfavorite",
                include_str!("sql/unfavorite.sql"),
                &[INT8, TEXT],
            )?,
            add_comment: conn.prepare(
                "w_add_comment",
                include_str!("sql/add_comment.sql"),
                &[TEXT, INT8, TEXT],
            )?,
            delete_comment: conn.prepare(
                "w_delete_comment",
                include_str!("sql/delete_comment.sql"),
                &[INT8, TEXT, INT8],
            )?,
        })
    }
}

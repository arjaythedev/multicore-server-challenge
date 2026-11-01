//! The SQL of the read side: one statement per request kind (plus the shared tag table), prepared once per
//! connection under stable names.
//!
//! Every statement takes arrays (one element per request in the batch) and answers the whole batch, see the header
//! comment of each `.sql` file for the output columns.

use crate::app::jobs::{ListKind, ReadKind};
use crate::pg::{Connection, INT8_ARRAY, PgError, Stmt, TEXT_ARRAY};

/// The groups a batch is split into. `Tags` has no statement of its own: the tag table is fetched whenever any
/// group needs it and the `Tags` requests are answered from it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Group {
    ListAll,
    ListTag,
    ListAuthor,
    ListFavorited,
    Feed,
    Article,
    Comments,
    Profile,
    CurrentUser,
    Login,
    Tags,
}

impl Group {
    pub const COUNT: usize = 11;
    pub const ALL: [Group; Group::COUNT] = [
        Group::ListAll,
        Group::ListTag,
        Group::ListAuthor,
        Group::ListFavorited,
        Group::Feed,
        Group::Article,
        Group::Comments,
        Group::Profile,
        Group::CurrentUser,
        Group::Login,
        Group::Tags,
    ];

    pub fn of(kind: ReadKind) -> Group {
        match kind {
            ReadKind::Tags => Group::Tags,
            ReadKind::CurrentUser => Group::CurrentUser,
            ReadKind::Profile => Group::Profile,
            ReadKind::List(ListKind::All) => Group::ListAll,
            ReadKind::List(ListKind::Tag) => Group::ListTag,
            ReadKind::List(ListKind::Author) => Group::ListAuthor,
            ReadKind::List(ListKind::Favorited) => Group::ListFavorited,
            ReadKind::List(ListKind::Feed) => Group::Feed,
            ReadKind::Article => Group::Article,
            ReadKind::Comments => Group::Comments,
            ReadKind::LoginLookup => Group::Login,
        }
    }

    pub fn index(self) -> usize {
        self as usize
    }

    /// True for the groups whose answer has the "articles" shape and needs the tag table to name tags.
    pub fn is_article_shaped(self) -> bool {
        matches!(
            self,
            Group::ListAll
                | Group::ListTag
                | Group::ListAuthor
                | Group::ListFavorited
                | Group::Feed
                | Group::Article
        )
    }

    /// Does answering this group need the tag table of the batch?
    pub fn needs_tag_table(self) -> bool {
        self.is_article_shaped() || self == Group::Tags
    }

    /// Statement text and parameter types; `None` for `Tags`.
    fn definition(self) -> Option<(&'static str, &'static [u32])> {
        const LIST: &[u32] = &[INT8_ARRAY, INT8_ARRAY, INT8_ARRAY, TEXT_ARRAY];
        const BY_KEY: &[u32] = &[INT8_ARRAY, TEXT_ARRAY];
        Some(match self {
            Group::ListAll => (include_str!("sql/list_all.sql"), LIST),
            Group::ListTag => (include_str!("sql/list_tag.sql"), LIST),
            Group::ListAuthor => (include_str!("sql/list_author.sql"), LIST),
            Group::ListFavorited => (include_str!("sql/list_favorited.sql"), LIST),
            Group::Feed => (include_str!("sql/feed.sql"), LIST),
            Group::Article => (include_str!("sql/article.sql"), BY_KEY),
            Group::Comments => (include_str!("sql/comments.sql"), BY_KEY),
            Group::Profile => (include_str!("sql/profile.sql"), BY_KEY),
            Group::CurrentUser => (include_str!("sql/current_user.sql"), &[INT8_ARRAY]),
            Group::Login => (include_str!("sql/login.sql"), &[TEXT_ARRAY]),
            Group::Tags => return None,
        })
    }

    fn statement_name(self) -> &'static str {
        match self {
            Group::ListAll => "read_list_all",
            Group::ListTag => "read_list_tag",
            Group::ListAuthor => "read_list_author",
            Group::ListFavorited => "read_list_favorited",
            Group::Feed => "read_feed",
            Group::Article => "read_article",
            Group::Comments => "read_comments",
            Group::Profile => "read_profile",
            Group::CurrentUser => "read_current_user",
            Group::Login => "read_login",
            Group::Tags => "read_tags",
        }
    }
}

/// The tag table: id and name of every tag, in name order.
const TAGS_SQL: &str = include_str!("sql/tags.sql");

/// The prepared statements of one connection.
pub struct Statements {
    by_group: [Option<Stmt>; Group::COUNT],
    tags: Stmt,
}

impl Statements {
    /// Prepares everything (one round trip per statement, at connection start).
    pub fn prepare(conn: &mut Connection) -> Result<Statements, PgError> {
        let mut by_group = [None; Group::COUNT];
        for group in Group::ALL {
            if let Some((sql, oids)) = group.definition() {
                by_group[group.index()] = Some(conn.prepare(group.statement_name(), sql, oids)?);
            }
        }
        let tags = conn.prepare(Group::Tags.statement_name(), TAGS_SQL, &[])?;
        Ok(Statements { by_group, tags })
    }

    /// The statement that answers `group`; `None` for `Tags`.
    pub fn of(&self, group: Group) -> Option<&Stmt> {
        self.by_group[group.index()].as_ref()
    }

    pub fn tags(&self) -> &Stmt {
        &self.tags
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn groups_are_dense_and_named_uniquely() {
        for (i, g) in Group::ALL.iter().enumerate() {
            assert_eq!(g.index(), i);
        }
        let mut names: Vec<_> = Group::ALL.iter().map(|g| g.statement_name()).collect();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), Group::COUNT);
    }

    #[test]
    fn every_kind_maps_to_its_group() {
        assert_eq!(Group::of(ReadKind::List(ListKind::Feed)), Group::Feed);
        assert_eq!(Group::of(ReadKind::LoginLookup), Group::Login);
        assert_eq!(Group::of(ReadKind::Tags), Group::Tags);
        assert!(Group::Tags.definition().is_none());
        assert!(Group::Article.is_article_shaped() && !Group::Comments.is_article_shaped());
    }
}

//! Public module surface for the test suites.
//!
//! The edge, behaviour, and integration suites import this module by name, the
//! same way they import `zix`. Keeping the re-exports here means the suites do
//! not reach across the module path with `../../src` imports.

pub const app = @import("app.zig");
pub const clock = @import("clock.zig");
pub const config = @import("config.zig");
pub const db = @import("db.zig");

pub const auth = struct {
    pub const password = @import("auth/password.zig");
    pub const request = @import("auth/request.zig");
    pub const token = @import("auth/token.zig");
};

pub const domain = struct {
    pub const article = @import("domain/article.zig");
    pub const article_input = @import("domain/article_input.zig");
    pub const comment = @import("domain/comment.zig");
    pub const comment_input = @import("domain/comment_input.zig");
    pub const favorite = @import("domain/favorite.zig");
    pub const profile = @import("domain/profile.zig");
    pub const tag = @import("domain/tag.zig");
    pub const user = @import("domain/user.zig");
    pub const user_input = @import("domain/user_input.zig");
};

pub const http = struct {
    pub const article_filter = @import("http/article_filter.zig");
    pub const article_view = @import("http/article_view.zig");
    pub const comment_view = @import("http/comment_view.zig");
    pub const json = @import("http/json.zig");
    pub const paging = @import("http/paging.zig");
    pub const respond = @import("http/respond.zig");
};

pub const handlers = struct {
    pub const api_articles = @import("handlers/api_articles.zig");
    pub const api_articles_feed = @import("handlers/api_articles_feed.zig");
    pub const api_articles_slug = @import("handlers/api_articles_slug.zig");
    pub const api_articles_slug_comments = @import("handlers/api_articles_slug_comments.zig");
    pub const api_articles_slug_comments_id = @import("handlers/api_articles_slug_comments_id.zig");
    pub const api_articles_slug_favorite = @import("handlers/api_articles_slug_favorite.zig");
    pub const api_profiles_username = @import("handlers/api_profiles_username.zig");
    pub const api_profiles_username_follow = @import("handlers/api_profiles_username_follow.zig");
    pub const api_tags = @import("handlers/api_tags.zig");
    pub const api_user = @import("handlers/api_user.zig");
    pub const api_users = @import("handlers/api_users.zig");
    pub const api_users_login = @import("handlers/api_users_login.zig");
};

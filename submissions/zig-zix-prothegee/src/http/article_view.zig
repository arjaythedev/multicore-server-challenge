//! Article domain rows to JSON views.

const std = @import("std");

const json = @import("json.zig");
const article_domain = @import("../domain/article.zig");

// --------------------------------------------------------- //

/// List shapes for a page of articles.
pub fn summaries(
    allocator: std.mem.Allocator,
    articles: []const article_domain.Article,
) ![]json.ArticleSummaryView {
    const views = try allocator.alloc(json.ArticleSummaryView, articles.len);

    for (articles, views) |article, *view| {
        view.* = summary(article);
    }

    return views;
}

/// List shape, without the body.
pub fn summary(article: article_domain.Article) json.ArticleSummaryView {
    return .{
        .slug = article.slug,
        .title = article.title,
        .description = article.description,
        .tagList = article.tag_list.tags,
        .createdAt = article.created_at,
        .updatedAt = article.updated_at,
        .favorited = article.favorited,
        .favoritesCount = article.favorites_count,
        .author = .{
            .username = article.username,
            .bio = article.bio,
            .image = article.image,
            .following = article.following,
        },
    };
}

/// Detail shape, with the body.
pub fn full(article: article_domain.Article) json.ArticleView {
    return .{
        .slug = article.slug,
        .title = article.title,
        .description = article.description,
        .body = article.body,
        .tagList = article.tag_list.tags,
        .createdAt = article.created_at,
        .updatedAt = article.updated_at,
        .favorited = article.favorited,
        .favoritesCount = article.favorites_count,
        .author = .{
            .username = article.username,
            .bio = article.bio,
            .image = article.image,
            .following = article.following,
        },
    };
}

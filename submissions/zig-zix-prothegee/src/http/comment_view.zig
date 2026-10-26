//! Comment domain rows to JSON views.

const std = @import("std");

const json = @import("json.zig");
const comment_domain = @import("../domain/comment.zig");

// --------------------------------------------------------- //

/// List shapes for a page of comments.
pub fn views(
    allocator: std.mem.Allocator,
    comments: []const comment_domain.Comment,
) ![]json.CommentView {
    const shapes = try allocator.alloc(json.CommentView, comments.len);

    for (comments, shapes) |comment, *shape| {
        shape.* = view(comment);
    }

    return shapes;
}

/// One comment shape.
pub fn view(comment: comment_domain.Comment) json.CommentView {
    return .{
        .id = comment.id,
        .body = comment.body,
        .createdAt = comment.created_at,
        .updatedAt = comment.updated_at,
        .author = .{
            .username = comment.username,
            .bio = comment.bio,
            .image = comment.image,
            .following = comment.following,
        },
    };
}

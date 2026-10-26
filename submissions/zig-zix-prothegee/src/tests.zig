//! Unit test root. Ported modules pull in their own inline tests.

test {
    _ = @import("app.zig");
    _ = @import("clock.zig");
    _ = @import("config.zig");
    _ = @import("auth/password.zig");
    _ = @import("auth/request.zig");
    _ = @import("auth/token.zig");
    _ = @import("domain/article_input.zig");
    _ = @import("domain/comment_input.zig");
    _ = @import("domain/user.zig");
    _ = @import("domain/user_input.zig");
    _ = @import("http/article_filter.zig");
    _ = @import("http/json.zig");
    _ = @import("http/paging.zig");
    _ = @import("http/respond.zig");
}

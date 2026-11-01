const std = @import("std");
const catalog = @import("query_catalog");

pub fn main() void {
    std.debug.print("BEGIN comments page\n{s}\nEND\n", .{catalog.details.comments_sql});
    std.debug.print("BEGIN single page\n{s}\nEND\n", .{catalog.details.single_sql});
    inline for (.{ catalog.articles.Family.feed, .all, .tag, .author, .favorited }) |family| {
        std.debug.print("BEGIN {s} page\n{s}\nEND\n", .{ @tagName(family), catalog.pages.statement(family, false) });
        std.debug.print("BEGIN {s} count\n{s}\nEND\n", .{ @tagName(family), catalog.pages.statement(family, true) });
    }
}

const std = @import("std");
const sql = @import("sql.zig");

pub fn main() void {
    inline for (comptime std.meta.fieldNames(sql.Stmt), 0..) |name, i| {
        std.debug.print("-- {s}\n{s};\n", .{ name, sql.defs[i].sql });
        if (sql.bdefs[i]) |b| std.debug.print("-- {s}.batched\n{s};\n", .{ name, b.sql });
    }
}

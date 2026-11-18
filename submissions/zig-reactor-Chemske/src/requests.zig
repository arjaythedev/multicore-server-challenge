const std = @import("std");
const http = @import("http.zig");
const auth = @import("auth.zig");
const pg = @import("postgres.zig");
const bcrypt = @import("bcrypt_pool.zig");
const url = @import("url.zig");
const articles = @import("articles.zig");
const operations = @import("operations.zig");

pub const Recipient = struct { index: usize, generation: u32 };
pub const Task = struct {
    arena: std.heap.ArenaAllocator,
    recipient: Recipient,
    route: http.Route,
    params: [6]?[:0]const u8 = @splat(null),
    param_count: usize = 0,
    token: []const u8 = "",
    job: bcrypt.Job = .{},
    needs_hash: bool = false,
    queued_at: i64 = 0,
    skip_write_batch: bool = false,
    row: ?pg.User = null,
    status: u16 = 503,
    body: ?[]const u8 = null,
    read: ?articles.Read = null,
    operation: ?operations.Operation = null,

    pub fn create(allocator: std.mem.Allocator, request: http.Request, recipient: Recipient, secret: []const u8, now: i64) !*Task {
        const self = try allocator.create(Task);
        self.* = .{ .arena = .init(allocator), .recipient = recipient, .route = request.route };
        errdefer self.destroy(allocator);
        const a = self.arena.allocator();
        const policy = request.route.auth();
        if (policy == .required or (policy == .optional and request.authorization != null)) {
            const identity = auth.verify(a, secret, request.authorization, now) catch return error.Unauthorized;
            if (request.route == .current or request.route == .update) self.token = try a.dupe(u8, identity.token);
            self.params[0] = try std.fmt.allocPrintSentinel(a, "{d}", .{identity.id}, 0);
        } else if (policy == .optional) self.params[0] = "0";
        if (request.route.isOperation()) {
            self.operation = operations.Operation.init(request.route);
            if (request.route != .create_article) self.params[1] = try url.pathSegment(a, request.argument);
            self.param_count = 2;
            if (request.route == .delete_comment) {
                const id = url.pathSegment(a, request.secondary) catch return error.NotFound;
                if (id.len == 0) return error.NotFound;
                for (id) |ch| if (ch < '0' or ch > '9') return error.NotFound;
                const number = std.fmt.parseInt(i64, id, 10) catch return error.NotFound;
                self.params[2] = try std.fmt.allocPrintSentinel(a, "{d}", .{number}, 0);
                self.param_count = 3;
            }
            switch (request.route) {
                .create_article, .update_article, .create_comment => try self.operationBody(request),
                else => {},
            }
            return self;
        }
        if (request.route.isProfile()) {
            self.params[1] = try url.pathSegment(a, request.argument);
            self.param_count = 2;
            return self;
        }
        if (request.route == .article) {
            self.params[1] = try url.pathSegment(a, request.argument);
            self.param_count = 2;
            self.read = .{ .family = .single };
            return self;
        }
        if (request.route == .articles or request.route == .feed) {
            const options = try url.query(a, request.query, request.route == .articles);
            const family: articles.Family = if (request.route == .feed) .feed else switch (options.filter) {
                .all => .all,
                .tag => .tag,
                .author => .author,
                .favorited => .favorited,
            };
            self.read = .{ .family = family };
            self.params[1] = try std.fmt.allocPrintSentinel(a, "{d}", .{options.limit}, 0);
            self.params[2] = try std.fmt.allocPrintSentinel(a, "{d}", .{options.offset}, 0);
            self.param_count = 3;
            if (request.route == .articles and options.value != null) {
                self.params[3] = options.value;
                self.param_count = 4;
            }
            return self;
        }
        if (request.route == .tags) return self;
        if (request.route == .current) {
            self.param_count = 1;
            return self;
        }
        const parsed = std.json.parseFromSlice(std.json.Value, a, request.body, .{ .allocate = .alloc_always }) catch return error.Validation;
        if (parsed.value != .object) return error.Validation;
        const wrapper = parsed.value.object.get("user") orelse return error.Validation;
        if (wrapper != .object) return error.Validation;
        const object = wrapper.object;
        switch (request.route) {
            .register => {
                self.params[0] = try text(a, object, "username", true, false);
                self.params[1] = try text(a, object, "email", true, false);
                try self.password(object, true);
                self.params[2] = &self.job.hash;
                self.param_count = 3;
            },
            .login => {
                self.params[0] = try text(a, object, "email", true, false);
                try self.password(object, true);
                self.needs_hash = false;
                self.job.mode = .verify;
                self.param_count = 1;
            },
            .update => {
                self.params[1] = try text(a, object, "email", false, false);
                self.params[2] = try text(a, object, "username", false, false);
                try self.password(object, false);
                self.params[3] = if (self.needs_hash) &self.job.hash else null;
                self.params[4] = try text(a, object, "bio", false, true);
                self.params[5] = try text(a, object, "image", false, true);
                self.param_count = 6;
            },
            else => unreachable,
        }
        return self;
    }

    fn operationBody(self: *Task, request: http.Request) !void {
        const a = self.arena.allocator();
        const parsed = std.json.parseFromSlice(std.json.Value, a, request.body, .{ .allocate = .alloc_always }) catch return error.Validation;
        if (parsed.value != .object) return error.Validation;
        const key = if (request.route == .create_comment) "comment" else "article";
        const wrapper = parsed.value.object.get(key) orelse return error.Validation;
        if (wrapper != .object) return error.Validation;
        const object = wrapper.object;
        if (request.route == .create_comment) {
            self.params[2] = try text(a, object, "body", true, false);
            self.param_count = 3;
        } else if (request.route == .update_article) {
            self.params[2] = try text(a, object, "title", false, false);
            self.params[3] = try text(a, object, "description", false, false);
            self.params[4] = try text(a, object, "body", false, false);
            self.param_count = 5;
        } else {
            self.params[1] = try text(a, object, "title", true, false);
            self.params[2] = try text(a, object, "description", true, false);
            self.params[3] = try text(a, object, "body", true, false);
            self.params[4] = "[]";
            self.param_count = 5;
            if (object.get("tagList")) |list| {
                if (list == .null) return;
                if (list != .array) return error.Validation;
                for (list.array.items) |value| {
                    if (value != .string or value.string.len == 0 or std.mem.indexOfScalar(u8, value.string, 0) != null) return error.Validation;
                }
                const json = try std.json.Stringify.valueAlloc(a, list, .{});
                self.params[4] = try a.dupeSentinel(u8, json, 0);
                self.operation.?.has_tags = list.array.items.len != 0;
            }
        }
    }

    pub fn send(self: *Task, connection: *pg.Conn) !void {
        if (self.operation) |operation| {
            const q = operation.query(self.params[0..self.param_count]);
            if (operation.kind == .comments) try pg.query(connection, .comments, q.params[0..q.count], null) else try pg.sendOperation(connection, q);
        } else try pg.query(connection, self.route, self.params[0..self.param_count], self.read);
    }

    fn text(a: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8, required: bool, allow_empty: bool) !?[:0]const u8 {
        const value = object.get(key) orelse return if (required) error.Validation else null;
        if (value == .null and !required) return null;
        if (value != .string or (!allow_empty and value.string.len == 0)) return error.Validation;
        // Text parameters cannot carry NUL in PostgreSQL's text protocol.
        if (std.mem.indexOfScalar(u8, value.string, 0) != null) return error.Validation;
        return try a.dupeSentinel(u8, value.string, 0);
    }

    fn password(self: *Task, object: std.json.ObjectMap, required: bool) !void {
        const value = object.get("password") orelse return if (required) error.Validation else {};
        if (value == .null and !required) return;
        if (value != .string or value.string.len == 0) return error.Validation;
        if (self.route != .login and value.string.len > 72) return error.Validation;
        // Match Go bcrypt: reject long new passwords, truncate verification inputs.
        self.job.password_len = @min(value.string.len, self.job.password.len);
        @memcpy(self.job.password[0..self.job.password_len], value.string[0..self.job.password_len]);
        std.crypto.secureZero(u8, @constCast(value.string));
        self.needs_hash = true;
    }

    pub fn userBody(self: *Task, secret: []const u8, now: i64) ![]const u8 {
        const row = self.row.?;
        const a = self.arena.allocator();
        const token = if (self.route == .register or self.route == .login) try auth.issue(a, secret, row.id, now) else self.token;
        return std.json.Stringify.valueAlloc(a, .{ .user = .{
            .email = row.email,
            .token = token,
            .username = row.username,
            .bio = row.bio,
            .image = row.image,
        } }, .{});
    }

    pub fn destroy(self: *Task, allocator: std.mem.Allocator) void {
        std.crypto.secureZero(u8, &self.job.password);
        self.arena.deinit();
        allocator.destroy(self);
    }
};

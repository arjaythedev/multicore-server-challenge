const std = @import("std");
const c = std.c;
const events = @import("events.zig");
const http = @import("http.zig");
const pg = @import("postgres.zig");
const requests = @import("requests.zig");
const bcrypt = @import("bcrypt_pool.zig");

const scheduling = @import("scheduler.zig");
const read_batch = @import("read_batch.zig");
const page_batch = @import("page_batch.zig");
const max_clients = @import("build_options").max_clients;
const reactor_count = @import("build_options").reactors;
const max_tasks = @import("build_options").max_tasks / reactor_count;
const max_input_bytes = 32 * 1024 * 1024 / reactor_count;
const max_output_bytes = 64 * 1024 * 1024 / reactor_count;
const max_input = http.max_head + http.max_body + 4096;
const database_bit: u64 = 1 << 31;
const database_connections = @import("build_options").database_connections;
const write_connections = @import("build_options").write_connections;
const listener_token = 1;
const worker_token = 2;
const Database = struct {
    connection: ?*pg.Conn = null,
    opening: ?pg.Connector = null,
    active: ?*requests.Task = null,
    writer: bool = false,
    active_since: i64 = 0,
    retry_at: i64 = 0,
    retry_delay: i64 = 250,
    generation: u32 = 1,
    fd: c_int = -1,
    followers: [read_batch.capacity - 1]?*requests.Task = @splat(null),
    follower_count: usize = 0,
    read_group: enum { none, article, comments, compact_comments, profiles, pages, favorite_write, favorite_read } = .none,
    batch_failure: enum { none, rolled_back, unusable } = .none,
};
const State = enum { closed, reading, queued, database, hashing, writing };
const Client = struct {
    fd: c_int = -1,
    generation: u32 = 1,
    state: State = .closed,
    input: std.ArrayList(u8) = .empty,
    output: []u8 = &.{},
    sent: usize = 0,
    keep_alive: bool = true,
    task: ?*requests.Task = null,
};

const Server = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    loop: events.Loop,
    listener: c_int,
    databases: []Database,
    database_url: [*:0]const u8,
    clients: []Client,
    pool: *bcrypt.Pool,
    password_owner: usize = 0,
    secret: []const u8,
    scheduler: scheduling.Scheduler,
    task_count: usize = 0,
    input_bytes: usize = 0,
    output_bytes: usize = 0,
    listener_retry_at: i64 = 0,
    reactor_id: usize = 0,
    next_stats: i64 = 0,
    admitted: u64 = 0,
    peak_tasks: usize = 0,
    capacity_rejections: u64 = 0,
    password_rejections: u64 = 0,
    database_failures: u64 = 0,
    responses_503: u64 = 0,
    compact_comment_batches: u64 = 0,
    favorite_batches: u64 = 0,
    favorite_fallbacks: u64 = 0,
    queued_dispatches: u64 = 0,
    queue_wait_ms: u64 = 0,
    max_queue_wait_ms: u64 = 0,
    processing_input: bool = false,

    fn now(self: *Server) i64 {
        return std.Io.Clock.awake.now(self.io).toMilliseconds();
    }

    fn token(self: *Server, index: usize) u64 {
        return (@as(u64, self.clients[index].generation) << 32) | (index + 3);
    }

    fn wallTime(self: *Server) i64 {
        return @divFloor(std.Io.Clock.real.now(self.io).toMilliseconds(), 1000);
    }

    fn releaseTask(self: *Server, task: *requests.Task) void {
        std.debug.assert(self.task_count > 0);
        self.task_count -= 1;
        task.destroy(self.allocator);
    }

    fn closeClient(self: *Server, index: usize) void {
        const client = &self.clients[index];
        if (client.fd < 0) return;
        if (client.task) |task| {
            // Active database work and bcrypt completions retain their own task lifetime.
            if (client.state == .queued) self.releaseTask(task);
        }
        _ = c.close(client.fd);
        self.input_bytes -= client.input.capacity;
        client.input.deinit(self.allocator);
        if (client.output.len != 0) {
            self.output_bytes -= client.output.len;
            self.allocator.free(client.output);
        }
        self.scheduler.release(index);
        client.* = .{ .generation = client.generation +% 1 };
    }

    fn acceptClients(self: *Server) !void {
        // A per-turn budget keeps a burst of new sockets from starving database progress.
        for (0..64) |_| {
            const fd = c.accept(self.listener, null, null);
            if (fd < 0) {
                if (c.errno(fd) == .INTR) continue;
                if (c.errno(fd) == .AGAIN) return;
                if (c.errno(fd) == .MFILE or c.errno(fd) == .NFILE) {
                    try self.loop.watch(self.listener, listener_token, false, false);
                    self.listener_retry_at = self.now() + 250;
                    return;
                }
                return error.Accept;
            }
            const slot = self.scheduler.acquire() orelse {
                _ = c.close(fd);
                continue;
            };
            events.nonblocking(fd) catch {
                _ = c.close(fd);
                self.scheduler.release(slot);
                continue;
            };
            events.noSigpipe(fd) catch {
                _ = c.close(fd);
                self.scheduler.release(slot);
                continue;
            };
            self.clients[slot].fd = fd;
            self.clients[slot].state = .reading;
            self.scheduler.schedule(slot, self.now() + 70_000);
            self.loop.watch(fd, self.token(slot), true, false) catch self.closeClient(slot);
        }
    }

    fn respond(self: *Server, index: usize, status: u16, body: []const u8) !void {
        const client = &self.clients[index];
        if (self.output_bytes + body.len + 256 > max_output_bytes) return error.OutputBudget;
        const reason: []const u8 = switch (status) {
            200 => "OK",
            201 => "Created",
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            404 => "Not Found",
            413 => "Content Too Large",
            422 => "Unprocessable Content",
            431 => "Request Header Fields Too Large",
            505 => "HTTP Version Not Supported",
            else => "Service Unavailable",
        };
        if (status == 503) self.responses_503 += 1;
        client.output = if (status == 204)
            try std.fmt.allocPrint(self.allocator, "HTTP/1.1 204 No Content\r\nConnection: {s}\r\n\r\n", .{if (client.keep_alive) @as([]const u8, "keep-alive") else "close"})
        else
            try std.fmt.allocPrint(self.allocator, "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: {s}\r\n\r\n{s}", .{ status, reason, body.len, if (client.keep_alive) @as([]const u8, "keep-alive") else "close", body });
        self.output_bytes += client.output.len;
        client.sent = 0;
        client.state = .writing;
        self.scheduler.schedule(index, self.now() + 9_000);
        if (@import("build_options").eager_write) {
            try self.writeClient(index);
            if (client.state == .writing) try self.loop.watch(client.fd, self.token(index), false, true);
        } else try self.loop.watch(client.fd, self.token(index), false, true);
    }

    fn processInput(self: *Server, index: usize) anyerror!void {
        // Eager writes can complete while a synchronous error response is being
        // parsed. Drain pipelined input iteratively, never recursively.
        if (self.processing_input) return;
        self.processing_input = true;
        defer self.processing_input = false;
        const client = &self.clients[index];
        while (client.state == .reading) {
            const buffered = client.input.items.len;
            try self.processOneInput(index);
            if (client.input.items.len == buffered) break;
        }
    }

    fn processOneInput(self: *Server, index: usize) !void {
        const client = &self.clients[index];
        switch (http.parse(client.input.items)) {
            .more => {},
            .bad => |status| {
                client.keep_alive = false;
                try self.respond(index, status, "{\"errors\":{\"body\":[\"invalid HTTP request\"]}}");
            },
            .request => |request| {
                client.keep_alive = request.keep_alive;
                // Request fields borrow this buffer. Copy them before compacting pipelined bytes.
                if (request.route == .unknown) {
                    consume(client, request.consumed);
                    try self.respond(index, 404, "{\"errors\":{\"body\":[\"route not implemented\"]}}");
                    return;
                }
                if (self.task_count == max_tasks) {
                    self.capacity_rejections += 1;
                    consume(client, request.consumed);
                    try self.respond(index, 503, "{\"errors\":{\"body\":[\"request capacity full\"]}}");
                    return;
                }
                const task = requests.Task.create(self.allocator, request, .{ .index = index, .generation = client.generation }, self.secret, self.wallTime()) catch |err| {
                    consume(client, request.consumed);
                    if (err == error.InvalidPath) client.keep_alive = false;
                    const status: u16 = if (err == error.Unauthorized) 401 else if (err == error.NotFound) 404 else if (err == error.InvalidPath) 400 else if (err == error.Validation) 422 else 503;
                    try self.respond(index, status, "{\"errors\":{\"body\":[\"invalid request\"]}}");
                    return;
                };
                consume(client, request.consumed);
                self.task_count += 1;
                self.admitted += 1;
                self.peak_tasks = @max(self.peak_tasks, self.task_count);
                client.task = task;
                if (task.needs_hash) self.startHash(task) else self.queue(task);
            },
        }
    }

    fn consume(client: *Client, consumed: usize) void {
        const remaining = client.input.items.len - consumed;
        std.mem.copyForwards(u8, client.input.items[0..remaining], client.input.items[consumed..]);
        std.crypto.secureZero(u8, client.input.items[remaining..]);
        client.input.items.len = remaining;
    }

    fn queue(self: *Server, task: *requests.Task) void {
        const index = task.recipient.index;
        const client = &self.clients[index];
        client.state = .queued;
        task.queued_at = self.now();
        if (write_connections > 0 and isWrite(task.route)) self.scheduler.enqueueWrite(index) else self.scheduler.enqueue(index);
        self.loop.watch(client.fd, self.token(index), false, false) catch self.closeClient(index);
    }

    fn startHash(self: *Server, task: *requests.Task) void {
        task.job.owner = self.password_owner;
        const index = task.recipient.index;
        self.clients[index].state = .hashing;
        self.loop.watch(self.clients[index].fd, self.token(index), false, false) catch {
            self.finish(task, 503, "{\"errors\":{\"body\":[\"worker unavailable\"]}}");
            return;
        };
        if (task.job.mode == .hash) self.io.randomSecure(&task.job.salt) catch {
            self.finish(task, 503, "{\"errors\":{\"body\":[\"random source unavailable\"]}}");
            return;
        };
        if (!self.pool.submit(&task.job)) {
            self.password_rejections += 1;
            self.finish(task, 503, "{\"errors\":{\"body\":[\"password queue full\"]}}");
        }
    }

    fn finish(self: *Server, task: *requests.Task, status: u16, body: []const u8) void {
        defer self.releaseTask(task);
        if (!self.isLive(task)) return;
        const index = task.recipient.index;
        self.clients[index].task = null;
        self.respond(index, status, body) catch self.closeClient(index);
    }

    fn userResponse(self: *Server, task: *requests.Task) void {
        const body = task.userBody(self.secret, self.wallTime()) catch {
            self.finish(task, 503, "{\"errors\":{\"body\":[\"response unavailable\"]}}");
            return;
        };
        self.finish(task, if (task.route == .register) 201 else 200, body);
    }

    fn workerReady(self: *Server) void {
        var completed: [bcrypt.capacity]*bcrypt.Job = undefined;
        const count = self.pool.collectOwner(self.password_owner, &completed);
        for (completed[0..count]) |job| {
            const task: *requests.Task = @fieldParentPtr("job", job);
            if (!self.isLive(task)) {
                self.releaseTask(task);
            } else if (!job.ok) {
                self.finish(task, if (job.mode == .verify) 401 else 503, "{\"errors\":{\"body\":[\"password check failed\"]}}");
            } else if (job.mode == .verify) {
                self.userResponse(task);
            } else self.queue(task);
        }
    }

    fn readClient(self: *Server, index: usize) !void {
        const client = &self.clients[index];
        var buffer: [4096]u8 = undefined;
        for (0..8) |_| {
            const n = c.recv(client.fd, &buffer, buffer.len, 0);
            if (n == 0) {
                self.closeClient(index);
                return;
            }
            if (n < 0) {
                if (c.errno(n) == .INTR) continue;
                if (c.errno(n) == .AGAIN) return;
                self.closeClient(index);
                return;
            }
            const len: usize = @intCast(n);
            if (client.input.items.len + len > max_input) {
                client.keep_alive = false;
                try self.respond(index, 413, "{\"errors\":{\"body\":[\"request buffer limit\"]}}");
                return;
            }
            const capacity = client.input.capacity;
            try client.input.appendSlice(self.allocator, buffer[0..len]);
            self.input_bytes += client.input.capacity - capacity;
            if (self.input_bytes > max_input_bytes) {
                self.closeClient(index);
                return;
            }
            // A partial-request deadline is fixed at its first byte, not extended by trickles.
            if (client.input.items.len == len) self.scheduler.schedule(index, self.now() + 9_000);
            try self.processInput(index);
            if (client.state != .reading) return;
        }
    }

    fn writeClient(self: *Server, index: usize) !void {
        const client = &self.clients[index];
        const n = events.send(client.fd, client.output[client.sent..]);
        if (n < 0) {
            if (c.errno(n) == .AGAIN or c.errno(n) == .INTR) return;
            self.closeClient(index);
            return;
        }
        if (n == 0) {
            self.closeClient(index);
            return;
        }
        client.sent += @intCast(n);
        if (client.sent != client.output.len) return;
        self.output_bytes -= client.output.len;
        self.allocator.free(client.output);
        client.output = &.{};
        if (!client.keep_alive) {
            self.closeClient(index);
            return;
        }
        client.state = .reading;
        self.scheduler.schedule(index, self.now() + @as(i64, if (client.input.items.len == 0) 70_000 else 9_000));
        if (client.input.items.len == 0) {
            self.input_bytes -= client.input.capacity;
            client.input.deinit(self.allocator);
            client.input = .empty;
        }
        try self.loop.watch(client.fd, self.token(index), true, false);
        if (client.input.items.len != 0) try self.processInput(index);
    }

    fn watchDatabase(self: *Server, index: usize, read: bool, write: bool) !void {
        const database = &self.databases[index];
        const conn = database.connection orelse if (database.opening) |opening| opening.conn else return;
        const fd = pg.PQsocket(conn);
        if (fd < 0) return error.DatabaseSocket;
        // libpq can change sockets during connection establishment. Old readiness
        // events must not advance a replacement connection or a reused descriptor.
        if (database.fd != fd) {
            database.fd = fd;
            database.generation +%= 1;
        }
        const tag = (@as(u64, database.generation) << 32) | database_bit | index;
        try self.loop.watch(fd, tag, read, write);
    }

    fn databaseFailed(self: *Server, index: usize) void {
        self.database_failures += 1;
        const database = &self.databases[index];
        if (database.connection) |connection| pg.PQfinish(connection);
        if (database.opening) |opening| pg.PQfinish(opening.conn);
        database.connection = null;
        database.opening = null;
        database.fd = -1;
        database.generation +%= 1;
        database.retry_at = self.now() + database.retry_delay;
        database.retry_delay = @min(database.retry_delay * 2, 5_000);
        self.finishReadFollowers(database, 503, "{\"errors\":{\"body\":[\"database unavailable\"]}}");
        if (database.active) |task| {
            database.active = null;
            // An uncertain write belongs to this failed connection, never the queue.
            self.finish(task, 503, "{\"errors\":{\"body\":[\"database unavailable\"]}}");
        }
    }

    fn finishReadFollowers(self: *Server, database: *Database, status: u16, body: []const u8) void {
        const count = database.follower_count;
        database.follower_count = 0;
        database.read_group = .none;
        for (database.followers[0..count]) |task| self.finish(task.?, status, body);
    }

    fn finishReadGroupTask(self: *Server, task: *requests.Task) void {
        if (!self.isLive(task)) {
            self.releaseTask(task);
        } else if (task.status != 200) {
            self.finish(task, task.status, "{\"errors\":{\"body\":[\"query failed\"]}}");
        } else {
            const body = task.body orelse ((if (task.read) |read| read.json(task.arena.allocator()) else task.operation.?.json(task.arena.allocator())) catch {
                self.finish(task, 503, "{\"errors\":{\"body\":[\"article response unavailable\"]}}");
                return;
            });
            self.finish(task, 200, body);
        }
    }

    fn pageInput(task: *requests.Task) page_batch.Input {
        return .{
            .viewer = task.params[0].?,
            .limit = task.params[1].?,
            .offset = task.params[2].?,
            .key = if (task.read.?.family == .feed) task.params[0].? else task.params[3] orelse "",
        };
    }

    fn sendPageGroup(database: *Database) !void {
        const primary = database.active.?;
        var inputs: [read_batch.capacity]page_batch.Input = undefined;
        inputs[0] = pageInput(primary);
        for (database.followers[0..database.follower_count], 1..) |task, index| inputs[index] = pageInput(task.?);
        try pg.sendPageBatch(database.connection.?, inputs[0 .. database.follower_count + 1], primary.arena.allocator(), primary.read.?.family, primary.read.?.phase == .count);
    }

    fn sendFavoriteGroup(database: *Database, reading: bool) !void {
        const primary = database.active.?;
        var inputs: [read_batch.capacity]read_batch.Input = undefined;
        const count = database.follower_count + 1;
        for (0..count) |index| {
            const task = if (index == 0) primary else database.followers[index - 1].?;
            inputs[index] = .{ .viewer = task.params[0].?, .slug = if (reading) task.operation.?.id orelse "0" else task.params[1].? };
        }
        try pg.sendFavoriteGroup(database.connection.?, inputs[0..count], primary.arena.allocator(), primary.route == .unfavorite, reading);
    }

    fn fallbackFavoriteGroup(self: *Server, database: *Database) void {
        var members: [read_batch.capacity]*requests.Task = undefined;
        members[0] = database.active.?;
        for (database.followers[0..database.follower_count], 1..) |task, index| members[index] = task.?;
        const count = database.follower_count + 1;
        database.active = null;
        database.follower_count = 0;
        database.read_group = .none;
        database.batch_failure = .none;
        self.favorite_fallbacks += 1;
        for (members[0..count]) |task| {
            if (!self.isLive(task)) {
                self.releaseTask(task);
                continue;
            }
            task.skip_write_batch = true;
            task.status = 503;
            self.clients[task.recipient.index].state = .queued;
            if (write_connections > 0) self.scheduler.enqueueWrite(task.recipient.index) else self.scheduler.enqueue(task.recipient.index);
        }
    }

    fn readGroupResult(self: *Server, database: *Database, result: *pg.Result) void {
        _ = self;
        var members: [read_batch.capacity]*requests.Task = undefined;
        members[0] = database.active.?;
        for (database.followers[0..database.follower_count], 1..) |task, index| members[index] = task.?;
        const group = members[0 .. database.follower_count + 1];
        var shared_articles = pg.SharedArticles.init(group[0].arena.allocator());
        defer shared_articles.deinit();
        if (database.read_group == .profiles) {
            for (group, 0..) |task, index| {
                task.body = pg.profileBatchJson(result, index, group.len, task.arena.allocator()) catch {
                    task.status = 503;
                    continue;
                };
                task.status = if (task.body == null) 404 else 200;
            }
            return;
        }
        if (database.read_group == .favorite_write) {
            if (pg.status(result) != 200) {
                database.batch_failure = if (pg.confirmedStatementFailure(result)) .rolled_back else .unusable;
                for (group) |task| task.status = 503;
                return;
            }
            for (group, 0..) |task, index| {
                task.operation.?.id = pg.favoriteTarget(result, index, group.len, task.arena.allocator()) catch {
                    database.batch_failure = .unusable;
                    return;
                };
                task.status = if (task.operation.?.id == null) 404 else 200;
            }
            return;
        }
        if (database.read_group == .favorite_read) {
            pg.checkSingleBatch(result, group.len) catch {
                for (group) |task| task.status = 503;
                return;
            };
            for (group, 0..) |task, index| {
                if (task.status != 200) continue;
                task.operation.?.article = (if (@import("build_options").shared_article_json) shared_articles.rows(result, index, index + 1, true, task.arena.allocator()) else pg.singleBatchRow(result, index, task.arena.allocator())) catch {
                    task.status = 503;
                    continue;
                };
                if (task.operation.?.article.len == 0) task.status = 404;
            }
            return;
        }
        if (database.read_group == .pages) {
            const count = group[0].read.?.phase == .count;
            if (!count and @import("build_options").compact_pages) {
                var decoded = pg.compactPages(result, group.len, group[0].arena.allocator()) catch {
                    for (group) |task| task.status = 503;
                    return;
                };
                defer decoded.deinit();
                for (group, 0..) |task, index| {
                    task.read.?.rows = decoded.rows(index, task.arena.allocator()) catch {
                        task.status = 503;
                        continue;
                    };
                    task.status = 200;
                }
                return;
            }
            var bounds: [read_batch.capacity + 1]usize = undefined;
            pg.readBatchBounds(result, group.len, if (count) 2 else 13, &bounds) catch {
                for (group) |task| task.status = 503;
                return;
            };
            if (count) for (0..group.len) |index| {
                if (bounds[index + 1] != bounds[index] + 1) {
                    for (group) |task| task.status = 503;
                    return;
                }
            };
            for (group, 0..) |task, index| {
                if (count) {
                    if (task.status != 200) continue;
                    task.read.?.count = pg.pageBatchCount(result, bounds[index]) catch {
                        task.status = 503;
                        continue;
                    };
                } else {
                    task.read.?.rows = (if (@import("build_options").shared_article_json) shared_articles.rows(result, bounds[index], bounds[index + 1], false, task.arena.allocator()) else pg.pageBatchRows(result, bounds[index], bounds[index + 1], task.arena.allocator())) catch {
                        task.status = 503;
                        continue;
                    };
                    task.status = 200;
                }
            }
            return;
        }
        if (database.read_group == .compact_comments) {
            var decoded = pg.compactComments(result, group.len, group[0].arena.allocator()) catch {
                for (group) |task| task.status = 503;
                return;
            };
            defer decoded.deinit();
            for (group, 0..) |task, index| {
                const rows = decoded.rows(index, task.arena.allocator()) catch {
                    task.status = 503;
                    continue;
                };
                if (rows) |comments| {
                    task.operation.?.comments = comments;
                    task.status = 200;
                } else task.status = 404;
            }
            return;
        }
        if (database.read_group == .comments) {
            var bounds: [read_batch.capacity + 1]usize = undefined;
            pg.readBatchBounds(result, group.len, 10, &bounds) catch {
                for (group) |task| task.status = 503;
                return;
            };
            for (group, 0..) |task, index| {
                const comments = pg.commentsBatchRows(result, bounds[index], bounds[index + 1], task.arena.allocator()) catch {
                    task.status = 503;
                    continue;
                };
                if (comments) |rows| {
                    task.operation.?.comments = rows;
                    task.status = 200;
                } else task.status = 404;
            }
            return;
        }
        pg.checkSingleBatch(result, group.len) catch {
            for (group) |task| task.status = 503;
            return;
        };
        for (group, 0..) |task, index| {
            task.read.?.rows = (if (@import("build_options").shared_article_json) shared_articles.rows(result, index, index + 1, true, task.arena.allocator()) else pg.singleBatchRow(result, index, task.arena.allocator())) catch {
                task.status = 503;
                continue;
            };
            task.status = if (task.read.?.rows.len == 0) 404 else 200;
        }
    }

    fn maintainDatabases(self: *Server, current: i64) void {
        for (self.databases, 0..) |*database, index| {
            if ((database.active != null and current - database.active_since > 8_000) or
                (database.opening != null and current - database.active_since > 20_000))
            {
                self.databaseFailed(index);
            } else if (database.connection == null and database.opening == null and current >= database.retry_at) {
                database.opening = pg.Connector.start(self.database_url) catch {
                    self.databaseFailed(index);
                    continue;
                };
                database.active_since = current;
                self.watchDatabase(index, false, true) catch self.databaseFailed(index);
            }
        }
    }

    fn isLive(self: *Server, task: *requests.Task) bool {
        const client = self.clients[task.recipient.index];
        return (client.state == .queued or client.state == .database or client.state == .hashing) and
            client.generation == task.recipient.generation and client.task == task;
    }

    fn databaseReady(self: *Server, index: usize, readable: bool) !void {
        const database = &self.databases[index];
        if (database.opening) |*opening| {
            const interest = opening.advance(readable) catch {
                self.databaseFailed(index);
                return;
            };
            if (interest.ready) {
                database.connection = opening.conn;
                database.opening = null;
                database.retry_delay = 250;
                self.watchDatabase(index, true, false) catch self.databaseFailed(index);
            } else self.watchDatabase(index, interest.read, interest.write) catch self.databaseFailed(index);
            return;
        }
        const connection = database.connection orelse return;
        if (readable and pg.PQconsumeInput(connection) != 1) {
            self.databaseFailed(index);
            return;
        }
        const flush = pg.PQflush(connection);
        if (flush < 0) {
            self.databaseFailed(index);
            return;
        }
        self.watchDatabase(index, true, flush == 1) catch {
            self.databaseFailed(index);
            return;
        };
        while (database.active != null and pg.PQisBusy(connection) == 0) {
            const task = database.active.?;
            const result = pg.PQgetResult(connection) orelse {
                // The statement is fully drained, including its transaction completion.
                if (database.read_group != .none) {
                    if (database.read_group == .favorite_write) {
                        // ReadyForQuery must confirm the implicit transaction
                        // ended before either reading back or retrying a rollback.
                        if (pg.PQtransactionStatus(connection) != 0 or database.batch_failure == .unusable) {
                            self.databaseFailed(index);
                            return;
                        }
                        if (database.batch_failure == .rolled_back) {
                            self.fallbackFavoriteGroup(database);
                            return;
                        }
                        var needs_read = task.status == 200 and self.isLive(task);
                        for (database.followers[0..database.follower_count]) |other| needs_read = needs_read or (other.?.status == 200 and self.isLive(other.?));
                        if (needs_read) {
                            database.read_group = .favorite_read;
                            database.active_since = self.now();
                            sendFavoriteGroup(database, true) catch {
                                self.databaseFailed(index);
                                return;
                            };
                            try self.databaseReady(index, false);
                            return;
                        }
                    }
                    if (database.read_group == .pages and task.read.?.phase == .page) {
                        var needs_count = task.status == 200 and self.isLive(task);
                        task.read.?.phase = .count;
                        for (database.followers[0..database.follower_count]) |other| {
                            needs_count = needs_count or (other.?.status == 200 and self.isLive(other.?));
                            other.?.read.?.phase = .count;
                        }
                        if (needs_count) {
                            database.active_since = self.now();
                            sendPageGroup(database) catch {
                                self.databaseFailed(index);
                                return;
                            };
                            try self.databaseReady(index, false);
                            return;
                        }
                    }
                    const count = database.follower_count;
                    database.follower_count = 0;
                    database.read_group = .none;
                    database.active = null;
                    for (database.followers[0..count]) |other| self.finishReadGroupTask(other.?);
                    self.finishReadGroupTask(task);
                    return;
                }
                if (task.operation) |*operation| {
                    if ((operation.stage == .commit or operation.stage == .rollback) and pg.PQtransactionStatus(connection) != 0) {
                        self.databaseFailed(index);
                        return;
                    }
                    if (operation.stage == .rollback and task.status != 200) {
                        self.databaseFailed(index);
                        return;
                    }
                    if (operation.stage == .commit and task.status != 200) operation.transaction = false;
                    // Keep transaction ownership even when the HTTP recipient has gone away.
                    if (operation.advance(task.status)) {
                        task.status = 503;
                        database.active_since = self.now();
                        task.send(connection) catch {
                            self.databaseFailed(index);
                            return;
                        };
                        try self.databaseReady(index, false);
                        return;
                    }
                    task.status = if (operation.http_status >= 400) operation.http_status else 200;
                }
                if (self.isLive(task) and task.status == 200) {
                    if (task.read) |*read| {
                        if (read.family != .single and read.phase == .page) {
                            read.phase = .count;
                            task.status = 503;
                            database.active_since = self.now();
                            task.send(connection) catch {
                                self.databaseFailed(index);
                                return;
                            };
                            try self.databaseReady(index, false);
                            return;
                        }
                    }
                }
                database.active = null;
                if (task.route == .tags) self.finishReadFollowers(database, task.status, if (task.status == 200) task.body.? else "{\"errors\":{\"body\":[\"query failed\"]}}");
                if (!self.isLive(task)) {
                    self.releaseTask(task);
                } else if (task.status != 200) {
                    self.finish(task, task.status, "{\"errors\":{\"body\":[\"query failed\"]}}");
                } else if (task.operation) |operation| {
                    if (operation.http_status == 204) {
                        self.finish(task, 204, "");
                    } else {
                        const body = operation.json(task.arena.allocator()) catch {
                            self.finish(task, 503, "{\"errors\":{\"body\":[\"operation response unavailable\"]}}");
                            return;
                        };
                        self.finish(task, operation.http_status, body);
                    }
                } else if (task.read) |read| {
                    const body = read.json(task.arena.allocator()) catch {
                        self.finish(task, 503, "{\"errors\":{\"body\":[\"article response unavailable\"]}}");
                        return;
                    };
                    self.finish(task, 200, body);
                } else if (task.route == .tags or task.route.isProfile()) {
                    self.finish(task, 200, task.body.?);
                } else if (task.route == .login) {
                    const hash = task.row.?.hash orelse "";
                    if (hash.len != 60) {
                        self.finish(task, 503, "{\"errors\":{\"body\":[\"invalid stored hash\"]}}");
                    } else {
                        @memcpy(task.job.hash[0..60], hash);
                        self.startHash(task);
                    }
                } else self.userResponse(task);
                return;
            };
            defer pg.PQclear(result);
            if (database.read_group != .none) {
                self.readGroupResult(database, result);
                continue;
            }
            task.status = pg.status(result);
            if (task.status != 200) continue;
            if (task.operation) |*operation| {
                task.status = pg.operationResult(result, operation, task.arena.allocator()) catch 503;
            } else if (task.read) |*read| {
                if (read.phase == .page) {
                    read.rows = pg.articlePage(result, task.arena.allocator(), read.family == .single) catch {
                        task.status = 503;
                        continue;
                    };
                    if (read.family == .single and read.rows.len == 0) task.status = 404;
                } else read.count = pg.articleCount(result) catch {
                    task.status = 503;
                    continue;
                };
            } else if (task.route == .tags) {
                task.body = pg.tagsJson(result, task.arena.allocator()) catch null;
                if (task.body == null) task.status = 503;
            } else if (task.route.isProfile()) {
                task.body = pg.profileJson(result, task.arena.allocator()) catch {
                    task.status = 503;
                    continue;
                };
                if (task.body == null) task.status = 404;
            } else {
                task.row = pg.user(result, task.arena.allocator(), task.route == .login) catch {
                    task.status = 503;
                    continue;
                };
                if (task.row == null) task.status = 401;
            }
        }
    }

    fn dispatch(self: *Server) !void {
        for (0..64) |_| {
            var selected: ?struct { index: usize, slot: usize, since: i64 } = null;
            var failed = false;
            for (0..if (write_connections > 0) @as(usize, 2) else @as(usize, 1)) |lane| {
                const head = if (lane == 1) self.scheduler.write_head else self.scheduler.head;
                if (head == scheduling.none) continue;
                var available = false;
                for (self.databases, 0..) |database, slot| {
                    if (write_connections > 0 and database.writer != (lane == 1)) continue;
                    if (database.connection == null) continue;
                    available = true;
                    if (database.active != null) continue;
                    const waiting = self.clients[head].task.?;
                    if (selected == null or waiting.queued_at < selected.?.since)
                        selected = .{ .index = head, .slot = slot, .since = waiting.queued_at };
                    break;
                }
                if (!available) {
                    self.scheduler.unqueue(head);
                    self.finish(self.clients[head].task.?, 503, "{\"errors\":{\"body\":[\"database unavailable\"]}}");
                    failed = true;
                }
            }
            const chosen = selected orelse {
                if (failed) continue;
                return;
            };
            const index = chosen.index;
            const slot = chosen.slot;
            const task = self.clients[index].task.?;
            self.scheduler.unqueue(index);
            const queued_ms: u64 = @intCast(@max(0, self.now() - task.queued_at));
            self.queued_dispatches += 1;
            self.queue_wait_ms += queued_ms;
            self.max_queue_wait_ms = @max(self.max_queue_wait_ms, queued_ms);
            const database = &self.databases[slot];
            self.clients[index].state = .database;
            database.active = task;
            database.active_since = self.now();
            if (@import("build_options").favorite_batch and !task.skip_write_batch and (task.route == .favorite or task.route == .unfavorite)) {
                var next = if (write_connections > 0) self.scheduler.write_head else self.scheduler.head;
                var bytes = task.params[0].?.len + task.params[1].?.len;
                for (0..read_batch.lookahead) |_| {
                    if (next == scheduling.none or database.follower_count == database.followers.len) break;
                    const candidate = next;
                    next = self.scheduler.nodes[candidate].next;
                    const other = &self.clients[candidate];
                    if (other.task.?.route != task.route or other.task.?.skip_write_batch) continue;
                    const size = other.task.?.params[0].?.len + other.task.?.params[1].?.len;
                    if (bytes + size > read_batch.max_parameter_bytes) break;
                    bytes += size;
                    self.scheduler.unqueue(candidate);
                    other.state = .database;
                    database.followers[database.follower_count] = other.task;
                    database.follower_count += 1;
                }
                if (database.follower_count != 0) {
                    database.read_group = .favorite_write;
                    database.batch_failure = .none;
                    self.favorite_batches += 1;
                    sendFavoriteGroup(database, false) catch {
                        self.databaseFailed(slot);
                        continue;
                    };
                    try self.databaseReady(slot, false);
                    continue;
                }
            }
            if (@import("build_options").page_batch and task.read != null and task.read.?.family != .single) {
                var next = self.scheduler.head;
                const first = pageInput(task);
                var bytes = first.viewer.len + first.limit.len + first.offset.len + first.key.len;
                for (0..read_batch.lookahead) |_| {
                    if (next == scheduling.none or database.follower_count == database.followers.len) break;
                    const candidate = next;
                    next = self.scheduler.nodes[candidate].next;
                    const other = &self.clients[candidate];
                    if (other.task.?.read == null or other.task.?.read.?.family != task.read.?.family) continue;
                    const input = pageInput(other.task.?);
                    const size = input.viewer.len + input.limit.len + input.offset.len + input.key.len;
                    if (bytes + size > read_batch.max_parameter_bytes) break;
                    bytes += size;
                    self.scheduler.unqueue(candidate);
                    other.state = .database;
                    database.followers[database.follower_count] = other.task;
                    database.follower_count += 1;
                }
                if (database.follower_count != 0) {
                    database.read_group = .pages;
                    sendPageGroup(database) catch {
                        self.databaseFailed(slot);
                        continue;
                    };
                    try self.databaseReady(slot, false);
                    continue;
                }
            }
            if (@import("build_options").tag_batch and task.route == .tags) {
                // Capture only requests already waiting before execution. Nothing
                // is added after dispatch, and no returned data survives the group.
                var next = self.scheduler.head;
                for (0..read_batch.lookahead) |_| {
                    if (next == scheduling.none or database.follower_count == database.followers.len) break;
                    const candidate = next;
                    next = self.scheduler.nodes[candidate].next;
                    const other = &self.clients[candidate];
                    if (other.task.?.route != .tags) continue;
                    self.scheduler.unqueue(candidate);
                    other.state = .database;
                    database.followers[database.follower_count] = other.task;
                    database.follower_count += 1;
                }
            }
            if ((@import("build_options").article_batch and task.route == .article) or (@import("build_options").comments_batch and task.route == .comments) or (@import("build_options").profile_batch and task.route == .profile)) {
                var inputs: [read_batch.capacity]read_batch.Input = undefined;
                inputs[0] = .{ .viewer = task.params[0].?, .slug = task.params[1].? };
                var bytes = inputs[0].viewer.len + inputs[0].slug.len;
                var next = self.scheduler.head;
                for (0..read_batch.lookahead) |_| {
                    if (next == scheduling.none or database.follower_count == database.followers.len) break;
                    const candidate = next;
                    next = self.scheduler.nodes[candidate].next;
                    const other = &self.clients[candidate];
                    if (other.task.?.route != task.route) continue;
                    const input: read_batch.Input = .{ .viewer = other.task.?.params[0].?, .slug = other.task.?.params[1].? };
                    if (bytes + input.viewer.len + input.slug.len > read_batch.max_parameter_bytes) break;
                    bytes += input.viewer.len + input.slug.len;
                    self.scheduler.unqueue(candidate);
                    other.state = .database;
                    database.followers[database.follower_count] = other.task;
                    database.follower_count += 1;
                    inputs[database.follower_count] = input;
                }
                if (database.follower_count != 0) {
                    const compact = @import("build_options").compact_comments and task.route == .comments and read_batch.overlappingComments(inputs[0 .. database.follower_count + 1]);
                    database.read_group = if (task.route == .profile) .profiles else if (compact) .compact_comments else if (task.route == .comments) .comments else .article;
                    if (compact) self.compact_comment_batches += 1;
                    pg.sendReadBatch(database.connection.?, inputs[0 .. database.follower_count + 1], task.arena.allocator(), task.route == .comments, compact, task.route == .profile) catch {
                        self.databaseFailed(slot);
                        continue;
                    };
                } else task.send(database.connection.?) catch {
                    self.databaseFailed(slot);
                    continue;
                };
            } else task.send(database.connection.?) catch {
                self.databaseFailed(slot);
                continue;
            };
            try self.databaseReady(slot, false);
        }
    }

    fn run(self: *Server) !void {
        try self.loop.watch(self.listener, listener_token, true, false);
        try self.loop.watch(self.pool.readPipe(self.password_owner), worker_token, true, false);
        for (0..self.databases.len) |index| try self.watchDatabase(index, true, false);
        var ready: [128]events.Event = undefined;
        while (true) {
            const before = self.now();
            const wait = self.scheduler.waitMilliseconds(before);
            const count = try self.loop.wait(&ready, if (self.listener_retry_at == 0) wait else @min(wait, @as(c_int, @intCast(std.math.clamp(self.listener_retry_at - before, 0, 1000)))));
            for (ready[0..count]) |event| {
                if (event.token == listener_token) {
                    try self.acceptClients();
                    continue;
                }
                if (event.token & database_bit != 0) {
                    const index: usize = @as(u32, @truncate(event.token)) & ~@as(u32, @intCast(database_bit));
                    if (index < self.databases.len and self.databases[index].generation == event.token >> 32) {
                        if (event.failed) self.databaseFailed(index) else try self.databaseReady(index, event.readable);
                    }
                    continue;
                }
                if (event.token == worker_token) {
                    self.workerReady();
                    continue;
                }
                const slot: u32 = @truncate(event.token);
                if (slot < 3) continue;
                const index: usize = slot - 3;
                if (index >= self.clients.len) continue;
                const client = &self.clients[index];
                if (client.state == .closed or client.generation != event.token >> 32) continue;
                if (event.failed) {
                    self.closeClient(index);
                    continue;
                }
                if (event.readable and client.state == .reading) self.readClient(index) catch self.closeClient(index);
                if (event.writable and client.state == .writing) self.writeClient(index) catch self.closeClient(index);
            }
            const current = self.now();
            // Closing a mass of expired sockets is bounded per turn so database
            // and active-client events keep making progress.
            for (0..512) |_| {
                const expired = self.scheduler.expired(current) orelse break;
                self.closeClient(expired);
            }
            if (current >= self.next_stats) {
                const password_stats = self.pool.statsFor(self.password_owner);
                std.log.info("comment_stats id={d} compact_batches={d}", .{ self.reactor_id, self.compact_comment_batches });
                std.log.info("favorite_stats id={d} batches={d} fallbacks={d}", .{ self.reactor_id, self.favorite_batches, self.favorite_fallbacks });
                std.log.info("password_stats id={d} outstanding={d} batches_1={d} batches_2={d} batches_3={d} batches_4={d} lanes={d}", .{ self.reactor_id, password_stats.outstanding, password_stats.batches[0], password_stats.batches[1], password_stats.batches[2], password_stats.batches[3], password_stats.lanes });
                self.next_stats = current + 10_000;
                std.log.info("reactor_stats id={d} admitted={d} active={d} peak={d} capacity_503={d} password_503={d} db_failures={d} responses_503={d} dispatches={d} queue_wait_ms={d} queue_max_ms={d} input_bytes={d} output_bytes={d}", .{ self.reactor_id, self.admitted, self.task_count, self.peak_tasks, self.capacity_rejections, self.password_rejections, self.database_failures, self.responses_503, self.queued_dispatches, self.queue_wait_ms, self.max_queue_wait_ms, self.input_bytes, self.output_bytes });
            }
            self.maintainDatabases(current);
            if (self.listener_retry_at != 0 and current >= self.listener_retry_at) {
                self.listener_retry_at = 0;
                try self.loop.watch(self.listener, listener_token, true, false);
            }
            try self.dispatch();
        }
    }
};

extern "c" fn sysctlbyname([*:0]const u8, ?*anyopaque, ?*usize, ?*const anyopaque, usize) c_int;

fn clientCapacity() !usize {
    var limit: c.rlimit = undefined;
    if (c.getrlimit(.NOFILE, &limit) != 0) return error.FileDescriptorLimit;
    const reserve = database_connections + 32 + reactor_count * 4;
    var desired: usize = max_clients + reserve;
    if (@import("builtin").os.tag == .macos) {
        var kernel_limit: c_int = 0;
        var length: usize = @sizeOf(c_int);
        // Read the existing ceiling; do not change any host/kernel setting.
        if (sysctlbyname("kern.maxfilesperproc", &kernel_limit, &length, null, 0) == 0 and kernel_limit > 0)
            desired = @min(desired, @as(usize, @intCast(kernel_limit)));
    }
    desired = @min(desired, limit.max);
    if (limit.cur < desired) {
        var raised = limit;
        raised.cur = desired;
        if (c.setrlimit(.NOFILE, &raised) == 0) limit = raised;
    }
    const available = @min(desired, limit.cur);
    if (available < reserve + 256) return error.FileDescriptorLimit;
    return @min(max_clients, available - reserve);
}

fn listen(host: []const u8, port: u16) !c_int {
    var address: c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = 0 };
    var parts = std.mem.splitScalar(u8, host, '.');
    var bytes: [4]u8 = undefined;
    for (&bytes) |*byte| byte.* = std.fmt.parseInt(u8, parts.next() orelse return error.InvalidHost, 10) catch return error.InvalidHost;
    if (parts.next() != null) return error.InvalidHost;
    address.addr = @bitCast(bytes);
    const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd < 0) return error.Socket;
    errdefer _ = c.close(fd);
    try events.nonblocking(fd);
    const one: c_int = 1;
    if (c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, &one, @sizeOf(c_int)) < 0) return error.SocketOption;
    if (reactor_count > 1 and c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEPORT, &one, @sizeOf(c_int)) < 0) return error.SocketOption;
    if (c.bind(fd, @ptrCast(&address), @sizeOf(@TypeOf(address))) < 0) return error.Bind;
    if (c.listen(fd, 4096) < 0) return error.Listen;
    return fd;
}

fn isWrite(route: http.Route) bool {
    return switch (route) {
        .register, .update, .follow, .unfollow, .create_article, .update_article, .delete_article, .favorite, .unfavorite, .create_comment, .delete_comment => true,
        else => false,
    };
}

fn share(total: usize, reactor_id: usize) usize {
    return total / reactor_count + @intFromBool(reactor_id < total % reactor_count);
}

const Config = struct { url: [*:0]const u8, secret: []const u8, host: []const u8, port: u16, clients: usize, password_pool: ?*bcrypt.Pool = null };

fn runReactor(config: Config, allocator: std.mem.Allocator, io: std.Io, reactor_id: usize) !void {
    const capacity = share(config.clients, reactor_id);
    const url = config.url;
    const secret = config.secret;
    const host = config.host;
    const port = config.port;
    const clients = try allocator.alloc(Client, capacity);
    defer allocator.free(clients);
    @memset(clients, .{});
    var private_pool: bcrypt.Pool = .{};
    const pool = config.password_pool orelse &private_pool;
    if (config.password_pool == null) try pool.start(io, share(bcrypt.worker_count, reactor_id), share(bcrypt.capacity, reactor_id));
    defer if (config.password_pool == null) {
        pool.stop();
        var completed: [bcrypt.capacity]*bcrypt.Job = undefined;
        const count = pool.collect(&completed);
        for (completed[0..count]) |job| {
            const task: *requests.Task = @fieldParentPtr("job", job);
            task.destroy(allocator);
        }
    };
    var database_storage: [database_connections]Database = @splat(.{});
    const databases = database_storage[0..share(database_connections, reactor_id)];
    defer for (databases) |*database| {
        if (database.connection) |connection| pg.PQfinish(connection);
        if (database.opening) |opening| pg.PQfinish(opening.conn);
        if (database.active) |task| task.destroy(allocator);
        for (database.followers[0..database.follower_count]) |task| task.?.destroy(allocator);
    };
    for (databases, 0..) |*database, index| {
        database.writer = index < share(write_connections, reactor_id);
        database.connection = try pg.connect(url, io);
    }
    var loop = try events.Loop.init();
    defer loop.deinit();
    const listener = try listen(host, port);
    defer _ = c.close(listener);
    var scheduler = try scheduling.Scheduler.init(allocator, capacity);
    defer scheduler.deinit(allocator);
    var server: Server = .{
        .allocator = allocator,
        .io = io,
        .loop = loop,
        .listener = listener,
        .databases = databases,
        .reactor_id = reactor_id,
        .database_url = url,
        .clients = clients,
        .pool = pool,
        .password_owner = if (config.password_pool != null) reactor_id else 0,
        .secret = secret,
        .scheduler = scheduler,
    };
    defer {
        for (0..clients.len) |index| server.closeClient(index);
    }
    std.log.info("reactor {d} thread={d}: all API routes on {s}:{d}; {d} database connections, {d} client slots, {d} bcrypt workers, prepared API queries: {}", .{ reactor_id, std.Thread.getCurrentId(), host, port, databases.len, capacity, (if (config.password_pool != null) bcrypt.worker_count else share(bcrypt.worker_count, reactor_id)), pg.prepared_queries });
    try server.run();
}

fn reactorEntry(config: Config, allocator: std.mem.Allocator, io: std.Io, reactor_id: usize) void {
    runReactor(config, allocator, io, reactor_id) catch |err| {
        std.log.err("reactor {d} failed: {s}", .{ reactor_id, @errorName(err) });
        // A failed reactor fails the process. No worker is silently restarted.
        std.process.exit(1);
    };
}

pub fn main(init: std.process.Init) !void {
    const env = init.minimal.environ;
    const url = env.getPosix("DATABASE_URL") orelse return error.MissingDatabaseUrl;
    const secret = env.getPosix("JWT_SECRET") orelse return error.MissingJwtSecret;
    if (secret.len == 0) return error.EmptyJwtSecret;
    var password_pool: bcrypt.Pool = .{};
    if (@import("build_options").shared_bcrypt) try password_pool.startShared(init.io, bcrypt.worker_count, bcrypt.capacity, reactor_count);
    defer if (@import("build_options").shared_bcrypt) password_pool.stop();
    const config: Config = .{
        .url = url,
        .secret = secret,
        .host = env.getPosix("HOST") orelse "127.0.0.1",
        .port = try std.fmt.parseInt(u16, env.getPosix("PORT") orelse "3000", 10),
        .clients = try clientCapacity(),
        .password_pool = if (@import("build_options").shared_bcrypt) &password_pool else null,
    };
    for (1..reactor_count) |index| {
        const thread = try std.Thread.spawn(.{}, reactorEntry, .{ config, init.gpa, init.io, index });
        thread.detach();
    }
    reactorEntry(config, init.gpa, init.io, 0);
}

test {
    _ = pg;
    _ = scheduling;
    _ = read_batch;
    _ = page_batch;
    _ = http;
    _ = @import("auth.zig");
    _ = bcrypt;
    _ = @import("bcrypt_lanes.zig");
    _ = @import("profiles.zig");
    _ = @import("url.zig");
    _ = @import("articles.zig");
    _ = @import("operations.zig");
}

//! Optional service-wide read drain. SPSC byte rings are shared across fork;
//! pointers carried as tokens are opaque outside the originating HTTP worker.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const Buf = @import("buf.zig").Buf;
const gpa = @import("buf.zig").gpa;

pub const Header = extern struct {
    token: u64 = 0,
    viewer: i64 = 0,
    limit: i32 = 0,
    offset: i32 = 0,
    stmt: u16 = 0,
    kind: u8 = 0,
    format: u8 = 0, // 0 PG reply / staged ask; 1 rendered body / raw SQL ask; 2 failure
    code: u16 = 200,
    more: u16 = 0,
};
const State = struct {
    head: u64 align(64) = 0,
    tail: u64 align(64) = 0,
};

pub const Ring = struct {
    state: *State,
    data: []u8,
    memory: []align(4096) u8,

    pub fn init(cap: usize) !Ring {
        std.debug.assert(std.math.isPowerOfTwo(cap));
        const len = @sizeOf(State) + cap;
        const rc = linux.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED, .ANONYMOUS = true }, -1, 0);
        if (sys.errnoOf(rc) != .SUCCESS) return error.OutOfMemory;
        const p: [*]align(4096) u8 = @ptrFromInt(rc);
        return .{ .state = @ptrCast(p), .data = p[@sizeOf(State)..len], .memory = p[0..len] };
    }

    pub fn deinit(self: Ring) void {
        sys.unmap(self.memory);
    }

    fn write(self: Ring, pos: u64, bytes: []const u8) void {
        const at: usize = @intCast(pos & (self.data.len - 1));
        const n = @min(bytes.len, self.data.len - at);
        @memcpy(self.data[at..][0..n], bytes[0..n]);
        @memcpy(self.data[0 .. bytes.len - n], bytes[n..]);
    }

    fn read(self: Ring, pos: u64, out: []u8) void {
        const at: usize = @intCast(pos & (self.data.len - 1));
        const n = @min(out.len, self.data.len - at);
        @memcpy(out[0..n], self.data[at..][0..n]);
        @memcpy(out[n..], self.data[0 .. out.len - n]);
    }

    pub fn push(self: Ring, header: Header, bytes: []const u8) bool {
        const size = 4 + @sizeOf(Header) + bytes.len;
        const tail = @atomicLoad(u64, &self.state.tail, .monotonic);
        const head = @atomicLoad(u64, &self.state.head, .acquire);
        if (size > self.data.len or tail -% head + size > self.data.len) return false;
        var prefix: [4]u8 = undefined;
        std.mem.writeInt(u32, &prefix, @intCast(size), .little);
        self.write(tail, &prefix);
        self.write(tail +% 4, std.mem.asBytes(&header));
        self.write(tail +% (4 + @sizeOf(Header)), bytes);
        @atomicStore(u64, &self.state.tail, tail +% size, .release);
        return true;
    }

    pub fn pop(self: Ring, out: *Buf, header: *Header) ?[]const u8 {
        const head = @atomicLoad(u64, &self.state.head, .monotonic);
        const tail = @atomicLoad(u64, &self.state.tail, .acquire);
        if (tail == head) return null;
        var prefix: [4]u8 = undefined;
        self.read(head, &prefix);
        const size = std.mem.readInt(u32, &prefix, .little);
        std.debug.assert(size >= 4 + @sizeOf(Header) and size <= self.data.len and size <= tail -% head);
        self.read(head +% 4, std.mem.asBytes(header));
        out.reset();
        // A zero-byte record is still a message, not an optional null slice.
        out.ensure(@max(1, size - 4 - @sizeOf(Header)));
        self.read(head +% (4 + @sizeOf(Header)), out.reserve(size - 4 - @sizeOf(Header)));
        @atomicStore(u64, &self.state.head, head +% size, .release);
        return out.slice();
    }
};

const Pending = struct { header: Header, bytes: []u8, offset: usize = 0 };
pub const Sender = struct {
    pending: std.ArrayList(Pending) = .empty,
    head: usize = 0,
    bytes: usize = 0,

    pub fn send(self: *Sender, ring: Ring, efd: i32, header: Header, bytes: []const u8) void {
        if (self.head >= 1024 and self.head >= self.pending.items.len / 2) {
            const n = self.pending.items.len - self.head;
            std.mem.copyForwards(Pending, self.pending.items[0..n], self.pending.items[self.head..]);
            self.pending.shrinkRetainingCapacity(n);
            self.head = 0;
        }
        // Queue whole messages so chunks of different requests can never interleave.
        self.pending.append(gpa, .{ .header = header, .bytes = gpa.dupe(u8, bytes) catch @panic("out of memory") }) catch @panic("out of memory");
        self.bytes += bytes.len;
        self.flush(ring, efd);
    }

    pub fn flush(self: *Sender, ring: Ring, efd: i32) void {
        var sent = false;
        while (self.head < self.pending.items.len) {
            const p = &self.pending.items[self.head];
            while (true) {
                const n = @min(64 * 1024, p.bytes.len - p.offset);
                var header = p.header;
                header.more = @intFromBool(p.offset + n != p.bytes.len);
                if (!ring.push(header, p.bytes[p.offset..][0..n])) {
                    if (sent) notify(efd);
                    return;
                }
                sent = true;
                p.offset += n;
                if (header.more == 0) break;
            }
            self.bytes -= p.bytes.len;
            gpa.free(p.bytes);
            self.head += 1;
        }
        self.pending.clearRetainingCapacity();
        self.head = 0;
        if (sent) notify(efd);
    }

    pub fn deinit(self: *Sender) void {
        for (self.pending.items[self.head..]) |p| gpa.free(p.bytes);
        self.pending.deinit(gpa);
    }
};

pub const Channel = struct {
    ask: Ring,
    answer: Ring,
    efd: i32,
    ask_sender: Sender = .{}, // HTTP producer only
    answer_sender: Sender = .{}, // drain producer only
    input: Buf = .{}, // per-channel request reassembly in the drain
};

pub const Hub = struct {
    channels: []Channel,
    efd: i32,

    pub fn init(workers: usize) !*Hub {
        const h = try gpa.create(Hub);
        h.* = .{ .channels = try gpa.alloc(Channel, workers), .efd = try eventfd() };
        for (h.channels) |*c| c.* = .{ .ask = try Ring.init(1024 * 1024), .answer = try Ring.init(4 * 1024 * 1024), .efd = try eventfd() };
        return h;
    }

    pub fn blocked(self: *Hub) bool {
        for (self.channels) |*c| if (c.answer_sender.bytes >= 64 * 1024 * 1024) return true;
        return false;
    }
};

fn eventfd() !i32 {
    const rc = linux.eventfd(0, linux.EFD.CLOEXEC);
    if (sys.errnoOf(rc) != .SUCCESS) return error.EventfdFailed;
    return @intCast(rc);
}

pub fn notify(fd: i32) void {
    const one: u64 = 1;
    while (true) {
        const rc = linux.write(fd, std.mem.asBytes(&one), 8);
        if (sys.errnoOf(rc) != .INTR) return; // EAGAIN means a wake is already pending.
    }
}

test "SPSC publication remains ordered across forked address spaces" {
    var ring = try Ring.init(4096);
    defer ring.deinit();
    const child = linux.fork();
    if (sys.errnoOf(child) != .SUCCESS) return error.ForkFailed;
    if (child == 0) {
        _ = linux.prctl(1, @backingInt(linux.SIG.KILL), 0, 0, 0);
        const deadline = sys.nowNs() + 5 * std.time.ns_per_s;
        const bytes: [257]u8 = @splat(0x96);
        for (0..10000) |i| {
            while (!ring.push(.{ .token = i }, &bytes)) {
                if (sys.nowNs() > deadline) linux.exit(2);
            }
        }
        linux.exit(0);
    }
    const pid: i32 = @intCast(child);
    var waited = false;
    var status: i32 = 0;
    defer if (!waited) {
        _ = linux.kill(pid, .KILL);
        _ = linux.waitpid(pid, &status, 0);
    };
    var b: Buf = .{};
    defer b.deinit();
    var header: Header = undefined;
    var next: usize = 0;
    const deadline = sys.nowNs() + 5 * std.time.ns_per_s;
    while (next < 10000) {
        if (ring.pop(&b, &header)) |bytes| {
            try std.testing.expectEqual(@as(u64, next), header.token);
            try std.testing.expectEqual(@as(usize, 257), bytes.len);
            for (bytes) |byte| try std.testing.expectEqual(@as(u8, 0x96), byte);
            next += 1;
        } else if (sys.nowNs() > deadline) return error.Timeout;
    }
    _ = linux.waitpid(pid, &status, 0);
    waited = true;
    try std.testing.expectEqual(@as(i32, 0), status);
}

test "chunked backpressure resumes without interleaving messages" {
    var ring = try Ring.init(128 * 1024);
    defer ring.deinit();
    const fd = try eventfd();
    defer _ = linux.close(fd);
    var sender: Sender = .{};
    defer sender.deinit();
    const payload = try gpa.alloc(u8, 600 * 1024);
    defer gpa.free(payload);
    @memset(payload, 0x69);
    sender.send(ring, fd, .{ .token = 1 }, payload);
    sender.send(ring, fd, .{ .token = 2 }, "tail");
    try std.testing.expect(sender.bytes != 0);
    var received: Buf = .{};
    defer received.deinit();
    var input: Buf = .{};
    defer input.deinit();
    var header: Header = undefined;
    var finished: usize = 0;
    while (finished != 2) {
        while (ring.pop(&input, &header)) |bytes| {
            try std.testing.expectEqual(@as(u64, finished + 1), header.token);
            received.putSlice(bytes);
            if (header.more == 0) {
                try std.testing.expectEqualSlices(u8, if (finished == 0) payload else "tail", received.slice());
                received.reset();
                finished += 1;
            }
        }
        sender.flush(ring, fd);
    }
    try std.testing.expectEqual(@as(usize, 0), sender.bytes);
}

test "SPSC ring wraps records and counters without exposing partial messages" {
    var r = try Ring.init(4096);
    defer r.deinit();
    var b: Buf = .{};
    defer b.deinit();
    var h: Header = undefined;
    try std.testing.expect(r.push(.{ .token = 42, .stmt = 7, .kind = 9, .code = 404 }, ""));
    try std.testing.expectEqual(@as(usize, 0), r.pop(&b, &h).?.len);
    try std.testing.expectEqual(@as(u64, 42), h.token);
    try std.testing.expectEqual(@as(u16, 7), h.stmt);
    try std.testing.expectEqual(@as(u8, 9), h.kind);
    try std.testing.expectEqual(@as(u16, 0), h.more);
    try std.testing.expectEqual(@as(u16, 404), h.code);
    r.state.head = std.math.maxInt(u64) - 99;
    r.state.tail = r.state.head;
    const data: [1000]u8 = @splat(0xa5);
    for (0..100) |i| {
        try std.testing.expect(r.push(.{ .token = i }, &data));
        try std.testing.expectEqualSlices(u8, &data, r.pop(&b, &h).?);
        try std.testing.expectEqual(@as(u64, i), h.token);
        try std.testing.expect(r.pop(&b, &h) == null);
    }
    for (0..3) |i| try std.testing.expect(r.push(.{ .token = i }, &data));
    try std.testing.expect(!r.push(.{}, &data));
    for (0..3) |i| {
        _ = r.pop(&b, &h).?;
        try std.testing.expectEqual(@as(u64, i), h.token);
    }
}

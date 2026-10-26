//! Memory the worker processes share with the drain process: per worker an ask ring (worker to drain) and an answer
//! ring (drain to worker), and the drain's idle flag. It is mapped once before forking, so every process sees it at
//! the same address.
//!
//! A ring is a single-producer single-consumer queue of byte records. A record is an 8-byte header holding the
//! payload's length, then the payload, padded to 8 bytes. A record never straddles the end of the data: when it does
//! not fit before the end, the producer writes a wrap marker there and the record starts at offset 0. `head` (bytes
//! ever published) and `tail` (bytes ever consumed) only grow, and each sits on its own cache line. Each side keeps
//! its position privately and publishes it with one store, so a batch of records costs each side one atomic store.
const std = @import("std");
const linux = std.os.linux;

const line = std.atomic.cache_line;
const header = 8;
const wrap_marker = std.math.maxInt(u32);

/// A ring's shared positions; its data follows it in the region.
pub const Ring = struct {
    head: std.atomic.Value(u64) align(line) = .init(0),
    tail: std.atomic.Value(u64) align(line) = .init(0),
};

fn recordSize(len: usize) usize {
    return std.mem.alignForward(usize, header + len, header);
}

/// The largest payload a ring of `cap` data bytes always takes once the consumer catches up. A record goes either
/// between the producer's position and the end of the data, or after a wrap marker between the start and that
/// position; the larger of the two is at least half the data, wherever the position is.
fn maxPayload(cap: usize) usize {
    return cap / 2 - header;
}

pub const Producer = struct {
    ring: *Ring,
    data: []u8,
    /// Bytes reserved so far, published or not.
    head: u64 = 0,
    /// The consumer's position when last read; read again only when the ring looks full.
    tail: u64 = 0,

    /// Room for one record of `len` payload bytes, or null while the ring is too full for it. Records reserved since
    /// the last `publish` stay invisible to the consumer until the next one.
    pub fn reserve(p: *Producer, len: usize) ?[]u8 {
        const cap = p.data.len;
        if (len > maxPayload(cap)) @panic("record larger than its ring");
        const need = recordSize(len);
        const at: usize = @intCast(p.head % cap);
        const to_end = cap - at;
        const total = if (need <= to_end) need else to_end + need;
        if (p.head + total - p.tail > cap) {
            p.tail = p.ring.tail.load(.acquire);
            if (p.head + total - p.tail > cap) return null;
        }
        var pos = at;
        if (need > to_end) {
            std.mem.writeInt(u32, p.data[at..][0..4], wrap_marker, .little);
            p.head += to_end;
            pos = 0;
        }
        std.mem.writeInt(u32, p.data[pos..][0..4], @intCast(len), .little);
        p.head += need;
        return p.data[pos + header ..][0..len];
    }

    /// Makes every reserved record visible. Sequentially consistent, so a store that follows it in this process
    /// (the drain's idle flag) is not seen before it.
    pub fn publish(p: *Producer) void {
        p.ring.head.store(p.head, .seq_cst);
    }
};

pub const Consumer = struct {
    ring: *Ring,
    data: []u8,
    /// Bytes consumed so far, released or not.
    tail: u64 = 0,
    /// The producer's position when last read.
    head: u64 = 0,

    /// The next published record's payload, or null when there is none. It stays valid until `release`.
    pub fn next(c: *Consumer) ?[]const u8 {
        if (c.tail == c.head) {
            c.head = c.ring.head.load(.acquire);
            if (c.tail == c.head) return null;
        }
        const cap = c.data.len;
        var at: usize = @intCast(c.tail % cap);
        var len = std.mem.readInt(u32, c.data[at..][0..4], .little);
        if (len == wrap_marker) {
            c.tail += cap - at;
            at = 0;
            len = std.mem.readInt(u32, c.data[0..4], .little);
        }
        c.tail += recordSize(len);
        return c.data[at + header ..][0..len];
    }

    /// Hands the space of every record taken so far back to the producer.
    pub fn release(c: *Consumer) void {
        c.ring.tail.store(c.tail, .seq_cst);
    }

    /// Whether a record is published that `next` has not taken yet. Sequentially consistent, for the drain's check
    /// after it raised its idle flag.
    pub fn pending(c: *Consumer) bool {
        return c.ring.head.load(.seq_cst) != c.tail;
    }
};

/// The mapping and where each ring lies in it. Made before forking; every process holds a copy of this struct.
pub const Region = struct {
    base: []align(std.heap.page_size_min) u8,
    workers: usize,
    ask_cap: usize,
    answer_cap: usize,

    const Flags = struct {
        /// 1 while the drain process sleeps with nothing queued: a worker that publishes an ask then wakes it.
        idle: std.atomic.Value(u32) align(line) = .init(0),
    };

    fn pairSize(r: *const Region) usize {
        return 2 * @sizeOf(Ring) + r.ask_cap + r.answer_cap;
    }

    /// Maps `workers` pairs of rings with `ask_cap` and `answer_cap` data bytes each (multiples of the cache line).
    pub fn map(workers: usize, ask_cap: usize, answer_cap: usize) !Region {
        std.debug.assert(ask_cap % line == 0 and answer_cap % line == 0);
        var r: Region = .{ .base = &.{}, .workers = workers, .ask_cap = ask_cap, .answer_cap = answer_cap };
        const size = std.mem.alignForward(usize, @sizeOf(Flags) + workers * r.pairSize(), std.heap.page_size_min);
        const rc = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED, .ANONYMOUS = true }, -1, 0);
        if (linux.errno(rc) != .SUCCESS) return error.Mmap;
        r.base = @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(rc))[0..size];
        // Anonymous memory starts zeroed, which is every ring empty and the drain not idle.
        return r;
    }

    pub fn idle(r: *const Region) *std.atomic.Value(u32) {
        return &@as(*Flags, @ptrCast(r.base.ptr)).idle;
    }

    fn ringAt(r: *const Region, off: usize, cap: usize) struct { *Ring, []u8 } {
        return .{ @ptrCast(@alignCast(r.base[off..].ptr)), r.base[off + @sizeOf(Ring) ..][0..cap] };
    }

    fn ask(r: *const Region, w: usize) struct { *Ring, []u8 } {
        return r.ringAt(@sizeOf(Flags) + w * r.pairSize(), r.ask_cap);
    }

    fn answer(r: *const Region, w: usize) struct { *Ring, []u8 } {
        return r.ringAt(@sizeOf(Flags) + w * r.pairSize() + @sizeOf(Ring) + r.ask_cap, r.answer_cap);
    }

    pub fn askProducer(r: *const Region, w: usize) Producer {
        const x = r.ask(w);
        return .{ .ring = x[0], .data = x[1] };
    }

    pub fn askConsumer(r: *const Region, w: usize) Consumer {
        const x = r.ask(w);
        return .{ .ring = x[0], .data = x[1] };
    }

    pub fn answerProducer(r: *const Region, w: usize) Producer {
        const x = r.answer(w);
        return .{ .ring = x[0], .data = x[1] };
    }

    pub fn answerConsumer(r: *const Region, w: usize) Consumer {
        const x = r.answer(w);
        return .{ .ring = x[0], .data = x[1] };
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Record `i`'s payload: `i % 300` bytes (zero included), each derived from `i` and its position.
fn fill(buf: []u8, i: u64) void {
    for (buf, 0..) |*b, k| b.* = @truncate(i *% 31 +% k);
}

fn payloadLen(i: u64) usize {
    return @intCast(i % 300);
}

fn expectRecord(got: []const u8, i: u64) !void {
    var want: [300]u8 = undefined;
    fill(want[0..payloadLen(i)], i);
    try testing.expectEqualSlices(u8, want[0..payloadLen(i)], got);
}

const TestRing = struct {
    ring: Ring = .{},
    data: [1024]u8 align(8) = undefined,

    fn ends(t: *TestRing) struct { Producer, Consumer } {
        return .{ .{ .ring = &t.ring, .data = &t.data }, .{ .ring = &t.ring, .data = &t.data } };
    }
};

test "records come out in order, byte for byte, and only once published" {
    var t: TestRing = .{};
    var p, var c = t.ends();
    for (0..5) |i| fill(p.reserve(payloadLen(i)).?, i);
    try testing.expectEqual(null, c.next());
    p.publish();
    for (0..5) |i| try expectRecord(c.next().?, i);
    try testing.expectEqual(null, c.next());
    try testing.expect(!c.pending());
}

test "a record that does not fit before the end starts over at the front" {
    var t: TestRing = .{};
    var p, var c = t.ends();
    // 1000 bytes in, 24 left: a 100-byte record wraps.
    _ = p.reserve(504 - header).?;
    _ = p.reserve(496 - header).?;
    p.publish();
    _ = c.next().?;
    _ = c.next().?;
    c.release();
    fill(p.reserve(payloadLen(100)).?, 100);
    p.publish();
    try expectRecord(c.next().?, 100);
    try testing.expectEqual(1024 + recordSize(100), c.tail);
    try testing.expectEqual(null, c.next());
}

test "a full ring refuses a record until the consumer releases space" {
    var t: TestRing = .{};
    var p, var c = t.ends();
    var n: u64 = 0;
    while (p.reserve(56)) |b| : (n += 1) fill(b, n);
    try testing.expectEqual(16, n);
    p.publish();
    _ = c.next().?;
    try testing.expectEqual(null, p.reserve(56));
    c.release();
    try testing.expect(p.reserve(56) != null);
    try testing.expectEqual(null, p.reserve(0));
}

test "the largest record fits an empty ring wherever the producer stands" {
    var t: TestRing = .{};
    var at: u64 = 0;
    while (at < t.data.len) : (at += header) {
        var p, var c = t.ends();
        t.ring.head.store(at, .seq_cst);
        t.ring.tail.store(at, .seq_cst);
        p.head = at;
        p.tail = at;
        c.head = at;
        c.tail = at;
        try testing.expect(p.reserve(maxPayload(t.data.len)) != null);
        p.publish();
        try testing.expectEqual(maxPayload(t.data.len), c.next().?.len);
    }
}

test "a long stream through a small ring, wrapping and filling at every size" {
    var t: TestRing = .{};
    var p, var c = t.ends();
    var sent: u64 = 0;
    var got: u64 = 0;
    while (got < 5000) {
        while (sent < 5000) : (sent += 1) fill(p.reserve(payloadLen(sent)) orelse break, sent);
        p.publish();
        // Take a few at a time, so the ring is sometimes full and sometimes nearly empty.
        var k: u32 = 0;
        while (k < 3) : (k += 1) {
            try expectRecord(c.next() orelse break, got);
            got += 1;
        }
        c.release();
    }
    try testing.expectEqual(null, c.next());
}

test "records cross a fork: a child process produces, this one consumes" {
    const r = try Region.map(2, 4096, 1024);
    defer _ = linux.munmap(r.base.ptr, r.base.len);
    const total = 20_000;
    const pid = linux.fork();
    if (pid == 0) {
        // The child writes to worker 1's answer ring, so the other rings must stay untouched.
        var p = r.answerProducer(1);
        var i: u64 = 0;
        while (i < total) {
            const b = p.reserve(payloadLen(i)) orelse {
                p.publish();
                _ = linux.sched_yield();
                continue;
            };
            fill(b, i);
            i += 1;
            if (i % 7 == 0) p.publish();
        }
        p.publish();
        r.idle().store(1, .seq_cst);
        linux.exit_group(0);
    }
    var c = r.answerConsumer(1);
    var i: u64 = 0;
    while (i < total) {
        const rec = c.next() orelse {
            c.release();
            _ = linux.sched_yield();
            continue;
        };
        try expectRecord(rec, i);
        i += 1;
    }
    c.release();
    var status: i32 = 0;
    _ = linux.wait4(@intCast(pid), &status, 0, null);
    try testing.expectEqual(0, status);
    try testing.expectEqual(1, r.idle().load(.seq_cst));
    try testing.expectEqual(null, c.next());
    for ([_]Consumer{ r.askConsumer(0), r.askConsumer(1), r.answerConsumer(0) }) |other| {
        var o = other;
        try testing.expectEqual(null, o.next());
    }
}

const std = @import("std");

pub const none = std.math.maxInt(u32);
const Node = struct {
    next: u32 = none,
    previous: u32 = none,
    timer_position: u32 = none,
    deadline: i64 = 0,
    queued: bool = false,
};

// One allocation per index, never one allocation per queue/timer operation.
// Free slots and pending requests are O(1); deadline changes are O(log open).
pub const Scheduler = struct {
    nodes: []Node,
    heap: []u32,
    timer_count: usize = 0,
    free_head: u32,
    head: u32 = none,
    tail: u32 = none,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Scheduler {
        const nodes = try allocator.alloc(Node, capacity);
        errdefer allocator.free(nodes);
        for (nodes, 0..) |*node, i| node.* = .{ .next = if (i + 1 < capacity) @intCast(i + 1) else none };
        return .{ .nodes = nodes, .heap = try allocator.alloc(u32, capacity), .free_head = if (capacity > 0) 0 else none };
    }

    pub fn deinit(self: *Scheduler, allocator: std.mem.Allocator) void {
        allocator.free(self.nodes);
        allocator.free(self.heap);
    }

    pub fn acquire(self: *Scheduler) ?usize {
        if (self.free_head == none) return null;
        const index = self.free_head;
        self.free_head = self.nodes[index].next;
        self.nodes[index] = .{};
        return index;
    }

    pub fn release(self: *Scheduler, index: usize) void {
        self.unqueue(index);
        self.cancel(index);
        self.nodes[index] = .{ .next = self.free_head };
        self.free_head = @intCast(index);
    }

    pub fn enqueue(self: *Scheduler, index: usize) void {
        const node = &self.nodes[index];
        std.debug.assert(!node.queued);
        node.queued = true;
        node.previous = self.tail;
        node.next = none;
        if (self.tail == none) self.head = @intCast(index) else self.nodes[self.tail].next = @intCast(index);
        self.tail = @intCast(index);
    }

    pub fn unqueue(self: *Scheduler, index: usize) void {
        const node = &self.nodes[index];
        if (!node.queued) return;
        if (node.previous == none) self.head = node.next else self.nodes[node.previous].next = node.next;
        if (node.next == none) self.tail = node.previous else self.nodes[node.next].previous = node.previous;
        node.next = none;
        node.previous = none;
        node.queued = false;
    }

    fn swap(self: *Scheduler, a: usize, b: usize) void {
        std.mem.swap(u32, &self.heap[a], &self.heap[b]);
        self.nodes[self.heap[a]].timer_position = @intCast(a);
        self.nodes[self.heap[b]].timer_position = @intCast(b);
    }

    fn earlier(self: *Scheduler, a: usize, b: usize) bool {
        return self.nodes[self.heap[a]].deadline < self.nodes[self.heap[b]].deadline;
    }

    fn up(self: *Scheduler, position: usize) void {
        var child = position;
        while (child > 0) {
            const parent = (child - 1) / 2;
            if (!self.earlier(child, parent)) break;
            self.swap(child, parent);
            child = parent;
        }
    }

    fn down(self: *Scheduler, position: usize) void {
        var parent = position;
        while (parent * 2 + 1 < self.timer_count) {
            var child = parent * 2 + 1;
            if (child + 1 < self.timer_count and self.earlier(child + 1, child)) child += 1;
            if (!self.earlier(child, parent)) break;
            self.swap(child, parent);
            parent = child;
        }
    }

    pub fn schedule(self: *Scheduler, index: usize, deadline: i64) void {
        const node = &self.nodes[index];
        const previous = node.deadline;
        node.deadline = deadline;
        if (node.timer_position == none) {
            const position = self.timer_count;
            self.timer_count += 1;
            self.heap[position] = @intCast(index);
            node.timer_position = @intCast(position);
            self.up(position);
        } else if (deadline < previous) self.up(node.timer_position) else self.down(node.timer_position);
    }

    pub fn cancel(self: *Scheduler, index: usize) void {
        const position = self.nodes[index].timer_position;
        if (position == none) return;
        self.nodes[index].timer_position = none;
        self.timer_count -= 1;
        if (position == self.timer_count) return;
        self.heap[position] = self.heap[self.timer_count];
        self.nodes[self.heap[position]].timer_position = position;
        if (position > 0 and self.earlier(position, (position - 1) / 2)) self.up(position) else self.down(position);
    }

    pub fn expired(self: *Scheduler, now: i64) ?usize {
        if (self.timer_count == 0 or self.nodes[self.heap[0]].deadline > now) return null;
        const index = self.heap[0];
        self.cancel(index);
        return index;
    }

    pub fn waitMilliseconds(self: *Scheduler, now: i64) c_int {
        if (self.timer_count == 0) return 1000;
        return @intCast(std.math.clamp(self.nodes[self.heap[0]].deadline - now, 0, 1000));
    }
};

test "FIFO removal and slot reuse preserve order without stale queue entries" {
    var s = try Scheduler.init(std.testing.allocator, 4);
    defer s.deinit(std.testing.allocator);
    for (0..4) |i| try std.testing.expectEqual(i, s.acquire().?);
    try std.testing.expect(s.acquire() == null);
    for (0..4) |i| s.enqueue(i);
    s.release(1);
    try std.testing.expectEqual(@as(usize, 1), s.acquire().?);
    s.enqueue(1);
    for ([_]u32{ 0, 2, 3, 1 }) |expected| {
        try std.testing.expectEqual(expected, s.head);
        s.unqueue(expected);
    }
    try std.testing.expectEqual(none, s.head);
    try std.testing.expectEqual(none, s.tail);
}

test "indexed deadlines survive arbitrary updates, cancellations and reuse" {
    var s = try Scheduler.init(std.testing.allocator, 128);
    defer s.deinit(std.testing.allocator);
    var expected: [128]?i64 = @splat(null);
    var random = std.Random.DefaultPrng.init(0x5343484544554c45);
    for (0..10_000) |_| {
        const index = random.random().uintLessThan(usize, expected.len);
        if (random.random().boolean()) {
            const deadline: i64 = random.random().uintLessThan(u32, 100_000);
            s.schedule(index, deadline);
            expected[index] = deadline;
        } else {
            s.cancel(index);
            expected[index] = null;
        }
        var minimum: i64 = std.math.maxInt(i64);
        var count: usize = 0;
        for (expected) |value| if (value) |d| {
            minimum = @min(minimum, d);
            count += 1;
        };
        try std.testing.expectEqual(count, s.timer_count);
        if (count > 0) try std.testing.expectEqual(minimum, s.nodes[s.heap[0]].deadline);
        for (s.heap[0..s.timer_count], 0..) |id, position| {
            try std.testing.expectEqual(position, s.nodes[id].timer_position);
            if (position > 0) try std.testing.expect(!s.earlier(position, (position - 1) / 2));
        }
    }
    var previous: i64 = std.math.minInt(i64);
    while (s.expired(std.math.maxInt(i64))) |index| {
        try std.testing.expect(s.nodes[index].deadline >= previous);
        previous = s.nodes[index].deadline;
        expected[index] = null;
    }
    for (expected) |value| try std.testing.expect(value == null);
}

test "one hundred thousand slots retain ordered deadlines and can all be reused" {
    const count = 100_000;
    var s = try Scheduler.init(std.testing.allocator, count);
    defer s.deinit(std.testing.allocator);
    for (0..count) |i| {
        const index = s.acquire().?;
        try std.testing.expectEqual(i, index);
        s.enqueue(index);
        s.schedule(index, @intCast(count - i));
    }
    for (0..count) |i| {
        const index = s.expired(@intCast(i + 1)).?;
        try std.testing.expectEqual(count - i - 1, index);
        s.release(index);
    }
    try std.testing.expectEqual(@as(usize, 0), s.timer_count);
    try std.testing.expectEqual(none, s.head);
    for (0..count) |_| try std.testing.expect(s.acquire() != null);
    try std.testing.expect(s.acquire() == null);
}

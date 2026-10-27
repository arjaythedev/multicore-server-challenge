const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const mac = builtin.os.tag == .macos;

pub const Event = struct { token: u64, readable: bool, writable: bool, failed: bool };

pub const Loop = struct {
    fd: c_int,

    pub fn init() !Loop {
        const fd = if (mac) c.kqueue() else if (builtin.os.tag == .linux) c.epoll_create1(0) else @compileError("macOS and Linux only");
        if (fd < 0) return error.EventLoop;
        return .{ .fd = fd };
    }

    pub fn deinit(self: *Loop) void {
        _ = c.close(self.fd);
    }

    pub fn watch(self: *Loop, fd: c_int, token: u64, read: bool, write: bool) !void {
        if (mac) {
            var changes = [_]c.Kevent{
                .{ .ident = @intCast(fd), .filter = c.EVFILT.READ, .flags = c.EV.ADD | (if (read) @as(u16, c.EV.ENABLE) else c.EV.DISABLE), .fflags = 0, .data = 0, .udata = @intCast(token) },
                .{ .ident = @intCast(fd), .filter = c.EVFILT.WRITE, .flags = c.EV.ADD | (if (write) @as(u16, c.EV.ENABLE) else c.EV.DISABLE), .fflags = 0, .data = 0, .udata = @intCast(token) },
            };
            var unused: [1]c.Kevent = undefined;
            if (c.kevent(self.fd, &changes, changes.len, &unused, 0, null) < 0) return error.EventWatch;
        } else {
            const ep = std.os.linux.EPOLL;
            // A zero-interest epoll registration can still repeatedly report HUP.
            if (!read and !write) {
                if (c.epoll_ctl(self.fd, ep.CTL_DEL, fd, null) < 0 and c.errno(@as(c_int, -1)) != .NOENT) return error.EventWatch;
                return;
            }
            var event: c.epoll_event = .{ .events = (if (read) ep.IN else @as(u32, 0)) | (if (write) ep.OUT else @as(u32, 0)) | ep.RDHUP, .data = .{ .u64 = token } };
            if (c.epoll_ctl(self.fd, ep.CTL_MOD, fd, &event) < 0) {
                if (c.errno(@as(c_int, -1)) != .NOENT or c.epoll_ctl(self.fd, ep.CTL_ADD, fd, &event) < 0) return error.EventWatch;
            }
        }
    }

    pub fn wait(self: *Loop, output: []Event, milliseconds: c_int) !usize {
        if (mac) {
            var raw: [128]c.Kevent = undefined;
            var changes: [1]c.Kevent = undefined;
            const timeout: c.timespec = .{ .sec = @divTrunc(milliseconds, 1000), .nsec = @as(isize, @rem(milliseconds, 1000)) * 1_000_000 };
            const n = c.kevent(self.fd, &changes, 0, &raw, @intCast(@min(raw.len, output.len)), &timeout);
            if (n < 0) {
                if (c.errno(n) == .INTR) return 0;
                return error.EventWait;
            }
            for (raw[0..@intCast(n)], output[0..@intCast(n)]) |e, *out| out.* = .{
                .token = e.udata,
                .readable = e.filter == c.EVFILT.READ,
                .writable = e.filter == c.EVFILT.WRITE,
                .failed = e.flags & c.EV.ERROR != 0,
            };
            return @intCast(n);
        } else {
            var raw: [128]c.epoll_event = undefined;
            const n = c.epoll_wait(self.fd, &raw, @intCast(@min(raw.len, output.len)), milliseconds);
            if (n < 0) {
                if (c.errno(n) == .INTR) return 0;
                return error.EventWait;
            }
            for (raw[0..@intCast(n)], output[0..@intCast(n)]) |e, *out| out.* = .{
                .token = e.data.u64,
                .readable = e.events & (std.os.linux.EPOLL.IN | std.os.linux.EPOLL.RDHUP | std.os.linux.EPOLL.HUP) != 0,
                .writable = e.events & std.os.linux.EPOLL.OUT != 0,
                .failed = e.events & std.os.linux.EPOLL.ERR != 0,
            };
            return @intCast(n);
        }
    }
};

pub fn nonblocking(fd: c_int) !void {
    const old = c.fcntl(fd, c.F.GETFL);
    const flag: u32 = @bitCast(c.O{ .NONBLOCK = true });
    if (old < 0 or c.fcntl(fd, c.F.SETFL, old | @as(c_int, @intCast(flag))) < 0) return error.Nonblocking;
    if (c.fcntl(fd, c.F.SETFD, @as(c_int, 1)) < 0) return error.CloseOnExec;
}

pub fn noSigpipe(fd: c_int) !void {
    if (mac) {
        const one: c_int = 1;
        if (c.setsockopt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, &one, @sizeOf(c_int)) < 0) return error.SocketOption;
    }
}

pub fn send(fd: c_int, bytes: []const u8) isize {
    return c.send(fd, bytes.ptr, bytes.len, if (mac) 0 else c.MSG.NOSIGNAL);
}

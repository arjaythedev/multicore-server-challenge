//! Response writes for the API endpoints.

const std = @import("std");
const zix = @import("zix");

const json = @import("json.zig");

// --------------------------------------------------------- //

/// Room for one rendered user or profile document. Seed bios and images are short.
const BODY_MAX: usize = 8 * 1024;

/// Room for one rendered error document.
const ERROR_BODY_MAX: usize = 256;

// --------------------------------------------------------- //

/// Send a JSON `{"user": ...}` response.
pub fn sendUser(res: *zix.Http1.Response, user: json.UserView, status: zix.Http1.Status.Code) !void {
    var buf: [BODY_MAX]u8 = undefined;

    const len = json.renderUser(&buf, user) catch {
        return sendError(res, .INTERNAL_SERVER_ERROR, "could not render response");
    };

    res.setStatus(status);

    try res.sendJson(buf[0..len]);
}

/// Send a JSON `{"profile": ...}` response.
pub fn sendProfile(res: *zix.Http1.Response, profile: json.ProfileView, status: zix.Http1.Status.Code) !void {
    var buf: [BODY_MAX]u8 = undefined;

    const len = json.renderProfile(&buf, profile) catch {
        return sendError(res, .INTERNAL_SERVER_ERROR, "could not render response");
    };

    res.setStatus(status);

    try res.sendJson(buf[0..len]);
}

/// Send the RealWorld error shape.
pub fn sendError(res: *zix.Http1.Response, status: zix.Http1.Status.Code, message: []const u8) !void {
    var buf: [ERROR_BODY_MAX]u8 = undefined;

    const len = json.renderError(&buf, message) catch {
        res.setStatus(.INTERNAL_SERVER_ERROR);

        try res.sendJson("{\"errors\":{\"body\":[\"internal error\"]}}");
        return;
    };

    res.setStatus(status);

    try res.sendJson(buf[0..len]);
}

// --------------------------------------------------------- //

test "respond: a render failure falls back to an internal error body" {
    // The user buffer cannot hold this document, so sendUser must fall back.
    // This only checks the render step, the socket write is not exercised.
    var buf: [16]u8 = undefined;

    try std.testing.expectError(error.NoSpaceLeft, json.renderUser(&buf, .{
        .email = "ada@example.com",
        .token = "tok",
        .username = "ada",
        .bio = null,
        .image = null,
    }));
}

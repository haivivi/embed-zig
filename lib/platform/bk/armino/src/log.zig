//! Armino SDK Logging
//!
//! Wraps BK_LOGI/BK_LOGW/BK_LOGE via C helper functions.
//! BK_LOG* are variadic C macros that Zig can't call directly.

const std = @import("std");

// C helper functions (defined in bk_zig_helper.c)
extern fn bk_zig_log(tag: [*:0]const u8, msg: [*:0]const u8) void;
extern fn bk_zig_log_int(tag: [*:0]const u8, msg: [*:0]const u8, val: i32) void;
extern fn bk_zig_log_warn(tag: [*:0]const u8, msg: [*:0]const u8) void;
extern fn bk_zig_log_err(tag: [*:0]const u8, msg: [*:0]const u8) void;

/// Log an info message with a tag
pub fn info(tag: [*:0]const u8, msg: [*:0]const u8) void {
    bk_zig_log(tag, msg);
}

/// Log an info message with a tag and integer value
pub fn infoInt(tag: [*:0]const u8, msg: [*:0]const u8, val: i32) void {
    bk_zig_log_int(tag, msg, val);
}

/// Log a warning message with a tag
pub fn warn(tag: [*:0]const u8, msg: [*:0]const u8) void {
    bk_zig_log_warn(tag, msg);
}

/// Log an error message with a tag
pub fn err(tag: [*:0]const u8, msg: [*:0]const u8) void {
    bk_zig_log_err(tag, msg);
}

/// Format a message into a buffer and log it.
/// This is the primary logging function for Zig code.
pub fn logFmt(tag: [*:0]const u8, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(buf[0..255], fmt, args) catch |e| switch (e) {
        error.NoSpaceLeft => blk: {
            buf[255] = 0;
            break :blk buf[0..255];
        },
    };
    buf[msg.len] = 0;
    bk_zig_log(tag, @ptrCast(buf[0..].ptr));
}

/// Format and log a warning
pub fn warnFmt(tag: [*:0]const u8, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(buf[0..255], fmt, args) catch |e| switch (e) {
        error.NoSpaceLeft => blk: {
            buf[255] = 0;
            break :blk buf[0..255];
        },
    };
    buf[msg.len] = 0;
    bk_zig_log_warn(tag, @ptrCast(buf[0..].ptr));
}

/// Format and log an error
pub fn errFmt(tag: [*:0]const u8, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(buf[0..255], fmt, args) catch |e| switch (e) {
        error.NoSpaceLeft => blk: {
            buf[255] = 0;
            break :blk buf[0..255];
        },
    };
    buf[msg.len] = 0;
    bk_zig_log_err(tag, @ptrCast(buf[0..].ptr));
}

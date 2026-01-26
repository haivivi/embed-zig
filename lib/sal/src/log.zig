//! SAL Log - Wrapper around std.log
//!
//! Usage:
//!   const sal = @import("sal");
//!   sal.log.info("Hello {s}", .{"world"});
//!
//! ESP platform: set std_options.logFn in main.zig

const std = @import("std");

pub const Level = std.log.Level;

pub fn err(comptime fmt: []const u8, args: anytype) void {
    std.log.scoped(.app).err(fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    std.log.scoped(.app).warn(fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    std.log.scoped(.app).info(fmt, args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    std.log.scoped(.app).debug(fmt, args);
}

//! std board for e2e trait/log

const std = @import("std");

pub const log = struct {
    pub fn info(comptime fmt: []const u8, args: anytype) void {
        std.debug.print("[INFO] " ++ fmt ++ "\n", args);
    }

    pub fn err(comptime fmt: []const u8, args: anytype) void {
        std.debug.print("[ERR]  " ++ fmt ++ "\n", args);
    }

    pub fn warn(comptime fmt: []const u8, args: anytype) void {
        std.debug.print("[WARN] " ++ fmt ++ "\n", args);
    }

    pub fn debug(comptime fmt: []const u8, args: anytype) void {
        std.debug.print("[DBG]  " ++ fmt ++ "\n", args);
    }
};

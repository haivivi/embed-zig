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

pub const time = struct {
    pub fn sleepMs(ms: u32) void {
        std.time.sleep(ms * std.time.ns_per_ms);
    }
};
